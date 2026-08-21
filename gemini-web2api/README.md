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

跑完打印 **Admin Token** 和 **API Key**，保存好。默认端口 8084，要改就 `sudo ./install.sh 9000`。

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

**坑 2：纯 IPv6 主控外部连不上。** 上游默认监听 `0.0.0.0`（IPv4 通配符），而且**没有 `--host` 参数**。`install.sh` 已自动写 `config.json` 设 `host: "::"` 双栈监听。自查：

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
systemctl status 3proxy                # 出口机状态
systemctl status 3proxy-local          # 主控本机出口槽（--local 装的）
cat /etc/3proxy/3proxy.cfg             # 忘了代理密码就看这里
```

## 装不上 3proxy 怎么办

脚本已内置三级回退（系统源 → 官方 deb/rpm → 源码编译），正常都能过。若仍失败：

```bash
apt update && apt install -y 3proxy    # 手动装
./outbound.sh                          # 再跑一次，会自动跳过安装步骤
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
| R1.2.0 | 修复 3proxy 安装 404（官方 deb 资产名是 `x86_64`/`arm64` 而非 dpkg 的 `amd64`，且写死的 0.9.4 已下架）。改为三级回退：系统源 → 官方 deb/rpm（版本动态取 latest tag）→ 源码编译；不再用 `-qq` 吞掉错误，失败时打印 journalctl 日志；`--local` 改用独立配置与服务名 `3proxy-local`(1081)，避免与出口机的 3proxy(1080) 互相覆盖 |
| R1.1.0 | 拆成三个脚本（主控 / 出口 / 加代理）；出口机改用 3proxy 无交互部署 + 出站强制 v6；addproxy.sh 支持 `--local` 补上主控 IP 闲置问题、自动测试代理连通性、自动读取凭据；主控支持纯 v4 / 纯 v6 / 双栈自适应；README 精简为三步 |
| R1.0.0 | 首发。单脚本部署 + 多节点巡检插件 |

仅供学习交流。
