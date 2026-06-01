# Port Monitor

一个轻量端口监控脚本。只需要运行 `install.sh`，即可自动安装 systemd 常驻服务。

功能：

- 每 5 分钟检测一次服务器端口
- 端口失败只提醒一次
- 恢复后发送恢复提醒
- 支持飞书、企业微信、钉钉 webhook
- 支持 Telegram Bot
- 输入 `check` 打开管理菜单

## 安装

```bash
sudo sh install.sh
```

安装完成后会自动启动服务，并设置开机自启。

## 使用

打开管理菜单：

```bash
check
```

备用命令：

```bash
port-monitor check
```

查看服务状态：

```bash
port-monitor status
```

查看实时日志：

```bash
port-monitor logs
```

立即检测一次：

```bash
port-monitor once
```

## 菜单

```text
1. 添加监测服务器
2. 删除监测服务器
3. 配置飞书/企微/钉钉 webhook
4. 配置 Telegram Bot
5. 立即检测一次
6. 一键卸载服务
0. 返回
```

## 卸载

```bash
sudo check
```

然后选择：

```text
6. 一键卸载服务
```

## 安装位置

```text
/opt/port-monitor/app.py
/opt/port-monitor/config.json
/etc/systemd/system/port-monitor.service
/usr/local/bin/port-monitor
/usr/local/bin/check
```

## 上传 GitHub

```bash
git init
git add install.sh README.md
git commit -m "Add port monitor installer"
git branch -M main
git remote add origin https://github.com/你的用户名/你的仓库名.git
git push -u origin main
```
