#!/bin/sh
# gemini-web2api 主控机一键部署 R1.1.0
# 用法：sudo ./install.sh [端口]     默认 8084
# 支持：纯 IPv6 / 纯 IPv4 / 双栈 VPS（Debian / Ubuntu / CentOS，systemd）
# 仓库：https://github.com/onshine/ScriptHubs/tree/main/gemini-web2api
set -e
SCRIPT_VERSION="R1.8.0"
RAWBASE="https://raw.githubusercontent.com/onshine/ScriptHubs/main/gemini-web2api"
VER="v4.0.0"
REGEN=0
PORT=8084
for a in "$@"; do
  case "$a" in
    --regen) REGEN=1 ;;
    [0-9]*)  PORT="$a" ;;
  esac
done
DIR="/opt/gemini-web2api"
SVC="gemini-web2api"

[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo "需要 systemd"; exit 1; }
command -v curl >/dev/null 2>&1 || { apt update -qq && apt install -y -qq curl; }
# ── 自愈：清掉早期版本(R1.2.0)装坏的 3proxy ──────────────────
# 它要 glibc>=2.38 而 Debian 12 只有 2.36，dpkg 停在"已解包未配置"，
# 会卡住后续所有 apt 安装。
if command -v dpkg >/dev/null 2>&1; then
  BROKEN=$(dpkg -l 3proxy 2>/dev/null | awk '/^[a-z]{1,2}[A-Z]/{print $2}' | head -1)
  if [ -n "$BROKEN" ]; then
    echo "检测到残留的损坏 3proxy，清理中"
    systemctl disable --now 3proxy >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/3proxy.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    dpkg --purge --force-all 3proxy >/dev/null 2>&1 || true
    apt-get --fix-broken install -y >/dev/null 2>&1 || true
    echo "已清理"
  fi
fi

echo "=== 主控机部署 $SCRIPT_VERSION (上游 $VER, 端口 $PORT) ==="

# 1. 架构
case "$(uname -m)" in
  x86_64)  A=amd64 ;;
  aarch64) A=arm64 ;;
  *) echo "不支持的架构 $(uname -m)"; exit 1 ;;
esac
echo "[1/6] 架构 linux_$A"

# 2. 凭据（内核 CSPRNG，不落 history、不进命令行）
gen() { tr -dc 'a-f0-9' < /dev/urandom | head -c "${1:-32}"; }
REUSED=0
if [ -f "$DIR/.credentials" ] && [ "$REGEN" != "1" ]; then
  # 复用已有凭据：重跑脚本不该让客户端配置全部失效
  WANT_PORT="$PORT"          # 存好命令行指定的端口
  . "$DIR/.credentials"
  PORT="$WANT_PORT"          # 别让文件里的 PORT= 覆盖它
  TOK="$ADMIN_TOKEN"; APIKEY="$API_KEY"
  [ -n "$TOK" ] && [ -n "$APIKEY" ] && REUSED=1
fi
if [ "$REUSED" = "1" ]; then
  echo "[2/6] 复用已有凭据（要重新生成请加 --regen）"
else
  TOK=$(gen 32)
  APIKEY="sk-gemini-$(gen 40)"
  echo "[2/6] 凭据已生成"
fi
# 立刻落盘：后续步骤若失败，凭据也不会丢
mkdir -p "$DIR"
cat > "$DIR/.credentials" <<EOF
ADMIN_TOKEN=$TOK
API_KEY=$APIKEY
PORT=$PORT
EOF
chmod 600 "$DIR/.credentials"

# 3. 下载
mkdir -p "$DIR/data" && cd "$DIR"
echo "[3/6] 下载二进制"
# 运行中的可执行文件不能被直接覆盖（Text file busy），
# 所以先停服务，再下到临时文件，最后 mv 原子替换。
systemctl stop $SVC >/dev/null 2>&1 || true
# 兜底：手工前台跑的实例不受 systemctl 管，仍会占用文件，一并停掉
if [ -x "$DIR/gemini-web2api" ]; then
  pkill -f "$DIR/gemini-web2api" >/dev/null 2>&1 || true
  sleep 1
fi
URL="https://github.com/zexadev/gemini-web2api-go/releases/download/$VER/gemini-web2api-go_${VER}_linux_$A"
if ! curl -fL --retry 3 -o gemini-web2api.new "$URL"; then
  rm -f gemini-web2api.new
  echo "❌ 下载失败：$URL"
  if [ -n "$(pgrep -f "$DIR/gemini-web2api" 2>/dev/null)" ]; then
    echo "   检测到仍有进程占用二进制，先执行： pkill -f $DIR/gemini-web2api"
  fi
  echo "   1) 检查能否访问 GitHub:  curl -sI https://github.com | head -1"
  echo "   2) 纯 IPv6 机需先配 NAT64/WARP"
  echo "   3) 或本地下好后:  scp 文件 root@本机:$DIR/gemini-web2api"
  exit 1
fi
chmod +x gemini-web2api.new
# 先验证新文件能跑，再替换旧的（坏包不会顶掉可用的版本）
if ! ./gemini-web2api.new --version >/dev/null 2>&1; then
  rm -f gemini-web2api.new
  echo "❌ 下载的二进制无法执行（可能是架构不符或文件损坏）"
  exit 1
fi
mv -f gemini-web2api.new gemini-web2api
echo "      $(./gemini-web2api --version 2>/dev/null || echo '版本未知')"

# 4. config.json —— host 必须 :: 才能同时监听 v4+v6
#    上游默认 0.0.0.0 是 IPv4 通配符，且没有 --host 参数，纯 v6 机外部连不上。
echo "[4/6] 写 config.json（host=[::] 双栈监听）"
cat > config.json <<EOF
{
  "port": $PORT,
  "host": "[::]",
  "db_path": "$DIR/data/gemini.db",
  "admin_enabled": true,
  "impersonate": "chrome_146",
  "default_model": "gemini-3.6-flash",
  "retry_attempts": 3,
  "retry_delay_sec": 2,
  "request_timeout_sec": 180,
  "retention_days": 30,
  "per_ip_concurrent": 5,
  "per_ip_rpm": 30,
  "per_ip_rph": 80,
  "log_requests": true
}
EOF

# 5. 预检 + 安装服务
echo "[5/6] 预检与安装服务"
id gemini >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin gemini
chown -R gemini:gemini "$DIR"

# 先停旧服务（重跑场景），否则预检必然撞 "address already in use"
systemctl stop $SVC >/dev/null 2>&1 || true
i=0
while [ $i -lt 12 ]; do
  ss -tlnH "sport = :$PORT" 2>/dev/null | grep -q . || break
  sleep 0.5; i=$((i+1))
done
if ss -tlnH "sport = :$PORT" 2>/dev/null | grep -q .; then
  echo "❌ 端口 $PORT 已被占用，占用者："
  ss -tlnpH "sport = :$PORT" 2>/dev/null | sed 's/^/     /'
  echo
  echo "   换端口重跑:  sudo ./install.sh 9000"
  exit 1
fi

# 预检：前台试跑 4 秒。放在写 unit 之前，避免"unit 已是新凭据但服务没重启"
# 导致运行中进程与 .credentials 不一致。
echo "      预检启动..."
run_pre() {
  cd "$DIR" && timeout 4 sudo -u gemini env ADMIN_TOKEN="$TOK" API_KEY="$APIKEY" \
    "$DIR/gemini-web2api" --config "$DIR/config.json" --port "$PORT" \
    --db "$DIR/data/gemini.db" 2>&1 || true
}
PRE=$(run_pre)
if echo "$PRE" | grep -qi "too many colons\|invalid.*address"; then
  echo "      ⚠️ [::] 不被接受，回退 0.0.0.0（仅 IPv4 监听）"
  sed -i 's|"host": "\[::\]"|"host": "0.0.0.0"|' "$DIR/config.json"
  chown gemini:gemini "$DIR/config.json"
  PRE=$(run_pre)
fi
if echo "$PRE" | grep -qi "server error\|permission denied\|no such file"; then
  echo "❌ 预检失败，错误信息："
  echo "$PRE" | grep -i "error\|denied\|no such" | head -5 | sed 's/^/     /'
  echo
  echo "   config.json 内容："
  sed 's/^/     /' "$DIR/config.json"
  echo
  echo "   （服务未安装/未改动，凭据已存于 $DIR/.credentials）"
  exit 1
fi
echo "      预检通过"

# 预检通过才写 unit —— 保证 unit 里的凭据必定与运行进程一致
cat > /etc/systemd/system/$SVC.service <<EOF
[Unit]
Description=gemini-web2api-go (Gemini web -> OpenAI API)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=gemini
Group=gemini
WorkingDirectory=$DIR
Environment=ADMIN_TOKEN=$TOK
Environment=API_KEY=$APIKEY
ExecStart=$DIR/gemini-web2api --config $DIR/config.json --port $PORT --db $DIR/data/gemini.db
Restart=on-failure
RestartSec=5
MemoryMax=256M
CPUQuota=50%
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
chmod 600 /etc/systemd/system/$SVC.service
systemctl daemon-reload
systemctl enable --now $SVC >/dev/null 2>&1

# 6. 自检
echo "[6/6] 自检"
sleep 3
if ! systemctl is-active --quiet $SVC; then
  echo "❌ 启动失败，最近日志："
  journalctl -u $SVC -n 25 --no-pager 2>/dev/null | grep -v "^--" | sed 's/^/     /'
  echo
  echo "   手动排查: cd $DIR && sudo -u gemini ./gemini-web2api --config config.json --port $PORT --db data/gemini.db"
  exit 1
fi
LISTEN=$(ss -tlnH "sport = :$PORT" 2>/dev/null | awk '{print $4}' | head -1)
HEALTH=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/" || echo FAIL)
# 实测 API Key 鉴权，确认运行进程与 .credentials 一致
AUTHTEST=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $APIKEY" "http://127.0.0.1:$PORT/v1/models" || echo 000)
case "$AUTHTEST" in
  200) AUTHMSG="✅ 通过" ;;
  401|403) AUTHMSG="❌ 失败(HTTP $AUTHTEST) — 试 systemctl restart $SVC" ;;
  *) AUTHMSG="⚠️ 未知(HTTP $AUTHTEST)" ;;
esac
V4=$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null || echo "")
V6=$(curl -6 -s --max-time 6 https://api64.ipify.org 2>/dev/null || echo "")

# 面板地址按实际有的 IP 给
if [ -n "$V4" ]; then PANEL="http://$V4:$PORT"; else PANEL="http://[$V6]:$PORT"; fi

echo
echo "=============================================================="
echo "  ✅ 主控机就绪"
echo "  监听        : ${LISTEN:-未知}   （含 :: 或 * 才表示 v6 可达）"
echo "  健康检查    : $HEALTH"
echo "  API Key 鉴权: $AUTHMSG"
echo "  本机 IPv4   : ${V4:-无}"
echo "  本机 IPv6   : ${V6:-无}"
echo "--------------------------------------------------------------"
echo "  Admin Token : $TOK"
echo "  API Key     : $APIKEY"
echo "  （已存 $DIR/.credentials）"
echo "  以后随时查看: ./gw.sh creds    或   cat $DIR/.credentials"
echo "--------------------------------------------------------------"
echo "  管理面板    : $PANEL/admin"
echo "  API 地址    : $PANEL/v1"
echo "  本机测试    : curl -H \"Authorization: Bearer $APIKEY\" http://127.0.0.1:$PORT/v1/models"
echo "--------------------------------------------------------------"
echo "  下一步：在每台出口机跑 outbound.sh，把它给出的 socks5 地址用"
echo "         ./addproxy.sh 'socks5h://...' 加进来"
echo "=============================================================="
