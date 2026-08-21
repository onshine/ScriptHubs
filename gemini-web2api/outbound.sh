#!/bin/sh
# gemini-web2api 出口机脚本 R1.2.0 — 装 socks5，把本机 IPv6 变成出口
# 用法：sudo ./outbound.sh
# 仓库：https://github.com/onshine/ScriptHubs/tree/main/gemini-web2api
set -e
SCRIPT_VERSION="R1.2.0"
PORT=1080
CFG=/etc/3proxy/3proxy.cfg

[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }
echo "=== 出口机部署 $SCRIPT_VERSION ==="

command -v curl >/dev/null 2>&1 || { apt-get update && apt-get install -y curl; }

# ── 1. 安装 3proxy：源装 → 官方 deb/rpm → 源码编译，三级回退 ──
install_3proxy() {
  # (a) 系统源（Debian 12+/Ubuntu 22+ 都有；不吞错误，失败就往下走）
  if command -v apt-get >/dev/null 2>&1; then
    echo "  尝试 apt 安装..."
    apt-get update -qq || true
    if apt-get install -y 3proxy >/dev/null 2>&1; then
      echo "  ✅ apt 安装成功"; return 0
    fi
    echo "  apt 源里没有，改用官方 deb"
  fi

  # (b) 官方 Release deb/rpm —— 注意资产名用 x86_64/arm64，且版本要存在
  M=$(uname -m)
  case "$M" in
    x86_64)  ASSET_ARCH=x86_64 ;;
    aarch64) ASSET_ARCH=arm64  ;;
    armv7l|armv6l) ASSET_ARCH=arm ;;
    *) ASSET_ARCH="" ;;
  esac
  if [ -n "$ASSET_ARCH" ]; then
    # 动态取最新 tag，避免写死版本号将来 404
    TAG=$(curl -fsSL https://api.github.com/repos/3proxy/3proxy/releases/latest 2>/dev/null \
          | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$TAG" ] || TAG=0.9.9
    if command -v dpkg >/dev/null 2>&1; then
      URL="https://github.com/3proxy/3proxy/releases/download/$TAG/3proxy-$TAG.$ASSET_ARCH.deb"
      echo "  下载 $URL"
      if curl -fsSL -o /tmp/3proxy.pkg "$URL"; then
        apt-get install -y /tmp/3proxy.pkg >/dev/null 2>&1 || dpkg -i /tmp/3proxy.pkg || true
        command -v 3proxy >/dev/null 2>&1 && { echo "  ✅ deb 安装成功"; return 0; }
      fi
    elif command -v rpm >/dev/null 2>&1; then
      URL="https://github.com/3proxy/3proxy/releases/download/$TAG/3proxy-$TAG.$ASSET_ARCH.rpm"
      curl -fsSL -o /tmp/3proxy.pkg "$URL" && rpm -i /tmp/3proxy.pkg 2>/dev/null || true
      command -v 3proxy >/dev/null 2>&1 && { echo "  ✅ rpm 安装成功"; return 0; }
    fi
    echo "  官方包不可用，改为源码编译"
  fi

  # (c) 源码编译（最后兜底，纯 v6 机也能过，只依赖 gcc+make）
  echo "  编译安装 3proxy $TAG"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y build-essential >/dev/null 2>&1 || apt-get install -y gcc make libc6-dev >/dev/null 2>&1
  else
    yum groupinstall -y "Development Tools" >/dev/null 2>&1 || yum install -y gcc make >/dev/null 2>&1
  fi
  curl -fsSL -o /tmp/3proxy.tar.gz "https://github.com/3proxy/3proxy/archive/refs/tags/$TAG.tar.gz" || return 1
  rm -rf /tmp/3proxy-src && mkdir -p /tmp/3proxy-src
  tar xzf /tmp/3proxy.tar.gz -C /tmp/3proxy-src --strip-components=1 || return 1
  ( cd /tmp/3proxy-src && make -f Makefile.Linux >/dev/null 2>&1 && \
    { install -m755 bin/3proxy /usr/local/bin/3proxy 2>/dev/null || \
      install -m755 src/3proxy /usr/local/bin/3proxy; } ) || return 1
  command -v 3proxy >/dev/null 2>&1
}

if command -v 3proxy >/dev/null 2>&1; then
  echo "[1/4] 3proxy 已安装，跳过"
else
  echo "[1/4] 安装 3proxy"
  install_3proxy || { echo "❌ 3proxy 安装失败，请手动 apt install 3proxy 后重跑"; exit 1; }
fi
BIN=$(command -v 3proxy)
echo "      使用 $BIN"

# ── 2. 账号密码（随机，防止变成公共代理）──────────────────────
echo "[2/4] 生成代理账号"
gen() { tr -dc 'a-z0-9' < /dev/urandom | head -c "${1:-16}"; }
USER="gw$(gen 6)"
PASS=$(gen 20)

# ── 3. 配置：监听双栈，出站强制 IPv6 ─────────────────────────
echo "[3/4] 写配置"
mkdir -p /etc/3proxy
cat > "$CFG" <<EOF
# gemini-web2api 出口 $SCRIPT_VERSION
nserver 2606:4700:4700::1111
nserver 2001:4860:4860::8888
nserver 1.1.1.1
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
users $USER:CL:$PASS
auth strong
allow $USER
# -6 = 出站强制走 IPv6（"IPv6 出口"的关键）
socks -p$PORT -6
EOF
chmod 600 "$CFG"

cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy socks5 (gemini-web2api outbound)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN $CFG
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy >/dev/null 2>&1
systemctl restart 3proxy
sleep 2

# ── 4. 自检 ──────────────────────────────────────────────────
echo "[4/4] 自检"
if ! systemctl is-active --quiet 3proxy; then
  echo "❌ 启动失败，最近日志："
  journalctl -u 3proxy -n 20 --no-pager 2>/dev/null || true
  exit 1
fi
ss -tlnH "sport = :$PORT" 2>/dev/null | head -2 | sed 's/^/      监听: /'

V6=$(curl -6 -s --max-time 8 https://api64.ipify.org 2>/dev/null || echo "")
V4=$(curl -4 -s --max-time 8 https://api.ipify.org 2>/dev/null || echo "")
OUT=$(curl -s --max-time 15 --proxy "socks5h://$USER:$PASS@127.0.0.1:$PORT" \
      https://api64.ipify.org 2>/dev/null || echo "")

echo
echo "=============================================================="
if [ -n "$OUT" ]; then
  echo "  ✅ 出口机就绪（代理实测可用）"
else
  echo "  ⚠️ 服务已启动，但本机代理自测未通（可能是出站 v6 不可用）"
  echo "     排查：curl -6 https://api64.ipify.org  能否返回地址"
fi
echo "  本机 IPv6   : ${V6:-无}"
echo "  本机 IPv4   : ${V4:-无（纯 v6 机）}"
echo "  代理出口 IP : ${OUT:-未探测到}"
echo "--------------------------------------------------------------"
echo "  复制下面这一整行，拿到主控机用："
echo
if [ -n "$V6" ]; then
  echo "  socks5h://$USER:$PASS@[$V6]:$PORT"
else
  echo "  socks5h://$USER:$PASS@$V4:$PORT"
fi
echo
echo "  ⚠️ 密码只显示这一次。忘了就看：cat $CFG"
echo "=============================================================="
