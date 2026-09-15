# 9NB.DE 每日签到

Loon 每日自动签到脚本，适用于 https://9nb.de/。脚本通过账号密码登录，自动获取并在 Loon 本地保存 Cookie，然后签到并显示签到奖励和积分余额。

## 安装

导入 [`9NB_Checkin.plugin`](./9NB_Checkin.plugin)，建议保持默认每天 08:00 执行。多账号签到时，相同 Cookie 会自动去重；每个账号之间随机等待 0～5 分钟。

首次使用：

1. 导入插件并保持默认每天 08:00 执行。
2. 在插件 Argument 的 `多账号登录` 中填写账号密码：

```text
账号A:密码A|账号B:密码B
```

3. 手动运行一次 `9NB每日签到` 测试。
4. 脚本先读取 Loon 本地保存的 Cookie；Cookie 不存在或失效时，才使用账号密码登录并更新本地 Cookie。
5. 每个账号动态获取 CSRF 后签到，账号之间随机等待 0～300 秒。

密码只用于 Loon 本地请求，不会输出到日志、通知或 GitHub。登录得到的 Cookie 保存在 Loon 持久化存储中。

相同账号自动去重，不会重复登录或重复签到。

## 签到结果

通知中会显示每个账号的：

- 签到成功或今天已经签到
- 签到奖励
- 当前积分余额（网站页面能读取时显示）

Cookie 和密码都属于登录凭据，不要发给他人，也不要提交到 GitHub。

## 工作原理

签到页面每次返回动态 `_csrf`，脚本先 GET `/nb_checkin` 获取当前 CSRF，再提交：

```text
POST /nb_checkin
_csrf=<动态值>
mode=fixed
```

`mode=fixed` 为直接签到，固定获得 5 积分；如需手气签到，可将脚本中的 `mode=fixed` 改为 `mode=random`。

## Cookie 失效

如果通知提示 Cookie 失效，请重新登录 9NB 并再次打开签到页。不要把 Cookie 发到聊天或提交到 GitHub。

## 文件

- `9nb-checkin.js`：签到脚本及 Cookie 自动捕获
- `9NB_Checkin.plugin`：Loon 定时任务、捕获规则和 MITM 配置

版本：`2026-09-15.r2.0.0`
