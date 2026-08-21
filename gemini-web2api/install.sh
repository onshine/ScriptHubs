#!/bin/sh
# gemini-web2api-go 一键部署脚本 R1.0.0
# 适用：IPv6 / 双栈 VPS（Debian / Ubuntu，systemd）
# 用法：chmod +x install.sh && sudo ./install.sh [端口]
# 仓库：https://github.com/onshine/ScriptHubs/tree/main/gemini-web2api
set -e

SCRIPT_VERSION="R1.0.0"
VER="v4.0.0"                     # gemini-web2api-go 版本
PORT="${1:-8084}"                # 默认 8084，可传参覆盖
DIR="/opt/gemini-web2api"
SVC="gemini-web2api"

echo "=== gemini-web2api 一键部署 $SCRIPT_VERSION (上游 $VER, 端口 $PORT) ==="

# ── 0. 前置检查 ──────────────────────────────────────────────
[ "$(id -u)" = "0" ] || { echo "请用 root 或 sudo 运行"; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo "需要 systemd"; exit 1; }
command -v curl >/dev/null 2>&1 || { apt update && apt install -y curl; }

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  A=amd64 ;;
  aarch64) A=arm64 ;;
  *) echo "不支持的架构：$ARCH"; exit 1 ;;
esac
echo "[1/6] 架构 $ARCH -> linux_$A"

# ── 1. 生成强凭据 ────────────────────────────────────────────
# 用内核 CSPRNG，不落 shell history，不进进程命令行
gen() { tr -dc 'a-f0-9' < /dev/urandom | head -c "${1:-32}"; }
TOK=$(gen 32)
APIKEY="sk-gemini-$(gen 40)"
echo "[2/6] 已生成 admin token 与 API key"

# ── 2. 下载二进制 ────────────────────────────────────────────
mkdir -p "$DIR/data" && cd "$DIR"
URL="https://github.com/zexadev/gemini-web2api-go/releases/download/$VER/gemini-web2api-go_${VER}_linux_$A"
echo "[3/6] 下载 $URL"
curl -fL --retry 3 -o gemini-web2api "$URL" || {
  echo "下载失败。纯 IPv6 机器请先配 NAT64/WARP，或本地下载后 scp 到 $DIR"; exit 1; }
chmod +x gemini-web2api
./gemini-web2api --version || { echo "二进制无法执行"; exit 1; }

# ── 3. 写 config.json（关键：host 必须 :: 才听 IPv6）────────
# 上游没有 --host 参数，默认 0.0.0.0 只监听 IPv4，
# 纯 v6 小鸡外部一律连不上。改成 :: 即双栈全收。
echo "[4/6] 写 config.json（host=:: 双栈监听）"
cat > config.json <<EOF
{
  "port": $PORT,
  "host": "::",
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

# ── 4. 低权限用户 ────────────────────────────────────────────
id gemini >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin gemini
chown -R gemini:gemini "$DIR"

# ── 5. systemd 单元（凭据走 Environment，ps 看不到）─────────
echo "[5/6] 安装 systemd 服务"
cat > /etc/systemd/system/$SVC.service <<EOF
[Unit]
Description=gemini-web2api-go (Gemini web -> OpenAI API)
Documentation=https://github.com/onshine/ScriptHubs/tree/main/gemini-web2api
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

chmod 600 /etc/systemd/system/$SVC.service   # 单元里有凭据，锁死权限
systemctl daemon-reload
systemctl enable --now $SVC

# ── 6. 自检 ──────────────────────────────────────────────────
echo "[6/6] 等待启动并自检"
sleep 3
systemctl is-active --quiet $SVC || { echo "启动失败，看日志：journalctl -u $SVC -n 50"; exit 1; }

LISTEN=$(ss -tlnH "sport = :$PORT" 2>/dev/null | awk '{print $4}' | head -1)
HEALTH=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/" || echo "FAIL")
V6=$(curl -6 -s --max-time 5 https://ifconfig.co 2>/dev/null || echo "未探测到")

echo
echo "================================================================"
echo "  ✅ 部署完成"
echo "----------------------------------------------------------------"
echo "  端口        : $PORT"
echo "  监听        : ${LISTEN:-未知}   (含 :: 或 * 才表示 IPv6 可达)"
echo "  健康检查    : $HEALTH"
echo "  本机 IPv6   : $V6"
echo "----------------------------------------------------------------"
echo "  Admin Token : $TOK"
echo "  API Key     : $APIKEY"
echo "  ⚠️ 以上两个值只显示这一次，请立刻保存"
echo "----------------------------------------------------------------"
echo "  管理面板    : http://[$V6]:$PORT/admin"
echo "  API Base    : http://[$V6]:$PORT/v1"
echo "  本机测试    : curl -H \"Authorization: Bearer $APIKEY\" http://127.0.0.1:$PORT/v1/models"
echo "----------------------------------------------------------------"
echo "  下一步："
echo "  1) 放行端口: ufw allow $PORT/tcp"
echo "  2) 挂 Google Cookie 解锁 gemini-3.1-pro（面板 设置 页）"
echo "  3) 双机组队: 见 README「两台小鸡一起玩」"
echo "================================================================"
