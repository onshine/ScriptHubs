# 9NB.DE 每日签到（VPS 版）

三个账号已验证可用。支持 Bark 与 Telegram 通知。

## 部署

```sh
curl -fsSL https://raw.githubusercontent.com/onshine/ScriptHubs/main/9nb-checkin/9nb_checkin_vps.py -o /root/9nb_checkin.py
python3 /root/9nb_checkin.py --add "user1:密码|user2:密码|user3:密码"
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

## 安全说明

- **不要把真实账号、密码、Bark Key、Bot Token 提交到仓库**。本文档中的 `你的Key`、`123456:ABC...`、`user1` 均为占位符。
- 账号保存在 `~/.9nb_accounts`（权限 600），Cookie 保存在 `~/.9nb_cookies.json`，都不在仓库里。
- 通知凭据通过环境变量传入（`BARK_URL` / `TG_BOT_TOKEN` / `TG_CHAT_ID`），不写入源码。
- 若使用 git 管理部署目录，建议把这些文件加进 `.gitignore`：

```
.9nb_accounts
.9nb_cookies.json
*.log
```

## 实现要点（排错参考）

- 登录 `POST /login` 成功与失败**都是 302**：成功跳 `/` 并下发 `bbs_auth`，失败跳 `/form_error` 并下发 `__form_error`（base64 内含中文原因）。必须**不跟随重定向**才能拿到 `Set-Cookie`。
- 签到页 `GET /nb_checkin` **未登录返回 404**，登录后才是 200 —— 不要把 404 误判为「接口不存在」。
- 签到提交 `POST /nb_checkin`，字段 `_csrf` + `mode=random`（试试手气 1~15 分）或 `mode=fixed`（直接签到 +5 分）。
- 签到响应是 **302 空 body**，拿不到奖励文案，因此奖励金额用**签到前后积分差**回填。
- 判断是否被踢回登录页时，**不能只看 `name="_csrf"`** —— 签到页自己也有该字段，会误判成登录页。应检测密码输入框或 `<title>登录`。
- 解析 `Set-Cookie` 时不能按逗号拆分：多条 Cookie 用逗号分隔，而 `expires=Mon, 21 Sep 2026 ...` 的值本身含逗号，需逐个头解析并只取第一个分号前的 `name=value`。
- 部分 Bark 服务端会以 403 拦截 `Python-urllib` 默认 UA，请求需带浏览器 User-Agent。

