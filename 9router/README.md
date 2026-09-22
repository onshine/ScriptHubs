# 9Router 部署套件

[9Router](https://github.com/decolua/9router)（MIT，Next.js）部署 / 更新脚本。
把 Claude Code、Codex、Gemini CLI、GitHub Copilot、Kiro、iFlow、Qwen、GLM 等
**40+ 家上游**收敛成一个 OpenAI 兼容端点，带配额追踪、多账号轮询和自动降级。

- **主脚本**：`9router.sh`
- **Caddy 示例**：`9router.example.conf`
- **版本**：R1.0.0

适用环境：1Panel 服务器（Docker + docker compose v2），amd64 / arm64。
官方镜像 `decolua/9router:latest` 是多平台构建，arm64 机器（含 Apple Silicon 的
Linux 虚拟机和大部分 ARM VPS）可以直接跑。

---

## 一键安装

```sh
mkdir -p /opt/9router && cd /opt/9router
curl -fsSLO https://raw.githubusercontent.com/onshine/ScriptHubs/main/9router/9router.sh
chmod +x 9router.sh
DOMAIN=9router.你的域名.com ./9router.sh
```

跑完会打印登录密码和下一步的 Caddy 配置片段。**把密码存进密码管理器**。

---

## 部署后必做：Caddy

脚本**不会**碰你的 Caddyfile（这是刻意的设计，见下文）。把这段手动加进去：

```caddyfile
9router.你的域名.com:18443 {
    tls internal
    encode gzip
    reverse_proxy 127.0.0.1:15900
}
```

然后：

```sh
cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak.$(date +%Y%m%d%H%M%S)
caddy fmt --overwrite /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy
```

校验不通过就**别 reload**（原配置还在跑，服务不受影响）。更多细节见
`9router.example.conf` 里的注释。

---

## LXC 里 bridge 出网不通？用 `NET_MODE=host`

在 LXC/PVE 容器里跑 Docker 时，bridge 网络的 NAT 出网经常是坏的 —— 表现是
**宿主机能上网，容器里连 github.com 都超时**。9Router 所有请求都要容器发起去连
上游，出网不通 = 网关完全不可用（仪表板能开，一个模型都调不通）。

自检里的「容器出网」那一项就是专门抓这个的。不通就切 host：

```sh
NET_MODE=host ./9router.sh
```

脚本会自动处理模式切换（删旧容器栈 + 清理 Docker 网络 + 标记 `.net_mode`），
再跑一次不带 `NET_MODE` 就切回 bridge。

### ⚠️ host 模式下的安全要点（和 workbuddy 那套不一样）

workbuddy2api 有 `WB2A_LISTEN` 这种"只改监听地址"的变量，绑回环很简单。
**9Router 没有这种变量** —— 它只能通过 `PORT` / `HOSTNAME` 两个环境变量控制绑定
地址，而**官方镜像的 Dockerfile 把 `HOSTNAME=0.0.0.0` 烤死了**：

```dockerfile
ENV PORT=20128
ENV HOSTNAME=0.0.0.0        # ← 只写 compose 的 environment 容易漏掉这个
```

如果 host 模式下没显式覆盖 `HOSTNAME`，9Router 会**直接监听宿主机 `0.0.0.0:15900`**，
没有 docker-proxy 那一层兜底，等于把持有全部上游 OAuth token 的网关挂上公网。

所以本脚本在 host 模式下做了两件事：

1. **`PORT` 和 `HOSTNAME` 都显式写进 compose**，不依赖镜像默认值
2. **启动后硬断言实际监听地址**：实测能不能从非回环地址连上，能连上就报警，
   并给出针对性排查提示（`NET_MODE=host` 时提示查 `HOSTNAME`）

（已核对 Next 16.1.6 的 standalone 模板：`hostname = process.env.HOSTNAME || '0.0.0.0'`，
确认是环境变量驱动，所以覆盖 `HOSTNAME` 这条路可行。）

### 两个模式的区别

| | bridge（默认） | host |
|---|---|---|
| 端口 | `127.0.0.1:15900:20128` | 只有 `15900`，容器宿主共用网络栈 |
| 容器内端口 | `20128` | `15900`（就是 PORT） |
| HOSTNAME | `0.0.0.0`（靠端口映射收口） | **必须** `127.0.0.1` |
| 出网 | 走 Docker bridge NAT（LXC 里常坏） | 直接用宿主网络栈 |
| healthcheck 探 | `127.0.0.1:20128/api/health` | `127.0.0.1:15900/api/health` |

⚠️ 切模式时脚本会重建整个容器栈，这是必须的：bridge 建的容器带端口映射，
切成 host 后那些映射会变成"宿主端口自己的监听"（docker-proxy 占着），
不清理干净会互相打架。

---

## 自检

```sh
./9router.sh status
```

会依次检查：

| 检查项 | 抓的是什么故障 |
|---|---|
| 容器状态 | 起没起来 |
| 端口映射 | 宿主端口 → 容器端口写错（bridge 模式下漏 `127.0.0.1:` 前缀那类静默 502） |
| 端口链（容器内 → 宿主 → HTTP 200） | 三段分开验，坏在哪一段一目了然 |
| 登录链路 | 拿密码真的 POST 一次 `/api/auth/login` |
| 容器出网 | 连不上上游 = 网关转发全挂，LXC 里很常见 → 该上 `NET_MODE=host` 了 |
| **监听地址** | **host 模式下最关键的一项**：实测有没有暴露到非回环地址 |
| 网络模式 | 当前记录的是 bridge 还是 host |

### 关于「监听地址」这项的判定方式

最早我用 `ss -lntp | grep 0.0.0.0` 做判定，**是个误报源**：bridge 模式下端口映射
写成 `127.0.0.1:15900:20128` 时，`ss` 会列出两条记录 ——

```
127.0.0.1:15900      ← docker-proxy 真正 accept 的连接
[::1]:15900          ← 端口映射规则，只接受 IPv6 回环，不 accept
```

只看"输出里有没有 `0.0.0.0`"会对**完全正确**的配置报警，很吓人。

现在改成先解析监听表、只认**会 accept 的通配地址**（`0.0.0.0:PORT` / `*:PORT` /
`[::]:PORT`），`[::1]:PORT` 不算；监听表拿不到时才退回 TCP 实测（从非回环地址
试着连一下）。这套判定逻辑有 10 个用例的单测覆盖（含 `[::1]` 误报、端口号前缀
`1590` vs `15900` 的边界）。

---

## 端口与目录

| 项 | 值 | 说明 |
|---|---|---|
| 宿主端口 | `15900` | 只绑 `127.0.0.1`，可用 `PORT=` 覆盖 |
| 容器内端口 | `20128` | 官方镜像写死，改不动 |
| 部署目录 | `/opt/9router` | `app/`（compose）、`data/`（数据）、`.env`（凭据） |
| 容器名 | `9router` | |

**备份只需要备份 `/opt/9router/data`** —— 里面是 `db/data.sqlite`
（提供商、组合、API Key、设置）和 usage 记录。

---

## 为什么和官方文档的命令不一样

官方 README / DOCKER.md 给的一键命令是：

```sh
docker run -d -p 20128:20128 -v "$HOME/.9router:/app/data" \
  -e DATA_DIR=/app/data --name 9router decolua/9router:latest
```

照抄能跑，但**有三个坑**，本套件全部规避了：

### 坑① `-p 20128:20128` = 网关直接挂公网

不带 `127.0.0.1:` 前缀的端口映射，等于监听 `0.0.0.0`。
而这个容器里存着**你全部上游账号的 OAuth token**（Claude Code、Codex、Copilot
的登录态），`/v1` 接口还能直接消耗你的订阅额度。

本脚本固定绑回环（`127.0.0.1:15900:20128`），对外只走 Caddy。

同时默认打开 `REQUIRE_API_KEY=1` —— 官方文档里写着「推荐用于暴露在互联网的
部署」，本脚本直接选了更彻底的方案：不给公网入口 + 加钥匙双保险。

### 坑② 远程登录会被 403 挡死（这条最坑）

9Router 的首次登录密码默认是 `123456`。但源码
`src/app/api/auth/login/route.js` 里有一段针对 CVE-2026-56679 的加固：

```js
const mustChangePassword =
  !storedHash && !process.env.INITIAL_PASSWORD && !isLocalRequest(request);
```

命中时**拒绝下发 JWT**，返回「必须在本机改密码」。

问题在于 `isLocalRequest()` 的判定（`src/dashboardGuard.js`）：

```js
if (request.headers.get("x-9r-via-proxy")) return false;
if (!isLoopbackPeer(request)) return false;
```

`x-9r-via-proxy` 是 `custom-server.js` 给**所有经过反代的请求**自动打上的。
所以：**只要你在 Caddy 后面，恒为 false**。

⇒ 结果就是：反代部署 + 没设 `INITIAL_PASSWORD` = 你从浏览器永远登不进去，
而且报错信息（「请在本机修改密码」）在服务器上根本无法执行 —— 容器里没有
「本机浏览器」这条路。

**修法**：首次启动前就把 `INITIAL_PASSWORD` 写进 `.env`。本脚本自动生成随机
密码并写死，所以你拿到手就能直接登录。

⚠️ 改完 `.env` 必须 `--force-recreate`，`restart` 不行 ——
Docker 的环境变量是**创建容器时**注入的，`restart` 读的是旧值。
脚本里 `restart` 子命令已经用的是 `up -d --force-recreate`。

### 坑③ 改了密码不改 `.env` 也没用（反之亦然）

有 `storedHash` 之后，`.env` 里的 `INITIAL_PASSWORD` **完全失效**，
密码只认数据库里的 bcrypt hash。所以：

- 改 `.env` ≠ 改密码
- 改密码必须用 `./9router.sh reset-password '新密码'`
  （实现：备份 → 挪走数据库 → 重启重新初始化 —— 见脚本内注释）

---

## 常用命令

```sh
./9router.sh                      # 部署或更新（自动停旧起新）
./9router.sh status               # 状态 + 四项自检
./9router.sh logs                 # 跟踪日志
./9router.sh restart              # 强制重建容器（重读 .env）
./9router.sh stop                 # 停止容器
./9router.sh reset-password       # 重置登录密码（自动备份数据目录）
```

可用环境变量覆盖：`DOMAIN` `BASE_DIR` `PORT` `CTR_PORT` `CONTAINER_NAME` `IMAGE`
`NET_MODE` `PANEL_PASSWORD` `REQUIRE_API_KEY` `SECURE_COOKIE` `OUTBOUND_PROXY`
`TZ_NAME` `PULL_IMAGE` `UPDATE_COMPOSE`。

例：换个端口、顺手给出站挂代理

```sh
DOMAIN=9r.example.com PORT=25900 OUTBOUND_PROXY=http://127.0.0.1:7890 ./9router.sh
```

例：LXC 里 bridge 出网不通（最常见的情况）

```sh
NET_MODE=host ./9router.sh
```

---

## 怎么用起来

部署完在仪表板做两件事：

1. **连上游**：`Providers` → 选 Claude Code / Gemini CLI / Kiro / iFlow 等 →
   OAuth 登录（免费层不需要注册）。想零成本的话，
   [README](https://github.com/decolua/9router/blob/master/i18n/README.zh-CN.md)
   推荐的组合是 Gemini CLI（180K 免费/月）+ iFlow（不限量免费）。
2. **拿 Key**：`Endpoint` 页复制 API Key。

然后在你任意一台设备的 CLI 工具里填：

```
Base URL : https://9router.你的域名.com:18443/v1
API Key  : （上面复制的）
Model    : if/kimi-k2-thinking  或其他前缀模型
```

前缀速记：`cc/` Claude Code、`cx/` Codex、`gc/` Gemini CLI、`gh/` Copilot、
`if/` iFlow、`qw/` Qwen、`kr/` Kiro、`glm/` GLM、`minimax/` MiniMax。

---

## FAQ

**Q：一定要用 Caddy 吗？我直接开 `0.0.0.0:20128` 行不行？**
行，但那个端口背后是你所有上游账号的登录态。要开就至少把
`REQUIRE_API_KEY=1` 打开，并且清楚自己在暴露什么。

**Q：`tls internal` 浏览器报不安全怎么办？**
自签证书的正常现象。要么把 Caddy 的根证书装进设备信任库，要么换成
有公网域名的真证书（去掉 `:18443` 和 `tls internal`，Caddy 自动签 LE）。
注意登录 cookie 带 `Secure`，**必须用 https 访问**，http 登不进去。

**Q：能不能在 Caddy 前面套 Cloudflare？**
不建议。9Router 的登录限流按 TCP 对端 IP 计数，而 CF 会让所有请求的
可见 IP 都变成 Caddy 地址 → 限流退化成「全站共用一个计数器」，
别人输错几次密码可能把你锁住。自用场景直连 Caddy 最省心。

**Q：想给 9Router 装 Headroom（省 token 的 sidecar）？**
官方 compose 里有，单独一个容器 `ghcr.io/chopratejas/headroom`，
然后在仪表板 `Endpoint → Token Saver → Headroom` 填 URL。
本脚本没带它（多一个容器、多一份体积），需要的话按官方
[DOCKER.md](https://github.com/decolua/9router/blob/master/DOCKER.md) 手动加。

**Q：`status` 里端口链不通？**
先等 30 秒。Next.js 冷启动要 10~30 秒，刚 `up -d` 完就探多半是假的。
还不行就 `docker logs --tail 50 9router`。

**Q：容器出网不通怎么办？**
这就是 `NET_MODE=host` 的用途，见上文专节。LXC 里 bridge NAT 出网坏掉很常见，
宿主机能上网不代表容器能。

**Q：host 模式下 `status` 报「已暴露公网」？**
说明 9Router 在监听 `0.0.0.0` 而不是 `127.0.0.1`。检查 compose 里
`HOSTNAME: "127.0.0.1"` 在不在 —— 官方镜像把 `HOSTNAME=0.0.0.0` 烤死了，
环境变量只在**创建容器时**注入，改完要 `./9router.sh restart`（内部用
`--force-recreate`，普通 `restart` 读旧值）。紧急止血：

```sh
iptables -I INPUT -p tcp --dport 15900 ! -s 127.0.0.1 -j DROP
```

**Q：更新怎么弄？**
直接重跑 `./9router.sh`（会拉新镜像、停旧起新，`.env` 和 `data/` 都不动）。
数据目录不在容器里，更新不会丢配置。如果你在用 host 模式，记得带上
`NET_MODE=host`，否则会被切回 bridge（脚本会提示模式变更）。

---

## 版本记录

| 版本 | 日期 | 说明 |
|---|---|---|
| R1.1.0 | 2026-09-22 | 新增 `NET_MODE=host`（LXC 里 bridge 出网不通时用），含模式切换自动清理（删旧容器栈 + 清 Docker 网络 + `.net_mode` 标记）。host 模式下显式覆盖 `PORT`/`HOSTNAME` 两个变量并把监听地址硬断言为回环 —— 官方镜像把 `HOSTNAME=0.0.0.0` 烤死了，漏覆盖就会把网关挂公网。修掉「监听地址自检」的误报：端口映射会让 `ss` 列出不 accept 的 `[::1]:PORT`，旧逻辑只看有没有 `0.0.0.0`，对正确配置也会报警；现改为只认会 accept 的通配地址，10 个用例单测覆盖。 |
| R1.0.0 | 2026-09-22 | 首版。基于 9Router 0.5.85 源码实测：仅绑回环端口、随机 `INITIAL_PASSWORD`（规避反代下 `isLocalRequest` 恒假导致的登录 403）、`REQUIRE_API_KEY` 默认开启、显式 healthcheck、`reset-password`（备份+重建库）、端口链/登录链路/出网/暴露面四项自检。 |

---

仅供学习交流。
