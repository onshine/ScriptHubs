# PingMe 签到 + 视频奖励（Loon 外壳）

给 **PingMe** App 自动签到、自动看视频赚 Coins。**脚本本体不是本仓库的**，这里只提供一个可安装的 Loon 插件外壳。

- 插件：`PingMe.plugin`
- 脚本：**引用上游，未内置**（原因见第五节）
  - 抓账号：`fmz200/wool_scripts/Scripts/cookie/get_cookie.js`
  - 签到任务：`fmz200/wool_scripts/Scripts/PingMe/PingMeSignin.js`

---

## 一、这外壳解决什么

上游脚本本身就**支持 Loon**（用 chavyleung 的 `Env` 类，`isLoon()` 分支齐全），
但它的 README 只给了 **Quantumult X 和 Egern** 的配置。网上流传的 Loon 版通常是这两行：

```ini
request if ${url} ~= /^https:\/\/api\.pingmeapp\.net\/app\/queryBalanceAndBonus/i then script("…/get_cookie.js") with enable=${PingMe}, tag="PingMe获取签到参数", timeout=60
cron "30 8,20 * * *" then script("…/PingMeSignin.js") with enable=${PingMe}, tag="PingMe签到"
```

**能用，但有三个问题**：

| 问题 | 说明 | 本外壳的处理 |
|---|---|---|
| **签到时间改不了** | `cron "30 8,20 * * *"` 是**字面量**，写死在指令里 —— 插件设置页里看不到、也改不了（官方 v2 语法里 Trigger 写成字面量就等于焊死） | 改用 `cron ${cron}`，并在 `[Argument]` 里声明 `cron = input,"30 8,20 * * *"` |
| **`${PingMe}` 是空引用** | 那份插件大多**没有 `[Argument]` 段**，`enable=${PingMe}` 引用的是未声明的参数（按官方语义属非法项） | 补上 `PingMe = switch,true,…` |
| **超时偏紧** | 签到还要跑最多 5 个视频、每个间隔 8 秒 | `timeout=300` |

> 官方 v2 语法的三段式是 `Trigger/Condition` + `Script Action` + `with`。

## 二、安装

Loon → 配置 → 插件 → `+`，填：

```
https://raw.githubusercontent.com/onshine/ScriptHubs/main/pingme/PingMe.plugin
```

装好后：

1. 打开 **MitM**（插件用 `%APPEND%` 追加 `api.pingmeapp.net`，不会覆盖你自己的列表）
2. 确认 MitM 证书已安装且被信任
3. **打开 PingMe App 并登录**，随便点一下余额 / 奖励页 —— 抓包钩子会把凭证存下来
4. 之后每天按 `cron` 自动签到，不用再管

## 三、配置项

| 参数 | 默认 | 说明 |
|---|---|---|
| `PingMe` | **开** | 总开关。关掉后抓包与定时签到都不执行 |
| `cron` | `30 8,20 * * *` | 签到时间，默认每天 8:30 与 20:30 各一次（`分 时 日 月 周`） |

## 四、抓凭证的机制（为什么键能对上）

```
get_cookie.js   写入  #pingme_capture_v3   ← 其内部 write() 会把开头的 # 剥掉
PingMeSignin.js 读取  pingme_capture_v3
```

两边键名一致，所以抓到就能直接用。若日志出现「未找到账号 / 凭证失效」之类提示，
多半是凭证过期 —— **打开 PingMe App 再走一遍就会自动刷新**。

## 五、⚠️ 风险提示（用之前请读）

1. **封号风险**：这类「看视频赚 Coins」脚本会**伪造设备号、UA 和 IP** 来绕过风控。
   服务端是有能力识别这种模式的。**请自行评估账号价值再决定用不用。**
2. **第三方依赖**：脚本本体在 `fmz200/wool_scripts`（上游可追溯到 `ZenmoFeiShi/Qx`，
   奶思做过改版）。本插件只**引用**它的 URL，不内置、不修改；上游一改，行为跟着变。
   本目录只维护**外壳**，脚本本身的问题请找上游。
3. **所以本目录没有内置 `.js`** —— 与仓库其他目录的三件套约定不同。
   内置他人代码涉及授权问题，且会导致上游更新收不到，因此遵循「引用而非复制」。

## 六、版本记录

- **R1.0.0**（2026-10-14）首版。把流传的 PingMe Loon 配置整理成可安装插件：
  `cron` 改为 Argument 可自定义、补上 `PingMe` 开关声明、超时放宽到 300 秒。
  已按官方 v2 语法逐条校验（引用的参数全部有声明）。

---

仅供学习交流。脚本版权归原作者所有。
