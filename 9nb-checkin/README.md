# 9NB.DE 每日签到

Loon 每日自动签到脚本，适用于 https://9nb.de/。

## 为什么不再用「模拟登录」

9NB 的登录接口是：

```text
POST /login
成功 → 302 跳转 /，Set-Cookie: bbs_auth=...
失败 → 302 跳转 /form_error，Set-Cookie: __form_error=...
```

**Loon 的 `$httpClient` 和 `$task.fetch` 都会强制跟随 302**，并且只返回最终那一跳的响应头，中间跳转的 `Set-Cookie`（也就是 `bbs_auth`）会被丢弃。

实测结果：

| 方式 | 能否拿到 bbs_auth |
|---|---|
| curl `--max-redirs 0` | 能 |
| Loon `$httpClient` | 不能 |
| Loon `$task.fetch` | 不能 |

所以本脚本改为 **MITM Cookie 捕获方案**：脚本本身不模拟登录，由你在 Loon 里正常登录一次，脚本自动存下 Cookie。

## 安装

导入 [`9NB_Checkin.plugin`](./9NB_Checkin.plugin)，建议保持默认每天 08:00 执行。

## 首次使用（重要）

1. 导入插件，保持默认每天 08:00 执行；
2. 开启 Loon 的 HTTPS 解密，确认 MITM 域名包含 `9nb.de`（插件已自带）；
3. 在 Loon 里打开 `https://9nb.de/` 并**正常登录**；
4. 登录成功后随便点几个页面，日志里会出现：

```text
[捕获] 检测到登录Cookie：bbs_csrf,bbs_auth，准备保存
[捕获] 已保存9NB登录Cookie（武则天），当前共1个账号
```

5. 退出该账号，登录下一个账号，重复第 3～4 步；
6. 全部账号登录完成后，手动运行一次「9NB每日签到」。

## 多账号

有两种方式，任选一种：

**方式一（推荐）**：Argument 只填账号和密码，登录一次后脚本自动按用户名关联捕获到的 Cookie。

**方式二**：Argument 直接填 Cookie

```text
武则天:bbs_auth=账号A的值; bbs_csrf=账号A的值|LOL:bbs_auth=账号B的值; bbs_csrf=账号B的值
```

账号之间随机等待 0～300 秒。

## 签到结果

通知中会显示每个账号的：

- 签到成功或今天已经签到
- 签到奖励
- 当前积分余额（网站页面能读取时显示）

## 关于签到入口

9NB 的签到是**首页顶栏的组件**（`.nb-checkin-entry`），

```text
/nb_checkin  → 404（不存在）
```

脚本当前读取首页来判定签到状态与积分。若站点改版，日志里会出现「签到页未找到动态CSRF」之类的明确提示，届时按提示调整即可。

## Cookie 失效

如果提示 Cookie 失效，重新登录一次 9NB 即可让脚本重新捕获。Cookie 和密码都属于登录凭据，不要发给他人，也不要提交到 GitHub。

## 文件

- `9nb-checkin.js`：签到脚本 + Cookie 自动捕获
- `9NB_Checkin.plugin`：Loon 定时任务、捕获规则和 MITM 配置

版本：`2026-09-15.r2.31.0`
