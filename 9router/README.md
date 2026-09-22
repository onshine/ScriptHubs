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
curl -fsSLO https://raw.githubusercontent.com/ScriptHubs/main/9router/9router.sh
```

> 上面这条 URL 请换成你的仓库实际路径，例如：
> `https://raw.githubusercontent.com/<你的用户名>/ScriptHubs/main/9router/9router.sh`

然后：

```sh
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

## 自检

```sh
./9router.sh status
```

会依次检查：

| 检查项 | 抓的是什么故障 |
|---|---|
| 容器状态 | 起没起来 |
| 端口映射 | 宿主端口 → 容器端口写错（`PANEL_PORT:PANEL_PORT` 那类静默 502） |
| 端口链（容器内 → 宿主 → HTTP 200） | 三段分开验，坏在哪一段一目了然 |
| 登录链路 | 拿密码真的 POST 一次 `/api/auth/login` |
| 容器出网 | 连不上上游 = 网关转发全挂，LXC 里很常见 |
| 暴露面 | 15900 是不是只绑在 127.0.0.1 上 |

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

可用环境变量覆盖：`DOMAIN` `BASE_DIR` `PORT` `CONTAINER_NAME` `IMAGE`
`PANEL_PASSWORD` `REQUIRE_API_KEY` `SECURE_COOKIE` `OUTBOUND_PROXY`
`TZ_NAME` `PULL_IMAGE` `UPDATE_COMPOSE`。

例：换个端口、顺手给出站挂代理

```sh
DOMAIN=9r.example.com PORT=25900 OUTBOUND_PROXY=http://127.0.0.1:7890 ./9router.sh
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

**Q：更新怎么弄？**
直接重跑 `./9router.sh`（会拉新镜像、停旧起新，`.env` 和 `data/` 都不动）。
数据目录不在容器里，更新不会丢配置。

---

## 版本记录

| 版本 | 日期 | 说明 |
|---|---|---|
| R1.0.0 | 2026-09-22 | 首版。基于 9Router 0.5.85 源码实测：仅绑回环端口、随机 `INITIAL_PASSWORD`（规避反代下 `isLocalRequest` 恒假导致的登录 403）、`REQUIRE_API_KEY` 默认开启、显式 healthcheck、`reset-password`（备份+重建库）、端口链/登录链路/出网/暴露面四项自检。 |

---

仅供学习交流。
