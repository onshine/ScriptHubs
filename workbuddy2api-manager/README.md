# workbuddy2api + 管理面板 部署套件

一键部署 **workbuddy2api**（上游网关）与 **workbuddy-manager**（管理面板），
面向跑在 LXC/容器里的服务器、或只能用高位端口的环境。

- `workbuddy2api.sh` — 部署 / 更新 / 停止 / 重启 / 状态自检 / 重置面板密码
- `deploy.sh` — ⚠️ **已更名**为 `workbuddy2api.sh`；此文件保留为兼容外壳，旧命令 `./deploy.sh xxx` 仍可用
- `net-check.sh` — 容器网络与出网排查
- `open-docker-ctl.sh` — 面板「一键更新」能力开关（诊断 / 开启 / 关闭），处理「套接字已挂载但容器无权限」这一中间态
- `caddy.example.conf` — 反向代理最小示例（仅反代，不含任何个人配置）

> ⚠️ **合规提醒**：workbuddy2api 是第三方账号的非官方 OpenAI 兼容网关，
> 涉及目标平台服务条款与账号风险。请仅用于**本人授权账号、私有环境测试**，
> 不要共享、转售或公网开放给他人。使用风险自负。

---

## 一、上游项目对比

| 项目 | 星数 | 定位 | 发布形态 |
|---|---|---|---|
| [Sliverkiss/workbuddy2api](https://github.com/Sliverkiss/workbuddy2api) | 1.2k | 账号池 → OpenAI 兼容网关（必须） | GHCR 镜像（多架构） |
| [ithtelab/workbuddy-manager](https://github.com/ithtelab/workbuddy-manager) | 300+ | 管理面板（推荐） | Release + GHCR 镜像 |
| [linbeize/workbuddy2api-gui](https://github.com/linbeize/workbuddy2api-gui) | 30 | 轻量管理面板 | 仅源码自构建 |

**面板选型结论**：需要**多密钥分发 / 用量审计 / IP 管控 / 网页一键更新**就用
`workbuddy-manager`（它被上游 README 列为社区前端面板，两者解耦、互不改代码）；
服务器资源极紧、只需账号运维才考虑 `workbuddy2api-gui`。

---

## 二、快速开始

```bash
git clone <本仓库>
cd workbuddy2api-manager
chmod +x workbuddy2api.sh

# 常规服务器（Docker bridge 网络正常）
./workbuddy2api.sh

# LXC / 容器里跑 Docker，或容器出网不通（见第五节）
NET_MODE=host ./workbuddy2api.sh
```

> 📌 **主脚本已从 `deploy.sh` 更名为 `workbuddy2api.sh`**（R1.0.1）。
> 旧命令 `./deploy.sh xxx` 仍然可用（同目录留了兼容外壳，透传到新脚本），
> 所以**已经部署好的服务器不需要做任何事**，也不用重跑脚本。
> 新文档统一用 `./workbuddy2api.sh`。

脚本会：写上游 `config.json` → 生成两份 compose → 修正数据目录属主 →
拉镜像 → 启动 → **端口链 + 登录接口 + 容器出网三重自检**。

Caddy 部分**脚本不碰**，照着 `caddy.example.conf` 自己加到 Caddyfile 里。

### 常用参数

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `NET_MODE` | `bridge` | `host` 用于 bridge 出网不通的环境 |
| `GW_PORT` / `PANEL_PORT` | `17863` / `17864` | 宿主侧端口 |
| `DOMAIN` | `workbuddy.example.com` | 仅用于打印提示与 Caddy 片段 |
| `PANEL_PASSWORD` | 首次自动生成 | 仅在首次部署（`users.json` 不存在）时生效 |
| `PULL_IMAGE` | `1` | 设为 `0` 跳过拉镜像 |
| `SECURE_COOKIE` | `true` | 走 HTTPS 就保持 true |

### 日常命令

```bash
./workbuddy2api.sh status           # 状态 + 端口链 + 登录链路 + 出网自检
./workbuddy2api.sh logs             # 跟踪日志
./workbuddy2api.sh restart          # 重启两个容器
./workbuddy2api.sh stop             # 停止
./workbuddy2api.sh reset-password   # 重置面板密码（随机生成）
./workbuddy2api.sh reset-password '新密码'
./workbuddy2api.sh                  # 再次运行 = 更新（自动停旧起新）
```

---

## 三、端口设计

系统一律用**高位端口**对外（绕开部分面板对低位端口的限制），
容器内端口按镜像实际情况决定：

| 容器 | 容器内监听 | 映射方式 |
|---|---|---|
| workbuddy2api | `config.json` 的 `listen`（脚本设为 `GW_PORT`） | `GW_PORT:GW_PORT` |
| workbuddy-manager | **写死 7864**（镜像里 `uvicorn --port 7864`） | `PANEL_PORT:7864` |

> 💡 **两个容易踩的「死配置」**（源码层面确认过，改了不生效）：
> - 面板的 `WB_MANAGER_PORT` / `WB_MANAGER_HOST` —— `config.py` 里定义了，
>   但**从不传给 uvicorn**（`config.HOST` 只被日志函数用来打警告）。
>   要改监听地址只能覆盖 `command`。
> - 上游网关**没有** `-listen` 命令行参数，但 `WB2A_LISTEN` 环境变量**真实生效**。

面板容器端口改不动，所以宿主侧想要高位端口就必须写 `17864:7864` ——
写成 `17864:17864` 会转发到容器内没人监听的端口，表现为
**Caddy 502 + healthcheck 一直 unhealthy + 面板登录页报网络错误**。

---

## 四、加账号

面板需要**直连上游平台**完成 OAuth（不经过网关），所以容器出网必须正常。

```bash
# 方式 1（推荐）：登录面板 → 账号页 → 添加账号 → 扫码
# 方式 2：服务器终端
cd /opt/workbuddy/workbuddy2api
docker compose exec -it wb2api bash -c './login.sh'
```

> ⚠️ 账号凭证文件属主必须是容器运行用户（uid 10001），否则网关扫描时
> **静默跳过**该文件，表现为「账号已添加但池里显示未加载，重启也无效」。
> 脚本已自动 `chown 10001`，手动添加时注意。

---

## 五、故障排查

### 5.1 面板登录页报「网络错误」/ Caddy 502

按顺序查：

```bash
./workbuddy2api.sh status
```

看自检输出：

- **端口链不通** → 映射写错了。面板容器内固定 7864，
  正确写法 `127.0.0.1:17864:7864`
- **登录接口不通** → 面板容器没起来，`docker logs --tail 50 workbuddy-manager`

### 5.2 「反代上游不可用」/ ConnectError

面板容器连不上网关。先确认：

```bash
docker exec workbuddy-manager sh -c 'curl -s http://127.0.0.1:17863/healthz'
```

不通时按 `NET_MODE` 区分：

- **bridge 模式**：两个容器各在 `docker compose` 自建的网络里，
  `172.17.0.1` 或 `host.docker.internal` 未必可达。
  最稳的做法是让两者进**同一网络**、用容器名互访
- **host 模式**：`WB2API_BASE` 应为 `http://127.0.0.1:GW_PORT`

### 5.3 容器出网全挂（连 baidu 都超时）

**LXC 里跑 Docker 的典型症状**：宿主机出网正常，容器内全部超时。
用 host 网络绕过：

```bash
NET_MODE=host ./workbuddy2api.sh
```

> 这是**绕过**而非修复。想根治要查宿主机侧：
> `cat /proc/sys/net/ipv4/ip_forward`、
> `iptables -t nat -L POSTROUTING -n -v`、
> `iptables -L FORWARD -n -v`。
> LXC 场景常需在 **PVE 宿主**上放开 apparmor / FORWARD 策略，
> 改容器内配置可能不生效。

### 5.4 登录提示「用户名或密码错误」

面板**只在 `users.json` 不存在时**读取 `WB_ADMIN_PASSWORD`（源码
`security.load_users()`），之后完全以文件里的哈希为准 ——
**环境变量再改也不生效**。

```bash
./workbuddy2api.sh reset-password '新密码'
```

脚本会备份 `users.json`、用与面板一致的 PBKDF2-SHA256（26 万次迭代）
写回新哈希，并递增会话版本以吊销所有已登录会话。

> 连续输错会按 **IP + 用户名双维度**锁定 10 分钟；此时接口返回 429。

### 5.5 Caddy `reload` 失败

```bash
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

**最常见的报错**：`File to import not found: xxx`
—— `import` 引用的 snippet **必须先在文件里定义好**（snippet 定义与
站点引用是两个步骤）。

失败时原配置仍在运行，**服务不受影响**，修好再 reload 即可。

### 5.6 端到端排查

```bash
sh net-check.sh
```

一次性检查：两个容器的网络归属、容器间可达性、容器出网、
面板/网关健康状态、完整 MASQUERADE 规则。

### 5.7 网关容器一直 `unhealthy`（服务其实是好的）

**症状**：`docker ps` 里网关显示 `Up N hours (unhealthy)`，但实际转发一切正常
（日志里全是 `200`、有 TTFB 和吞吐数字）。

**原因**：官方镜像的 healthcheck **写死探测自身默认端口**：

```bash
# 看镜像内置的探针
docker inspect workbuddy2api --format '{{json .Config.Healthcheck}}' | python3 -m json.tool
# → "wget -qO- http://127.0.0.1:7863/healthz || exit 1"
```

而本脚本让网关监听的是 `GW_PORT`（默认 `17863`）。**763 ≠ 17863**，
探针永远连不上 → 连续失败几千次。

> ℹ️ 本脚本 **R1.0.2 起已在生成的 compose 里覆盖 healthcheck**，新部署不会再遇到。
> 只有用旧版脚本部署的机器需要按下文手动补。

**危害不只是"显示红色"**：告警会彻底失效 —— 永远是红的，
将来服务**真的**挂掉时你也看不出来。

**修复**（往 compose 的 `wb2api` 服务里加一段）：

```yaml
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:17863/healthz || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
```

⚠️ 端口要填**实际监听端口**（`WB2A_LISTEN` 里的那个，默认 17863）。
`restart` 不生效，必须重建：

```bash
cd /opt/workbuddy/workbuddy2api && docker compose up -d --force-recreate && sleep 45 && docker ps | grep workbuddy
```

### 5.8 面板提示「当前环境无法操作 docker」

**症状**：面板「一键更新」区域显示：

> 当前环境无法操作 docker（宿主未安装 docker，或容器未挂载 /var/run/docker.sock）…

**这句话有误导性 —— 它把三类完全不同的情况混成一句提示。** 宿主有 docker
（1Panel 必然有）时，**最常见的原因其实是权限，不是挂载**：套接字确实挂进去了，
但容器进程读不到，`permission denied` 被面板笼统显示成了"未挂载"。

#### 先搞清楚官方是怎么设计的

上游仓库 `docker-compose.yml` 里两处注释直接说明了设计意图：

- 文件头：「容器版**能**在界面上更新上游 —— 镜像内置了 docker CLI 与 compose 插件，
  **挂上 docker.sock 后即可在容器内重建上游容器**。不挂时降级为「请到宿主机操作」」
- volumes：「**安全性说明（值得读）**：挂 docker.sock 等于把宿主 root 权限交给本容器。
  但这**不是新增的风险等级** —— 宿主部署时本服务本来就是 root 运行
  （systemd 单元无 `User=`、安装脚本要求 root），而 root 进程本来就能
  `docker run -v /:/host`。**两者权限等价。**」

**两个关键结论：**

1. **官方 compose 里 socket 那行默认就是启用的**，不是选装项。所以"要不要挂"
   在多数部署里已经既成事实 —— 加 `group_add` 只是让**已经挂着的**套接字真正生效。
2. **"挂了 socket = 新增风险"是个误解。** 官方部署路径本来就以 root 运行，
   权限本来就等价。真正的风险点在于**面板本身是否暴露公网**，而不是这一行配置。

> ⚠️ 但"权限等价"不等于"没风险"——它意味着**风险一直存在，且由部署方式决定**。
> 如果这台机器上面板曾暴露公网、或多人共用，那风险是真实且高的（见第六节）。

#### 诊断：三步定位，别猜

```bash
# ① 套接字有没有挂进面板容器
docker inspect workbuddy-manager --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' | grep docker.sock

# ② 面板容器里的用户身份
docker exec workbuddy-manager id        # 期望看到 groups=10001(app),995(docker)

# ③ 宿主 docker 组 GID
getent group docker                     # 例如 docker:x:995:

# ④ ★ 决定性证据：容器里能不能真的调通 docker
docker exec workbuddy-manager docker ps
```

**④ 的报错文案决定修法，这两种完全不同：**

| ④ 报什么 | 含义 | 修法 |
|---|---|---|
| `permission denied while trying to connect to the Docker daemon socket` | **权限问题**：套接字挂上了，但容器非 root 且不在 docker 组 | 补 `group_add`（见下） |
| `command not found` / `not found` | **镜像问题**：容器里压根没有 docker CLI | 补 `group_add` **无效**！需换回官方镜像 |
| 正常列出容器 | 已经能用 | 无需操作 |

「挂了但没权限」这个中间态官方没覆盖 —— 他的 compose 假设"挂上就能用"，
但没考虑容器以非 root 且不在 docker 组运行的情况（1Panel 环境常见）。

#### 修法：补一行 group_add

```yaml
# workbuddy-manager 服务的 volumes 之后加
    group_add:
      - "995"      # GID 以 getent group docker 的实际输出为准，不要照抄 995
```

```bash
cd /opt/workbuddy/workbuddy-manager
docker compose up -d --force-recreate workbuddy-manager

# 验证两条都要过
docker exec workbuddy-manager id          # 应出现 ,995(docker)
docker exec workbuddy-manager docker ps   # 应正常列出容器
```

> 💡 本目录新增 **`open-docker-ctl.sh`** 把上面这套流程封装了，含诊断 + 幂等开/关：
> ```bash
> ./open-docker-ctl.sh status   # 诊断（只读，告诉你到底卡在哪一类）
> ./open-docker-ctl.sh on       # 开启（自动取宿主 GID、备份 compose、校验 YAML、重建）
> ./open-docker-ctl.sh off      # 关闭（精确移除，逐字节还原 compose）
> ```
> 它**不替你判断该不该开**，只负责正确地开/关/诊断。

#### 关闭（回到"界面提示"模式）

```bash
./open-docker-ctl.sh off
# 或手工：删掉 group_add 那两行，然后
cd /opt/workbuddy/workbuddy-manager && docker compose up -d --force-recreate workbuddy-manager
```

关闭后「一键更新」按钮降级为界面提示「请到宿主机操作」，**不会静默失败** ——
这也是官方设计的降级路径。之后用 5.9 的命令行方式更新。

#### 开了还是不开？

| 场景 | 建议 |
|---|---|
| 自用测试机 / 面板不对外 | 开，省事。面板更新上游时还会**自动重新施加端口收敛**（守住 `WB2A_LISTEN` 绑回环，比手工脚本只检测不动手强） |
| 面板曾暴露公网 / 多人共用 | 别开，用 5.9 命令行更新 |
| 只是不想每次敲命令 | 用 5.9，三行命令，效果完全一样 |

**唯一的分界线是「面板有没有被外人碰到」。** 挂 socket 不会凭空创造风险，
但会让**已存在的暴露**变成整机沦陷。

### 5.9 更新上游 / 面板（不依赖面板按钮）

面板「一键更新」不可用时，用宿主机命令，效果完全一样。

**更新上游网关**：

```bash
cd /opt/workbuddy/workbuddy2api

# 备份 —— auths/ 是账号凭据，务必确认这条成功执行
tar czf /root/wb2api-backup-$(date +%F-%H%M).tar.gz auths/ data/ config.json

# 拉新镜像 + 重建
docker compose pull && docker compose up -d --force-recreate

# 验证
sleep 45 && docker ps | grep workbuddy && curl -s -o /dev/null -w "网关 -> %{http_code}\n" http://127.0.0.1:17863/healthz
```

**更新面板**：

```bash
cd /opt/workbuddy/workbuddy-manager
tar czf /root/wb-manager-backup-$(date +%F-%H%M).tar.gz data/
docker compose pull && docker compose up -d --force-recreate
sleep 20 && docker ps | grep workbuddy
```

**三个坑**：

1. **别用 `docker compose down`** —— `down` 会删容器，若 compose 里有匿名卷，
   数据可能跟着走。`up -d --force-recreate` 足够。
2. **更新后若账号池变空** —— 多半是 `auths/` 属主问题（网关以 10001 运行，
   属主不对会**静默跳过**该文件，表现为"添加了但没加载"）：
   ```bash
   cd /opt/workbuddy/workbuddy2api && chown -R 10001:10001 auths/ && docker compose up -d --force-recreate
   ```
3. **更新期间面板会短暂报「上游不可用」** —— 属正常，容器起来即恢复。

**更新后必查监听地址**（尤其 `NET_MODE=host`，没有网络隔离兜底）：

```bash
ss -lntp | grep 17863     # 必须是 127.0.0.1:17863，若是 0.0.0.0 则已暴露公网
```

---

## 六、安全基线

- [ ] 两个容器都只绑 `127.0.0.1`，不对公网暴露
- [ ] 面板经 **HTTPS** 访问（`WB_SECURE_COOKIE=true`）
- [ ] 反代透传 `X-Real-IP`（`caddy.example.conf` 已含）
- [ ] `WB_TRUSTED_PROXY_CIDRS` 覆盖反代实际来源网段
- [ ] 面板密码为强随机值（它是唯一那道门时尤其重要）
- [ ] `auths/` 权限 `700`、属主 10001；备份文件 `600`
- [ ] 评估面板是否需要 docker 控制能力（`open-docker-ctl.sh status` 可诊断）。
      **注意**：官方 compose 默认就挂 `/var/run/docker.sock`，且原生部署本来也是 root 运行——
      挂载**不新增**风险等级；真正的分界线是**面板有没有可能被外人访问**。
      面板曾暴露公网 / 多人共用 → 用 `off` 关闭，走命令行更新（5.9）
      自用测试机 / 面板不对外 → 可开，省事且能自动重施端口收敛
- [ ] 明确这是非官方网关，仅用于本人授权账号 + 私有测试

> 面板安全机制（来自其源码）：PBKDF2-SHA256 26 万次迭代存储密码、
> HttpOnly + SameSite=Lax 签名 Cookie、登录失败 5 次锁 10 分钟、
> 网关密钥仅存 SHA-256 哈希、请求体 8 MiB 上限、每密钥限流、
> 生产默认关闭 `/docs`。
>
> 真实 IP 只采信**来自可信代理网段**的对端所写的 `X-Real-IP`
> （`X-Forwarded-For` 首段可被客户端伪造）—— 所以反代来源网段配错时，
> IP 黑白名单与登录锁定会一起失效，安全页里会看到 docker 网桥地址
> 而不是访客真实 IP。

---

## 七、目录结构

```
workbuddy2api-manager/
├── workbuddy2api.sh     # 部署 / 运维脚本（主脚本）
├── deploy.sh            # 兼容外壳，透传到 workbuddy2api.sh
├── net-check.sh         # 网络排查
├── caddy.example.conf   # 反代示例（仅最小片段）
└── README.md

# 部署后服务器上的目录：
/opt/workbuddy/
├── workbuddy2api/       # 上游网关
│   ├── auths/           # 账号凭证（700，属主 10001）
│   ├── data/            # state.json
│   ├── config.json
│   └── docker-compose.yml
└── workbuddy-manager/   # 管理面板
    ├── data/            # SQLite / users.json / 备份
    └── docker-compose.yml
```

---

## 版本记录

| 版本 | 说明 |
|---|---|
| R1.0.3 | **修正 5.8 的认知错误**：原文称「官方作者建议不挂 docker.sock」，实际读上游仓库后确认**反了** —— 官方 compose 里该行默认启用，且注释明确论证「挂 socket 与原生 root 部署权限等价，不是新增风险」。新增 `open-docker-ctl.sh`（诊断 / 开启 / 关闭面板 docker 控制能力，幂等、带 compose 备份与 YAML 校验）。重写 5.8：明确区分 `permission denied`（权限，补 group_add）与 `command not found`（缺镜像 CLI，补组无效），补齐开启/关闭完整流程与决策依据。第六节清单同步修正。 |
| R1.0.2 | **修正网关容器永远 `unhealthy`**：官方镜像 healthcheck 写死探测 `127.0.0.1:7863/healthz`，而本脚本让网关监听 `GW_PORT`（默认 17863），两者不一致导致连续失败（服务实际正常）。生成 compose 时覆盖为实际端口（host/bridge 两个分支都已处理）。此问题会让**告警彻底失效**（永远红 → 真挂了也看不出）。新增 README 5.7/5.8/5.9：unhealthy 修复、面板「无法操作 docker」的权限诊断（`group_add` 与风险）、不依赖面板按钮的上游/面板更新命令与三个坑。 |
| R1.0.1 | 主脚本 `deploy.sh` 更名为 `workbuddy2api.sh`（脚本内容与 R1.0.0 完全一致，仅自身引用文案随之更新）。原 `deploy.sh` 保留为**兼容外壳**，透传参数到新脚本，旧命令继续可用 —— 已部署的服务器无需任何操作。README 命令示例统一改为新名。 |
| R1.0.0 | 首个版本。`deploy.sh` 支持部署/更新/停止/重启/状态/日志/重置密码；`NET_MODE=host` 应对 LXC 里 Docker bridge 出网不通；三重自检（端口链 / 登录接口 / 容器出网）；修正面板容器内固定 7864 但映射写成同号导致的 502；修正「每次重跑都打印一个无效的面板密码」；`reset-password` 用与面板一致的 PBKDF2-SHA256 重写哈希并递增会话版本。附 `net-check.sh` 与 `caddy.example.conf`。 |

仅供学习交流。

