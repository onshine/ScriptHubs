#!/usr/bin/env bash
# workbuddy2api + workbuddy-manager 部署 / 更新脚本 R1.0.2
#
# 版本记录见同目录 README.md 末尾「版本记录」表。
# 适用：1Panel 服务器（Docker + docker compose v2），amd64 / arm64
#
# ⚠️ 本脚本【绝对不会】读取、写入、备份或 reload 任何 Caddy 配置。
#    原因：Caddyfile 里往往有 IP 白名单这类"唯一入口"内容，任何写操作
#    （哪怕只是 append）都有把操作者锁在外面的风险。
#    Caddy 改动请照同目录 caddy.example.conf 自己在编辑器里做。
#
# ── 端口设计（v3 修正，重要）─────────────────────────────────
#   宿主一律用高位端口（绕开 1Panel 的 10000 以上限制）；
#   容器内用【官方镜像的默认端口】，因为镜像里的端口是写死的，改不动：
#
#     网关 workbuddy2api ：容器内监听 = config.json 的 listen（本脚本设为 GW_PORT）
#                          → 映射写成  GW_PORT:GW_PORT
#     面板 workbuddy-manager：容器内端口写死在官方镜像里（uvicorn --port 7864），
#                          无法用环境变量改（WB_MANAGER_PORT 是死配置，
#                          官方 deploy/install.sh 靠 sed 改 --port 才生效）
#                          → 映射写成  PANEL_PORT:7864
#
#   v2 版曾把面板映射写成 PANEL_PORT:PANEL_PORT，而容器实际只监听 7864，
#   结果宿主端口转发到容器内的空端口 → Caddy 502、healthcheck unhealthy。
#   v3 修正，并加了「容器内探测 + 宿主探测」的一致性自检，这类错误不会再静默。
#
# 用法：
#   ./workbuddy2api.sh                      # 部署或更新（自动停旧实例再起新的）
#   ./workbuddy2api.sh stop                 # 只停止两个容器
#   ./workbuddy2api.sh restart              # 只重启两个容器
#   ./workbuddy2api.sh status               # 看状态与端口链路
#   ./workbuddy2api.sh logs                 # 跟踪日志
set -euo pipefail

SCRIPT_VERSION="R1.0.2"

# ============ CONFIG（可用环境变量覆盖） ============
DOMAIN="${DOMAIN:-workbuddy.example.com}"
BASE_DIR="${BASE_DIR:-/opt/workbuddy}"
GW_PORT="${GW_PORT:-17863}"        # 宿主侧：网关端口
PANEL_PORT="${PANEL_PORT:-17864}"  # 宿主侧：面板端口
# 面板容器内端口：官方镜像写死 7864，不要改这个
PANEL_CTR_PORT="${PANEL_CTR_PORT:-7864}"
# 网关容器内端口（= config.json 的 listen）
GW_CTR_PORT="${GW_CTR_PORT:-$GW_PORT}"
# 网络模式：bridge（默认）| host
#
# 什么时候需要 NET_MODE=host：
#   在 LXC 里跑 Docker 时（主机名 ct* / PVE 容器），bridge 的 NAT 出网
#   经常是坏的 —— 表现为容器内连 baidu.com 都超时，但宿主机一切正常。
#   此时用 host 网络绕过整条 NAT 路径。
#
# NET_MODE=host 时本脚本会：
#   · 两个容器都设 network_mode: host
#   · 用 command 覆盖，把监听地址绑回 127.0.0.1（不暴露公网）
#   · WB2API_BASE 用 127.0.0.1（同宿主网络栈）
#   ⚠️ 注意：WB_MANAGER_HOST / WB_MANAGER_PORT 都是**死配置**
#      （config.py 定义但从不传给 uvicorn），唯一有效的办法是覆盖 command。
NET_MODE="${NET_MODE:-bridge}"
# 走 HTTPS 域名访问 → true。
# 不用 auto：auto 依赖反代透传 X-Forwarded-Proto，一旦中间链路变了而没传，
# 会静默降级为不带 Secure ——「以为安全其实没有」比明确报错更危险。
SECURE_COOKIE="${SECURE_COOKIE:-true}"
# 可信代理来源网段。Caddy 跑宿主机 → 127.0.0.0/8 够用。
# Caddy 跑容器里 → 面板看到的对端是 docker 网桥地址，必须把它加进来。
TRUSTED_PROXY_CIDRS="${TRUSTED_PROXY_CIDRS:-127.0.0.0/8,::1/128,172.16.0.0/12}"
GW_API_KEY="${GW_API_KEY:-}"          # 留空则自动生成
PANEL_PASSWORD="${PANEL_PASSWORD:-}"  # 空 = 沿用已有密码；首次部署则自动生成
PULL_IMAGE="${PULL_IMAGE:-1}"         # 1 = 启动前拉最新镜像
UPDATE_COMPOSE="${UPDATE_COMPOSE:-1}" # 1 = 本脚本生成过的 compose 允许自动更新
# ====================================================

C_GREEN='\033[32m'; C_YELLO='\033[33m'; C_RED='\033[31m'; C_OFF='\033[0m'
log()  { echo -e "${C_GREEN}[+]${C_OFF} $*"; }
warn() { echo -e "${C_YELLO}[!]${C_OFF} $*"; }
die()  { echo -e "${C_RED}[x]${C_OFF} $*" >&2; exit 1; }

GW_DIR="$BASE_DIR/workbuddy2api"
PANEL_DIR="$BASE_DIR/workbuddy-manager"
GW_NAME=workbuddy2api
PANEL_NAME=workbuddy-manager
COMPOSE_MARKER="# managed-by: workbuddy-deploy"

# ─────────────────────────────────────────────────────────────
# 面板密码管理
#
# 关键事实（面板源码 server/security.py）：
#   users.json 不存在 → bootstrap_users() 用 WB_ADMIN_PASSWORD 建 admin（仅此一次）
#   users.json 已存在 → 直接读文件，WB_ADMIN_PASSWORD **完全被忽略**
#
# v3 及之前的脚本每次都重新生成随机密码并打印，但第 2 次之后那个密码
# 根本没被采用 —— 打印出来的是个错密码，比不打印更误导。
# 现在：有 users.json 就沿用，不再假装改了密码。
# ─────────────────────────────────────────────────────────────
USERS_FILE="$PANEL_DIR/data/users.json"

panel_password_state() {
  [[ -f "$USERS_FILE" ]] && echo "exists" || echo "absent"
}

# 生成 PBKDF2-SHA256 哈希，格式与面板一致：pbkdf2_sha256$260000$salt$digest
panel_hash_pwd() {
  python3 - "$1" <<'PY'
import hashlib, secrets, sys
pwd = sys.argv[1]
salt = secrets.token_hex(16)
it = 260000
digest = hashlib.pbkdf2_hmac('sha256', pwd.encode(), bytes.fromhex(salt), it)
print(f'pbkdf2_sha256${it}${salt}${digest.hex()}')
PY
}

# 重置面板密码：备份 users.json，写入新哈希（保留 secret 与其他用户）
reset_panel_password() {
  local newpwd="$1"
  [[ -f "$USERS_FILE" ]] || die "找不到 $USERS_FILE（面板还没跑过？先执行 ./workbuddy2api.sh）"
  local bak="$USERS_FILE.bak.$(date +%Y%m%d%H%M%S)"
  cp "$USERS_FILE" "$bak"
  python3 - "$USERS_FILE" "$newpwd" <<'PY'
import hashlib, json, secrets, sys
path, pwd = sys.argv[1], sys.argv[2]
d = json.load(open(path, encoding='utf-8'))
users = d.get('users')
if not isinstance(users, list) or not users:
    sys.exit('users.json 结构异常，已备份但未修改')
salt = secrets.token_hex(16)
it = 260000
digest = hashlib.pbkdf2_hmac('sha256', pwd.encode(), bytes.fromhex(salt), it)
h = f'pbkdf2_sha256${it}${salt}${digest.hex()}'
hit = False
for u in users:
    if u.get('username') == 'admin':
        u['pwd_hash'] = h
        # 递增会话版本 → 立即吊销该用户全部已登录会话
        u['sv'] = int(u.get('sv', 0)) + 1
        hit = True
        break
if not hit:
    users.append({'username': 'admin', 'role': 'admin', 'pwd_hash': h, 'sv': 1})
json.dump(d, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('users.json 已更新（admin 密码 + 会话版本已递增）')
PY
  chown 10001:10001 "$USERS_FILE" 2>/dev/null || true
  chmod 600 "$USERS_FILE" 2>/dev/null || true
  log "旧文件已备份：$bak"
  log "密码已重置，请用新密码登录（旧会话已全部失效）"
}

# ─────────────────────────────────────────────────────────────
# 登录链路自检（网络错误的定位手段）
# ─────────────────────────────────────────────────────────────
login_selftest() {
  local host="$1" path="/api/login"
  local code
  # 故意用错密码：返回 401 = 链路通且鉴权正常；网络错误/000 = 链路不通
  code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:${host}${path}" \
    -H 'Content-Type: application/json' \
    -d '{"username":"__probe__","password":"__probe__"}' 2>/dev/null || true)
  case "$code" in
    401|400) log "登录接口链路 OK（用探测账号得到 $code，符合预期）"; return 0 ;;
    000|"")  warn "登录接口无响应（网络层不通）"; return 1 ;;
    403)     warn "登录接口返回 403（Origin 校验或 IP 拦截）"; return 1 ;;
    429)     log "登录接口 OK（返回 429 说明触发了失败锁定，链路是通的）"; return 0 ;;
    5*)      warn "登录接口返回 $code（面板内部错误，看 docker logs）"; return 1 ;;
    *)       warn "登录接口返回意外状态码 $code"; return 1 ;;
  esac
}

# 容器出网自检 —— LXC 里跑 Docker 时 bridge NAT 常坏，
# 表现为容器内连 baidu 都超时（宿主机一切正常）。
egress_selftest() {
  local name="$1" label="$2" out
  out=$(timeout 15 docker exec "$name" sh -c '
    if command -v python3 >/dev/null 2>&1; then
      python3 - <<'"'"'PY'"'"'
import urllib.request
try:
    urllib.request.urlopen("https://www.baidu.com", timeout=6)
    print("OK")
except Exception:
    print("FAIL")
PY
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- -T 6 https://www.baidu.com >/dev/null 2>&1 && echo OK || echo FAIL
    else
      echo SKIP
    fi' 2>/dev/null || true)
  case "$out" in
    *OK*)   log "$label：容器出网 OK"; return 0 ;;
    *SKIP*) warn "$label：容器内无探测工具，跳过出网检查"; return 0 ;;
    *)      warn "$label：容器【出网不通】（连 baidu 都失败）"
            if [[ "$NET_MODE" == "host" ]]; then
              # host 模式已绕过 bridge NAT，还连不上说明是宿主机层面的问题
              warn "  → 当前是 host 网络，已绕过 Docker bridge，仍不通说明问题在宿主机："
              warn "        - 宿主机自己能否出网？curl -sI https://www.baidu.com"
              warn "        - 是否有防火墙/iptables OUTPUT 策略拦截"
              warn "        - 是否被 TUN 模式代理劫持（Clash/V2Ray 内核级接管）"
            else
              warn "  → 若宿主机能出网，说明是 Docker bridge NAT 问题"
              warn "  → 常见于 LXC 里跑 Docker；解决办法："
              warn "        NET_MODE=host ./workbuddy2api.sh"
            fi
            return 1 ;;
  esac
}

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

# 查出占用端口的进程（尽力而为）
# ⚠️ 必须总是返回 0：调用方是 owner=$(port_owner ...)，
#    若返回非 0，set -e 会在赋值处直接杀掉脚本（错误提示一行都打不出来）。
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
# 容器内探测（校验「容器内监听端口」，这是 v2 出错的症结所在）
# ─────────────────────────────────────────────────────────────
probe_in_container() {
  local name="$1" port="$2" path="$3" url
  url="http://127.0.0.1:${port}${path}"
  docker exec "$name" sh -c "
    u='$url'
    if command -v curl >/dev/null 2>&1; then curl -fsS -m 5 \"\$u\"
    elif command -v wget >/dev/null 2>&1; then wget -qO- -T 5 \"\$u\"
    else python3 -c 'import urllib.request,sys;sys.stdout.write(urllib.request.urlopen(sys.argv[1],timeout=5).read().decode())' \"\$u\"
    fi" 2>/dev/null
  return 0
}

# 校验完整端口链：宿主映射端口 → 容器内监听端口
check_port_chain() {
  local name="$1" host_port="$2" ctr_port="$3" path="$4" label="$5"
  local inside outside
  inside=$(probe_in_container "$name" "$ctr_port" "$path")
  if [[ -z "$inside" ]]; then
    warn "$label：容器内部 127.0.0.1:$ctr_port$path 无响应"
    warn "  → 容器没起来，或容器内监听的不是 $ctr_port"
    warn "  → 看日志：docker logs --tail 50 $name"
    return 1
  fi
  outside=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$host_port$path" 2>/dev/null || true)
  if [[ "$outside" != "200" ]]; then
    warn "$label：宿主 127.0.0.1:$host_port 返回 '$outside'，但容器内 $ctr_port 是通的"
    warn "  → 端口映射写错了。应为 127.0.0.1:${host_port}:${ctr_port}"
    warn "  → 当前映射：$(docker port "$name" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi
  log "$label：端口链 OK（宿主 $host_port → 容器 $ctr_port）"
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

stop_all() {
  log "停止旧实例（若存在）"
  compose_down "$PANEL_DIR" "$PANEL_NAME"
  compose_down "$GW_DIR" "$GW_NAME"
  local i
  for i in $(seq 1 15); do
    port_busy "$GW_PORT" || port_busy "$PANEL_PORT" || return 0
    sleep 1
  done
  warn "等待 15s 后端口仍被占用"
  return 1
}

# ─────────────────────────────────────────────────────────────
# compose 文件同步：只在「是本脚本生成的」前提下才覆盖，且先备份
# ─────────────────────────────────────────────────────────────
is_our_compose() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep -qF "$COMPOSE_MARKER" "$f" && return 0
  # 兼容 v2 老脚本生成的文件（无 marker，但特征唯一）
  grep -qF "ghcr.io/ithtelab/workbuddy-manager" "$f" && return 0
  grep -qF "ghcr.io/sliverkiss/workbuddy2api" "$f" && return 0
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
  # 不是我们生成的：绝不动它
  rm -f "$tmp"
  warn "$label compose 不是本脚本生成的，保持不动：$path"
  warn "  如需自动管理，请先手动备份并删除该文件，再重跑本脚本。"
  warn "  或设 UPDATE_COMPOSE=0 跳过检测。"
  return 1
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
    (cd "$GW_DIR" && docker compose up -d)
    (cd "$PANEL_DIR" && docker compose up -d)
    log "已重启"
    exit 0
    ;;
  status)
    echo "── $GW_NAME ──"
    (cd "$GW_DIR" 2>/dev/null && docker compose ps) || echo "(未部署)"
    echo "── $PANEL_NAME ──"
    (cd "$PANEL_DIR" 2>/dev/null && docker compose ps) || echo "(未部署)"
    echo "── 端口映射 ──"
    for n in "$GW_NAME" "$PANEL_NAME"; do
      p=$(docker port "$n" 2>/dev/null | tr '\n' ' ')
      echo "  $n: ${p:-（未运行）}"
    done
    echo "── 端口占用 ──"
    for p in "$GW_PORT" "$PANEL_PORT"; do
      if port_busy "$p"; then echo "  $p: 占用中  $(port_owner "$p")"; else echo "  $p: 空闲"; fi
    done
    echo "── 端口链自检 ──"
    check_port_chain "$GW_NAME" "$GW_PORT" "$GW_PORT" "/healthz" "网关" || true
    check_port_chain "$PANEL_NAME" "$PANEL_PORT" "$PANEL_CTR_PORT" "/api/healthz" "面板" || true
    echo "── 登录链路自检 ──"
    login_selftest "$PANEL_PORT" || true
    echo "── 面板密码状态 ──"
    if [[ -f "$USERS_FILE" ]]; then
      echo "  users.json 已存在 → 密码沿用首次部署时设定的那个"
      echo "  （WB_ADMIN_PASSWORD 环境变量此时【不会】生效）"
      echo "  忘记密码：./workbuddy2api.sh reset-password"
    else
      echo "  users.json 不存在 → 下次启动会用本次 PANEL_PASSWORD 创建"
    fi
    exit 0
    ;;
  reset-password|passwd)
    [[ $EUID -eq 0 ]] || die "请用 root 运行"
    NEWPWD="${2:-}"
    if [[ -z "$NEWPWD" ]]; then
      # 生成一个强随机密码
      NEWPWD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
      warn "未指定密码，已生成随机密码"
    fi
    reset_panel_password "$NEWPWD"
    echo
    echo "  面板账号 : admin"
    echo "  面板密码 : $NEWPWD"
    echo
    warn "请立即存入密码管理器，并清除本次终端输出记录"
    exit 0
    ;;
  logs)
    docker logs -f --tail 100 "$GW_NAME" 2>/dev/null &
    docker logs -f --tail 100 "$PANEL_NAME" 2>/dev/null &
    wait
    exit 0
    ;;
  deploy|update|"") : ;;
  *) die "未知子命令：$CMD（可用：deploy / update / stop / restart / status / logs / reset-password）" ;;
esac

# ============ 以下是部署主流程 ============
[[ $EUID -eq 0 ]] || die "请用 root 运行（或 sudo ./workbuddy2api.sh）"
command -v docker >/dev/null || die "未找到 docker，请先在 1Panel 安装"
docker compose version >/dev/null 2>&1 || die "未找到 docker compose v2 插件"

# ─── 0. 停旧实例 ───
stop_all || warn "端口仍被占用，稍后启动可能失败"

for p in "$GW_PORT" "$PANEL_PORT"; do
  if port_busy "$p"; then
    owner=$(port_owner "$p" || true)
    die "端口 $p 仍被占用${owner:+（$owner）}。

  ■ 若是【别的服务】占着，换个端口重跑即可：
        GW_PORT=27863 PANEL_PORT=27864 ./workbuddy2api.sh

  ■ 若是【旧的 workbuddy 容器】没删干净，先手动清理：
        docker ps -a | grep -E 'workbuddy'
        docker rm -f workbuddy2api workbuddy-manager
        docker network prune -f

  ■ 想看清楚到底是谁占着：
        ss -lntp | grep -E ':(${GW_PORT}|${PANEL_PORT})'
        lsof -iTCP:${p} -sTCP:LISTEN -P -n"
  fi
done
log "端口 $GW_PORT / $PANEL_PORT 均已空闲"

# ─── 随机凭据 ───
[[ -n "$GW_API_KEY" ]] || GW_API_KEY="wbk_$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)"

# 面板密码：只在【users.json 不存在】时才生成/采用。
# users.json 已存在时密码由文件决定，环境变量无效 —— 此时绝不能
# 生成随机密码并打印（那是个错密码，比不打印更误导）。
PWD_STATE=$(panel_password_state)
if [[ "$PWD_STATE" == "exists" ]]; then
  if [[ -n "$PANEL_PASSWORD" ]]; then
    warn "users.json 已存在，PANEL_PASSWORD 环境变量将被忽略（面板只认文件里的哈希）"
    warn "  如需改密码：./workbuddy2api.sh reset-password '新密码'"
  fi
  PANEL_PASSWORD=""
  PWD_NOTE="沿用首次部署时设定的密码"
else
  if [[ -z "$PANEL_PASSWORD" ]]; then
    PANEL_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
    PWD_NOTE="（本次生成，请立即保存）"
  else
    PWD_NOTE="（由 PANEL_PASSWORD 指定）"
  fi
fi

mkdir -p "$GW_DIR/auths" "$GW_DIR/data" "$PANEL_DIR/data"

# ─── 1. 上游 config.json ───
if [[ ! -f "$GW_DIR/config.json" ]]; then
  log "写入上游 config.json（listen=${GW_PORT}）"
  python3 - "$GW_DIR/config.json" "$GW_PORT" "$GW_API_KEY" <<'PY'
import json, sys
path, port, key = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = {
    "listen": port,
    "api_key": key,
    "auth_dir": "/app/auths",
    "state_file": "/app/data/state.json",
    "cooldown": {"soft_rate": "600s", "soft_rate_max": "2h"},
    "schedule": {
        "checkin_hours": [9, 21], "travel_hours": [9, 21],
        "activity_hours": [10], "keepalive_hours": [22],
        "school_hours": [12], "cat_hours": [1],
        "checkin_enabled": True, "travel_enabled": True,
        "activity_enabled": True, "keepalive_enabled": True,
        "school_enabled": True, "cat_enabled": True,
    },
    "admin": {"enabled": True},
    "global": {"enabled": True, "chat_base": "", "billing_base": ""},
    "upstream": {
        "timeout_seconds": 120, "header_timeout_seconds": 120,
        "idle_timeout_seconds": 300, "client_name": "WorkBuddy",
    },
    "features": {"sanitize_blacklist_fingerprints": True},
    "prompt": {"mode": "passthrough", "file": ""},
    "pool": {
        "max_in_flight": 3, "max_in_flight_global": 2,
        "breaker_threshold": 3, "breaker_cooldown": "30m",
        "breaker_cooldown_max": "6h",
        "expiring_soon": "168h", "cost_explore_interval": "30m",
    },
    "session_sticky": {"enabled": True, "ttl": "30m", "gc_interval": "5m"},
}
json.dump(cfg, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
print("config.json 已写入并通过 JSON 校验")
PY
else
  warn "$GW_DIR/config.json 已存在，保留不动"
  cur=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('listen',''))" "$GW_DIR/config.json" 2>/dev/null || echo "")
  if [[ -n "$cur" && "$cur" != "$GW_PORT" && "$cur" != ":$GW_PORT" ]]; then
    warn "config.json 里的 listen=$cur 与本次 GW_PORT=$GW_PORT 不一致！"
    warn "请手动改成 \"listen\": \"$GW_PORT\" 后重跑，否则容器端口映射会对不上。"
  fi
fi

# ─── 2. 上游 compose ───
if [[ "$NET_MODE" == "host" ]]; then
sync_compose "$GW_DIR" "上游" <<EOF
$COMPOSE_MARKER
# NET_MODE=host：绕过 bridge NAT（LXC 里跑 Docker 常见 bridge 出网不通）
services:
  wb2api:
    image: ghcr.io/sliverkiss/workbuddy2api:latest
    container_name: ${GW_NAME}
    restart: unless-stopped
    network_mode: host
    # 用环境变量把监听地址绑回回环，避免暴露公网。
    # ⚠️ 网关只有一个命令行参数 -config（没有 -listen），
    #    但 WB2A_LISTEN 是**真实生效**的环境变量
    #    （cmd/server/config.go: applyEnv 在 normalize 之前执行）。
    #    config.json 的 listen 仍写 ${GW_PORT}（宿主侧端口），实际监听由这里决定。
    environment:
      - TZ=Asia/Shanghai
      - WB2A_LISTEN=127.0.0.1:${GW_PORT}
    volumes:
      - ./auths:/app/auths
      - ./data:/app/data
      - ./config.json:/app/config.json
    # 官方镜像的 healthcheck 写死探测 127.0.0.1:7863/healthz（见镜像 Config.
    #   Healthcheck.Test），而本脚本让网关监听 ${GW_PORT}，两者不一致 →
    # 容器永远 unhealthy（服务其实是好的，只是探针探错端口）。
    # ⚠️ 危害不是"显示红色"这么简单：告警会彻底失效，将来真挂了也看不出来。
    # 所以这里覆盖成实际监听端口。
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:${GW_PORT}/healthz || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
EOF
else
sync_compose "$GW_DIR" "上游" <<EOF
$COMPOSE_MARKER
services:
  wb2api:
    image: ghcr.io/sliverkiss/workbuddy2api:latest
    container_name: ${GW_NAME}
    restart: unless-stopped
    environment:
      - TZ=Asia/Shanghai
    ports:
      # 网关容器内监听 = config.json 的 listen（本脚本设为 ${GW_PORT}），
      # 所以两侧同号映射即可。
      - "127.0.0.1:${GW_PORT}:${GW_CTR_PORT}"
    volumes:
      - ./auths:/app/auths
      - ./data:/app/data
      - ./config.json:/app/config.json
    extra_hosts:
      - "host.docker.internal:host-gateway"
    # 官方镜像的 healthcheck 写死探测 127.0.0.1:7863/healthz，与本脚本设定的
    # 容器内端口 ${GW_CTR_PORT} 不一致 → 容器永远 unhealthy（服务本身是好的）。
    # ⚠️ 危害不是"显示红色"这么简单：告警会彻底失效，将来真挂了也看不出来。
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:${GW_CTR_PORT}/healthz || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
EOF
fi

# ─── 3. 面板 compose ───
# 关键：容器内端口是官方镜像写死的 ${PANEL_CTR_PORT}（uvicorn --port），
# 不能用环境变量改（WB_MANAGER_PORT / WB_MANAGER_HOST 都是死配置）。
# 所以：
#   bridge 模式 → 映射必须写成  宿主 PANEL_PORT : 容器 PANEL_CTR_PORT
#   host   模式 → 用 command 覆盖 --host/--port
if [[ "$NET_MODE" == "host" ]]; then
PANEL_NET_BLOCK="    network_mode: host
    # 覆盖官方镜像的 --host 0.0.0.0；WB_MANAGER_HOST 是死配置（没传给 uvicorn）
    command: [\"python\", \"-m\", \"uvicorn\", \"server.main:app\", \"--host\", \"127.0.0.1\", \"--port\", \"${PANEL_PORT}\"]"
PANEL_BASE_URL="http://127.0.0.1:${GW_CTR_PORT}"
PANEL_PORTS_BLOCK=""
PANEL_EXTRA_HOSTS=""
else
PANEL_NET_BLOCK=""
PANEL_BASE_URL="http://host.docker.internal:${GW_PORT}"
PANEL_PORTS_BLOCK="    ports:
      # 宿主 ${PANEL_PORT} → 容器 ${PANEL_CTR_PORT}（官方镜像默认端口，改不动）
      # 只绑本机：面板持有全部账号凭证，必须藏在反代后面
      - \"127.0.0.1:${PANEL_PORT}:${PANEL_CTR_PORT}\""
PANEL_EXTRA_HOSTS="    extra_hosts:
      - \"host.docker.internal:host-gateway\""
fi

sync_compose "$PANEL_DIR" "面板" <<EOF
$COMPOSE_MARKER
services:
  workbuddy-manager:
    image: ghcr.io/ithtelab/workbuddy-manager:latest
    container_name: ${PANEL_NAME}
    restart: unless-stopped          # 网页一键更新会重建容器，靠它自动拉起
${PANEL_NET_BLOCK}
    environment:
      TZ: Asia/Shanghai
      # 仅在 users.json 不存在（首次启动）时生效；之后面板只认文件里的哈希，
      # 这里留空即表示「沿用已有密码」。
      WB_ADMIN_PASSWORD: "${PANEL_PASSWORD}"
      WB2API_BASE: ${PANEL_BASE_URL}
      WB_TRUST_PROXY: "1"
      WB_SECURE_COOKIE: "${SECURE_COOKIE}"
      WB_ENABLE_DOCS: "0"
      WB2API_MODE: docker
      WB2API_CONTAINER: ${GW_NAME}
      WB_AUTH_DIR: /opt/workbuddy2api/auths
      WB_UPSTREAM_CONFIG: /opt/workbuddy2api/config.json
      WB_UPSTREAM_DIR: /opt/workbuddy2api
      WB_TRUSTED_PROXY_CIDRS: "${TRUSTED_PROXY_CIDRS}"
      WB_TRUSTED_PROXY_HOPS: "1"
${PANEL_PORTS_BLOCK}
    volumes:
      - ./data:/app/data
      - ${GW_DIR}:/opt/workbuddy2api
      # docker.sock：换取「保存设置后自动重启上游 / 读上游日志 / 网页更新上游」
      # 不想要就注释掉，相关功能会自动降级为界面提示
      - /var/run/docker.sock:/var/run/docker.sock
${PANEL_EXTRA_HOSTS}
    # 官方镜像的 healthcheck 写死探测容器内 7864，端口改了会一直 unhealthy，
    # 所以这里覆盖成实际端口。
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:${PANEL_PORT}/api/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
EOF

# ─── 4. 权限（漏了会出现「账号数为 0 且重启无效」）───
log "修正数据目录属主为 10001（两个容器的运行 uid）"
chown -R 10001:10001 "$GW_DIR/auths" "$GW_DIR/data" "$PANEL_DIR/data"
chmod 700 "$GW_DIR/auths"

# ─── 5. 拉镜像（可选）───
if [[ "$PULL_IMAGE" == "1" ]]; then
  log "拉取最新镜像（PULL_IMAGE=0 可跳过）"
  docker pull ghcr.io/sliverkiss/workbuddy2api:latest   || warn "上游镜像拉取失败，将用本地已有镜像"
  docker pull ghcr.io/ithtelab/workbuddy-manager:latest || warn "面板镜像拉取失败，将用本地已有镜像"
fi

# ─── 6. 启动 ───
log "启动上游网关"
(cd "$GW_DIR" && docker compose up -d)
sleep 3
log "启动管理面板"
(cd "$PANEL_DIR" && docker compose up -d)
sleep 8

# ─── 7. 自检（含端口链一致性，v2 出错的地方这次会明确报出来）───
echo
log "===== 自检 ====="
(cd "$GW_DIR" && docker compose ps)
(cd "$PANEL_DIR" && docker compose ps)
echo
echo "── 端口映射 ──"
for n in "$GW_NAME" "$PANEL_NAME"; do
  echo "  $n: $(docker port "$n" 2>/dev/null | tr '\n' ' ' || echo '（未运行）')"
done
echo
echo "── 端口链自检（宿主 → 容器）──"
CHAIN_OK=1
# host 模式下容器内端口就是宿主端口（同一个网络栈），bridge 模式下才是 PANEL_CTR_PORT
if [[ "$NET_MODE" == "host" ]]; then
  check_port_chain "$GW_NAME" "$GW_PORT" "$GW_PORT" "/healthz" "网关" || CHAIN_OK=0
  check_port_chain "$PANEL_NAME" "$PANEL_PORT" "$PANEL_PORT" "/api/healthz" "面板" || CHAIN_OK=0
else
  check_port_chain "$GW_NAME" "$GW_PORT" "$GW_CTR_PORT" "/healthz" "网关" || CHAIN_OK=0
  check_port_chain "$PANEL_NAME" "$PANEL_PORT" "$PANEL_CTR_PORT" "/api/healthz" "面板" || CHAIN_OK=0
fi

echo
echo "── 登录链路自检 ──"
LOGIN_OK=1
login_selftest "$PANEL_PORT" || LOGIN_OK=0

echo
echo "── 容器出网自检（连不上腾讯就没法转发）──"
egress_selftest "$GW_NAME" "网关" || true
egress_selftest "$PANEL_NAME" "面板" || true

if [[ "$CHAIN_OK" != "1" ]]; then
  echo
  warn "有端口链不通，常见原因："
  warn "  · compose 里端口映射两侧不一致（本脚本 v3 已修正为 PANEL_PORT:${PANEL_CTR_PORT}）"
  warn "  · 若是你自己改过 compose，注意面板容器内固定监听 ${PANEL_CTR_PORT}"
  echo
fi

cat <<EOF

============================================================
  容器部署完成 —— 但还差一步：Caddy
============================================================
  ⚠️ 本脚本没有、也不会碰你的 Caddyfile。
     请手动在编辑器里完成（见 caddy.example.conf）：

     import 的 snippet 名必须**先在文件里定义好**，
     否则 reload 会报 "File to import not found"（服务不受影响，但配置不生效）。
     你已选择不加白名单，则直接用下面这段即可：

            ${DOMAIN} {
                tls internal

                encode gzip

                reverse_proxy 127.0.0.1:${PANEL_PORT} {
                    header_up X-Real-IP {remote_host}
                }
            }

     然后校验通过才 reload：
            cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak.\$(date +%Y%m%d%H%M%S)
            caddy fmt --overwrite /etc/caddy/Caddyfile
            caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
            systemctl reload caddy

     ⚠️ reload 失败时看完整报错（systemctl 的输出会被截断）：
            caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
            journalctl -xeu caddy.service -n 30 --no-pager | grep -i error

============================================================
  凭据
============================================================
  上游网关    : http://127.0.0.1:${GW_PORT}   （容器内 ${GW_PORT}）
  网关 API Key: ${GW_API_KEY}

  管理面板    : http://127.0.0.1:${PANEL_PORT}   （容器内 ${PANEL_CTR_PORT}）
  外部访问    : https://${DOMAIN} （配好 Caddy 后）
  面板账号    : admin
EOF

if [[ -n "$PANEL_PASSWORD" ]]; then
cat <<EOF
  面板密码    : ${PANEL_PASSWORD} ${PWD_NOTE}

  ⚠️ 请立即存入密码管理器，并清除本次终端输出记录
EOF
else
cat <<EOF
  面板密码    : （${PWD_NOTE}，本次未改动）

  ⚠️ 忘了密码就用这个重置（会吊销所有已登录会话）：
        ./workbuddy2api.sh reset-password '你的新密码'
     或不带参数让它生成随机密码：
        ./workbuddy2api.sh reset-password
EOF
fi

cat <<EOF
============================================================

  日常命令：
    ./workbuddy2api.sh status             状态 + 端口链 + 登录链路自检
    ./workbuddy2api.sh logs               跟踪日志
    ./workbuddy2api.sh restart            重启两个容器
    ./workbuddy2api.sh stop               停止两个容器
    ./workbuddy2api.sh reset-password     重置面板密码
    ./workbuddy2api.sh                    再次运行 = 更新（自动停旧起新）

  加 CodeBuddy 账号（二选一）：
    浏览器打开面板 → 账号页 → 「添加账号」扫码（推荐）
    或：cd ${GW_DIR} && docker compose exec -it wb2api bash -c './login.sh'
============================================================
EOF
