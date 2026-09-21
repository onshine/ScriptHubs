# 9NB 签到

当前版本：r2.35.0。

> ⚠️ **结论：Loon 无法用于 9NB 签到。**
> 9nb.de 位于 Cloudflare 之后，Loon 对其 MITM 解密后响应损坏，Safari 会把页面当成文件下载（表现为「下载文件 document」）。
> 另外 Loon 的 `$httpClient` / `$task.fetch` 均强制跟随 302 重定向，导致登录接口的 `Set-Cookie: bbs_auth` 必然丢失，模拟登录不可行。
> **请改用 VPS 方案。**

## 推荐方案：VPS 运行

服务器上直连不受上述限制，可以完整处理 302 并拿到 `bbs_auth`。

### 安装

```sh
curl -fsSL https://raw.githubusercontent.com/onshine/ScriptHubs/main/9nb-checkin/deploy_9nb.sh | sh
```

### 配置账号（三种方式，任选）

**方式一：命令行保存（推荐，无需编辑代码）**

```sh
python3 /root/9nb_checkin.py --add 武则天:你的密码
python3 /root/9nb_checkin.py --add LOL:你的密码
python3 /root/9nb_checkin.py --add maxwin:你的密码
```

一次加多个：

```sh
python3 /root/9nb_checkin.py --add "武则天:密码1|LOL:密码2|maxwin:密码3"
```

查看 / 删除：

```sh
python3 /root/9nb_checkin.py --list
python3 /root/9nb_checkin.py --del-account LOL
```

**方式二：环境变量（适合临时测试）**

```sh
NINE_NB_ACCOUNTS='武则天:密码|LOL:密码' python3 /root/9nb_checkin.py
```

**方式三：编辑脚本**

```sh
vi /root/9nb_checkin.py
```

找到 `ACCOUNTS`，去掉行首的 `#` 并填入密码：

```python
ACCOUNTS = [
    ("武则天", "你的密码"),
    ("LOL", "你的密码"),
]
```

⚠️ 注意：**行首的 `#` 必须删掉**，否则那一行仍是注释，脚本会认为没有账号。
`vi` 保存要按 `Esc` 后输入 `:wq` 回车。

### 使用

```sh
# 先测试登录，不签到
python3 /root/9nb_checkin.py --dry-run

# 正式签到
python3 /root/9nb_checkin.py

# 不随机等待（调试用）
python3 /root/9nb_checkin.py --no-jitter
```

### 自动运行

安装脚本已配置 crontab，每天 08:00 自动签到。查看：

```sh
crontab -l
```

## 其它说明

- 账号文件 `~/.9nb_accounts` 权限 `600`，仅 root 可读
- Cookie 缓存 `~/.9nb_cookies.json`，登录成功后复用，失效自动重新登录
- 登录失败会解码站点返回的 `__form_error`，直接显示中文原因
- 通知推送：编辑脚本里的 `BARK_URL` 填入 Bark 地址即可

## Loon（已废弃，保留供参考）

插件仅保留 cron，已移除 `[MITM]` 和 `http-request` 规则，避免破坏网页访问。
由于 Loon 无法拿到 `bbs_auth`，此方式实际无法完成签到。
