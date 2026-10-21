# AgentRouter 签到

两个版本，**命名区分，二选一**（同时开会重复签到）。本地版当前版本：**r8.4**。

## 变更记录

| 版本 | 说明 |
|---|---|
| **r8.4**（2026-10-21） | 同步上游 `2026-10-20.r7`：新增 `agentrouter_status` 签到状态登记（供「签到汇总」读取）、全角 `＄` 奖励金额识别、插件未填时回退 BoxJS、`merge` 统一通知静默。<br>**保留本站自有改动**：多账号间随机等待 0～300 秒、Loon 无参 `$done()` 兼容处理、账号完成/失败日志。 |
| r8.3（2026-09-12） | 增加多账号签到随机抖动。 |

| 插件 | 脚本来源 | 适合谁 | 导入地址 |
|---|---|---|---|
| **ScriptHubs 本地版**<br>`AgentRouter_Checkin_ScriptHubs.plugin` | 本仓库 `agentrouter/agentrouter.js`（**内置，不随上游变**） | 想固定用自己这份脚本；账号密码等设置写在**插件设置**里 | `https://raw.githubusercontent.com/onshine/ScriptHubs/main/agentrouter/AgentRouter_Checkin_ScriptHubs.plugin` |
| **上游原版**<br>`AgentRouter_Checkin_Upstream.plugin` | 上游 `MaYIHEI/paperclip` 的 `app/agentrouter/agentrouter.js`（**仅引用，不内置**） | 想跟作者保持同步；账号设置走 **BoxJS** | `https://raw.githubusercontent.com/onshine/ScriptHubs/main/agentrouter/AgentRouter_Checkin_Upstream.plugin` |

- `AgentRouter_Checkin.plugin`：旧文件名，内容等同本地版的前身，**仅保留兼容旧链接**，已标记 `_deprecated`。
- `AgentRouter_Checkin_deprecated.plugin`：旧文件留存副本，不要再用。

## 本地版

默认每天 09:00 执行。

- 单账号：填写账号、密码
- 多账号：在“多账号（JSON）”填写原脚本要求的 JSON 数组
- 第一个账号立即执行
- 从第二个账号开始，每个账号随机等待 0～300 秒
- 登录、余额查询、签到记录确认等原逻辑未改变

随机抖动只影响账号开始处理的时间，不修改 AgentRouter 的签到判定逻辑。

## 上游原版

- 只有「签到时间」一个设置，默认 `0 9 * * *`
- 账号 / 密码 / 多账号 / 调试开关都在 **BoxJS**（`AgentRouter` 命名空间）里填
- 脚本由上游仓库直供，作者改逻辑这里自动跟上；Loon 会缓存脚本，**更新后请删除旧插件重新添加**以强制重下
