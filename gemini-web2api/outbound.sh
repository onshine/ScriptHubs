#!/bin/sh
# gemini-web2api 出口机脚本 R1.1.0 — 装 socks5，把本机 IPv6 变成出口
# 用法：sudo ./outbound.sh
# 仓库：https://github.com/onshine/ScriptHubs/tree/main/gemini-web2api
set -e
SCRIPT_VERSION="R1.1.0"
PORT=1080

[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }
echo "=== 出口机部署 $SCRIPT_VERSION ==="

# 1. 装 3proxy（比 dante 配置简单，支持 v6，无交互）
if ! command -v 3proxy >/dev/null 2>&1; then
  echo "[1/4] 安装 3proxy"
  if command -v apt >/dev/null 2>&1; then
    apt update -qq && DEBIAN_FRONTEND=noninteractive apt install -y -qq 3proxy curl >/dev/null 2>&1 || {
      # 官方源没有就下 deb
      ARCH=$(dpkg --print-architecture)
      curl -fsSL -o /tmp/3proxy.deb "https://github.com/3proxy/3proxy/releases/download/0.9.4/3proxy-0.9.4.${ARCH}.deb"
      dpkg -i /tmp/3proxy.deb >/dev/null 2>&1
    }
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q 3proxy curl >/dev/null 2>&1
  fi
fi
command -v 3proxy >/dev/null 2>&1 || { echo "3proxy 安装失败"; exit 1; }

# 2. 生成随机账号密码（避免成公共代理被滥用）
echo "[2/4] 生成代理账号"
gen() { tr -dc 'a-z0-9' < /dev/urandom | head -c "${1:-16}"; }
USER="gw$(gen 6)"
PASS=$(gen 20)

# 3. 写配置：监听 v4+v6 双栈，出站优先 IPv6
echo "[3/4] 写配置"
mkdir -p /etc/3proxy
cat > /etc/3proxy/3proxy.cfg <<EOF
# gemini-web2api 出口 $SCRIPT_VERSION
nserver 2606:4700:4700::1111
nserver 2001:4860:4860::8888
nserver 1.1.1.1
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
users $USER:CL:$PASS
auth strong
allow $USER
# -6 = 出站强制走 IPv6（这是"IPv6 出口"的关键）
socks -p$PORT -6
EOF
chmod 600 /etc/3proxy/3proxy.cfg

cat > /etc/systemd/system/3proxy.service <<'EOF'
[Unit]
Description=3proxy socks5 (gemini-web2api outbound)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
[ -x /usr/bin/3proxy ] || sed -i "s|/usr/bin/3proxy|$(command -v 3proxy)|" /etc/systemd/system/3proxy.service

systemctl daemon-reload
systemctl enable --now 3proxy >/dev/null 2>&1
sleep 2

# 4. 自检 + 输出主控机要用的地址
echo "[4/4] 自检"
systemctl is-active --quiet 3proxy || { echo "启动失败：journalctl -u 3proxy -n 30"; exit 1; }

V6=$(curl -6 -s --max-time 8 https://api64.ipify.org 2>/dev/null || echo "")
V4=$(curl -4 -s --max-time 8 https://api.ipify.org 2>/dev/null || echo "")
# 通过自己的代理测出口 IP，确认真的走 v6
OUT=$(curl -s --max-time 12 --socks5-hostname "$USER:$PASS@127.0.0.1:$PORT" https://api64.ipify.org 2>/dev/null || echo "探测失败")

echo
echo "=============================================================="
echo "  ✅ 出口机就绪"
echo "  本机 IPv6   : ${V6:-无}"
echo "  本机 IPv4   : ${V4:-无（纯 v6 机）}"
echo "  代理出口 IP : $OUT"
echo "--------------------------------------------------------------"
echo "  把下面这一整行复制给主控机用（addproxy.sh 的参数）："
echo
if [ -n "$V6" ]; then
  echo "  socks5h://$USER:$PASS@[$V6]:$PORT"
else
  echo "  socks5h://$USER:$PASS@$V4:$PORT"
fi
echo
echo "  ⚠️ 密码只显示这一次。如需重看：cat /etc/3proxy/3proxy.cfg"
echo "=============================================================="
