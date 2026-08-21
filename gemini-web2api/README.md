# gemini-web2api — IPv6 小鸡部署套件

把 Google Gemini **网页端**反代成 **OpenAI 兼容 API**（不要 Google API Key、不要付费配额），
针对 **纯 IPv6 / 双栈 VPS** 的一键部署脚本 + **多节点健康巡检** Loon 插件。

- 上游项目：[zexadev/gemini-web2api-go](https://github.com/zexadev/gemini-web2api-go)（本目录不含上游代码，只做部署与运维）
- 适配上游版本：**v4.0.0**
- 本套件版本：**R1.0.0**

## 目录内容

| 文件 | 作用 |
|---|---|
| `install.sh` | 一键部署脚本（下载二进制 + systemd + 强凭据生成 + IPv6 监听修正） |
| `gemini-api-monitor.js` | 多节点巡检脚本（Loon / Quantumult X / Surge） |
| `Gemini_API_Monitor.plugin` | Loon 插件（参数化节点列表与 cron） |

---

## 一、一键部署

```bash
curl -fL -o install.sh https://raw.githubusercontent.com/onshine/ScriptHubs/main/gemini-web2api/install.sh
chmod +x install.sh
sudo ./install.sh          # 默认端口 8084
sudo ./install.sh 9000     # 或自定义端口
```

脚本完成后会一次性打印 **Admin Token** 和 **API Key**（务必立刻保存，只显示这一次）。

### 脚本做了什么

1. 识别架构（amd64 / arm64）并下载对应的官方 Release 二进制
2. 用内核 CSPRNG 生成 32 位 admin token + 40 位 `sk-gemini-` API Key
3. **写 `config.json` 把 `host` 设为 `::`** ← 关键，见下节
4. 建 `gemini` 低权限用户，装 systemd 服务（开机自启 + 崩溃重启）
5. 凭据走 systemd `Environment=`，**不进命令行**（`ps aux` 看不到），单元文件 `chmod 600`
6. 资源限额 `MemoryMax=256M` / `CPUQuota=50%` + `NoNewPrivileges` / `ProtectSystem` 加固
7. 自检监听地址、健康接口、本机 IPv6，并打印面板与 API 地址

### ⚠️ 为什么必须写 config.json：上游的 IPv6 坑

上游默认 `host` 是 **`0.0.0.0`**，这是 **IPv4 通配符**——Go 的 `net.Listen` 只会监听 v4，
**纯 IPv6 小鸡从外部一律连不上**。而上游**没有 `--host` 命令行参数**（flag 只有 port/config/db/
admin-token/api-key/cookie-file/proxy/impersonate/version），所以唯一改法是走 `config.json`
把 `host` 设成 `::`（v6 通配符，Go 下默认双栈全收）。

自查监听是否正确：

```bash
ss -tlnp | grep 8084
# [::]:8084 或 *:8084  → 双栈，正确 ✅
# 0.0.0.0:8084         → 只听 v4，外部连不上 ❌
```

### 部署后必做

```bash
ufw allow 8084/tcp                  # 放行端口（或用 CF Tunnel 完全不开端口）
systemctl status gemini-web2api     # 看状态
journalctl -u gemini-web2api -f     # 跟日志
```

浏览器开 `http://[你的v6]:8084/admin`，用 admin token 登录 →「设置」页粘 Google Cookie
即可解锁 `gemini-3.1-pro`（带思考链 `reasoning_content`）。

Cookie 取法：登录 gemini.google.com → F12 → Application → Cookies，复制
`SID` / `HSID` / `SSID` / `APISID` / `SAPISID` / `__Secure-1PSID` 拼成一行：

```
SID=...; HSID=...; SSID=...; APISID=...; SAPISID=...; __Secure-1PSID=...
```

---

## 二、两台 IPv6 小鸡一起玩

**先理解为什么要组队**：单个出口 IP 打 **80~180 次**就会被 Google 302 到 `/sorry/`（硬拦，
20 分钟内无漏网）。上游实测结论：放慢节奏没用，**保持长连接反而能多打约 60%**。扩容唯一
有效手段是**多出口 IP**——每个代理是独立 slot，享有独立的 并发/RPM/RPH 配额。

### ⚠️ 关键陷阱：配了代理池后不再回退直连

读上游 `internal/app/proxy.go` 的 `pickProxyWithCapacity()` 可确认：**代理池非空时，绝不
使用主机自身 IP**（设计如此，防止代理满了把主机 IP 也打爆）。

所以想让**两台机的 IP 都干活**，不能只把 B 机填进池子——那样 A 机自己的 IP 就闲置了，
等于白买一台。正确做法是 **A 机自己也开一个本地 socks5，作为一个代理条目加进池子**。

### 方案一：A 主控 + B 出口（推荐，两个 slot 双倍配额）

```
[客户端] → A机:8084 (API 服务)
              ├─ 代理槽1: socks5h://127.0.0.1:1080      → A 机自己的 v6 出口
              └─ 代理槽2: socks5h://[B机v6]:1080        → B 机的 v6 出口
```

**两台机都执行**（装 socks5 出口）：

```bash
apt update && apt install -y dante-server
IFACE=$(ip -o -6 route show default | awk '{print $5}' | head -1)   # 自动取默认网卡
cat > /etc/danted.conf <<EOF
logoutput: syslog
internal: :: port = 1080
external: $IFACE
socksmethod: username
user.privileged: root
user.unprivileged: nobody
client pass { from: ::/0 to: ::/0 }
socks pass  { from: ::/0 to: ::/0 socksmethod: username }
EOF
useradd -r -s /usr/sbin/nologin proxyuser 2>/dev/null || true
echo 'proxyuser:换成你自己的强密码' | chpasswd
systemctl restart danted && systemctl enable danted
```

**B 机防火墙只放 A 机进来**（别开全网，否则成公共代理被滥用）：

```bash
ufw allow from A机的v6地址 to any port 1080 proto tcp
```

**A 机面板 →「代理池」→ 新增两条**：

| 名称 | URL |
|---|---|
| A机-本地出口 | `socks5h://proxyuser:密码@127.0.0.1:1080` |
| B机-v6出口 | `socks5h://proxyuser:密码@[B机的v6地址]:1080` |

> IPv6 地址在 URL 里**必须套方括号**。上游 `validateProxyURL` 只接受
> `http:// / https:// / socks5:// / socks5h://` 开头，推荐 `socks5h://`（远程 DNS 解析，
> 绕开本地 DNS 污染）。失败 5 次自动熔断，面板可手动重置。

**注意代理路径的指纹差异**：直连走 utls 模拟 Chrome 146，走代理时换 stdlib `net/http`，
暴露给 Google 的是 **Go 标准库指纹**而非 Chrome。上游实测这不影响封禁阈值（111 vs 103 次，
远小于出口间 36% 的方差），但长期账号画像层面需自行权衡。

### 方案二：两台各自独立部署 + 客户端侧负载均衡

两台都跑完整服务（各自 `install.sh`），然后在 newapi / one-api 里建**两个渠道**做轮询。

- 优点：无代理层、无单点、配置简单
- 缺点：两份配置（Cookie / API Key / 限流）要分别维护

### 两方案怎么选

| | 方案一（主控+出口） | 方案二（独立+负载均衡） |
|---|---|---|
| 客户端配置 | 一个地址 | 两个渠道 |
| 单点故障 | A 机挂了全停 | 一台挂了另一台还在 |
| Cookie 管理 | 只在 A 机管一份 | 两台各管一份 |
| TLS 指纹 | 代理路径退化为 Go stdlib | 两台都是 Chrome 146 |
| 适合 | 想要统一入口、集中管理 | 想要冗余、怕单点 |

---

## 三、多节点巡检插件

双机部署后最烦的是不知道哪台挂了、Cookie 什么时候过期。这个插件定时替你查。

### 安装

Loon → 插件 → 添加：

```
https://raw.githubusercontent.com/onshine/ScriptHubs/main/gemini-web2api/Gemini_API_Monitor.plugin
```

### 参数

| 参数 | 说明 |
|---|---|
| `nodes` | 节点列表，格式 `别名\|http://[v6]:8084\|sk-gemini-xxx`，多节点用英文逗号分隔；Key 可省略（则只做存活检查） |
| `cron` | 巡检周期，默认 `0 */6 * * *`（每 6 小时） |
| `timeout` | 单节点超时秒数，默认 15；纯 v6 链路慢可调大 |
| `probe_pro` | 是否真发一次 Pro 请求验证 Cookie（会消耗 1 次配额），默认 true |
| `notify_ok` | 全部正常时是否也推送，默认 false（仅异常打扰你） |

`nodes` 填写示例（两台机）：

```
A机|http://[2001:db8:1::1]:8084|sk-gemini-aaa,B机|http://[2001:db8:2::1]:8084|sk-gemini-bbb
```

### 能检出什么

| 状态 | 含义 |
|---|---|
| `✅ A机：v4.0.0 / 3 模型 / Pro可用` | 一切正常，Cookie 有效 |
| `✅ A机：v4.0.0 / 2 模型 / 匿名(无Cookie)` | 存活但没挂 Cookie，只有 flash 系 |
| `❌ A机：Pro已降级(Cookie过期)` | **Cookie 过期**——Gemini 不报错只静默降级，靠 `reasoning_content` 是否存在识别 |
| `❌ A机：被限流 (429)，配额打满` | 该节点 IP 配额用尽，等恢复或加代理 |
| `❌ A机：API Key 无效或已轮换` | 面板轮换过 Key，插件参数要同步更新 |
| `❌ A机：离线 (...)` | 服务挂了或网络不通 |

> 「Cookie 过期检测」是这个脚本最有价值的地方：Gemini 对失效 Cookie **不返回错误**，
> 只是把你当匿名用户静默降级，面板的「最近成功」也照样是绿的。唯一可靠判据是发一次
> `gemini-3.1-pro` 看有没有 `reasoning_content`。

---

## 四、客户端接入

| 客户端 | Base URL | 模型 |
|---|---|---|
| Cherry Studio / ChatBox / Open WebUI / dify | `http://[你的v6]:8084/v1` | `gemini-3.6-flash` |
| newapi / one-api（渠道类型选 OpenAI） | `http://宿主机IP:8084` | `gemini-3.6-flash,gemini-3.5-flash-lite` |
| Codex CLI（走 `/v1/responses`） | `http://[你的v6]:8084/v1` | 同上 |

```python
from openai import OpenAI
client = OpenAI(base_url="http://[2001:db8::1]:8084/v1", api_key="sk-gemini-xxx")
r = client.chat.completions.create(model="gemini-3.6-flash",
    messages=[{"role": "user", "content": "你好"}])
print(r.choices[0].message.content)
```

**客户端所在网络没有 IPv6 怎么办**：用 Cloudflare Tunnel，免费 + 自带 HTTPS + 小鸡不用开任何公网端口：

```bash
curl -L -o cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared && mv cloudflared /usr/local/bin/
cloudflared tunnel login
cloudflared tunnel create gemini-api
# 配置 ingress 指向 http://localhost:8084，然后：
cloudflared tunnel route dns gemini-api gemini.你的域名.com
cloudflared service install && systemctl enable --now cloudflared
```

---

## 五、FAQ

**Q：为什么测试命令是 `127.0.0.1`？**
A：那是**在小鸡本机自测**用的。外部访问要用 `http://[你的v6地址]:8084`。同时务必确认
`ss -tlnp | grep 8084` 显示 `[::]` 而不是 `0.0.0.0`，否则外部根本连不上（见上文 IPv6 坑）。

**Q：能扛多少请求？**
A：单 IP 80~180 次触发硬拦。两台机 ≈ 两倍。适合个人玩票和轻度使用，商用请买代理池。

**Q：同一个 /64 里绑多个 v6 当代理池行吗？**
A：技术上可行，但同 `/64` 被 Google 视作"同一户"的概率很高，**可能整个前缀一起封**。
玩可以，别指望稳定。

**Q：会封 Google 账号吗？**
A：匿名模式无账号，封的是出口 IP。挂 Cookie 模式用的是你账号的网页会话，请求会出现在
Gemini 网页端历史里（可在「我的活动」删除）。

**Q：升级上游版本？**
A：`systemctl stop gemini-web2api` → 下载新二进制覆盖 → `start`。数据库建表全是
`IF NOT EXISTS`，老库直接可用。或改 `install.sh` 里的 `VER` 重跑（会覆盖 config 与 service，
凭据会重新生成）。

**Q：prompt 内容会被记录吗？**
A：不会。上游只存元数据（模型、延迟、token 数、状态码），prompt/response 内容永不入库。

---

## 版本记录

| 版本 | 变更 |
|---|---|
| R1.0.0 | 首发。一键部署脚本（修正上游 IPv6 监听坑、强凭据生成、systemd 加固）+ 多节点巡检脚本与插件 + 双机代理池方案 |

仅供学习交流。
