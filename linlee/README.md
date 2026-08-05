# ScriptHubs

Loon / Quantumult X / Surge / Stash 签到与定时脚本合集。

## 目录

| 脚本 | 功能 | 说明 |
|------|------|------|
| [linlee/linlee.js](linlee/linlee.js) | 林里柠檬茶 · 每日签到 + 鸭币兑换 | R11 免维护版，token 临期/失效自动刷新，无需手动开小程序 |

## 林里签到兑换 (linlee)

### 功能
- 每日自动签到领鸭币
- 10 点抢单杯免单券 / 林里鸭游乐园周边（BoxJS 可分别开关）
- **R11 起免维护**：token 保存满 20 小时自动预刷新；签到/兑换途中失效也会自动续期重试，不用再每天手动打开小程序
- Cookie 存 Loon 持久化（`$persistentStore`），抓一次长期有效
- R12 起抓包时自动把 referer/origin 规范为微信小程序指纹，避免隔天 9009「未知的请求来源」

### 原理（为什么 R11 不用手动开小程序）
Loon 的 `http-request` 抓包规则按 URL 匹配，不区分请求来自小程序还是脚本。脚本用旧 token 主动请求商城/签到接口，触发抓包规则重跑 `captureCookie`，丘麦网关下发的新 token 即被合并保存——完成自动续期。

### 安装（Loon）

`[MITM]`
```
hostname = webapi.qmai.cn
```

`[Script]`
```
http-request ^https:\/\/webapi\.qmai\.cn\/web\/(cmk-center\/sign\/(activityInfo|userSignStatistics|userSignRecordCalendar)|catering\/common\/common-info|mall-apiserver\/integral\/(home\/index|item\/goods(\/detail)?)) tag=林里 Cookie, script-path=https://raw.githubusercontent.com/onshine/ScriptHubs/main/linlee/linlee.js, requires-body=true

cron "0 10 * * *" script-path=https://raw.githubusercontent.com/onshine/ScriptHubs/main/linlee/linlee.js, tag=林里签到兑换, timeout=300
```

### 使用
1. 打开「林里」小程序 → 进入签到页，脚本自动抓取 Cookie，通知"凭据获取成功"即可
2. 之后每天 10 点自动签到，token 快过期时脚本自动续期
3. 如需抢 10 点兑换，在 BoxJS（或插件 Argument）里开启对应开关

### BoxJS / Argument 开关

| Key | 默认 | 说明 |
|-----|------|------|
| `linli_task_exchange_coupon` | 关 | 10 点兑换单杯免单券 |
| `linli_task_exchange_toy` | 关 | 10 点兑换林里鸭周边 |
| `linli_refresh_token` | 开 | token 自动刷新（建议保持开启） |
| `linli_debug` | 关 | 调试日志 |
| `linli_clear` | 关 | 置为 true 清除已存 Cookie 重新抓取 |

### 常见问题
- **每天 10 点提示"登录超时"？** R10 及以前版本的已知问题：token 滑动过期约 20~30 小时，正好卡在本次与上次签到之间。升级到 R11 后由脚本自动续期解决。
- **还是提示 Cookie 失效？** 极少数情况下网关拒绝给脚本请求换新 token，此时打开一次林里小程序首页即可（无需进签到页），脚本后续会继续自动维护。

## 许可

仅供学习交流，请勿用于商业用途。脚本原作者 [MaYIHEI](https://github.com/MaYIHEI/paperclip)，本仓库在原文基础上做了稳定性与免维护改造。
