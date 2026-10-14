# WeTalk 签到 + 视频奖励（Loon 外壳）

给 **WeTalk** App 自动签到、自动看视频赚 Coins。**脚本本体不是本仓库的**，这里只提供一个可安装的 Loon 插件外壳。

- 插件：`WeTalk.plugin`
- 脚本：**引用上游，未内置**（原因见第五节）
  - `CaoXiaoMann/XiaoMan/Scripts/WeTalk/WeTalk.js`（上游 `ZenmoFeiShi/Qx`）

---

## 一、这外壳解决什么

上游脚本本身就**支持 Loon**（用 chavyleung 的 `Env` 类，`isLoon()` 分支齐全），
但作者的 README 只给了 **Quantumult X 和 Egern** 的配置。本目录把 Loon 那份补上，
并顺手修正了两处：

| 问题 | 说明 | 本外壳的处理 |
|---|---|---|
| **签到时间改不了** | 若把 cron 写成字面量（`cron "20 8,20 * * *"`），时间就焊死在指令里 —— 插件设置页里看不到、也改不了（官方 v2 语法里 Trigger 写成字面量即如此） | 改用 `cron ${cron}`，并在 `[Argument]` 里声明 `cron = input,"20 8,20 * * *"` |
| **没有总开关** | 上游只给了配置片段，没有开关 | 补上 `WeTalk = switch,true,…` |

> 官方 v2 语法的三段式是 `Trigger/Condition` + `Script Action` + `with`。

## 二、安装

Loon → 配置 → 插件 → `+`，填：

```
https://raw.githubusercontent.com/onshine/ScriptHubs/main/wetalk/WeTalk.plugin
```

装好后：

1. 打开 **MitM**（插件用 `%APPEND%` 追加 `api.wetalkapp.com`，不会覆盖你自己的列表）
2. 确认 MitM 证书已安装且被信任
3. **打开 WeTalk App 并登录**，随便点一下余额 / 奖励页 —— 抓包钩子会把账号参数存下来
   （存到时会有通知：「✅ 新账号已入库」）
4. 之后每天按 `cron` 自动签到，不用再管

## 三、配置项

| 参数 | 默认 | 说明 |
|---|---|---|
| `WeTalk` | **开** | 总开关。关掉后抓包与定时签到都不执行 |
| `cron` | `20 8,20 * * *` | 签到时间，默认每天 8:20 与 20:20 各一次（`分 时 日 月 周`） |

## 四、抓凭证的机制

**WeTalk 和 PingMe 不一样**：PingMe 用 fmz200 的通用抓包脚本 `get_cookie.js`，
而 **WeTalk.js 自己就负责抓包** —— 同一个脚本，靠有没有 `$request` 来区分角色：

```js
if (typeof $request !== 'undefined' && $request) { …抓账号，存进 wetalk_accounts_v1… }
else { …定时任务：读取 wetalk_accounts_v1 里的全部账号逐个签到… }
```

所以本插件两条指令都指向同一个 `WeTalk.js`（抓包那条从 `$request.url` 的 query 里取
`email`，再从 `$request.headers` 取 UA）。**存储键是 `wetalk_accounts_v1`。**

> 注意：fmz200 那个通用 `get_cookie.js` **不支持 WeTalk**，别照搬 PingMe 的配法。

## 五、⚠️ 风险提示（用之前请读）

1. **封号风险**：这类「看视频赚 Coins」脚本会**伪造设备号、UA 和 IP** 来绕过风控。
   服务端是有能力识别这种模式的。**请自行评估账号价值再决定用不用。**
2. **第三方依赖**：脚本本体在 `CaoXiaoMann/XiaoMan`（上游 `ZenmoFeiShi/Qx`）。
   本插件只**引用**它的 URL，不内置、不修改；上游一改，行为跟着变。
   本目录只维护**外壳**，脚本本身的问题请找上游。
3. **所以本目录没有内置 `.js`** —— 与仓库其他目录的三件套约定不同。
   内置他人代码涉及授权问题，且会导致上游更新收不到，因此遵循「引用而非复制」。

## 六、版本记录

- **R1.0.0**（2026-10-14）首版。补齐上游没给的 Loon 外壳：`cron` 做成 Argument 可自定义、
  补上 `WeTalk` 开关、超时放宽到 300 秒（签到要跑多个视频）。
  已按官方 v2 语法逐条校验（引用的参数全部有声明）。

---

仅供学习交流。脚本版权归原作者所有。
