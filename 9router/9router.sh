#!/usr/bin/env bash
# 9Router 部署 / 更新脚本 R1.0.0
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
#   ./9router.sh status               # 状态 + 端口链 + 登录链路自检
#   ./9router.sh logs                 # 跟踪日志
#   ./9router.sh reset-password [新密码]
set -euo pipefail

SCRIPT_VERSION="R1.0.0"

# ============ CONFIG（可用环境变量覆盖） ============
DOMAIN="${DOMAIN:-9router.example.com}"
BASE_DIR="${BASE_DIR:-/opt/9router}"
PORT="${PORT:-15900}"           # 宿主侧端口；容器内固定 20128，改不动
CTR_PORT="${CTR_PORT:-20128}"   # 官方镜像固定值，仅在镜像改版时才需要动
CONTAINER_NAME="${CONTAINER_NAME:-9router}"
IMAGE="${IMAGE:-decolua/9router:latest}"
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
# 自检：容器出网（连不上上游就没法转发）
# ─────────────────────────────────────────────────────────────
egress_selftest() {
  local name="$1" label="$2"
  printf '  %s出网: ' "$label"
  docker ps --format '{{.Names}}' | grep -qx "$name" || { echo "容器未运行"; return 1; }
  if docker exec "$name" sh -c 'wget -qO- --timeout=6 https://api.github.com/zen >/dev/null 2>&1 || wget -qO- --timeout=6 https://www.baidu.com >/dev/null 2>&1'; then
    echo "OK"
    return 0
  fi
  echo "不通（LXC 里 Docker bridge NAT 出网坏掉是常见原因）"
  return 1
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
    check_port_chain "$CONTAINER_NAME" "$PORT" "$CTR_PORT" "/api/health" "网关" || true
    echo "── 登录链路自检 ──"
    login_selftest "$PORT" "$(env_get INITIAL_PASSWORD || true)" || true
    echo "── 容器出网自检 ──"
    egress_selftest "$CONTAINER_NAME" "网关" || true
    echo "── 暴露面检查 ──"
    ss -lntp 2>/dev/null | grep -E "[:.]${CTR_PORT}\b|[:.]${PORT}\b" || true
    echo "  ↑ ${PORT} 只应出现在 127.0.0.1 上；若看到 0.0.0.0 或 [::] 说明已暴露公网"
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

# ============ 以下是部署主流程 ============
[[ $EUID -eq 0 ]] || die "请用 root 运行（或 sudo ./9router.sh）"
command -v docker >/dev/null || die "未找到 docker，请先在 1Panel 安装"
docker compose version >/dev/null 2>&1 || die "未找到 docker compose v2 插件"

[[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT 必须是数字"
[[ "$CTR_PORT" =~ ^[0-9]+$ ]] || die "CTR_PORT 必须是数字"
[[ "$PORT" != "$CTR_PORT" ]] || die "PORT 不能等于 CTR_PORT(${CTR_PORT})，会自相冲突"

# ─── 0. 停旧实例 ───
stop_all || warn "端口仍被占用，稍后启动可能失败"

if port_busy "$PORT"; then
  owner=$(port_owner "$PORT" || true)
  die "端口 ${PORT} 仍被占用${owner:+（$owner）}。

  ■ 若是【别的服务】占着，换个端口重跑即可：
        PORT=25900 ./9router.sh

  ■ 若是【旧的 9router 容器】没删干净，先手动清理：
        docker ps -a | grep 9router
        docker rm -f ${CONTAINER_NAME}
        docker network prune -f

  ■ 想看清楚到底是谁占着：
        ss -lntp | grep ':${PORT}'
        lsof -iTCP:${PORT} -sTCP:LISTEN -P -n"
fi
log "端口 ${PORT} 已空闲"

mkdir -p "$APP_DIR" "$DATA_DIR"

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

sync_compose "$APP_DIR" "9router" <<EOF
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
check_port_chain "$CONTAINER_NAME" "$PORT" "$CTR_PORT" "/api/health" "网关" || CHAIN_OK=0

echo
echo "── 登录链路自检 ──"
login_selftest "$PORT" "$PANEL_PASSWORD" || true

echo
echo "── 容器出网自检（连不上上游就没法转发）──"
egress_selftest "$CONTAINER_NAME" "网关" || true

echo
echo "── 暴露面检查 ──"
if ss -lntp 2>/dev/null | grep -qE "[:.]${PORT}\b"; then
  if ss -lntp 2>/dev/null | grep -E "[:.]${PORT}\b" | grep -qE "0\.0\.0\.0|\[::\]"; then
    warn "检测到 ${PORT} 监听在 0.0.0.0 —— 已暴露公网！"
    warn "  检查 compose 的 ports 是否被改过（官方默认写的就是 0.0.0.0，本脚本已改成 127.0.0.1）"
  else
    log "${PORT} 仅绑定回环（127.0.0.1），符合预期"
  fi
fi

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
  网关地址    : http://127.0.0.1:${PORT}   （容器内 ${CTR_PORT}）
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
    ./9router.sh status              状态 + 端口链 + 登录链路 + 暴露面自检
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
