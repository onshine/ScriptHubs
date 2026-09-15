# 9NB.DE 每日签到

Loon 每日自动签到脚本，适用于 https://9nb.de/。采用浏览器登录后捕获Cookie的稳定方案：每个账号首次登录并进入签到页，由Loon保存Cookie，之后脚本自动签到并显示奖励和积分余额。

## 安装

导入 [`9NB_Checkin.plugin`](./9NB_Checkin.plugin)，建议保持默认每天 08:00 执行。多账号签到时，相同 Cookie 会自动去重；每个账号之间随机等待 0～5 分钟。

首次使用：

1. 导入插件并保持默认每天 08:00 执行。
2. 开启Loon的HTTPS解密和MITM，打开第一个账号的 `https://9nb.de/` 并登录。
3. 登录成功后进入 `https://9nb.de/nb_checkin`，让Loon捕获该账号的完整Cookie。
4. 退出该账号，再登录下一个账号并重复第2～3步。
5. 把每个账号捕获到的完整Cookie填写到插件 Argument 的 `多账号Cookie`：

```text
武则天:bbs_auth=账号A的值; bbs_csrf=账号A的值|LOL:bbs_auth=账号B的值; bbs_csrf=账号B的值
```

6. 手动运行一次 `9NB每日签到` 测试。
7. 后续脚本只使用Cookie，不再提交账号密码；相同Cookie自动去重，账号之间随机等待0～300秒。

Cookie属于登录凭据，不要发给他人，也不要提交到GitHub。Cookie失效后，只需重新登录对应账号并更新该账号Cookie。

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

版本：`2026-09-15.r2.10.0`
