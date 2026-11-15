# 飞飞币每日签到（讯飞 AI 学习机）

R1.0.1 · 每天定时领取讯飞 AI 学习机「飞飞币」签到奖励，通知里直接给**今日状态、连续签到天数、近 7 天打卡图、最近收入明细**。

| 文件 | 说明 |
|---|---|
| `feifei.js` | Loon / Surge / Stash 脚本本体（签到 + 明细 + 通知） |
| `feifei-capture.js` | `http-request` 抓取脚本：打开家长端「飞飞币」页面时自动保存登录凭证 |
| `Feifei.plugin` | Loon 插件（cron 定时 + 抓 Token + MITM），签到时间在 `cronexp` 处改 |
| `feifei.py` | 同一套逻辑的 Python 版，**零第三方依赖**，适合 NAS / 路由器 / VPS / iSH |
| `config.example.json` | Python 版配置模板（真配置 `config.json` 已被 `.gitignore` 忽略） |

---

## 一、Loon 安装（手机自己跑，推荐）

**一键添加插件**（Loon → 配置 → 插件 → 右上角 `+`，粘贴下面地址）：

```
https://raw.githubusercontent.com/onshine/ScriptHubs/main/feifei/Feifei.plugin
```

或直接点这条深链：`loon://import?plugin=https%3A%2F%2Fraw.githubusercontent.com%2Fonshine%2FScriptHubs%2Fmain%2Ffeifei%2FFeifei.plugin`

1. 装好后在插件设置页开启 **MITM**（Loon → 设置 → MitM → 安装证书并信任）。
2. 打开学习机家长端 App 的「飞飞币」页面一次 → 凭证自动写入本地存储（key：`feifei_token`）。
3. 想立刻试一次：插件设置页点「飞飞币签到」→ 运行，通知里应看到今日状态。
4. 参数都在插件设置页里填，不用改文件：

```
token        = Bearer v01_xxx     # 留空=用抓包自动保存的；多账号用 ; 分隔：名字|token;名字2|token2
bark_url     = https://api.day.app/你的Key
tg_bot       = 123:ABC
tg_chat      = 123456789
details      = 5                  # 通知里带几条明细，0=不带
claim_tasks  = false              # true=顺带领取「可领取」状态的任务奖励
```

5. **自定义签到时间**：插件设置页第一项「签到时间」直接改，标准 5 段 cron（分 时 日 月 周）：

| 想实现 | 填 |
|---|---|
| 每天 08:00 | `0 8 * * *` |
| 工作日 07:30 | `30 7 * * 1-5` |
| 每天 8 点和 20 点 | `0 8,20 * * *` |
| 每天 09:15 | `15 9 * * *` |

> 用的是 Loon 官方 v2 Script 语法 `cron ${cron} then script(...)`，
> 所以设置页里改完立即生效，不用动文件。（旧式 `cronexp="..."` 写法在参数化场景下不生效，本插件已按 v2 写法。）

通知长这样：

```
[ 飞飞币 ]
✅ 签到成功 +30 飞飞币
💰 飞飞币：140（今日任务可得 100）
📅 连续签到：2 天
🗓 11-10○  11-11●  11-12●  …  11-16●
📋 最近明细：
   11-16 08:00  +30  签到领飞飞币
   11-15 09:39  +20  完成查看孩子学习记录任务奖励
```

token 过期（接口返回 483）时会推「登录态失效，请用家长端 App 打开一次飞飞币页面以重新抓取 Token」。

---

## 二、Python 安装（有服务器/软路由时更稳）

```bash
# 1) 拿凭证：抓包 HAR 或直接粘贴 Authorization（Bearer v01_…）
python3 feifei.py import --har 抓包.har --name 学习机
python3 feifei.py import --token "Bearer v01_xxxxxxxx..." --name 学习机

# 2) 跑一次
python3 feifei.py sign --details 5
python3 feifei.py info          # 只查询
python3 feifei.py details 20    # 只看明细

# 3) 自定义 cron
python3 feifei.py cron --set "0 8 * * *"
python3 feifei.py cron --show
python3 feifei.py cron --remove
```

`cron --set` 写入的行带 `# feifei-cron` 标记，重复执行只覆盖自己，不动系统其它任务：

```
0 8 * * * /usr/bin/python3 /path/feifei.py sign --details 5 >> /path/feifei.log 2>&1  # feifei-cron 飞飞币每日签到
```

通知在 `config.json` 的 `notify` 段配置，改完用 `python3 feifei.py notify-test` 自测：

```json
"notify": {
  "bark":     { "url": "https://api.day.app/你的Key", "group": "飞飞币" },
  "telegram": { "bot_token": "123:ABC", "chat_id": "123456789" },
  "webhook":  { "url": "", "method": "POST" },
  "only_on_error": false
}
```

- `bark.url` 支持自建服务（自动补 `/push`）
- `webhook` 会 POST `{title, content, text}`，方便接别的推送
- `only_on_error: true` → 只在失败时推

---

## 三、凭证（Token）怎么拿

三种方式，任选：

1. **Loon 抓包**（推荐，插件装好打开一次飞飞币页面就自动存了，过期也能自动续）
2. **HAR 导入**：Stream / Charles / Thor 抓 `api.xunfeixxj.com`，`python3 feifei.py import --har xx.har`
3. **手填**：复制请求头里的 `Authorization`（`Bearer v01_…`，约 60 天有效）

本仓库**不含任何真实凭证**，`config.json` 已在 `.gitignore` 中忽略；日志与通知正文只输出飞飞币相关数据，不打印 Token。

---

## 四、FAQ

**Q：为什么要过 MITM？**
只有 `feifei-capture.js` 抓凭证需要；签到本身是普通 HTTPS 请求。不想开 MITM 就手填 `token`，把插件里的抓 Token 那条 `[Script]` 删掉即可。

**Q：任务奖励要不要自动领？**
默认不领（`claim_tasks = false`）。开启后只会调用接口领取**已经处于「可领取」状态**的任务，不会伪造任务完成。

**Q：签到时间为什么不是 0 点？**
飞飞币签到没有抢名额性质，8 点跑更贴合作息；连签第 7 天奖励更高（接口会如实返回）。改 `cronexp` 或 `--set` 即可。

**Q：iSH / 手机上 cron 不跑？**
iOS 上进程会被挂起，建议用「快捷指令 → 个人自动化（每天 08:00）」或在 Minis 里挂定时任务；软路由/群晖的 cron 不受影响。

**Q：接口返回 483 / 1000 是什么？**
483 = 登录态失效（重抓 Token）；1000 = 参数错误（一般是接口字段变了，提 issue）。

---

## 五、版本记录

### R1.0.1（2026-11-15）
- 插件改用 **Loon 官方 v2 Script 语法**：`cron ${cron} then script(...)`，签到时间在插件设置页可直接改
- 参数改为**位置数组**解析（`script(url, {${a},${b}})`），同时兼容旧的对象写法
- `[Argument]` 补全 `input/switch` 类型、`tag`/`desc` 与示例，MitM 用 `%APPEND%` 不覆盖其它插件
- 插件元信息补 `homepage` / `tag` / `loon_version`

### R1.0.0（2026-11-15）
- 首个版本：每日签到、可选任务奖励领取
- 通知带今日状态 / 飞飞币余额 / 连续签到天数 / 近 7 天打卡图 / 最近收入明细
- Loon 系统通知 + Bark + Telegram；Python 版 Bark + Telegram + 自定义 Webhook
- `feifei-capture.js` 自动抓取凭证；483 登录态失效给出明确提示
- Python 版零依赖，支持 HAR 导入与自定义 crontab

---

仅供学习交流，脚本只操作你自己的账号；凭证等同密码，请勿贴到公开场合。
