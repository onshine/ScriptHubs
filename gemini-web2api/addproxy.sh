#!/bin/sh
# gemini-web2api 加代理脚本 R1.1.0 — 把出口机加进主控的代理池
#
# 用法（在主控机上跑）：
#   ./addproxy.sh 'socks5h://user:pass@[2001:db8::2]:1080'     # 加一个出口
#   ./addproxy.sh --local                                       # 把主控自己也变成一个出口槽
#   ./addproxy.sh --list                                        # 看当前池子
#
# 为什么要 --local：上游代码 pickProxyWithCapacity() 决定了
# **代理池非空时绝不回退直连**，所以只加了别的机器的话，主控自己的 IP 会闲置。
# 想让主控的 IP 也干活，必须在主控上装 socks5 并作为一条代理加进池子。
#
# 仓库：https://github.com/onshine/ScriptHubs/tree/main/gemini-web2api
set -e
SCRIPT_VERSION="R1.2.0"
DIR="/opt/gemini-web2api"

[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }
[ -f "$DIR/.credentials" ] || { echo "找不到 $DIR/.credentials，请先跑 install.sh"; exit 1; }
. "$DIR/.credentials"
API="http://127.0.0.1:$PORT/admin/api/proxies"
AUTH="Authorization: Bearer $ADMIN_TOKEN"

list_pool() {
  echo "当前代理池："
  curl -s -H "$AUTH" "$API" | sed 's/},{/}\n{/g' \
    | sed -n 's/.*"name":"\([^"]*\)".*"url":"\([^"]*\)".*"enabled":\([a-z]*\).*/  - \1  \2  enabled=\3/p' \
    || echo "  (解析失败，请开面板查看)"
}

# ── --list ───────────────────────────────────────────────────
if [ "$1" = "--list" ]; then list_pool; exit 0; fi

# ── --local：在主控本机装 socks5 并加入池子 ──────────────────
if [ "$1" = "--local" ]; then
  echo "=== 让主控自己也成为一个出口槽 $SCRIPT_VERSION ==="
  if ! command -v 3proxy >/dev/null 2>&1; then
    echo "[1/3] 安装 3proxy"
    OK=0
    # (a) 系统源
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq || true
      apt-get install -y 3proxy >/dev/null 2>&1 && OK=1
    elif command -v yum >/dev/null 2>&1; then
      yum install -y -q 3proxy >/dev/null 2>&1 && OK=1
    fi
    # (b) 官方 Release（资产名用 x86_64/arm64，版本动态取，避免写死后 404）
    if [ "$OK" = "0" ]; then
      case "$(uname -m)" in
        x86_64)  AA=x86_64 ;;
        aarch64) AA=arm64  ;;
        armv7l|armv6l) AA=arm ;;
        *) AA="" ;;
      esac
      TAG=$(curl -fsSL https://api.github.com/repos/3proxy/3proxy/releases/latest 2>/dev/null \
            | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
      [ -n "$TAG" ] || TAG=0.9.9
      if [ -n "$AA" ] && command -v dpkg >/dev/null 2>&1; then
        curl -fsSL -o /tmp/3proxy.deb \
          "https://github.com/3proxy/3proxy/releases/download/$TAG/3proxy-$TAG.$AA.deb" \
          && { apt-get install -y /tmp/3proxy.deb >/dev/null 2>&1 || dpkg -i /tmp/3proxy.deb >/dev/null 2>&1; }
        command -v 3proxy >/dev/null 2>&1 && OK=1
      fi
    fi
    [ "$OK" = "1" ] || { echo "❌ 3proxy 安装失败，请先手动 apt install 3proxy"; exit 1; }
  fi

  gen() { tr -dc 'a-z0-9' < /dev/urandom | head -c "${1:-16}"; }
  LU="loc$(gen 6)"; LP=$(gen 20); LPORT=1081
  # 用独立配置和独立服务名，避免和 outbound.sh 装的 3proxy(1080) 互相覆盖
  # ——同一台机既当主控又当出口时也能共存
  mkdir -p /etc/3proxy
  cat > /etc/3proxy/3proxy-local.cfg <<EOF
nserver 2606:4700:4700::1111
nserver 1.1.1.1
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
users $LU:CL:$LP
auth strong
allow $LU
# 只听 127.0.0.1，外部进不来；不加 -6，走本机默认出口
socks -p$LPORT -i127.0.0.1
EOF
  chmod 600 /etc/3proxy/3proxy-local.cfg
  cat > /etc/systemd/system/3proxy-local.service <<EOF
[Unit]
Description=3proxy socks5 (local outbound slot for gemini-web2api)
After=network-online.target
[Service]
ExecStart=$(command -v 3proxy) /etc/3proxy/3proxy-local.cfg
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  echo "[2/3] 启动本地 socks5 (127.0.0.1:$LPORT)"
  systemctl daemon-reload
  systemctl enable 3proxy-local >/dev/null 2>&1
  systemctl restart 3proxy-local
  sleep 2
  if ! systemctl is-active --quiet 3proxy-local; then
    echo "❌ 启动失败，日志："
    journalctl -u 3proxy-local -n 20 --no-pager 2>/dev/null || true
    exit 1
  fi
  URL="socks5h://$LU:$LP@127.0.0.1:$LPORT"
  NAME="本机出口"
  echo "[3/3] 加入代理池"
else
  # ── 加远程出口 ─────────────────────────────────────────────
  URL="$1"
  [ -n "$URL" ] || {
    echo "用法：$0 'socks5h://user:pass@[v6地址]:1080'"
    echo "     $0 --local     让主控自己也成为出口槽"
    echo "     $0 --list      查看当前池子"
    exit 1
  }
  case "$URL" in
    http://*|https://*|socks5://*|socks5h://*) ;;
    *) echo "URL 必须以 socks5h:// / socks5:// / http:// / https:// 开头"; exit 1 ;;
  esac
  NAME="${2:-出口$(date +%H%M%S)}"

  echo "先测这个代理通不通..."
  # 把 socks5h:// 转成 curl 认的形式测一下
  TESTURL=$(echo "$URL" | sed 's|^socks5h://|socks5h://|; s|^socks5://|socks5://|')
  OUT=$(curl -s --max-time 15 --proxy "$TESTURL" https://api64.ipify.org 2>/dev/null || echo "")
  if [ -z "$OUT" ]; then
    echo "⚠️ 代理测试失败（可能出口机防火墙没放行，或账号密码不对）"
    printf "仍然加入池子？[y/N] "
    read -r yn
    [ "$yn" = "y" ] || [ "$yn" = "Y" ] || { echo "已取消"; exit 1; }
  else
    echo "✅ 代理可用，出口 IP：$OUT"
  fi
fi

# ── 调 admin API 加入 ────────────────────────────────────────
RESP=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"name\":\"$NAME\",\"url\":\"$URL\",\"weight\":1}" "$API")
case "$RESP" in
  *'"id"'*) echo "✅ 已加入代理池：$NAME" ;;
  *) echo "❌ 加入失败：$RESP"; exit 1 ;;
esac

echo
list_pool
echo
echo "提示：池子里每条代理 = 一个独立 IP 槽，各自享有 并发5/RPM30/RPH80 配额。"
echo "     N 条代理 ≈ N 倍总容量。失败 5 次会自动熔断，面板可重置。"
