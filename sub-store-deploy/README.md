# Sub-Store 部署套件

一键部署自建 **Sub-Store**（订阅管理与节点转换），面向 1Panel / Docker 环境。

- `sub-store.sh` — 部署 / 更新 / 停止 / 重启 / 状态自检 / CORS 实测
- `sub-store.example.conf` — Caddy 与 1Panel Nginx 反向代理示例
- `README.md` — 本文件

> ⚠️ **合规提醒**：Sub-Store 里存的是你全部机场订阅与节点明文，
> 以及各家机场的订阅链接（拿到链接等于拿到你的账号额度）。
> 请务必只绑本机 + 走 HTTPS 反代，**不要**把 3001 端口直接开到公网。

---

## 一、它解决什么问题

Sub-Store 官方 README 给的 compose 只有四行：

```yaml
services:
  sub-store:
    image: xream/sub-store
    container_name: sub-store
    restart: always
    environment:
      - SUB_STORE_CRON=50 23 * * *
      - SUB_STORE_FRONTEND_BACKEND_PATH=/maxwin5566
    ports:
      - "127.0.0.1:3001:3001"
    volumes:
      - /etc/sub-store:/opt/app/data
```

照抄上线，网页端**必**遇到下面两类问题，而报错信息都不会直说是配置问题。

### 问题 ① 前端能打开，一操作就 403

```
POST https://你的域名/api/utils/env 403 (Forbidden)
CORS origin not allowed
```

Sub-Store 后端对**带 `Origin` 头的请求**做白名单校验。默认白名单里只有
它自己内置前端的那一个来源，所以：

- 用**官方在线前端** `https://sub-store.vercel.app` 连你的后端 → 被拒
- 用**反向代理出来的自建前端**（域名和 API 不同源时）→ 被拒
- 直接 `curl` 后端 API → 不带 Origin，**不会被拒**（所以自测很容易误判成"后端正常"）

**解法**：设置 `SUB_STORE_CORS_ALLOWED_ORIGINS` 列出允许的来源。
本脚本默认已包含 `https://sub-store.vercel.app` 和你的域名。

### 问题 ② 网页端能打开，但订阅列表 / 日志刷不出来

页面和 API 不是同一个来源时，浏览器的同源策略会直接拦掉 XHR。
表现常常是**空白**而不是报错，比 403 更难查。

**解法**：让页面与 API 同源 —— 这正是 `SUB_STORE_FRONTEND_BACKEND_PATH`
的用途，也是本脚本的核心设计。

---

## 二、核心设计：前后端同源

镜像**内置了前端**。配上 `SUB_STORE_FRONTEND_BACKEND_PATH=/xxx` 之后，
同一个 3001 端口上长这样：

| 请求 | 返回 |
|---|---|
| `GET /xxx` | 前端页面（HTML） |
| `GET /xxx/api/utils/env` | 接口数据（JSON） |
| `GET /xxx/api/sub/<路径>` | 订阅内容（节点文本 / base64 / clash 配置） |

所以只要**反向代理把整站转到容器端口**，浏览器访问
`https://你的域名/xxx` 时，页面与 API 就是同源：

- ① 不触发（同源请求不带 Origin 校验）
- ② 不触发（同源策略天然满足）

**一个路径同时是"网页端入口"和"订阅根地址"**，别改。

> ⚠️ **反代里不要再加 `/xxx` 前缀**。
> 站点根 `/` → `127.0.0.1:3001/`，不要写成 → `127.0.0.1:3001/xxx`，
> 否则浏览器访问 `/xxx` 时后端收到的是 `/xxx/xxx` → 404。

---

## 三、快速开始

```bash
git clone <本仓库>
cd sub-store-deploy
chmod +x sub-store.sh

DOMAIN=sub.你的域名.com ./sub-store.sh
```

脚本会：校验参数 → 生成 compose → 停旧实例 → 拉镜像 →
**强制重建容器** → 端口链自检 → 前端路径自检 → CORS 实测 → 打印反代指引。

### 常用参数

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `BACKEND_PATH` | `/substore` | 后端路径 = 网页端入口。只允许 `[A-Za-z0-9_-]+` |
| `STORE_PORT` | `127.0.0.1:3001` | 宿主侧端口。可写 `3001` / `127.0.0.1:3001` / `0.0.0.0:3001` |
| `BASE_DIR` | `/etc/sub-store` | 数据目录（订阅、节点、配置全在这） |
| `DOMAIN` | `sub.example.com` | 只用于打印提示，不影响运行 |
| `STORE_CRON` | `50 23 * * *` | 定时更新订阅的 cron（容器 TZ 为 `Asia/Shanghai`） |
| `CORS_ALLOWED_ORIGINS` | 含 vercel 前端 + 你的域名 | 跨域白名单 |
| `EXTRA_ORIGINS` | 空 | 往默认白名单里追加来源，逗号分隔 |
| `PULL_IMAGE` | `1` | 设 `0` 跳过拉镜像 |

### 日常命令

```bash
./sub-store.sh status                 # 状态 + 端口链 + 前端路径 + CORS 实测
./sub-store.sh logs                   # 跟踪日志
./sub-store.sh restart                # 重启（强制重建，刷新环境变量）
./sub-store.sh stop                   # 停止
./sub-store.sh test-cors https://xxx  # 单独测某个来源能否跨域
./sub-store.sh                        # 再次运行 = 更新（自动停旧起新）
```

> **改完 `BACKEND_PATH` 或 CORS 白名单，必须重跑 `./sub-store.sh`，不能只 `restart`。**
> Docker 的环境变量是**容器创建时**注入的，`restart` 只是重启同一个容器，
> 读的还是旧变量 —— 这是"明明改了却没生效"最常见的原因。
> 本脚本的 `restart` 子命令用的是 `docker compose up -d --force-recreate`，已规避此坑。

---

## 四、反向代理

### Caddy

见 `sub-store.example.conf`。最小片段：

```caddyfile
sub.你的域名.com {
    tls you@example.com
    encode gzip
    reverse_proxy 127.0.0.1:3001
}
```

不需要任何额外 `header_up`：订阅 URL 是直接给订阅 App 拉的，
App 侧没有"页面来源"概念，不带 Origin，CORS 根本不参与。

### 1Panel（Nginx）

```
网站 → 你的域名 → 反向代理 → 新建
  代理地址: http://127.0.0.1:3001
  代理路径: /
```

1Panel 默认生成的这行**要留着**（它负责透传真实协议与 IP）：

```nginx
proxy_set_header X-Forwarded-Proto $scheme;
```

并且确认关闭了对 `/api/sub/` 的缓存：

```nginx
location ~ ^/substore/api/sub/ {
    proxy_pass http://127.0.0.1:3001;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_cache off;
    add_header Cache-Control "no-store";
}
```

---

## 五、故障排查

### 5.1 网页端 403 / `CORS origin not allowed`

```bash
./sub-store.sh test-cors https://你的前端域名
```

输出会直接告诉你该来源放不放行。不被放行就把它加进白名单后重跑：

```bash
EXTRA_ORIGINS=https://你的前端域名 ./sub-store.sh
```

> **注意**：`curl` 测试后端**不会**复现这个错，因为 curl 不带 `Origin` 头。
> 一定要带 `-H "Origin: ..."` 才有意义（脚本内部就是这么测的）。

### 5.2 网页端能打开，但列表空白

页面与 API 不同源。**最省事的解法是直接访问同源地址**：

```
https://你的域名/<BACKEND_PATH>
```

而不是用官方在线前端去连你的后端。若确实要用官方前端，就必须把
`https://sub-store.vercel.app` 留在 CORS 白名单里。

### 5.3 打开 `https://域名/<BACKEND_PATH>` 显示一屏节点文本

说明这个路径被一个**同名订阅**占用了，前端被遮住。

Sub-Store 里生成订阅时如果填的路径刚好等于 `BACKEND_PATH`，就会这样。
换个路径重跑：

```bash
BACKEND_PATH=/substore-2 ./sub-store.sh
```

### 5.4 改完环境变量没生效

```bash
./sub-store.sh status    # 看「容器内环境变量」那一段
```

如果里面还是旧值 → 容器没被重建，重跑 `./sub-store.sh`（不是 `restart`）。

### 5.5 404 / 502

- **404**：多半是反代里多加了 `/<BACKEND_PATH>` 前缀（见第二节警告）
- **502**：容器没起来。`docker logs --tail 50 sub-store`；
  再看端口链：`./sub-store.sh status`

### 5.6 订阅更新失败

```bash
./sub-store.sh logs | grep -iE 'error|fail|timeout'
```

本套件启动时会做**容器出网自检**。若自检已报"出网不通"，
那就是宿主机的 Docker bridge NAT 问题（LXC 里跑 Docker 的经典症状），
需要在 compose 里加 `network_mode: host` 并自行处理端口绑定。

### 5.7 端口被占用

1Panel 里装过 Sub-Store 应用、或旧容器没删干净，都会占着 3001：

```bash
docker ps -a | grep -i sub-store
docker rm -f sub-store
# 或换端口
STORE_PORT=127.0.0.1:3301 ./sub-store.sh
```

---

## 六、安全基线

- [ ] 端口只绑 `127.0.0.1`，公网访问一律走反代（脚本默认已是）
- [ ] 反代**必须**是 HTTPS（订阅链接会到处分发，明文等于送人）
- [ ] `BACKEND_PATH` 不要用 `/sub` `/store` 这类可猜路径，等价于后台入口
- [ ] 反代层加 IP 白名单 / 面板侧 WAF（可选，但后台入口值得）
- [ ] 定期备份 `BASE_DIR`（里面是全部订阅和配置）
- [ ] 不要把 `BASE_DIR` 放进任何同步盘 / 公开仓库

> Sub-Store 的"登录口令"是**可选**的，且只保护前端页面本身，
> 拿到订阅 URL 的人无需口令即可拉取节点。
> 所以真正的门是"路径猜不到 + HTTPS + 不公开端口"这三样。

---

## 七、目录结构

```
sub-store-deploy/
├── sub-store.sh             # 部署 / 运维脚本
├── sub-store.example.conf   # 反代示例（Caddy + 1Panel Nginx）
└── README.md

# 部署后服务器上的目录：
/etc/sub-store/              # 数据目录（BASE_DIR）
├── docker-compose.yml       # 由脚本生成，带 managed-by marker
└── ...                      # Sub-Store 自身的订阅 / 节点 / 配置数据
```

---

## 版本记录

| 版本 | 说明 |
|---|---|
| R1.0.0 | 首个版本。`sub-store.sh` 支持部署/更新/停止/重启/状态/日志/`test-cors`；默认写入 `SUB_STORE_CORS_ALLOWED_ORIGINS` 解决「网页端 403 CORS origin not allowed」；默认写入 `SUB_STORE_FRONTEND_BACKEND_PATH` 并做**前端路径自检**（校验返回 HTML 而非同名订阅文本）解决「列表空白」；`BACKEND_PATH` 在生成文件前做强校验，避免拼出双前缀 404；环境变量变更加 `--force-recreate` 自动重建容器；三重自检（端口链 / 前端路径 / CORS 实测）+ 容器出网自检。 |

仅供学习交流。
