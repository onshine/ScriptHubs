# 车来了 每日签到（Loon）

自动完成车来了 App「**7天连续签**」活动的每日签到，并把奖励结果推送给你。

- 插件：`CheLaiLe_Checkin.plugin`
- 脚本：`chelaile-checkin.js`
- 版本：**R1.0.1**
- 适配：车来了 iOS 7.6.3 ｜ Loon ≥ 3.5.1

---

## 一、原理（基于真实抓包逆向，含在线验证）

车来的签到是 H5 活动页，挂在 `web.chelaile.net.cn` 下：

```
H5 页面   https://web.chelaile.net.cn/app-relate/everyday-sign/index.html
活动配置  GET /api/op-activity-api/daily-act/config
每日签到  GET /api/op-activity-api/daily-act/signin
```

**实测得到的五条结论**（2026-10-11，HAR 逆向 + 逐条在线验证）：

| # | 结论 | 验证方式 |
|---|---|---|
| 1 | **凭证只需 `udid` + `accountId` 两个参数** | 5 个参数排列组合穷举 31 种，只有含这两个的组合能返回本人数据 |
| 2 | **`secret` / `cityId` / `s` 可以完全省略** | 去掉后返回数据与完整参数逐字节一致 |
| 3 | **Cookie 完全不需要** | 不带任何 Cookie 同样返回 200 正常数据 |
| 4 | **`sign` / `signature` / `nonce` / `h5TimeStamp` 是装饰性的** | 伪造签名、甚至完全不带，均返回 200 |
| 5 | 请求头里**必须有 `Referer`**（值不校验） | 缺失 → 400；填成首页地址 → 仍然 200 |

> ⚠️ 第 1 条有个坑值得单独说：**只带 `udid` 也能通过 HTTP 校验**，但返回的是**匿名数据**
> （`signRewards[0].status = "unsigned"`，第 1 天显示未签）。必须同时带 `accountId`
> 才能拿到本人账户状态。所以判断"接口通不通"不能只看状态码，**要看数据是不是自己的**。

## 二、安装

Loon → 配置 → 插件 → `+`，填插件地址：

```
https://raw.githubusercontent.com/onshine/ScriptHubs/main/chelaile-checkin/CheLaiLe_Checkin.plugin
```

装好后**打开一次车来了 App → 进入「每日签到」页**（进页面就行，不必手动点签到），
脚本会自动抓到 `udid` / `accountId` 并保存。之后每天按 `cron` 自动签到。

> 不想开 MITM 也行：在插件 Argument 里手动填 `udid` 和 `accountId` 即可。
> 开启 MITM 的情况下，插件已自动把 `web.chelaile.net.cn` 加进 MitM（`%APPEND%`）。

## 三、配置项

| 参数 | 默认 | 说明 |
|---|---|---|
| `cron` | `5 8 * * *` | 每日执行时间，默认 08:05 |
| `udid` | 空 | 一般留空，用抓包自动捕获的值 |
| `accountId` | 空 | 同上 |
| `notify_when_signed` | **开** | 当天已签到时是否也推送通知；关掉后只在签到有动作或出错时通知 |
| `debug` | 关 | 输出接口原始响应，排查时打开 |

## 四、FAQ

**Q：提示"未配置凭证"？**
先打开车来了 App 进一次「每日签到」页；若仍不行，检查 MITM 是否已开启并信任证书，
或手动在 Argument 填 `udid` / `accountId`。

**Q：为什么不需要 Cookie，也不需要那些签名参数？**
实测结论：这些端点的鉴权只看 `udid` + `accountId`，Cookie 与 `sign/signature/nonce`
服务端不校验（详见第一节表格）。所以本插件**不需要 `requires-body`**，
抓包钩子只读 URL 就够，开销极小。

**Q：签到失败怎么办？**
打开 `debug` 开关跑一次，看运行日志里的 `config 原始响应` / `signin 原始响应`。常见情况：
- `status=1002` + `今日已签到` → 已经签过了，属正常
- `status=400` + `Missing Request Parameter: udid` → 凭证丢了，重新抓一次
- 活动下线/换期 → 报 `读取活动配置失败`，等新一期活动上线

**Q：会不会误签 / 重复签？**
不会。脚本先用 `config` 判断 `signRewards[].signDate == 今天`，
已签就直接跳过，连 `signin` 都不发。

## 五、已知边界

- **判断"今天是否已签"必须用 `signDate`，不能用 `status`。**
  `status == "signed"` 表示"本周期内该天已签"，昨天签的第 1 天，今天看仍是 `signed`。
  只看 `status` 会导致**第二天开始每天都跳过签到**。
- 本插件只做**签到**。活动里的「惊喜任务」（`taskType: share` 分享至朋友圈、
  `taskType: video` 看视频）**没有实现**——那两个接口需要伪造"已完成"状态去领奖励，
  与签到（点一下按钮就完成）性质不同，本脚本不做。
- 若车来修改活动接口路径或鉴权规则，需要重新抓包核对（脚本会把原始响应打在 `debug` 日志里）。

## 六、版本记录

| 版本 | 说明 |
|---|---|
| R1.0.1 | `notify_when_signed` 默认改为**开**：当天已签到时也推送通知（脚本侧同步改为「未显式传 `false` 即通知」，手动挂载时不再静默）。签到逻辑无变化。 |
| R1.0.0 | 首版。基于真实 HAR 逆向，凭证 `udid`+`accountId`，带抓包自动捕获 + 已签跳过 |
