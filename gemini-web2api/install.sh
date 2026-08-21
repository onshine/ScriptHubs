#!/bin/sh
# gemini-web2api 主控机一键部署 R1.1.0
# 用法：sudo ./install.sh [端口]     默认 8084
# 支持：纯 IPv6 / 纯 IPv4 / 双栈 VPS（Debian / Ubuntu / CentOS，systemd）
# 仓库：https://github.com/onshine/ScriptHubs/tree/main/gemini-web2api
set -e
SCRIPT_VERSION="R1.3.2"
VER="v4.0.0"
PORT="${1:-8084}"
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
TOK=$(gen 32)
APIKEY="sk-gemini-$(gen 40)"
echo "[2/6] 凭据已生成"

# 3. 下载
mkdir -p "$DIR/data" && cd "$DIR"
echo "[3/6] 下载二进制"
curl -fL --retry 3 -o gemini-web2api \
  "https://github.com/zexadev/gemini-web2api-go/releases/download/$VER/gemini-web2api-go_${VER}_linux_$A" \
  || { echo "下载失败。纯 IPv6 机需先配 NAT64/WARP，或本地下好 scp 到 $DIR"; exit 1; }
chmod +x gemini-web2api
./gemini-web2api --version >/dev/null || { echo "二进制不可执行"; exit 1; }

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

# 5. systemd
echo "[5/6] 安装服务"
id gemini >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin gemini
chown -R gemini:gemini "$DIR"
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

# 先前台试跑 3 秒，能提前暴露配置类错误（比如监听地址写法不对）
echo "      预检启动..."
PRE=$(cd "$DIR" && timeout 4 sudo -u gemini env ADMIN_TOKEN="$TOK" API_KEY="$APIKEY" \
      "$DIR/gemini-web2api" --config "$DIR/config.json" --port "$PORT" \
      --db "$DIR/data/gemini.db" 2>&1 || true)
if echo "$PRE" | grep -qi "too many colons\|invalid.*address"; then
  # 极少数环境不吃 [::]，回退成 0.0.0.0（仅 IPv4，但至少能起来）
  echo "      ⚠️ [::] 不被接受，回退 0.0.0.0（仅 IPv4 监听）"
  sed -i 's|"host": "\[::\]"|"host": "0.0.0.0"|' "$DIR/config.json"
  chown gemini:gemini "$DIR/config.json"
  PRE=$(cd "$DIR" && timeout 4 sudo -u gemini env ADMIN_TOKEN="$TOK" API_KEY="$APIKEY" \
        "$DIR/gemini-web2api" --config "$DIR/config.json" --port "$PORT" \
        --db "$DIR/data/gemini.db" 2>&1 || true)
fi
if echo "$PRE" | grep -qi "server error\|permission denied\|no such file"; then
  echo "❌ 预检失败，错误信息："
  echo "$PRE" | grep -i "error\|denied\|no such" | head -5 | sed 's/^/     /'
  echo
  echo "   config.json 内容："
  sed 's/^/     /' "$DIR/config.json"
  exit 1
fi

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
V4=$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null || echo "")
V6=$(curl -6 -s --max-time 6 https://api64.ipify.org 2>/dev/null || echo "")

# 存一份凭据给 addproxy.sh 免手输
cat > "$DIR/.credentials" <<EOF
ADMIN_TOKEN=$TOK
API_KEY=$APIKEY
PORT=$PORT
EOF
chmod 600 "$DIR/.credentials"

# 面板地址按实际有的 IP 给
if [ -n "$V4" ]; then PANEL="http://$V4:$PORT"; else PANEL="http://[$V6]:$PORT"; fi

echo
echo "=============================================================="
echo "  ✅ 主控机就绪"
echo "  监听        : ${LISTEN:-未知}   （含 :: 或 * 才表示 v6 可达）"
echo "  健康检查    : $HEALTH"
echo "  本机 IPv4   : ${V4:-无}"
echo "  本机 IPv6   : ${V6:-无}"
echo "--------------------------------------------------------------"
echo "  Admin Token : $TOK"
echo "  API Key     : $APIKEY"
echo "  （已存 $DIR/.credentials，addproxy.sh 会自动读取）"
echo "--------------------------------------------------------------"
echo "  管理面板    : $PANEL/admin"
echo "  API 地址    : $PANEL/v1"
echo "  本机测试    : curl -H \"Authorization: Bearer $APIKEY\" http://127.0.0.1:$PORT/v1/models"
echo "--------------------------------------------------------------"
echo "  下一步：在每台出口机跑 outbound.sh，把它给出的 socks5 地址用"
echo "         ./addproxy.sh 'socks5h://...' 加进来"
echo "=============================================================="
