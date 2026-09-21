# 9NB.DE 每日签到（VPS 版）

三个账号已验证可用。支持 Bark 与 Telegram 通知。

## 部署

```sh
curl -fsSL https://raw.githubusercontent.com/onshine/ScriptHubs/main/9nb-checkin/9nb_checkin_vps.py -o /root/9nb_checkin.py
python3 /root/9nb_checkin.py --add "武则天:密码|LOL:密码|maxwin:密码"
python3 /root/9nb_checkin.py --dry-run
```

## 通知配置

用环境变量配置，不要写进代码。

Bark：

```sh
export BARK_URL="https://api.day.app/你的Key"
```

Telegram：

```sh
export TG_BOT_TOKEN="123456:ABC..."
export TG_CHAT_ID="你的chatid"
```

测试推送：

```sh
python3 /root/9nb_checkin.py --test-notify
```

## 定时任务

Bark：

```cron
5 8 * * * cd /root && BARK_URL="https://api.day.app/你的Key" /usr/bin/python3 /root/9nb_checkin.py --no-jitter >> /root/9nb.log 2>&1
```

Telegram：

```cron
5 8 * * * cd /root && TG_BOT_TOKEN="123:ABC" TG_CHAT_ID="12345" /usr/bin/python3 /root/9nb_checkin.py --no-jitter >> /root/9nb.log 2>&1
```

## 命令行

```
--add 账号:密码        添加账号（可一次多个，用 | 分隔）
--list                列出已保存账号
--del-account 账号     删除账号
--dry-run             只测登录不签到
--no-jitter           账号间不随机等待
--account 账号         只处理指定账号
--test-notify         测试推送
```
