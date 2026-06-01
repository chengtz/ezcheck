#!/usr/bin/env sh
set -eu

SERVICE_NAME="port-monitor"
APP_DIR="/opt/port-monitor"
APP_PATH="$APP_DIR/app.py"
BIN_PATH="/usr/local/bin/port-monitor"
CHECK_BIN_PATH="/usr/local/bin/check"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 权限运行：sudo sh install.sh"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "未找到 python3，正在尝试安装..."
  if command -v apt >/dev/null 2>&1; then
    apt update
    apt install -y python3
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3
  else
    echo "无法自动安装 python3，请先手动安装 Python 3。"
    exit 1
  fi
fi

mkdir -p "$APP_DIR"

cat > "$APP_PATH" <<'PYEOF'
import argparse
import json
import os
import shutil
import socket
import subprocess
import threading
import time
import urllib.request
from copy import deepcopy
from datetime import datetime
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
CONFIG_FILE = BASE_DIR / "config.json"
SERVICE_NAME = "port-monitor"
APP_DIR = Path("/opt/port-monitor")
BIN_PATH = Path("/usr/local/bin/port-monitor")
CHECK_BIN_PATH = Path("/usr/local/bin/check")
SERVICE_PATH = Path(f"/etc/systemd/system/{SERVICE_NAME}.service")

DEFAULT_CONFIG = {
    "check_interval_seconds": 300,
    "connect_timeout_seconds": 5,
    "servers": [],
    "notify": {
        "feishu": {"enabled": False, "webhook": ""},
        "wecom": {"enabled": False, "webhook": ""},
        "dingtalk": {"enabled": False, "webhook": ""},
        "telegram": {"enabled": False, "bot_token": "", "chat_id": ""},
    },
}

config_lock = threading.Lock()


def now_text():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def save_config(config):
    with CONFIG_FILE.open("w", encoding="utf-8") as f:
        json.dump(config, f, ensure_ascii=False, indent=2)


def load_config():
    if not CONFIG_FILE.exists():
        save_config(deepcopy(DEFAULT_CONFIG))
        return deepcopy(DEFAULT_CONFIG)

    with CONFIG_FILE.open("r", encoding="utf-8") as f:
        data = json.load(f)

    changed = False
    merged = deepcopy(DEFAULT_CONFIG)
    merged.update(data)
    merged["notify"].update(data.get("notify", {}))

    for key, value in DEFAULT_CONFIG["notify"].items():
        if key not in merged["notify"]:
            merged["notify"][key] = deepcopy(value)
            changed = True

    for server in merged.get("servers", []):
        if "last_status" not in server:
            server["last_status"] = "unknown"
            changed = True
        if "name" not in server:
            server["name"] = f'{server.get("ip", "")}:{server.get("port", "")}'
            changed = True

    if changed:
        save_config(merged)
    return merged


def get_config():
    with config_lock:
        return load_config()


def update_config(mutator):
    with config_lock:
        config = load_config()
        result = mutator(config)
        save_config(config)
        return result


def check_port(host, port, timeout):
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True, ""
    except Exception as exc:
        return False, str(exc)


def post_json(url, payload, timeout=10):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", errors="replace")


def send_feishu(webhook, message):
    return post_json(webhook, {"msg_type": "text", "content": {"text": message}})


def send_wecom(webhook, message):
    return post_json(webhook, {"msgtype": "text", "text": {"content": message}})


def send_dingtalk(webhook, message):
    return post_json(webhook, {"msgtype": "text", "text": {"content": message}})


def send_telegram(bot_token, chat_id, message):
    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    return post_json(url, {"chat_id": chat_id, "text": message})


def send_notification(message):
    config = get_config()
    notify = config.get("notify", {})
    errors = []
    channels = [
        ("飞书", "feishu", lambda item: send_feishu(item["webhook"], message)),
        ("企微", "wecom", lambda item: send_wecom(item["webhook"], message)),
        ("钉钉", "dingtalk", lambda item: send_dingtalk(item["webhook"], message)),
    ]

    for display_name, key, sender in channels:
        item = notify.get(key, {})
        if item.get("enabled") and item.get("webhook"):
            try:
                sender(item)
            except Exception as exc:
                errors.append(f"{display_name}: {exc}")

    telegram = notify.get("telegram", {})
    if telegram.get("enabled") and telegram.get("bot_token") and telegram.get("chat_id"):
        try:
            send_telegram(telegram["bot_token"], telegram["chat_id"], message)
        except Exception as exc:
            errors.append(f"Telegram: {exc}")

    if errors:
        print("通知发送失败：" + " | ".join(errors), flush=True)


def format_status(status):
    return {"ok": "正常", "failed": "失败", "unknown": "未知"}.get(status, status)


def make_message(title, server, detail):
    return (
        f"【{title}】\n"
        f"服务器：{server.get('name') or server['ip']}\n"
        f"地址：{server['ip']}:{server['port']}\n"
        f"时间：{now_text()}\n"
        f"状态：{detail}"
    )


def check_all_servers(verbose=False):
    config = get_config()
    servers = config.get("servers", [])
    timeout = int(config.get("connect_timeout_seconds", 5))

    if not servers:
        if verbose:
            print("暂无监控服务器。")
        return

    results = []
    for server in servers:
        ok, error = check_port(server["ip"], server["port"], timeout)
        new_status = "ok" if ok else "failed"
        old_status = server.get("last_status", "unknown")

        if verbose:
            status_text = "正常" if ok else f"失败（{error}）"
            print(f"- {server.get('name') or server['ip']} {server['ip']}:{server['port']} {status_text}")

        if new_status == "failed" and old_status != "failed":
            send_notification(make_message("端口监控失败", server, "连接失败"))
        if new_status == "ok" and old_status == "failed":
            send_notification(make_message("端口监控恢复", server, "连接正常"))

        results.append((server["ip"], server["port"], new_status))

    def mutator(config_to_update):
        for item in config_to_update.get("servers", []):
            for ip, port, status in results:
                if item["ip"] == ip and str(item["port"]) == str(port):
                    item["last_status"] = status

    update_config(mutator)


def background_loop(stop_event):
    print("端口监控服务已启动。手动管理请在终端输入：check", flush=True)
    while not stop_event.is_set():
        try:
            check_all_servers()
        except Exception as exc:
            print(f"[{now_text()}] 检测任务异常：{exc}", flush=True)

        interval = int(get_config().get("check_interval_seconds", 300))
        stop_event.wait(interval)


def print_server_list():
    config = get_config()
    servers = config.get("servers", [])
    print("\n当前正在检测的服务器：")
    if not servers:
        print("暂无监控服务器。")
        return

    for index, server in enumerate(servers, start=1):
        print(
            f"{index}. {server.get('name') or '-'} "
            f"{server['ip']}:{server['port']} "
            f"状态：{format_status(server.get('last_status', 'unknown'))}"
        )


def input_required(prompt):
    while True:
        value = input(prompt).strip()
        if value:
            return value
        print("不能为空，请重新输入。")


def input_port(prompt):
    while True:
        value = input_required(prompt)
        if value.isdigit() and 1 <= int(value) <= 65535:
            return int(value)
        print("端口必须是 1-65535 的数字。")


def add_server():
    print("\n添加监测服务器")
    name = input("请输入服务器名称，可直接回车跳过：").strip()
    ip = input_required("请输入 IP 或域名：")
    port = input_port("请输入端口：")

    def mutator(config):
        for server in config.get("servers", []):
            if server["ip"] == ip and int(server["port"]) == port:
                return False
        config.setdefault("servers", []).append(
            {"name": name or f"{ip}:{port}", "ip": ip, "port": port, "last_status": "unknown"}
        )
        return True

    if update_config(mutator):
        print(f"添加成功：{name or ip} {ip}:{port}")
    else:
        print("该服务器和端口已存在。")


def delete_server():
    config = get_config()
    servers = config.get("servers", [])
    print_server_list()
    if not servers:
        return

    choice = input("\n请输入要删除的序号，输入 0 返回：").strip()
    if choice == "0":
        return
    if not choice.isdigit() or not 1 <= int(choice) <= len(servers):
        print("序号无效。")
        return

    index = int(choice) - 1
    server = servers[index]
    confirm = input(f"确认删除 {server.get('name')} {server['ip']}:{server['port']}？输入 yes 确认：").strip()
    if confirm.lower() != "yes":
        print("已取消。")
        return

    def mutator(config_to_update):
        return config_to_update["servers"].pop(index)

    removed = update_config(mutator)
    print(f"删除成功：{removed.get('name')} {removed['ip']}:{removed['port']}")


def configure_webhook_channel(key, display_name):
    webhook = input_required(f"请输入 {display_name} webhook 地址：")
    if not webhook.startswith(("http://", "https://")):
        print("webhook 地址必须以 http:// 或 https:// 开头。")
        return

    def mutator(config):
        config["notify"][key]["webhook"] = webhook
        config["notify"][key]["enabled"] = True

    update_config(mutator)
    print(f"{display_name} webhook 已保存。")

    if input("是否发送测试消息？yes/no：").strip().lower() == "yes":
        send_notification(f"端口监控测试消息：{display_name} 配置成功，时间 {now_text()}")
        print("测试消息已发送。")


def show_notify_config():
    config = get_config()
    notify = config.get("notify", {})
    print("\n当前通知配置：")
    for key, display_name in [("feishu", "飞书"), ("wecom", "企微"), ("dingtalk", "钉钉")]:
        item = notify.get(key, {})
        status = "已启用" if item.get("enabled") and item.get("webhook") else "未启用"
        print(f"- {display_name}: {status}")

    telegram = notify.get("telegram", {})
    telegram_status = "已启用" if telegram.get("enabled") and telegram.get("bot_token") and telegram.get("chat_id") else "未启用"
    print(f"- Telegram: {telegram_status}")


def configure_webhooks():
    while True:
        print(
            "\n请选择要配置的消息渠道：\n"
            "1. 飞书 webhook\n"
            "2. 企业微信 webhook\n"
            "3. 钉钉 webhook\n"
            "4. 查看当前配置\n"
            "0. 返回"
        )
        choice = input("请输入选项：").strip()
        if choice == "1":
            configure_webhook_channel("feishu", "飞书")
        elif choice == "2":
            configure_webhook_channel("wecom", "企业微信")
        elif choice == "3":
            configure_webhook_channel("dingtalk", "钉钉")
        elif choice == "4":
            show_notify_config()
        elif choice == "0":
            return
        else:
            print("无效选项。")


def configure_telegram():
    print("\n配置 Telegram Bot")
    bot_token = input_required("请输入 Telegram Bot Token：")
    chat_id = input_required("请输入 Chat ID：")

    def mutator(config):
        config["notify"]["telegram"]["bot_token"] = bot_token
        config["notify"]["telegram"]["chat_id"] = chat_id
        config["notify"]["telegram"]["enabled"] = True

    update_config(mutator)
    print("Telegram 配置已保存。")

    if input("是否发送测试消息？yes/no：").strip().lower() == "yes":
        send_telegram(bot_token, chat_id, f"端口监控测试消息：Telegram 配置成功，时间 {now_text()}")
        print("测试消息发送成功。")


def run_command(command):
    return subprocess.run(command, check=False, text=True, capture_output=True)


def remove_file(path):
    try:
        path.unlink()
        print(f"已删除：{path}")
    except FileNotFoundError:
        pass
    except Exception as exc:
        print(f"删除失败 {path}：{exc}")


def uninstall_from_menu():
    print("\n一键卸载服务")
    print("将停止并禁用 systemd 服务，删除服务文件和全局命令。")
    print("如果需要删除 /opt/port-monitor 里的配置和脚本，稍后会单独确认。")

    if os.name != "posix" or not hasattr(os, "geteuid"):
        print("当前系统不支持此卸载功能，请在 Linux 服务器上执行。")
        return
    if os.geteuid() != 0:
        print("权限不足。请使用 sudo check 或 sudo port-monitor check 后再选择此项。")
        return

    confirm = input("确认卸载 port-monitor？输入 yes 继续：").strip().lower()
    if confirm != "yes":
        print("已取消。")
        return

    for command in (["systemctl", "stop", SERVICE_NAME], ["systemctl", "disable", SERVICE_NAME]):
        result = run_command(command)
        if result.returncode != 0 and result.stderr.strip():
            print(result.stderr.strip())

    remove_file(SERVICE_PATH)
    remove_file(BIN_PATH)

    if CHECK_BIN_PATH.exists():
        content = CHECK_BIN_PATH.read_text(encoding="utf-8", errors="ignore")
        if "PORT_MONITOR_CHECK_WRAPPER" in content:
            remove_file(CHECK_BIN_PATH)
        else:
            print(f"检测到 {CHECK_BIN_PATH} 不是本程序创建的命令，已保留。")

    run_command(["systemctl", "daemon-reload"])

    delete_app = input("是否同时删除 /opt/port-monitor 配置和脚本？输入 yes 删除：").strip().lower()
    if delete_app == "yes":
        try:
            shutil.rmtree(APP_DIR)
            print(f"已删除：{APP_DIR}")
        except FileNotFoundError:
            pass
        except Exception as exc:
            print(f"删除失败 {APP_DIR}：{exc}")
    else:
        print(f"已保留配置目录：{APP_DIR}")

    print("卸载完成。")


def menu_loop():
    while True:
        print_server_list()
        print(
            "\n请选择操作：\n"
            "1. 添加监测服务器\n"
            "2. 删除监测服务器\n"
            "3. 配置飞书/企微/钉钉 webhook\n"
            "4. 配置 Telegram Bot\n"
            "5. 立即检测一次\n"
            "6. 一键卸载服务\n"
            "0. 返回"
        )
        choice = input("请输入选项：").strip()
        if choice == "1":
            add_server()
        elif choice == "2":
            delete_server()
        elif choice == "3":
            configure_webhooks()
        elif choice == "4":
            configure_telegram()
        elif choice == "5":
            print("\n开始立即检测：")
            check_all_servers(verbose=True)
        elif choice == "6":
            uninstall_from_menu()
        elif choice == "0":
            return
        else:
            print("无效选项。")


def command_loop(stop_event):
    while not stop_event.is_set():
        try:
            command = input("> ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print("\n正在退出...")
            stop_event.set()
            return

        if command == "check":
            menu_loop()
        elif command in {"exit", "quit"}:
            stop_event.set()
            return
        elif command:
            print("未知命令。输入 check 打开菜单，输入 exit 退出。")


def main():
    parser = argparse.ArgumentParser(description="轻量端口监控脚本")
    parser.add_argument(
        "command",
        nargs="?",
        default="interactive",
        choices=["interactive", "daemon", "menu", "check", "once"],
        help="interactive: 前台运行；daemon: systemd 常驻；menu/check: 打开菜单；once: 立即检测一次",
    )
    args = parser.parse_args()
    load_config()

    if args.command in {"menu", "check"}:
        menu_loop()
        return
    if args.command == "once":
        check_all_servers(verbose=True)
        return

    stop_event = threading.Event()
    worker = threading.Thread(target=background_loop, args=(stop_event,), daemon=True)
    worker.start()

    if args.command == "daemon":
        try:
            while not stop_event.is_set():
                time.sleep(3600)
        except KeyboardInterrupt:
            stop_event.set()
    else:
        print("输入 check 打开管理菜单，输入 exit 退出。")
        command_loop(stop_event)

    worker.join(timeout=2)
    print("程序已退出。")


if __name__ == "__main__":
    main()
PYEOF

chmod 755 "$APP_PATH"

if [ ! -f "$APP_DIR/config.json" ]; then
  cat > "$APP_DIR/config.json" <<'JSONEOF'
{
  "check_interval_seconds": 300,
  "connect_timeout_seconds": 5,
  "servers": [],
  "notify": {
    "feishu": {"enabled": false, "webhook": ""},
    "wecom": {"enabled": false, "webhook": ""},
    "dingtalk": {"enabled": false, "webhook": ""},
    "telegram": {"enabled": false, "bot_token": "", "chat_id": ""}
  }
}
JSONEOF
fi

cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Port Monitor Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/env python3 $APP_PATH daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > "$BIN_PATH" <<EOF
#!/usr/bin/env sh
set -eu

APP_DIR="$APP_DIR"
APP_PATH="$APP_PATH"
SERVICE_NAME="$SERVICE_NAME"

case "\${1:-}" in
  check|menu)
    cd "\$APP_DIR"
    python3 "\$APP_PATH" check
    ;;
  once)
    cd "\$APP_DIR"
    python3 "\$APP_PATH" once
    ;;
  status)
    systemctl status "\$SERVICE_NAME" --no-pager
    ;;
  logs)
    journalctl -u "\$SERVICE_NAME" -f
    ;;
  restart)
    systemctl restart "\$SERVICE_NAME"
    ;;
  stop)
    systemctl stop "\$SERVICE_NAME"
    ;;
  start)
    systemctl start "\$SERVICE_NAME"
    ;;
  *)
    echo "用法：port-monitor {check|once|status|logs|restart|start|stop}"
    echo "  check   打开管理菜单"
    echo "  once    立即检测一次"
    echo "  status  查看服务状态"
    echo "  logs    查看实时日志"
    exit 1
    ;;
esac
EOF

chmod +x "$BIN_PATH"

if [ ! -e "$CHECK_BIN_PATH" ] || grep -q "PORT_MONITOR_CHECK_WRAPPER" "$CHECK_BIN_PATH" 2>/dev/null; then
  cat > "$CHECK_BIN_PATH" <<EOF
#!/usr/bin/env sh
# PORT_MONITOR_CHECK_WRAPPER
exec "$BIN_PATH" check
EOF
  chmod +x "$CHECK_BIN_PATH"
else
  echo "检测到 $CHECK_BIN_PATH 已存在，未覆盖。你仍然可以使用：port-monitor check"
fi

python3 -m py_compile "$APP_PATH"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo "安装完成。"
echo "服务已启动并设置开机自启。"
echo ""
echo "打开主菜单：check"
echo "备用命令：port-monitor check"
echo "查看状态：port-monitor status"
echo "查看日志：port-monitor logs"
echo "一键卸载：sudo check 后选择 6"
