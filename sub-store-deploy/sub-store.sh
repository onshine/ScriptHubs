#!/usr/bin/env bash
# Sub-Store 部署 / 更新脚本 R1.0.0
#
# 版本记录见同目录 README.md 末尾「版本记录」表。
# 适用：1Panel 服务器（Docker + docker compose v2），amd64 / arm64
#
# ── 本脚本解决什么 ──────────────────────────────────────────
#   官方 README 给的 compose 只有 image/ports/volumes 四行，
#   照抄上线后必然遇到两类问题：
#
#   ① 前端能打开，但任何操作都提示
#        POST https://你的域名/api/utils/env 403 (Forbidden)
#        CORS origin not allowed
#      → 后端默认只放行它自己内置的那一份前端来源，
#        自建网页端 / 官方在线前端(sub-store.vercel.app) 都被拒。
#        解法是设置 SUB_STORE_CORS_ALLOWED_ORIGINS（本脚本自动写入）。
#
#   ② 网页端能打开，但首页「订阅」列表刷不出来、日志空白。
#      → 页面和 API 不是同一个来源时受同源策略限制。
#        解法是让页面与 API 同源（SUB_STORE_FRONTEND_BACKEND_PATH）。
#
# ── 核心设计：前后端同源 ────────────────────────────────────
#   镜像内置前端，后端路径用一种「靠猜」的写法挂在同一个端口上：
#
#       GET /<BACKEND_PATH>          → 返回前端页面（HTML）
#       GET /<BACKEND_PATH>/api/xxx  → 返回接口数据（JSON）
#
#   只要反向代理把 整站 转到容器端口，浏览器访问
#       https://域名/<BACKEND_PATH>
#   页面与 API 就是同源，CORS 根本不参与，① ② 同时消失。
#
#   ⚠️ 反代里【不要】再额外加 /<BACKEND_PATH> 前缀，
#      否则变成 /xxx/xxx 双前缀 404（见 README 第三节）。
#
# ── 用法 ────────────────────────────────────────────────────
#   ./sub-store.sh                      # 部署或更新（自动停旧实例再起新的）
#   ./sub-store.sh stop                 # 只停止容器
#   ./sub-store.sh restart              # 只重启容器
#   ./sub-store.sh status               # 状态 + 端口链 + CORS/前端路径自检
#   ./sub-store.sh logs                 # 跟踪日志
#   ./sub-store.sh test-cors [来源]     # 实测某个 Origin 当前是否被放行
#   ./sub-store.sh help
set -euo pipefail

SCRIPT_VERSION="R1.0.0"

# ============ CONFIG（可用环境变量覆盖） ============
# 后端路径：访问 https://域名/<BACKEND_PATH> 打开网页端。
# 相当于"后台入口"，越长越不容易被扫；只允许 [A-Za-z0-9_-]。
BACKEND_PATH="${BACKEND_PATH:-/substore}"

# 宿主侧端口。默认绑 127.0.0.1（必须走反代，见 README 第六节安全基线）。
STORE_PORT="${STORE_PORT:-127.0.0.1:3001}"
# 容器内端口：官方镜像写死 3001，不要改
STORE_CTR_PORT="${STORE_CTR_PORT:-3001}"

# 数据目录（宿主机）。官方 compose 示例用的是 /etc/sub-store
BASE_DIR="${BASE_DIR:-/etc/sub-store}"

# 定时更新订阅的 cron（容器内 TZ=Asia/Shanghai，五段式：分 时 日 月 周）
STORE_CRON="${STORE_CRON:-50 23 * * *}"

# 允许跨域访问 API 的网页来源。**只在前后端不同源时才有用**。
# 默认值覆盖两种最常见场景：
#   · https://sub-store.vercel.app  官方在线前端
#   · https://<$DOMAIN>             自己反代的域名（万一你想从别的路径访问）
# 反代成同源（推荐）时这里留空也无所谓，但留着没副作用。
DOMAIN="${DOMAIN:-sub.example.com}"
EXTRA_ORIGINS="${EXTRA_ORIGINS:-}"
CORS_ALLOWED_ORIGINS="${CORS_ALLOWED_ORIGINS:-https://sub-store.vercel.app${EXTRA_ORIGINS:+,$EXTRA_ORIGINS}}"

IMAGE="${IMAGE:-xream/sub-store:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-sub-store}"

# 允许自动更新由本脚本生成的 compose（0 = 只提示不覆盖）
UPDATE_COMPOSE="${UPDATE_COMPOSE:-1}"
# 1 = 启动前拉最新镜像
PULL_IMAGE="${PULL_IMAGE:-1}"
# 时区
TZ_VALUE="${TZ_VALUE:-Asia/Shanghai}"
# ====================================================

C_GREEN='\033[32m'; C_YELLO='\033[33m'; C_RED='\033[31m'; C_OFF='\033[0m'
log()  { echo -e "${C_GREEN}[+]${C_OFF} $*"; }
warn() { echo -e "${C_YELLO}[!]${C_OFF} $*"; }
die()  { echo -e "${C_RED}[x]${C_OFF} $*" >&2; exit 1; }

COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
COMPOSE_MARKER="# managed-by: substore-deploy"

# ─────────────────────────────────────────────────────────────
# 路径与端口形式校验
#
# BACKEND_PATH 会被拼进 URL，写错（带斜杠、带空格、带 . 或 /）
# 会得到一个「容器起得来、网页端死活 404」的静默故障，
# 所以在生成任何文件之前就拦掉。
# ─────────────────────────────────────────────────────────────
normalize_backend_path() {
  local p="$1"
  p="${p#/}"                 # 容忍用户手写成 /xxx
  if [[ -z "$p" ]]; then
    die "BACKEND_PATH 不能为空（至少要有一个路径段，如 /substore）"
  fi
  if [[ ! "$p" =~ ^[A-Za-z0-9_-]+$ ]]; then
    die "BACKEND_PATH 只允许字母/数字/下划线/连字符，且只有一段，当前：$1
  ✅ 正确：/substore  /maxwin5566  /s3cr3t_path
  ❌ 错误：/a/b  /a b  /a.b  /  （多段、空格、点号都会导致前端 404）"
  fi
  printf '/%s' "$p"
}

# 端口支持三种写法：3001 / 127.0.0.1:3001 / 0.0.0.0:3001
port_host_ip()  { case "$1" in *:*) printf '%s' "${1%%:*}" ;; *) printf '127.0.0.1' ;; esac; }
port_host_num() { case "$1" in *:*) printf '%s' "${1##*:}" ;; *) printf '%s' "$1" ;; esac; }

# ─────────────────────────────────────────────────────────────
# 端口探测：四通道，任一命中即算占用
# ─────────────────────────────────────────────────────────────
port_hex() { printf '%04X' "$1" 2>/dev/null; }

_busy_ss()      { command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]$1$"; }
_busy_netstat() { command -v netstat >/dev/null 2>&1 && netstat -lnt 2>/dev/null | awk 'NR>2{print $4}' | grep -qE "[:.]$1$"; }
_busy_proc() {
  [ -r /proc/net/tcp ] || return 1
  local hex; hex=$(port_hex "$1"); local line
  while read -r line; do
    set -- $line
    case "${2:-}" in *":$hex") return 0 ;; esac
  done < /proc/net/tcp
  return 1
}
_busy_tcp() {
  command -v bash >/dev/null 2>&1 || return 1
  bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null || return 1
  return 0
}

port_busy() {
  local p="$1"
  _busy_ss "$p" && return 0
  _busy_netstat "$p" && return 0
  _busy_proc "$p" && return 0
  _busy_tcp "$p" && return 0
  return 1
}

# ⚠️ 必须总是返回 0：调用方是 owner=$(port_owner ...)，
#    返回非 0 时 set -e 会在赋值处直接杀掉脚本（错误提示一行都打不出来）。
port_owner() {
  local p="$1" out=""
  if command -v ss >/dev/null 2>&1; then
    out=$(ss -lntp 2>/dev/null | awk -v p=":$p\$" '$4 ~ p {print $6; exit}' || true)
  fi
  if [[ -z "$out" ]] && command -v lsof >/dev/null 2>&1; then
    out=$(lsof -iTCP:"$p" -sTCP:LISTEN -P -n 2>/dev/null | awk 'NR==2{print $1" pid="$2}' || true)
  fi
  case "$out" in ""|"(null)"|*"(null)"*) out="" ;; esac
  printf '%s' "$out"
  return 0
}

# ─────────────────────────────────────────────────────────────
# 容器内 / 宿主侧探测
# ─────────────────────────────────────────────────────────────
# 在容器里请求一个路径，返回响应体（失败返回空）
probe_in_container() {
  local name="$1" path="$2" url
  url="http://127.0.0.1:${STORE_CTR_PORT}${path}"
  docker exec "$name" sh -c "
    u='$url'
    if command -v curl >/dev/null 2>&1; then curl -fsS -m 5 \"\$u\"
    elif command -v wget >/dev/null 2>&1; then wget -qO- -T 5 \"\$u\"
    else exit 1
    fi" 2>/dev/null
  return 0
}

# 容器内请求，只看状态码
code_in_container() {
  local name="$1" path="$2" url
  url="http://127.0.0.1:${STORE_CTR_PORT}${path}"
  docker exec "$name" sh -c "
    u='$url'
    if command -v curl >/dev/null 2>&1; then curl -s -m 5 -o /dev/null -w '%{http_code}' \"\$u\"
    elif command -v wget >/dev/null 2>&1; then
      c=\$(wget -S -qO /dev/null -T 5 \"\$u\" 2>&1 | awk '/HTTP\//{print \$2; exit}'); echo \"\${c:-000}\"
    else echo 000
    fi" 2>/dev/null || true
  return 0
}

# ─────────────────────────────────────────────────────────────
# 前端路径自检 —— 这是本套件最核心的一条检查
#
# 期望行为（镜像内置前端）：
#   GET /<BACKEND_PATH>          → 200，且响应体是 HTML
#   GET /<BACKEND_PATH>/api/xxx  → 200，且响应体是 JSON
#
# 若 /<BACKEND_PATH> 返回 200 但不是 HTML，说明命中了一个"同名订阅"，
# 前端被遮住了；此时网页端会显示一堆节点文本而不是界面。
# ─────────────────────────────────────────────────────────────
frontend_selftest() {
  local name="$1" path="$2" body code
  body=$(probe_in_container "$name" "$path")
  if [[ -z "$body" ]]; then
    warn "前端路径自检：容器内 GET $path 无响应"
    warn "  → 容器没起来，看日志：docker logs --tail 50 $name"
    return 1
  fi
  if ! printf '%s' "$body" | grep -qiE '<html|<!doctype'; then
    warn "前端路径自检：GET $path 返回的不是 HTML（可能被同名订阅占用）"
    warn "  → 换个 BACKEND_PATH（如 /substore-2）重跑即可"
    return 1
  fi
  code=$(code_in_container "$name" "${path}/api/utils/env")
  if [[ "$code" != "200" ]]; then
    warn "接口自检：GET ${path}/api/utils/env 返回 $code（期望 200）"
    return 1
  fi
  log "前端路径自检：$path 已同时提供 HTML 页面与 $path/api/* 接口（同源，无需 CORS）"
  return 0
}

# ─────────────────────────────────────────────────────────────
# CORS 实测
#
# 3001 端口在镜像里跑的是 express-cors 中间件，对带 Origin 的请求做白名单。
# 用 -H "Origin: xxx" 直接问后端"放不放行"，比对着文档猜环境变量名可靠。
# ─────────────────────────────────────────────────────────────
cors_probe() {
  local name="$1" origin="$2" path="$3" hdr
  local url="http://127.0.0.1:${STORE_CTR_PORT}${path}/api/utils/env"
  hdr=$(docker exec "$name" sh -c "
    if command -v curl >/dev/null 2>&1; then
      curl -s -m 6 -D - -o /dev/null -H 'Origin: $origin' '$url'
    fi" 2>/dev/null || true)
  local code aho
  code=$(printf '%s' "$hdr" | awk '/^HTTP\//{c=$2} END{print c}')
  aho=$(printf '%s' "$hdr" | tr -d '\r' | awk 'tolower($1)=="access-control-allow-origin:"{print $2}')
  if [[ -z "$code" ]]; then
    printf '  %-42s 无响应（容器内 curl 不可用或容器未运行）\n' "$origin"
    return 1
  fi
  if [[ "$code" == "403" ]]; then
    printf '  %-42s ❌ %s  CORS origin not allowed\n' "$origin" "$code"
    return 1
  fi
  printf '  %-42s ✅ %s  allow-origin=%s\n' "$origin" "$code" "${aho:-（未回该头）}"
  return 0
}

# 容器出网自检 —— 拉订阅、推送节点都要先能出网
egress_selftest() {
  local name="$1" out
  out=$(timeout 15 docker exec "$name" sh -c '
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -m 8 -o /dev/null https://www.baidu.com && echo OK || echo FAIL
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- -T 8 https://www.baidu.com >/dev/null 2>&1 && echo OK || echo FAIL
    else echo SKIP
    fi' 2>/dev/null || true)
  case "$out" in
    *OK*)   log "容器出网 OK"; return 0 ;;
    *SKIP*) warn "容器内无探测工具，跳过出网检查"; return 0 ;;
    *)      warn "容器【出网不通】（连 baidu 都失败）"
            warn "  → 宿主机能出网的话，多半是 Docker bridge NAT 问题"
            warn "  → LXC 里跑 Docker 常见，解决：容器加 network_mode: host"
            warn "     （本套件没做 host 模式，因为端口就不好绑 127.0.0.1 了；"
            warn "       确认要的话在 compose 里手动加）"
            return 1 ;;
  esac
}

cors_report() {
  local name="$1" path="$2"
  echo "── CORS 实测（带 Origin 请求 ${path}/api/utils/env）──"
  local ok=1 e
  for e in $CORS_LIST; do
    cors_probe "$name" "$e" "$path" || ok=0
  done
  # 额外验证「完全无 Origin」的请求必须通（curl/订阅 App 拉订阅走这条）
  local code
  code=$(code_in_container "$name" "${path}/api/utils/env")
  printf '  %-42s %s\n' '（不带 Origin，订阅 App 拉取走这条）' \
    "$([[ "$code" == "200" ]] && echo "✅ $code" || echo "❌ $code")"
  if [[ "$ok" != "1" ]]; then
    echo
    warn "有来源被拒 → 把实际前端域名补进 SUB_STORE_CORS_ALLOWED_ORIGINS 后重跑本脚本"
    warn "  最省事的做法其实是走同源：直接访问 https://${DOMAIN}${path}"
    warn "  同源请求不带 Origin 校验问题，CORS 整段逻辑都不参与"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────
# 端口链自检：宿主映射端口 → 容器内监听端口
# ─────────────────────────────────────────────────────────────
check_port_chain() {
  local name="$1" host_port="$2" ctr_port="$3" path="$4" label="$5"
  local inside outside
  inside=$(code_in_container "$name" "$path")
  if [[ -z "$inside" || "$inside" == "000" ]]; then
    warn "$label：容器内部 127.0.0.1:$ctr_port$path 无响应"
    warn "  → 容器没起来，或容器内监听的不是 $ctr_port"
    warn "  → 看日志：docker logs --tail 50 $name"
    return 1
  fi
  outside=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$host_port$path" 2>/dev/null || true)
  if [[ "$outside" == "000" || -z "$outside" ]]; then
    warn "$label：宿主 127.0.0.1:$host_port 无响应，但容器内 $ctr_port 是通的"
    warn "  → 端口映射写错了。应为 127.0.0.1:${host_port}:${ctr_port}"
    warn "  → 当前映射：$(docker port "$name" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi
  if [[ "$outside" != "$inside" ]]; then
    warn "$label：宿主返回 $outside，容器内返回 $inside（不一致）"
    return 1
  fi
  log "$label：端口链 OK（宿主 $host_port → 容器 $ctr_port，$path = $outside）"
  return 0
}

# ─────────────────────────────────────────────────────────────
# 停止 / 清理
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

stop_service() {
  log "停止旧实例（若存在）"
  compose_down "$BASE_DIR" "$CONTAINER_NAME"
  local i
  for i in $(seq 1 15); do
    port_busy "$HOST_PORT" || return 0
    sleep 1
  done
  warn "等待 15s 后端口仍被占用"
  return 1
}

# ─────────────────────────────────────────────────────────────
# compose 同步：只在「是本脚本生成的」前提下才覆盖，且先备份
# ─────────────────────────────────────────────────────────────
is_our_compose() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep -qF "$COMPOSE_MARKER" "$f" && return 0
  grep -qF "xream/sub-store" "$f" && return 0
  return 1
}

sync_compose() {
  local dir="$1" label="$2" tmp path
  path="$dir/docker-compose.yml"
  tmp=$(mktemp)
  cat > "$tmp"

  if [[ ! -f "$path" ]]; then
    mkdir -p "$dir"; mv "$tmp" "$path"; log "写入 $label compose：$path"
    return 0
  fi
  if cmp -s "$tmp" "$path"; then
    rm -f "$tmp"; log "$label compose 已是最新"
    return 0
  fi
  if is_our_compose "$path" && [[ "$UPDATE_COMPOSE" == "1" ]]; then
    local bak="$path.bak.$(date +%Y%m%d%H%M%S)"
    cp "$path" "$bak"; mv "$tmp" "$path"
    log "$label compose 已更新（旧文件备份：$bak）"
    return 0
  fi
  rm -f "$tmp"
  warn "$label compose 不是本脚本生成的，保持不动：$path"
  warn "  如需自动管理，请先手动备份并删除该文件，再重跑本脚本。"
  return 1
}

# ─────────────────────────────────────────────────────────────
# 解析参数 / 环境变量
# ─────────────────────────────────────────────────────────────
BACKEND_PATH="$(normalize_backend_path "$BACKEND_PATH")"
HOST_PORT="$(port_host_num "$STORE_PORT")"
HOST_BIND="$(port_host_ip "$STORE_PORT")"

# CORS 列表：去空格，去空项
CORS_LIST=""
IFS=',' read -r -a _origins <<< "$CORS_ALLOWED_ORIGINS"
for _o in "${_origins[@]}"; do
  _o="$(printf '%s' "$_o" | tr -d '[:space:]')"
  [[ -z "$_o" ]] && continue
  CORS_LIST="${CORS_LIST:+$CORS_LIST }$_o"
done

CMD="${1:-deploy}"

case "$CMD" in
  help|-h|--help)
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
    cat <<EOF

可用环境变量：
  BACKEND_PATH            后端路径（= 网页端入口），默认 ${BACKEND_PATH}
  STORE_PORT              宿主侧端口，默认 127.0.0.1:3001
  BASE_DIR                数据目录，默认 /etc/sub-store
  DOMAIN                  你的域名，仅用于打印提示，默认 sub.example.com
  EXTRA_ORIGINS           额外放行的前端来源（逗号分隔）
  CORS_ALLOWED_ORIGINS    完全覆盖 CORS 白名单
  STORE_CRON              定时更新订阅的 cron，默认 "50 23 * * *"
  PULL_IMAGE=0            跳过拉镜像
EOF
    exit 0
    ;;
  stop)
    [[ $EUID -eq 0 ]] || die "请用 root 运行"
    stop_service && log "已停止" || warn "停止后端口仍被占用，请手动检查"
    exit 0
    ;;
  restart)
    [[ $EUID -eq 0 ]] || die "请用 root 运行"
    (cd "$BASE_DIR" && docker compose up -d --force-recreate) && log "已重启（强制重建，确保环境变量生效）"
    exit 0
    ;;
  logs)
    docker logs -f --tail 100 "$CONTAINER_NAME"
    exit 0
    ;;
  test-cors)
    shift || true
    _origin="${1:-}"
    [[ -z "$_origin" ]] && die "用法：./sub-store.sh test-cors https://sub-store.vercel.app"
    echo "── 白名单 ──"
    for e in $CORS_LIST; do echo "  $e"; done
    echo
    cors_report "$CONTAINER_NAME" "$BACKEND_PATH"
    echo
    echo "── 单点测试 $_origin ──"
    cors_probe "$CONTAINER_NAME" "$_origin" "$BACKEND_PATH" || true
    exit 0
    ;;
  status)
    echo "── 客户端（客户端指浏览器网页端，非本脚本）──"
    echo "  网页端入口 : https://${DOMAIN}${BACKEND_PATH}"
    echo "  订阅根地址 : https://${DOMAIN}${BACKEND_PATH}"
    echo "  容器       : $CONTAINER_NAME ($IMAGE)"
    echo
    echo "── 容器状态 ──"
    (cd "$BASE_DIR" 2>/dev/null && docker compose ps) || echo "(未部署)"
    echo
    echo "── 端口映射 ──"
    echo "  $CONTAINER_NAME: $(docker port "$CONTAINER_NAME" 2>/dev/null | tr '\n' ' ' || echo '（未运行）')"
    for p in "$HOST_PORT"; do
      if port_busy "$p"; then echo "  宿主 $p: 占用中  $(port_owner "$p")"; else echo "  宿主 $p: 空闲"; fi
    done
    echo
    echo "── 容器内环境变量 ──"
    docker inspect "$CONTAINER_NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
      | grep -E '^SUB_STORE' || echo "  （读不到，容器未运行）"
    echo
    echo "── 端口链自检 ──"
    check_port_chain "$CONTAINER_NAME" "$HOST_PORT" "$STORE_CTR_PORT" "$BACKEND_PATH" "Sub-Store" || true
    echo
    frontend_selftest "$CONTAINER_NAME" "$BACKEND_PATH" || true
    echo
    cors_report "$CONTAINER_NAME" "$BACKEND_PATH" || true
    exit 0
    ;;
  deploy|update|"") : ;;
  *) die "未知子命令：$CMD（可用：deploy / update / stop / restart / status / logs / test-cors / help）" ;;
esac

# ============ 以下是部署主流程 ============
[[ $EUID -eq 0 ]] || die "请用 root 运行（或 sudo ./sub-store.sh）"
command -v docker >/dev/null || die "未找到 docker，请先在 1Panel 安装"
docker compose version >/dev/null 2>&1 || die "未找到 docker compose v2 插件"

# ─── 0. 停旧实例 ───
stop_service || warn "端口仍被占用，稍后启动可能失败"

if port_busy "$HOST_PORT"; then
  owner=$(port_owner "$HOST_PORT" || true)
  die "端口 $HOST_PORT 仍被占用${owner:+（$owner）}。

  ■ 若是【别的服务】占着（1Panel 里常见：装过 Sub-Store 应用、或旧容器没删干净）：
        docker ps -a | grep -i sub-store
        docker rm -f sub-store
        换个端口重跑：STORE_PORT=127.0.0.1:3301 ./sub-store.sh

  ■ 想看清楚到底是谁占着：
        ss -lntp | grep -E ':$HOST_PORT'
        lsof -iTCP:$HOST_PORT -sTCP:LISTEN -P -n"
fi
log "端口 $HOST_PORT 已空闲"

mkdir -p "$BASE_DIR"

# ─── 1. 生成 compose ───
# ⚠️ 环境变量在这里是「按容器创建时注入」的：
#    只 docker restart 不会读取新的 environment，必须 up -d --force-recreate
#    （stop/restart 子命令已处理这一点）。
sync_compose "$BASE_DIR" "Sub-Store" <<EOF
$COMPOSE_MARKER
# 由 ScriptHubs/sub-store-deploy 生成。
# 重新生成请跑 ./sub-store.sh；不要在这里手改后又删掉 marker，
# 否则脚本会认为"不是自己生成的"而拒绝更新。
services:
  sub-store:
    image: ${IMAGE}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    environment:
      # 容器内时区：cron 表达式按这个时区解释
      TZ: "${TZ_VALUE}"
      # 定时更新订阅
      SUB_STORE_CRON: "${STORE_CRON}"
      # 前后端同源的关键：GET ${BACKEND_PATH} = 前端页面，
      # GET ${BACKEND_PATH}/api/* = 接口。反代整站转到本容器即可。
      SUB_STORE_FRONTEND_BACKEND_PATH: "${BACKEND_PATH}"
      # 跨域白名单。同源访问时用不到；前后端不同源（用官方在线前端）时才生效。
      SUB_STORE_CORS_ALLOWED_ORIGINS: "${CORS_ALLOWED_ORIGINS}"
    ports:
      # 只绑本机，公网一律走反代（Sub-Store 里有你的机场订阅和节点明文）
      - "${HOST_BIND}:${HOST_PORT}:${STORE_CTR_PORT}"
    volumes:
      - ${BASE_DIR}:/opt/app/data
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- -T 3 http://127.0.0.1:${STORE_CTR_PORT}${BACKEND_PATH} >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
EOF

# ─── 2. 数据目录权限说明（不做 chown，见 README）───
log "数据目录：$BASE_DIR（镜像以 root 运行，无需 chown）"

# ─── 3. 拉镜像 ───
if [[ "$PULL_IMAGE" == "1" ]]; then
  log "拉取最新镜像（PULL_IMAGE=0 可跳过）"
  docker pull "$IMAGE" || warn "镜像拉取失败，将用本地已有镜像"
fi

# ─── 4. 启动（--force-recreate 保证环境变量生效）───
log "启动 Sub-Store"
(cd "$BASE_DIR" && docker compose up -d --force-recreate)

# 等待就绪：最多 30s
_ready=0
for i in $(seq 1 15); do
  c=$(code_in_container "$CONTAINER_NAME" "$BACKEND_PATH")
  if [[ "$c" == "200" ]]; then _ready=1; break; fi
  sleep 2
done
if [[ "$_ready" == "1" ]]; then
  log "服务已就绪（${BACKEND_PATH} 返回 200）"
else
  warn "等待 30s 后 ${BACKEND_PATH} 仍未返回 200，继续自检定位"
fi

# ─── 5. 自检 ───
echo
log "===== 自检 ====="
(cd "$BASE_DIR" && docker compose ps) || true

echo
echo "── 端口映射 ──"
echo "  $CONTAINER_NAME: $(docker port "$CONTAINER_NAME" 2>/dev/null | tr '\n' ' ' || echo '（未运行）')"

echo
echo "── 端口链自检（宿主 → 容器）──"
CHAIN_OK=1
check_port_chain "$CONTAINER_NAME" "$HOST_PORT" "$STORE_CTR_PORT" "$BACKEND_PATH" "Sub-Store" || CHAIN_OK=0

echo
echo "── 前端路径自检（前后端同源是否生效）──"
FRONT_OK=1
frontend_selftest "$CONTAINER_NAME" "$BACKEND_PATH" || FRONT_OK=0

echo
cors_report "$CONTAINER_NAME" "$BACKEND_PATH" || true

echo
echo "── 容器出网自检（下载订阅要先能出网）──"
egress_selftest "$CONTAINER_NAME" || true

if [[ "$CHAIN_OK" != "1" || "$FRONT_OK" != "1" ]]; then
  echo
  warn "有自检未通过，常见原因与处置："
  warn "  · 端口链不通    → compose 端口映射两侧不一致，删掉 compose 让它重新生成"
  warn "  · 前端路径非 HTML → 该路径被同名订阅占用，换 BACKEND_PATH 重跑"
  warn "  · 接口非 200    → 容器内 Node 进程异常，docker logs --tail 50 $CONTAINER_NAME"
  echo
fi

cat <<EOF

============================================================
  部署完成 —— 还差一步：反向代理
============================================================
  ⚠️ 本脚本不碰你的 Caddy / Nginx / 1Panel 网站配置。
     照 sub-store.example.conf 自己加。

     关键点：反代【整站】转到 127.0.0.1:${HOST_PORT}，
     不要额外加 ${BACKEND_PATH} 前缀（会变成 ${BACKEND_PATH}${BACKEND_PATH} → 404）。

     1Panel 里对应设置：
       网站 → 你的域名 → 反向代理 → 新建
         代理地址: http://127.0.0.1:${HOST_PORT}
         代理路径: /
EOF

cat <<EOF

============================================================
  访问方式
============================================================
  网页端（前后端同源，推荐）:
      https://${DOMAIN}${BACKEND_PATH}

  订阅链接就是网页端首页里生成的那些，
  形如 https://${DOMAIN}${BACKEND_PATH}/api/sub/<你生成时用的路径>

  ⚠️ 只绑了 ${HOST_BIND}:${HOST_PORT}，公网访问必须经反代。
     直接用 http://IP:${HOST_PORT} 是打不开的（这是刻意的）。

============================================================
  日常命令
============================================================
    ./sub-store.sh status                     状态 + 端口链 + 前端路径 + CORS 实测
    ./sub-store.sh logs                       跟踪日志
    ./sub-store.sh restart                    重启（强制重建，刷新环境变量）
    ./sub-store.sh stop                       停止
    ./sub-store.sh test-cors <Origin>         单独测某个来源能否跨域
    ./sub-store.sh                            再次运行 = 更新（自动停旧起新）

  改了 ${BACKEND_PATH} / CORS 白名单后：
    ./sub-store.sh                            （必须重跑，restart 不够）
    因为环境变量是容器创建时注入的，compose 会自动重建容器。

  数据全在 ${BASE_DIR}，备份就是打包这个目录：
    tar czf substore-backup-\$(date +%F).tar.gz -C $(dirname "$BASE_DIR") $(basename "$BASE_DIR")
============================================================
EOF

# ─────────────────────────────────────────────────────────────
# 解析参数 / 环境变量
# ─────────────────────────────────────────────────────────────
BACKEND_PATH="$(normalize_backend_path "$BACKEND_PATH")"
HOST_PORT="$(port_host_num "$STORE_PORT")"
HOST_BIND="$(port_host_ip "$STORE_PORT")"

# CORS 列表：去空格，去空项
CORS_LIST=""
IFS=',' read -r -a _origins <<< "$CORS_ALLOWED_ORIGINS"
for _o in "${_origins[@]}"; do
  _o="$(printf '%s' "$_o" | tr -d '[:space:]')"
  [[ -z "$_o" ]] && continue
  CORS_LIST="${CORS_LIST:+$CORS_LIST }$_o"
done

CMD="${1:-deploy}"
