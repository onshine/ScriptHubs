#!/usr/bin/env bash
# 9Router 部署 / 更新脚本 R1.1.1
#
# 版本记录见同目录 README.md 末尾「版本记录」表。
# 适用：1Panel 服务器（Docker + docker compose v2），amd64 / arm64
#
# ⚠️ 本脚本【绝对不会】读取、写入、备份或 reload 任何 Caddy 配置。
#    Caddy 改动请照同目录 9router.example.conf 自己在编辑器里做。
#
# ── 关于 9Router（读源码后确认的事实，不是猜的）──────────────
#   项目：https://github.com/decolua/9router  (MIT, JS/Next.js)
#   作用：把 Claude Code / Codex / Gemini CLI / Copilot / Kiro / iFlow 等
#         40+ 家上游收敛成一个 OpenAI 兼容端点，支持配额追踪 + 自动降级。
#
#   官方镜像：decolua/9router:latest（多平台 amd64+arm64）
#   容器内固定：PORT=20128、HOSTNAME=0.0.0.0、DATA_DIR=/app/data
#
#   ★ 本脚本的两个关键设计，都踩在官方 compose/DOCKER.md 的默认值上：
#
#   ① 端口映射写成  127.0.0.1:${PORT}:20128
#      官方 compose 写的是 "20128:20128"，等于把网关挂在 0.0.0.0 公网。
#      这个网关**持有你全部上游账号的 OAuth token**（Claude/Codex/Copilot），
#      还有能直接花你额度的 /v1 接口。所以本脚本只绑回环，一律靠 Caddy 出网。
#
#   ② healthcheck 显式覆盖
#      官方镜像默认探针是 127.0.0.1:20128/api/health。本脚本不改容器内端口，
#      所以理论上一致；但仍显式写一遍 —— 将来镜像换端口时，
#      「容器永远 unhealthy 但服务其实是好的」这类静默故障会立刻暴露。
#      （同一套坑在 workbuddy2api-manager 里已经踩过一次。）
#
# ── 登录密码（这条不设就直接废）────────────────────────────
#   9Router 首次登录密码默认 123456。而源码 src/app/api/auth/login/route.js
#   有一段 CVE-2026-56679 修复逻辑：
#       mustChangePassword = 没设过密码 hash && 没设 INITIAL_PASSWORD && 非本机请求
#   命中时**拒绝下发 JWT**，并提示「必须在本机改密码」。
#   而「本机」判定（src/dashboardGuard.js isLocalRequest）在反代场景下必然为假：
#   自定义服务器给经代理的请求打上 x-9r-via-proxy 头 → 直接 return false。
#
#   ⇒ 结论：远程部署**必须**在第一次启动前就把 INITIAL_PASSWORD 写进 .env，
#     否则你从浏览器登录会一直被 403 挡在门外。容器里没有"本机浏览器"这条路
#     可走，等于账号进不去。本脚本默认替你随机生成并写死。
#
# 用法：
#   ./9router.sh                      # 部署或更新（自动停旧实例再起新的）
#   ./9router.sh stop                 # 只停止容器
#   ./9router.sh restart              # 只重启容器（强制重建，重读 .env）
#   ./9router.sh status               # 状态 + 监听地址 + 端口链 + 登录链路自检
#   ./9router.sh logs                 # 跟踪日志
#   ./9router.sh reset-password [新密码]
#
#   NET_MODE=host ./9router.sh        # LXC 里 bridge 出网不通时用这个
set -euo pipefail

SCRIPT_VERSION="R1.1.1"

# ============ CONFIG（可用环境变量覆盖） ============
DOMAIN="${DOMAIN:-9router.example.com}"
BASE_DIR="${BASE_DIR:-/opt/9router}"
# PORT 的含义随 NET_MODE 变化：
#   bridge → 宿主侧端口（容器内固定 CTR_PORT，靠 docker-proxy 映射）
#   host   → 唯一的监听端口：容器与宿主共用网络栈，只有这一个端口
PORT="${PORT:-15900}"
CTR_PORT="${CTR_PORT:-20128}"   # 官方镜像默认值，bridge 模式下用作容器内端口
CONTAINER_NAME="${CONTAINER_NAME:-9router}"
IMAGE="${IMAGE:-decolua/9router:latest}"
# 网络模式：bridge（默认）| host
#
# 什么时候需要 NET_MODE=host：
#   在 LXC 里跑 Docker 时（主机名 ct* / PVE 容器），bridge 的 NAT 出网经常是坏的
#   —— 表现为容器内连 github.com 都超时，但宿主机一切正常。此时用 host 绕过整条
#   NAT 路径。（本套件的出网自检就是专门抓这个的；workbuddy2api-manager 同样。）
#
# ⚠️ host 模式下的安全要点（与 workbuddy 那套不同，9Router 没有 LISTEN 变量）：
#   host 模式没有网络隔离兜底，9Router 只能通过 PORT / HOSTNAME 两个环境变量
#   控制绑定地址。而官方镜像的 Dockerfile 把 HOSTNAME=0.0.0.0 烤死了，只看 compose
#   的 environment 会漏掉入口脚本里的那个 —— 一旦漏掉，网关会直接监听宿主机
#   0.0.0.0:PORT，把「持有全部上游 OAuth token」的接口挂上公网。
#   所以本脚本在 host 模式下：
#     · 把 PORT 和 HOSTNAME 两个变量都显式写进 compose（不依赖镜像默认值）
#     · 启动后【硬断言】实际监听地址必须是 127.0.0.1，是 0.0.0.0 就立即报警
#   （已核对 Next 16.1.6 standalone 模板：hostname = process.env.HOSTNAME || '0.0.0.0'，
#     确实是环境变量驱动，所以这条路可行。）
NET_MODE="${NET_MODE:-bridge}"
# Docker 网络名（仅 bridge 模式用；compose 派生名 = app_default）
DOCKER_NET="${DOCKER_NET:-app_default}"
# 首次登录密码。留空则自动生成随机密码并写入 .env（仅首次）。
# ⚠️ 改这个变量【不会】改已部署实例的密码 —— 见上面「登录密码」一节，
#    请用 ./9router.sh reset-password '新密码'
PANEL_PASSWORD="${PANEL_PASSWORD:-}"
# 在 /v1/* 上强制 Bearer API Key。默认 1（推荐）。
# 9Router 既是网关又是仪表板，只靠回环绑定防不住配置失误，加一层钥匙更稳。
REQUIRE_API_KEY="${REQUIRE_API_KEY:-1}"
# 强制 Secure 认证 cookie。走 HTTPS 域名访问 → true。
# 不用 auto：auto 依赖反代透传 X-Forwarded-Proto，一旦中间链路变了而没传，
# 会静默降级为不带 Secure ——「以为安全其实没有」比明确报错更危险。
SECURE_COOKIE="${SECURE_COOKIE:-true}"
# 出站代理（可选）。给上游提供商调用用，不是给入站用。
# 例：OUTBOUND_PROXY=http://127.0.0.1:7890
OUTBOUND_PROXY="${OUTBOUND_PROXY:-}"
TZ_NAME="${TZ_NAME:-Asia/Shanghai}"
PULL_IMAGE="${PULL_IMAGE:-1}"          # 1 = 启动前拉最新镜像
UPDATE_COMPOSE="${UPDATE_COMPOSE:-1}"  # 1 = 本脚本生成过的 compose 允许自动更新
# ====================================================

C_GREEN='\033[32m'; C_YELLO='\033[33m'; C_RED='\033[31m'; C_OFF='\033[0m'
log()  { echo -e "${C_GREEN}[+]${C_OFF} $*"; }
warn() { echo -e "${C_YELLO}[!]${C_OFF} $*"; }
die()  { echo -e "${C_RED}[x]${C_OFF} $*" >&2; exit 1; }

APP_DIR="$BASE_DIR/app"
DATA_DIR="$BASE_DIR/data"
ENV_FILE="$BASE_DIR/.env"
MODE_FILE="$BASE_DIR/.net_mode"     # 记录当前网络模式（bridge/host），供模式切换检测
COMPOSE_MARKER="# managed-by: 9router-deploy"

# ─────────────────────────────────────────────────────────────
# 端口占用探测（/proc → netstat → TCP 连接，三路兜底）
# ─────────────────────────────────────────────────────────────
port_hex() { printf '%04X' "$1" 2>/dev/null; }

_busy_netstat() { command -v netstat >/dev/null 2>&1 && netstat -lnt 2>/dev/null | awk 'NR>2{print $4}' | grep -qE "[:.]$1$"; }
_busy_proc() {
  local h; h=$(port_hex "$1") || return 1
  local f
  for f in /proc/net/tcp /proc/net/tcp6; do
    [[ -r "$f" ]] || continue
    awk -v h="$h" 'NR>1 && $4=="0A" {split($2,a,":"); if (toupper(a[2])==h) found=1} END{exit !found}' "$f" && return 0
  done
  return 1
}
_busy_tcp() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
s.settimeout(0.4)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
    sys.exit(0)
except Exception:
    sys.exit(1)
finally:
    s.close()
PY
}
port_busy() { _busy_proc "$1" || _busy_netstat "$1" || _busy_tcp "$1"; }

port_owner() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {print $6; exit}'
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$p" -sTCP:LISTEN -P -n 2>/dev/null | awk 'NR==2{print $1" pid="$2}'
  fi
}

# ─────────────────────────────────────────────────────────────
# 自检：宿主 → 容器 的端口链（最容易静默失败的一环）
# ─────────────────────────────────────────────────────────────
probe_in_container() {
  local name="$1" port="$2" path="$3"
  docker exec "$name" sh -c "wget -qO- --timeout=3 http://127.0.0.1:${port}${path} >/dev/null 2>&1"
}

check_port_chain() {
  local name="$1" host_port="$2" ctr_port="$3" path="$4" label="$5"
  printf '  %s: ' "$label"

  if ! docker ps --format '{{.Names}}' | grep -qx "$name"; then
    echo "容器未运行"; return 1
  fi

  # 1) 容器内自探（证明进程在监听、路径对）
  if ! probe_in_container "$name" "$ctr_port" "$path"; then
    echo "容器内 ${ctr_port}${path} 不通 → 进程没起来或探针路径变了"
    return 1
  fi

  # 2) 宿主端口探（证明映射正确）
  if ! _busy_tcp "$host_port"; then
    echo "宿主 ${host_port} 无人监听 → 端口映射写错了"
    return 1
  fi

  # 3) 端到端 HTTP（证明能返回 200）
  if command -v curl >/dev/null 2>&1; then
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${host_port}${path}" || echo 000)
    if [[ "$code" == "200" ]]; then
      echo "OK（容器内 ${ctr_port} → 宿主 ${host_port}，HTTP 200）"
      return 0
    fi
    echo "宿主 ${host_port} 返回 HTTP ${code}（期望 200）"
    return 1
  fi
  echo "OK（容器内 ${ctr_port} → 宿主 ${host_port}）"
  return 0
}

# ─────────────────────────────────────────────────────────────
# 自检：登录链路
#
# 这一步专门抓「默认密码 + 反代」那个 403：
#   反代场景下 isLocalRequest 恒为 false，只要 INITIAL_PASSWORD 没设，
#   登录接口会一律拒绝下发 JWT，界面上表现为「密码没写错却进不去」。
# ─────────────────────────────────────────────────────────────
login_selftest() {
  local port="$1" pwd="$2" code body
  printf '  登录接口: '

  [[ -n "$pwd" ]] || { echo "跳过（不知道密码）"; return 0; }
  command -v curl >/dev/null 2>&1 || { echo "跳过（无 curl）"; return 0; }

  body=$(curl -s --max-time 8 -X POST "http://127.0.0.1:${port}/api/auth/login" \
      -H 'Content-Type: application/json' \
      -d "{\"password\":\"${pwd}\"}" 2>/dev/null || echo '{}')
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST "http://127.0.0.1:${port}/api/auth/login" \
      -H 'Content-Type: application/json' \
      -d "{\"password\":\"${pwd}\"}" 2>/dev/null || echo 000)

  if [[ "$code" == "200" ]] && echo "$body" | grep -q '"success":true'; then
    echo "OK（HTTP 200）"
    return 0
  fi

  echo "HTTP ${code}"
  if echo "$body" | grep -q 'mustChangePassword'; then
    warn "命中了「默认密码必须先在本机修改」保护（源码 login/route.js）。"
    warn "  原因：INITIAL_PASSWORD 没设置，且反代场景下 isLocalRequest 恒为 false。"
    warn "  修法：在 ${ENV_FILE} 里设 INITIAL_PASSWORD='强密码'，然后"
    warn "        cd ${APP_DIR} && docker compose up -d --force-recreate"
    warn "        ⚠️ 必须 --force-recreate：环境变量是【创建容器时】注入的，restart 读不到新值"
  elif echo "$body" | grep -q 'Too many failed'; then
    warn "登录限流已触发（连续失败过多）。等几分钟再试，或用正确密码。"
  else
    warn "登录失败，返回：$(echo "$body" | head -c 200)"
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────
# 自检：上游可达性
#
# ⚠️ 探针必须打【真实的 LLM 上游域名】，不能拿随便一个大站当标准。
#    R1.1.0 之前这里探的是 api.github.com（失败再退到 www.baidu.com），
#    结果在一台能连 OpenAI/Anthropic、但连不上 github/百度的机器上
#    报了假警报 —— 用户白排查一轮。判定"有没有网"必须用用户真正要连的目标。
#
#    上游域名取自 9Router 自己的 provider registry
#    （open-sse/providers/registry/*.js 里的 baseUrl），不是我猜的。
#
# 判定标准：【任何 HTTP 状态码都算通】。403/404/421 只说明服务器正常应答了，
# TCP+TLS 链路是完整的；只有连不上 / 超时 / DNS 失败才算不通。
# ─────────────────────────────────────────────────────────────

# 上游清单： label|URL
# 挑的是 9Router 常用上游，且域名各自独立（能覆盖不同的出站策略）
UPSTREAM_PROBES=(
  "OpenAI|https://api.openai.com"
  "Anthropic|https://api.anthropic.com"
  "OpenRouter|https://openrouter.ai/api/v1"
  "Google Gemini|https://generativelanguage.googleapis.com"
  "DeepSeek|https://api.deepseek.com"
  "GitHub|https://api.github.com"
)

# 探一个 URL，只看"能不能连上"。
#   0 = 连上了（任何 HTTP 码）   1 = 连不上/超时/DNS 失败
# 用 wget 而不是 curl：官方镜像基于 Alpine，wget 一定在；curl 不一定。
_probe_url() {
  local url="$1" timeout="${2:-8}"
  # wget 对 4xx/5xx 会返回非 0，所以不能拿退出码当判据 —— 要看有没有回显
  # 到 "HTTP/" 或 "saving to" 之类的握手痕迹。这里用 -S 把响应头打到 stderr，
  # 只要出现过 HTTP/x.x 就说明握手成功。
  local out
  out=$(wget -S -O /dev/null --timeout="$timeout" --tries=1 "$url" 2>&1) || true
  if printf '%s' "$out" | grep -qE 'HTTP/[0-9]\.[0-9]|Misdirected Request|server returned error'; then
    return 0
  fi
  return 1
}

egress_selftest() {
  local name="$1" label="$2"
  local ok=0 fail=0 line name_l url
  local failed_list=""

  printf '  %s上游可达性: ' "$label"
  docker ps --format '{{.Names}}' | grep -qx "$name" || { echo "容器未运行"; return 1; }

  for line in "${UPSTREAM_PROBES[@]}"; do
    name_l="${line%%|*}"
    url="${line##*|}"
    if _probe_url "$url" 8; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
      failed_list="${failed_list}${name_l} "
    fi
  done

  if [[ "$fail" == "0" ]]; then
    echo "全部 ${ok} 个上游可达"
    return 0
  fi

  echo "${ok} 个可达 / ${fail} 个不可达"
  echo "      ❌ 不可达：${failed_list}"
  if [[ "$ok" == "0" ]]; then
    warn "     全部上游都连不上 —— 这台机器确实出不了网"
    warn "     · 先确认宿主机自己能不能连（curl -I https://api.openai.com）"
    warn "     · 宿主机也不通 = 机器网络/防火墙问题，与 Docker 无关"
    warn "     · 宿主机通、容器不通 = 试试 NET_MODE=host 绕过 bridge NAT"
  else
    warn "     部分上游不可达。9Router 只能转发【可达】的那几家，"
    warn "     配置上游时请优先选上面 ✅ 可达的（连不通的连了也只会一直报错）。"
  fi
  # 全部不可达时顺手区分一下 DNS / 路由，省得再问一轮
  if [[ "$ok" == "0" ]]; then
    egress_diagnose "$name" || true
  fi
  return 1
}

# 在容器里探一个 URL（同 _probe_url 的判据）
_docker_probe() {
  local name="$1" url="$2" timeout="${3:-8}"
  docker exec "$name" sh -c \
    "wget -S -O /dev/null --timeout=${timeout} --tries=1 '${url}' 2>&1 | grep -qE 'HTTP/[0-9]\.[0-9]|Misdirected Request|server returned error'" \
    2>/dev/null
}

# DNS vs 路由 的区分诊断：解析得到但连不上 = 路由/防火墙问题
egress_diagnose() {
  local name="$1"
  local host="api.openai.com"
  printf '  DNS 解析 %s: ' "$host"
  local ip
  ip=$(docker exec "$name" sh -c "getent hosts ${host} 2>/dev/null | head -1 | awk '{print \$1}'" 2>/dev/null || true)
  if [[ -z "$ip" ]]; then
    echo "解析失败 → DNS 问题"
    warn "     容器内的 /etc/resolv.conf 指向的 DNS 不可达。"
    warn "     host 模式下容器用的是宿主的 resolv.conf，先查宿主机能不能解析："
    warn "       getent hosts ${host}"
    return 1
  fi
  echo "$ip"
  if _docker_probe "$name" "http://${ip}" 4; then
    log "     且用 IP 直连可达 → 说明网络通，问题只在 DNS 解析环节"
  else
    warn "     但用 IP 直连也不可达 → 是路由/防火墙在拦（不是 DNS 问题）"
    warn "     这种只能从机器/网关层面放行，9Router 本身绕不过去"
  fi
  return 0
}


# ─────────────────────────────────────────────────────────────
# 停止
# ─────────────────────────────────────────────────────────────
compose_down() {
  local dir="$1" name="$2"
  if [[ -f "$dir/docker-compose.yml" || -f "$dir/compose.yml" ]]; then
    (cd "$dir" && docker compose down --remove-orphans >/dev/null 2>&1) || true
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    docker rm -f "$name" >/dev/null 2>&1 || true
    log "已移除容器 $name"
  fi
}

stop_all() {
  log "停止旧实例（若存在）"
  compose_down "$APP_DIR" "$CONTAINER_NAME"
  local i
  for i in $(seq 1 15); do
    port_busy "$PORT" || return 0
    sleep 1
  done
  warn "等待 15s 后端口 ${PORT} 仍被占用"
  return 1
}

# ─────────────────────────────────────────────────────────────
# compose 同步：只在「是本脚本生成的」前提下才覆盖，且先备份
# ─────────────────────────────────────────────────────────────
is_our_compose() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep -qF "$COMPOSE_MARKER" "$f" && return 0
  grep -qF "decolua/9router" "$f" && return 0
  return 1
}

sync_compose() {
  local dir="$1" label="$2" tmp
  local path="$dir/docker-compose.yml"
  tmp=$(mktemp)
  cat > "$tmp"

  if [[ ! -f "$path" ]]; then
    mv "$tmp" "$path"; log "写入 $label compose"
    return 0
  fi
  if cmp -s "$tmp" "$path"; then
    rm -f "$tmp"; log "$label compose 已是最新"
    return 0
  fi
  if is_our_compose "$path" && [[ "$UPDATE_COMPOSE" == "1" ]]; then
    local bak="$path.bak.$(date +%Y%m%d%H%M%S)"
    cp "$path" "$bak"
    mv "$tmp" "$path"
    log "$label compose 已更新（旧文件备份：$bak）"
    return 0
  fi
  rm -f "$tmp"
  warn "$label compose 不是本脚本生成的，保持不动：$path"
  warn "  如需自动管理，请先手动备份并删除该文件，再重跑本脚本。"
  return 1
}

# ─────────────────────────────────────────────────────────────
# .env 读写
#
# 9Router 的 .env 里最要命的一行是 INITIAL_PASSWORD：
# 它只在【没有保存过密码 hash】的首次启动时生效，之后就无效了。
# 所以「改 .env 不改密码」，改密码必须走 reset-password。
# ─────────────────────────────────────────────────────────────
env_get() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 1
  grep -m1 -E "^${key}=" "$ENV_FILE" 2>/dev/null | sed "s/^${key}=//" | sed 's/^"//; s/"$//'
}

env_set() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

# 生成 20 位密码。
#
# ⚠️ 不用 `head -c 18 /dev/urandom | base64 | tr -d '/+='`：
#    18 字节恰好是 3 的倍数 → base64 输出正好 24 字符、**无填充**，
#    每字符 6 bit = 144 bit，去掉 '/+=' 三个字符后平均剩 21.5 字符。
#    但取值是 64 个字符均匀分布，落在那 3 个被删字符上的概率是 3/64，
#    → 期望剩余 24×(61/64) ≈ 22.9，**有极小概率低于 20**
#    （实测 3000 次出现 1 次长度 19，概率约 3.3e-4）。
#    短一位不影响安全性，但会让"密码长度"这类断言不稳。
#    这里改成最多重试 10 次，保证长度恒为 20。
gen_password() {
  local p i
  for i in $(seq 1 10); do
    p=$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n')
    if [[ ${#p} -ge 20 ]]; then
      printf '%s' "${p:0:20}"
      return 0
    fi
  done
  # 兜底（实际上到不了）：hex 是安全的字符集且长度确定
  printf '%s' "$(head -c 10 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

# ─────────────────────────────────────────────────────────────
# 重置登录密码
#
# 事实（README 故障排除 + 源码 login/route.js）：
#   · 有 storedHash 时用 bcrypt 比对数据库里的 hash，.env 完全无效
#   · 密码存在 DATA_DIR 的数据库里，不是文本文件，不能 sed
#   · 官方口径是走 CLI 的 Settings → Reset Password to Default
# ⇒ 实现：把数据库挪走（先整目录备份）→ 让应用重新初始化 →
#   用新的 INITIAL_PASSWORD 登录。对单用户自建实例最稳、最可解释。
# ─────────────────────────────────────────────────────────────
reset_password() {
  local newpwd="$1"
  [[ -d "$DATA_DIR" ]] || die "找不到数据目录 $DATA_DIR（还没部署过？先执行 ./9router.sh）"

  local stamp; stamp=$(date +%Y%m%d%H%M%S)
  local bak="$BASE_DIR/data-backup-$stamp"
  log "备份数据目录 → $bak"
  cp -a "$DATA_DIR" "$bak"

  env_set "INITIAL_PASSWORD" "$newpwd"

  log "停止容器"
  compose_down "$APP_DIR" "$CONTAINER_NAME"

  local moved=0 f
  for f in "$DATA_DIR"/db/*.sqlite "$DATA_DIR"/*.sqlite "$DATA_DIR"/db.json; do
    [[ -e "$f" ]] || continue
    mv "$f" "$f.reset.$stamp"
    moved=1
  done
  if [[ "$moved" != "1" ]]; then
    warn "没找到数据库文件，改用整体挪走（保留备份）"
    mv "$DATA_DIR" "$DATA_DIR.old.$stamp"
    mkdir -p "$DATA_DIR"
  fi

  log "重新启动（会重建空数据库，用新密码初始化）"
  (cd "$APP_DIR" && docker compose up -d --force-recreate)
  sleep 12

  echo
  echo "  登录密码 : $newpwd"
  echo "  数据备份 : $bak  （上游账号/OAuth 需重新连接）"
  echo
  warn "旧数据没删，回滚：docker compose down → 把 $bak 恢复成 $DATA_DIR → up -d"
}

net_exposure_check() {
  local p="$1" mode="$2"
  local lines="" verdict=""

  # ── 步骤 1：拿原始监听信息（仅用于展示 + 交叉验证）──
  if command -v ss >/dev/null 2>&1; then
    lines=$(ss -lnt 2>/dev/null | awk -v p=":${p}" '$4 ~ p"$"') || lines=""
  fi
  if [[ -z "$lines" ]] && command -v netstat >/dev/null 2>&1; then
    lines=$(netstat -lnt 2>/dev/null | awk -v p=":${p}" '$4 ~ p"$"') || lines=""
  fi

  if [[ -n "$lines" ]]; then
    echo "$lines" | sed 's/^/    /'
    # 只认【会 accept 的通配地址】：0.0.0.0:PORT / *:PORT / [::]:PORT
    # 端口映射规则产生的 [::1]:PORT 不算 —— 它只接受 IPv6 回环。
    if echo "$lines" | grep -qE '(^|[[:space:]])(0\.0\.0\.0|\*):'"${p}"'([[:space:]]|$)|\[::\]:'"${p}"'([[:space:]]|$)'; then
      verdict="exposed"
    else
      verdict="safe"
    fi
  else
    echo "    （本机列不出监听表，以下为 TCP 实测结论）"
  fi

  # ── 步骤 2：TCP 实测（拿不到监听表时的兜底，也用于交叉验证）──
  #   连得上非回环地址 → 外面真能进来。
  #   ⚠️ 注意：极少数环境（如 iSH）会把非回环地址也路由回本机，
  #      此时这个探测恒为"连得上"，需要靠步骤 1 的监听表纠正。
  local rc=3
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$p" <<'PY' || rc=$?
import socket, sys
port = int(sys.argv[1])

ip = None
# UDP connect 不真发包，只是让内核选源地址
for probe in (("8.8.8.8", 80), ("1.1.1.1", 80)):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(probe)
        cand = s.getsockname()[0]
        s.close()
        if cand and not cand.startswith("127."):
            ip = cand
            break
    except Exception:
        continue

if ip is None:
    import subprocess
    try:
        out = subprocess.run(["hostname", "-I"], capture_output=True, text=True).stdout.split()
        for cand in out:
            if cand and not cand.startswith("127.") and "." in cand:
                ip = cand
                break
    except Exception:
        pass

if ip is None:
    sys.exit(2)          # 无法判定

t = socket.socket()
t.settimeout(1.0)
try:
    t.connect((ip, port))
    sys.exit(0)          # 非回环可达
except Exception:
    sys.exit(1)          # 只有回环
finally:
    t.close()
PY
  fi

  # ── 步骤 3：合并结论 ──
  # 监听表能列出来时以它为准（它区分得了"绑定地址"），
  # TCP 实测只用来补刀：实测"连不上"是强证据（一定是安全的）。
  if [[ "$rc" == "1" ]]; then
    log "  仅回环可达（127.0.0.1:${p}），符合预期"
    return 0
  fi

  case "$verdict" in
    exposed)
      warn "  监听在通配地址上（0.0.0.0 / * / [::]）—— 已暴露公网！"
      _expose_hint "$mode" "$p"
      return 1
      ;;
    safe)
      log "  仅绑定回环（127.0.0.1:${p}），符合预期"
      return 0
      ;;
  esac

  # 监听表拿不到，只能看 TCP 实测
  if [[ "$rc" == "0" ]]; then
    warn "  实测从非回环地址可连通 ${p} —— 已暴露公网！（本机列不出监听表，此为实测结论）"
    _expose_hint "$mode" "$p"
    return 1
  fi

  warn "  取不到非回环地址，无法判定监听范围（已跳过）"
  return 0
}

_expose_hint() {
  local mode="$1" p="$2"
  if [[ "$mode" == "host" ]]; then
    warn "  host 模式排查：确认 compose 的 environment 里显式写了 HOSTNAME: \"127.0.0.1\"。"
    warn "    镜像的 Dockerfile 把 HOSTNAME=0.0.0.0 烤死了，不显式覆盖就会监听 0.0.0.0。"
    warn "    改完必须 ./9router.sh restart（内部用 --force-recreate，环境变量只在创建时注入）。"
    warn "  临时止血：iptables -I INPUT -p tcp --dport ${p} ! -s 127.0.0.1 -j DROP"
  else
    warn "  bridge 模式排查：ports 是不是被改成了 \"${p}:${CTR_PORT}\"（漏了 127.0.0.1: 前缀）"
  fi
}

# ─────────────────────────────────────────────────────────────
# 子命令
# ─────────────────────────────────────────────────────────────
CMD="${1:-deploy}"

case "$CMD" in
  stop)
    [[ $EUID -eq 0 ]] || die "请用 root 运行"
    stop_all && log "已停止" || warn "停止后端口仍被占用，请手动检查"
    exit 0
    ;;
  restart)
    [[ $EUID -eq 0 ]] || die "请用 root 运行"
    stop_all || true
    # 关键：用 --force-recreate 而不是 restart。
    # Docker 的环境变量是【创建容器时】注入的，restart 读的是旧值 ——
    # 改完 .env 用 restart「看起来重启了但配置没生效」，这个坑不值再踩。
    (cd "$APP_DIR" && docker compose up -d --force-recreate)
    log "已重启（强制重建，重新读取 .env）"
    exit 0
    ;;
  status)
    echo "── 容器状态 ──"
    (cd "$APP_DIR" 2>/dev/null && docker compose ps) || echo "(未部署)"
    echo "── 端口映射 ──"
    echo "  ${CONTAINER_NAME}: $(docker port "$CONTAINER_NAME" 2>/dev/null | tr '\n' ' ' || echo '（未运行）')"
    echo "── 端口占用 ──"
    if port_busy "$PORT"; then echo "  ${PORT}: 占用中  $(port_owner "$PORT")"; else echo "  ${PORT}: 空闲"; fi
    echo "── 端口链自检 ──"
    check_port_chain "$CONTAINER_NAME" "$PORT" "$(_ctr_port)" "/api/health" "网关" || true
    echo "── 登录链路自检 ──"
    login_selftest "$PORT" "$(env_get INITIAL_PASSWORD || true)" || true
    echo "── 容器出网自检 ──"
    egress_selftest "$CONTAINER_NAME" "网关" || true
    echo "── 监听地址自检（host 模式下这是最关键的一项）──"
    net_exposure_check "$PORT" "$NET_MODE" || true
    echo "── 网络模式 ──"
    if [[ -f "$MODE_FILE" ]]; then
      echo "  当前：$(tr -d ' \n' < "$MODE_FILE")（记录于 $MODE_FILE）"
    else
      echo "  当前：${NET_MODE}（还没记录过，下次 deploy 会写入）"
    fi
    exit 0
    ;;
  reset-password|passwd)
    [[ $EUID -eq 0 ]] || die "请用 root 运行"
    NEWPWD="${2:-}"
    if [[ -z "$NEWPWD" ]]; then
      NEWPWD="$(gen_password)"
      warn "未指定密码，已生成随机密码"
    fi
    reset_password "$NEWPWD"
    exit 0
    ;;
  logs)
    docker logs -f --tail 100 "$CONTAINER_NAME"
    exit 0
    ;;
  deploy|update|"") : ;;
  *) die "未知子命令：$CMD（可用：deploy / update / stop / restart / status / logs / reset-password）" ;;
esac

# 容器内实际监听的端口。
#   bridge → 容器内固定 CTR_PORT（20128），靠端口映射对外
#   host   → 容器与宿主共用网络栈，端口就是 PORT
# ⚠️ 探「容器内」时必须用这个，不能直接用 CTR_PORT：host 模式下 20128 上
#    什么都没有，会探出假的"容器内不通"。
_ctr_port() {
  if [[ "${NET_MODE:-bridge}" == "host" ]]; then
    printf '%s' "$PORT"
  else
    printf '%s' "$CTR_PORT"
  fi
}

# ============ 以下是部署主流程 ============[[ $EUID -eq 0 ]] || die "请用 root 运行（或 sudo ./9router.sh）"
command -v docker >/dev/null || die "未找到 docker，请先在 1Panel 安装"
docker compose version >/dev/null 2>&1 || die "未找到 docker compose v2 插件"

[[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT 必须是数字"
[[ "$CTR_PORT" =~ ^[0-9]+$ ]] || die "CTR_PORT 必须是数字"
[[ "$NET_MODE" == "bridge" || "$NET_MODE" == "host" ]] || die "NET_MODE 只能是 bridge 或 host（当前：${NET_MODE}）"

PREV_MODE=""

# 目录必须先建出来：下面的模式记录文件写在 BASE_DIR 下
mkdir -p "$APP_DIR" "$DATA_DIR"

# ── 网络模式变更：必须清干净再重建 ──
# bridge ↔ host 的切换不是改个字段就完事：
#   · bridge 模式创建的容器带端口映射；切成 host 后那些映射会变成"宿主端口
#     自己的监听"（docker-proxy 占着），新容器反而起不来，或者两套并存互相打架
#   · 网络命名空间变了，旧容器必须删掉重建，不能就地改
# 所以这里显式 down（含 --remove-orphans）+ 必要时删网络，再做切换。
if [[ "$PREV_MODE" != "$NET_MODE" ]]; then
  if [[ -n "$PREV_MODE" ]]; then
    warn "检测到网络模式变更：${PREV_MODE} → ${NET_MODE}"
    warn "  会重建整个容器栈（含 Docker 网络），以保证不残留旧模式的端口映射"
  else
    log "首次记录网络模式：${NET_MODE}"
  fi
  log "停止并清理旧容器栈"
  compose_down "$APP_DIR" "$CONTAINER_NAME"

  # 旧网络可能还挂着，删掉让 compose 重建
  if docker network inspect "$DOCKER_NET" >/dev/null 2>&1; then
    # 先确认网络里没别的容器在跑（别误删别人的）
    local_users=$(docker network inspect "$DOCKER_NET" --format '{{len .Containers}}' 2>/dev/null || echo 0)
    if [[ "$local_users" == "0" ]]; then
      docker network rm "$DOCKER_NET" >/dev/null 2>&1 && log "已删除空网络 $DOCKER_NET" || true
    else
      warn "网络 $DOCKER_NET 里还有 ${local_users} 个容器，保持不动"
    fi
  fi
  # 记录新模式（写进 compose 目录旁边的隐藏文件，随 .env 一起在 BASE_DIR）
  printf '%s' "$NET_MODE" > "$MODE_FILE"
fi

# ─── 0. 停旧实例 ───
stop_all || warn "端口仍被占用，稍后启动可能失败"

# host 模式下只有 PORT 一个端口（容器与宿主共用网络栈）
# bridge 模式下 PORT 是宿主侧，容器内为 CTR_PORT，可以同号
if [[ "$NET_MODE" == "bridge" && "$PORT" == "$CTR_PORT" ]]; then
  die "bridge 模式下 PORT 不能等于 CTR_PORT(${CTR_PORT})，会自相冲突"
fi

if port_busy "$PORT"; then
  owner=$(port_owner "$PORT" || true)
  die "端口 ${PORT} 仍被占用${owner:+（$owner）}。

  ■ 若是【别的服务】占着，换个端口重跑即可：
        PORT=25900 ./9router.sh

  ■ 若是【旧的 9router 容器】没删干净，先手动清理：
        docker ps -a | grep 9router
        docker rm -f ${CONTAINER_NAME}
        docker network prune -f

  ■ 若你刚从 bridge 切到 host（或反过来）：旧容器的端口映射可能还挂在
    宿主上，等几秒让 docker-proxy 退出，或手动 docker rm -f ${CONTAINER_NAME}

  ■ 想看清楚到底是谁占着：
        ss -lntp | grep ':${PORT}'
        lsof -iTCP:${PORT} -sTCP:LISTEN -P -n"
fi
log "端口 ${PORT} 已空闲"

# ─── 1. .env ───
# 首次部署：生成随机密码。
# 已部署：沿用文件里的，绝不再生成新密码 —— 生成一个没生效的密码打印出来，
# 比不打印更误导（同 workbuddy2api.sh 的处理方式）。
PWD_NOTE=""
if [[ ! -f "$ENV_FILE" ]]; then
  log "写入 $ENV_FILE"
  if [[ -z "$PANEL_PASSWORD" ]]; then
    PANEL_PASSWORD="$(gen_password)"
    PWD_NOTE="（本次生成，请立即保存）"
  else
    PWD_NOTE="（由 PANEL_PASSWORD 指定）"
  fi
  touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
  env_set INITIAL_PASSWORD "$PANEL_PASSWORD"
  env_set REQUIRE_API_KEY "$REQUIRE_API_KEY"
  env_set AUTH_COOKIE_SECURE "$SECURE_COOKIE"
  env_set TZ "$TZ_NAME"
else
  warn "$ENV_FILE 已存在，保留原有凭据（改密码请用 reset-password）"
  PANEL_PASSWORD="$(env_get INITIAL_PASSWORD || true)"
  PWD_NOTE="（沿用已有 .env）"
  [[ -n "$PANEL_PASSWORD" ]] || warn "  .env 里没有 INITIAL_PASSWORD，远程登录会被 403 拒绝，建议补上后重跑"
fi

# ─── 2. compose ───
# 出站代理（可选）：只在用户显式指定时才写进 compose，避免空值污染
PROXY_BLOCK=""
if [[ -n "$OUTBOUND_PROXY" ]]; then
  PROXY_BLOCK="      HTTP_PROXY: \"${OUTBOUND_PROXY}\"
      HTTPS_PROXY: \"${OUTBOUND_PROXY}\"
      NO_PROXY: \"localhost,127.0.0.1\""
fi

if [[ "$NET_MODE" == "host" ]]; then
# ── host 模式 ──
# 容器与宿主共用网络栈，没有 docker-proxy 这一层，PORT 就是唯一端口。
# 关键：把 HOSTNAME 从镜像烤死的 0.0.0.0 改成 127.0.0.1，否则网关直接暴露公网。
sync_compose "$APP_DIR" "9router(host)" <<EOF
$COMPOSE_MARKER
services:
  9router:
    image: ${IMAGE}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    # 绕过 LXC 里坏掉的 bridge NAT（容器内连不上外网 → 上游全部不可用）
    network_mode: host
    environment:
      TZ: ${TZ_NAME}
      DATA_DIR: /app/data
      # ⚠️ 这两个变量是 host 模式下的【唯一防线】，一个都不能少：
      #   PORT     —— 容器与宿主共用网络栈，这个端口就是宿主端口
      #   HOSTNAME —— 官方镜像的 Dockerfile 把 HOSTNAME=0.0.0.0 烤进了镜像，
      #               environment 里不写就会用镜像默认值 → 监听 0.0.0.0 → 暴露公网。
      #               （Next standalone 模板：hostname = process.env.HOSTNAME || '0.0.0.0'）
      # 改完这两个值必须 --force-recreate：环境变量是【创建容器时】注入的。
      PORT: "${PORT}"
      HOSTNAME: "127.0.0.1"
      NODE_ENV: production
      # 首次启动的登录密码（只在没有密码 hash 时生效）。
      # 不设这行 = 远程登录直接被 403 拒绝，详见脚本头部说明。
      INITIAL_PASSWORD: "${PANEL_PASSWORD}"
      REQUIRE_API_KEY: "${REQUIRE_API_KEY}"
      # 反代走 HTTPS → 认证 cookie 必须带 Secure。
      AUTH_COOKIE_SECURE: "${SECURE_COOKIE}"
      ENABLE_REQUEST_LOGS: "false"
${PROXY_BLOCK}
    volumes:
      - ${DATA_DIR}:/app/data
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- --timeout=3 http://127.0.0.1:${PORT}/api/health >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
EOF
else
# ── bridge 模式（默认）──
sync_compose "$APP_DIR" "9router(bridge)" <<EOF
$COMPOSE_MARKER
services:
  9router:
    image: ${IMAGE}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      # 只绑回环：容器内固定 ${CTR_PORT}（官方镜像写死，改不动）
      # ⚠️ 官方 compose 写的是 "${CTR_PORT}:${CTR_PORT}"，那等于把持有你全部
      #    上游 OAuth token 的网关挂到 0.0.0.0。这里刻意绑 127.0.0.1，
      #    对外一律走 Caddy。
      - "127.0.0.1:${PORT}:${CTR_PORT}"
    environment:
      TZ: ${TZ_NAME}
      DATA_DIR: /app/data
      PORT: "${CTR_PORT}"
      HOSTNAME: "0.0.0.0"        # 容器内绑全接口，靠上面的端口映射收口到回环
      NODE_ENV: production
      # 首次启动的登录密码（只在没有密码 hash 时生效）。
      # 不设这行 = 远程登录直接被 403 拒绝，详见脚本头部说明。
      INITIAL_PASSWORD: "${PANEL_PASSWORD}"
      REQUIRE_API_KEY: "${REQUIRE_API_KEY}"
      # 反代走 HTTPS → 认证 cookie 必须带 Secure。
      # 写死而不是交给应用 auto 判断：auto 依赖 X-Forwarded-Proto 透传，
      # 链路一变就静默降级，不如明确要求。
      AUTH_COOKIE_SECURE: "${SECURE_COOKIE}"
      ENABLE_REQUEST_LOGS: "false"
${PROXY_BLOCK}
    volumes:
      - ${DATA_DIR}:/app/data
    # 官方镜像的探针是 127.0.0.1:20128/api/health。这里显式覆盖一遍：
    # 将来镜像换端口时，「容器永远 unhealthy 但服务其实是好的」这类静默
    # 故障会立刻暴露，而不是靠人肉翻日志。
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- --timeout=3 http://127.0.0.1:${CTR_PORT}/api/health >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
EOF
fi

# ─── 3. 拉镜像 ───
if [[ "$PULL_IMAGE" == "1" ]]; then
  log "拉取最新镜像（PULL_IMAGE=0 可跳过）"
  docker pull "$IMAGE" || warn "镜像拉取失败，将用本地已有镜像"
fi

# ─── 4. 启动 ───
log "启动 9router"
(cd "$APP_DIR" && docker compose up -d)
sleep 12

# ─── 5. 自检 ───
echo
log "===== 自检 ====="
(cd "$APP_DIR" && docker compose ps)
echo
echo "── 端口映射 ──"
echo "  ${CONTAINER_NAME}: $(docker port "$CONTAINER_NAME" 2>/dev/null | tr '\n' ' ' || echo '（未运行）')"
echo
echo "── 端口链自检（宿主 → 容器）──"
CHAIN_OK=1
check_port_chain "$CONTAINER_NAME" "$PORT" "$(_ctr_port)" "/api/health" "网关" || CHAIN_OK=0

echo
echo "── 登录链路自检 ──"
login_selftest "$PORT" "$PANEL_PASSWORD" || true

echo
echo "── 上游可达性自检 ──"
egress_selftest "$CONTAINER_NAME" "网关" || true

echo
echo "── 监听地址自检（host 模式下这是最关键的一项）──"
EXPOSE_OK=1
net_exposure_check "$PORT" "$NET_MODE" || EXPOSE_OK=0

if [[ "$CHAIN_OK" != "1" ]]; then
  echo
  warn "端口链不通，按顺序查："
  warn "  · docker logs --tail 50 ${CONTAINER_NAME}"
  warn "  · 容器可能还没起完（Next.js 冷启动 10~30s，等一会儿再跑 status）"
fi
cat <<EOF

============================================================
  容器部署完成 —— 还差一步：Caddy
============================================================
  ⚠️ 本脚本没有、也不会碰你的 Caddyfile。
     请手动在编辑器里完成（见 9router.example.conf）。

     按你现有写法（18443 端口 + tls internal），追加这一段：

            ${DOMAIN}:18443 {
                tls internal
                encode gzip
                reverse_proxy 127.0.0.1:${PORT}
            }

     然后校验通过才 reload：
            cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak.\$(date +%Y%m%d%H%M%S)
            caddy fmt --overwrite /etc/caddy/Caddyfile
            caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
            systemctl reload caddy

     ⚠️ 校验不通过时【不要】reload —— 原配置仍在运行，服务不受影响。
        reload 失败看完整报错（systemctl 输出会被截断）：
            journalctl -xeu caddy.service -n 30 --no-pager | grep -i error

     💡 9Router 有 SSE 流式转发，Caddy 默认 flush_interval=-1 正好合适，
        不需要像 nginx 那样手写 proxy_buffering off / proxy_read_timeout。

============================================================
  凭据
============================================================
  网关地址    : http://127.0.0.1:${PORT}$( [[ "$NET_MODE" == "host" ]] && printf '   （host 模式，容器内同端口）' || printf '   （容器内 %s）' "$CTR_PORT" )
  外部访问    : https://${DOMAIN}:18443 （配好 Caddy 后）
  OpenAI 兼容 : https://${DOMAIN}:18443/v1
  登录密码    : ${PANEL_PASSWORD} ${PWD_NOTE}
  .env        : ${ENV_FILE}
  数据目录    : ${DATA_DIR}   （备份就备份这个）

  ⚠️ 请立即存入密码管理器，并清除本次终端输出记录

  首次登录后建议做三件事：
    1) 仪表板 → Providers，连 Claude Code / Gemini CLI 等（OAuth 扫码）
    2) 仪表板 → Endpoint，复制 API Key，填进你的 CLI 工具
    3) 需要的话改密码：./9router.sh reset-password '你的新密码'
============================================================

  日常命令：
    ./9router.sh status              状态 + 端口链 + 登录链路 + 上游可达性 + 监听地址自检
    ./9router.sh logs                跟踪日志
    ./9router.sh restart             强制重建容器（重读 .env）
    ./9router.sh stop                停止容器
    ./9router.sh reset-password      重置登录密码（含备份）
    ./9router.sh                     再次运行 = 更新（自动停旧起新）

  在别的机器上用它：
    Claude Code / Codex / Cline / Cursor 等：
      Base URL : https://${DOMAIN}:18443/v1
      API Key  : 仪表板 Endpoint 页复制
      Model    : 用组合名或 cc/… gc/… 前缀
============================================================
EOF
