# gemini-web2api — 小鸡部署套件

把 Google Gemini **网页端**反代成 **OpenAI 兼容 API**（不用 Google API Key、不用付费配额）。
一台做主控，其他小鸡做 IPv6 出口，配额叠加。

- 上游项目：[zexadev/gemini-web2api-go](https://github.com/zexadev/gemini-web2api-go) v4.0.0
- 本套件版本：**R1.2.0**

---

## 就三步

```
① 出口机（每台 IPv6 小鸡）跑 outbound.sh  → 复制它给出的 socks5 地址
② 主控机跑 install.sh                     → 拿到 API Key
③ 主控机跑 addproxy.sh 把①的地址加进去    → 完成
```

主控机可以是 **IPv4 机、IPv6 机、双栈机**都行。

---

### ① 出口机（每台 IPv6 小鸡都跑一遍）

```bash
curl -fL -o outbound.sh https://raw.githubusercontent.com/onshine/ScriptHubs/main/gemini-web2api/outbound.sh
chmod +x outbound.sh && sudo ./outbound.sh
```

跑完会打印一行，**复制下来**：

```
socks5h://gwab12cd:xxxxxxxx@[2001:db8::2]:1080
```

> 账号密码随机生成（防止变成公共代理被人蹭）。出站强制走 IPv6。

### ② 主控机

```bash
curl -fL -o install.sh https://raw.githubusercontent.com/onshine/ScriptHubs/main/gemini-web2api/install.sh
chmod +x install.sh && sudo ./install.sh
```

> **拉到的是旧版？** `raw.githubusercontent.com` 有约 5 分钟 CDN 缓存。
> 脚本第一行会打印版本号，与本文档顶部的版本不一致就是拿到缓存了，
> 用这个地址强制取最新：
> ```bash
> curl -fL -o install.sh "https://raw.githubusercontent.com/onshine/ScriptHubs/main/gemini-web2api/install.sh?$(date +%s)"
> ```

跑完打印 **Admin Token** 和 **API Key**，保存好。默认端口 8084，要改就 `sudo ./install.sh 9000`。

> 重跑脚本是安全的：会自动停旧服务、复用已有凭据（客户端不用改配置）。
> **想彻底重装换新凭据**：`sudo ./install.sh --regen`。
> 忘了凭据看 `cat /opt/gemini-web2api/.credentials`。
>
> 凭据文件丢了也不怕，它们在 systemd 单元里，可这样恢复：
> ```bash
> sed -n 's/^Environment=//p' /etc/systemd/system/gemini-web2api.service
> ```

### ③ 主控机加出口

```bash
curl -fL -o addproxy.sh https://raw.githubusercontent.com/onshine/ScriptHubs/main/gemini-web2api/addproxy.sh
chmod +x addproxy.sh

# 把 ① 复制的地址粘进来（有几台出口机就加几次）
sudo ./addproxy.sh 'socks5h://gwab12cd:xxxxxxxx@[2001:db8::2]:1080' 'B机'
sudo ./addproxy.sh 'socks5h://gwef34gh:yyyyyyyy@[2001:db8::3]:1080' 'C机'

# 让主控自己的 IP 也干活（见下方说明，建议加）
sudo ./addproxy.sh --local

sudo ./addproxy.sh --list      # 看池子
```

加之前会自动测一次通不通，并显示出口 IP。凭据自动从 `install.sh` 存的文件读，不用手输。

---

## ⚠️ 两个坑（这套脚本已经帮你处理）

**坑 1：主控机 IP 会闲置。** 上游代码写死了——**代理池非空时绝不回退直连**（防止代理满了把主控 IP 也打爆）。所以只加了出口机的话，主控自己的 IP 一次都不用。想让它也干活，跑一次 `addproxy.sh --local`（在主控本机装个只听 127.0.0.1 的 socks5 加进池子）。

**坑 2：纯 IPv6 主控外部连不上。** 上游默认监听 `0.0.0.0`（IPv4 通配符），而且**没有 `--host` 参数**。`install.sh` 已自动写 `config.json` 设 `host: "[::]"` 双栈监听（注意必须带方括号，上游是 `fmt.Sprintf("%s:%d")` 拼接，填 `::` 会拼成非法的 `:::8084`）。自查：

```bash
ss -tlnp | grep 8084     # 要看到 [::] 或 *，不能是 0.0.0.0
```

---

## 常见搭配

| 主控 | 出口 | 说明 |
|---|---|---|
| IPv4 机 | 几台 IPv6 机 | **最推荐**。你自己电脑没 v6 也能连主控，出口全走 v6 |
| IPv6 机 | 其他 IPv6 机 | 可行，但你的客户端网络得有 v6，否则连不上主控 |
| 双栈机 | IPv6 机 | 同第一种 |

配额：每条代理 = 一个独立 IP 槽，各自 并发5 / RPM30 / RPH80。单个 IP 打 80~180 次会被 Google 拦（硬拦，约 20 分钟）。**N 条代理 ≈ N 倍容量。**

---

## 用起来

浏览器开 `http://主控IP:8084/admin`，用 Admin Token 登录。

**想用最强的 `gemini-3.1-pro`**（带思考链）：面板「设置」页粘 Google Cookie。
取法：登录 gemini.google.com → F12 → Application → Cookies，复制这 6 个拼成一行：

```
SID=...; HSID=...; SSID=...; APISID=...; SAPISID=...; __Secure-1PSID=...
```

**客户端接入**（Cherry Studio / ChatBox / dify / newapi 等都一样）：

| 填什么 | 值 |
|---|---|
| Base URL | `http://主控IP:8084/v1` |
| API Key | `sk-gemini-...` |
| 模型 | `gemini-3.6-flash` |

---

## 可选：巡检插件

多台机器最烦不知道哪台挂了、Cookie 啥时候过期。Loon 插件订阅：

```
https://raw.githubusercontent.com/onshine/ScriptHubs/main/gemini-web2api/Gemini_API_Monitor.plugin
```

参数 `nodes` 填：`主控|http://IP:8084|sk-gemini-xxx`

能查出：离线 / 被限流 / API Key 失效 / **Cookie 过期导致 Pro 静默降级**。
最后这项最有用——Cookie 失效时 Gemini **不报错**，只默默把你当匿名用户，面板还显示正常。

---

## 运维命令

```bash
systemctl status gemini-web2api        # 主控状态
journalctl -u gemini-web2api -f        # 主控日志
systemctl status danted-gw             # 出口机状态
systemctl status danted-local          # 主控本机出口槽（--local 装的）
# 忘了代理密码：只能重跑 outbound.sh 生成新的（密码是系统用户密码，不落盘明文）
```

## 装不上 socks5 怎么办

脚本会自动二选一：优先 apt 装 **dante-server**，源里没有就编译 **microsocks**
（极简 socks5，只依赖 gcc）。两条路都失败才会报错，通常无需干预。

**跑过 R1.2.0 装坏了 3proxy？** R1.3.1 起脚本会自动检测并清理，直接重跑即可。

若仍卡住（apt 报 unmet dependencies），手动清一次：

```bash
dpkg --purge --force-all 3proxy; apt --fix-broken install -y
```

---

## FAQ

**Q：IPv4 主控能用 IPv6 小鸡做出口吗？**
A：**能。**这是最推荐的组合。上游走 socks5 代理时用 Go stdlib 的 `http.ProxyURL`，原生支持 socks5h（DNS 也在出口机解析），所以主控有没有 v6 完全不影响。

**Q：为什么测试命令是 127.0.0.1？**
A：那是在小鸡本机自测用的。外部访问用 `http://主控IP:8084`。

**Q：出口机要开防火墙吗？**
A：脚本用随机账号密码防蹭。如果你的小鸡有防火墙，出口机放行 1080 端口即可。

**Q：会封 Google 账号吗？**
A：不挂 Cookie 时是匿名的，没账号可封，封的是 IP。挂 Cookie 后用的是你账号的网页会话。

**Q：升级上游版本？**
A：`systemctl stop gemini-web2api` → 覆盖 `/opt/gemini-web2api/gemini-web2api` → `start`。数据库兼容。

**Q：prompt 会被记录吗？**
A：不会。上游只存元数据（模型、延迟、token 数、状态码），内容永不入库。

---

## 版本记录

| 版本 | 变更 |
|---|---|
| R1.4.0 | **双引擎 + 强制 IPv6 出口**。部分系统源里没有 dante-server（报 `Unable to locate package`），新增 microsocks 源码编译回退（仅依赖 gcc，无 glibc 版本坑）。出口地址不再依赖系统默认路由：自动探测全局 IPv6 并显式绑定（dante 用 `external: <v6>`，microsocks 用 `-b <v6>`），确保「优先 IPv6 出口」。自检会明确报告实际走的是 v6 还是 v4；有 v6 的机器同时给出 v4 入口地址，方便无 v6 的主控连接 |
| R1.3.8 | 下载前额外 `pkill` 掉不受 systemd 管的手工前台实例（它们同样会占用二进制导致 `Text file busy`）；失败时若检测到残留进程，直接给出 pkill 命令 |
| R1.3.7 | 修复重跑时 `Text file busy`：运行中的可执行文件无法被 curl 直接覆盖。改为先 stop 服务、下载到 `.new` 临时文件、验证 `--version` 可执行后再 `mv` 原子替换（坏包不会顶掉可用版本）。下载失败的报错也不再一律归咎于 IPv6，改为列出 GitHub 连通性 / NAT64 / scp 三条排查方向 |
| R1.3.6 | 修复 `source .credentials` 时文件里的 `PORT=` 会覆盖命令行指定端口的问题；补充 7 项本地逻辑测试（参数解析 / 凭据复用与重生 / 端口不被覆盖 / config.json 合法性 / 回退 sed）全部通过 |
| R1.3.5 | 修复**凭据与运行进程不一致**：原先先写 systemd unit 再预检，预检失败 exit 时 unit 里已是新凭据但服务从未重启，运行中进程仍用旧 key，导致 `.credentials` 里的 key 报 `invalid_api_key`。改为预检通过后才写 unit；自检新增用 API Key 实测 `/v1/models` 鉴权是否真的通 |
| R1.3.4 | 凭据改为**生成后立刻落盘**（原先写在最后一步，中途自检失败就丢，用户拿不到 token）；`addproxy.sh` 在 `.credentials` 缺失时自动从 systemd 单元的 `Environment=` 行恢复 |
| R1.3.3 | **重跑幂等**：① 预检前先 stop 旧服务并等端口释放，不再撞 `address already in use`；端口确实被别的进程占用时打印占用者 PID 并提示换端口 ② 凭据改为复用 `.credentials` 已有值，重跑不再让客户端配置全部失效；需要重新生成加 `--regen` |
| R1.3.2 | 修复主控启动失败 `too many colons in address`：上游用 `fmt.Sprintf("%s:%d", host, port)` 拼监听地址，`host` 填 `::` 会拼成非法的 `:::8084`，Go 要求 IPv6 通配符必须写 `[::]`。另新增：装服务前先前台预检启动 4 秒提前暴露配置错误、`[::]` 不被接受时自动回退 `0.0.0.0`、自检失败直接打印 journalctl 日志与手动排查命令（不再只提示"去看日志"） |
| R1.3.1 | 三个脚本均加入**自愈逻辑**：启动时检测 dpkg 里处于"已解包未配置"（iU/iF）状态的残留 3proxy 并自动 purge + `apt --fix-broken install`。此前若跑过 R1.2.0，损坏的 3proxy 会卡住 apt 安装**任何**包，导致 R1.3.0 也装不上 dante；安装失败时给出明确自救命令 |
| R1.3.0 | **改用 dante-server 替代 3proxy**。根因：3proxy 不在 Debian 12 官方源里，而官方 0.9.9 deb 要求 glibc ≥ 2.38，Debian 12 只有 2.36 → 装上也跑不起来（`GLIBC_2.38 not found`）；且 dpkg 解包后 `command -v` 能找到文件，导致脚本误判成功。dante-server 在 Debian/Ubuntu 官方源自带，无依赖坑。服务名 `danted-gw`(1080) / `danted-local`(1081)，配置独立不冲突；自动停用 Debian 自带的空配置 danted 服务 |
| R1.2.0 | 修复 3proxy 安装 404（官方 deb 资产名是 `x86_64`/`arm64` 而非 dpkg 的 `amd64`，且写死的 0.9.4 已下架）。改为三级回退：系统源 → 官方 deb/rpm（版本动态取 latest tag）→ 源码编译；不再用 `-qq` 吞掉错误，失败时打印 journalctl 日志；`--local` 改用独立配置与服务名 `3proxy-local`(1081)，避免与出口机的 3proxy(1080) 互相覆盖 |
| R1.1.0 | 拆成三个脚本（主控 / 出口 / 加代理）；出口机改用 3proxy 无交互部署 + 出站强制 v6；addproxy.sh 支持 `--local` 补上主控 IP 闲置问题、自动测试代理连通性、自动读取凭据；主控支持纯 v4 / 纯 v6 / 双栈自适应；README 精简为三步 |
| R1.0.0 | 首发。单脚本部署 + 多节点巡检插件 |

仅供学习交流。
