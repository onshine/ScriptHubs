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
SCRIPT_VERSION="R1.3.0"
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
  LPORT=1081
  LCFG=/etc/danted-local.conf
  LSVC=danted-local

  if command -v danted >/dev/null 2>&1 || command -v sockd >/dev/null 2>&1; then
    echo "[1/3] dante 已安装，跳过"
  else
    echo "[1/3] 安装 dante-server"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y dante-server \
        || { echo "❌ 安装失败，请手动执行：apt install dante-server"; exit 1; }
    elif command -v yum >/dev/null 2>&1; then
      yum install -y dante-server || { echo "❌ 安装失败"; exit 1; }
    else
      echo "❌ 不支持的发行版"; exit 1
    fi
  fi
  LBIN=$(command -v danted || command -v sockd)
  [ -n "$LBIN" ] || { echo "❌ 找不到 danted"; exit 1; }
  systemctl disable --now danted >/dev/null 2>&1 || true

  IFACE=$(ip -o -6 route show default 2>/dev/null | awk '{print $5}' | head -1)
  [ -n "$IFACE" ] || IFACE=$(ip -o -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
  [ -n "$IFACE" ] || IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')

  gen() { tr -dc 'a-z0-9' < /dev/urandom | head -c "${1:-16}"; }
  LU="loc$(gen 6)"; LP=$(gen 20)
  id "$LU" >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin "$LU"
  echo "$LU:$LP" | chpasswd

  # 独立配置与服务名，和 outbound.sh 的 danted-gw(1080) 共存不冲突
  cat > "$LCFG" <<EOF
# gemini-web2api 本机出口槽
logoutput: syslog
internal: 127.0.0.1 port = $LPORT
external: $IFACE
socksmethod: username
user.privileged: root
user.unprivileged: nobody
client pass {
    from: 127.0.0.0/8 to: 0.0.0.0/0
    log: error
}
socks pass {
    from: 127.0.0.0/8 to: 0.0.0.0/0
    socksmethod: username
    log: error
}
EOF
  chmod 644 "$LCFG"
  cat > /etc/systemd/system/$LSVC.service <<EOF
[Unit]
Description=Dante socks5 (local outbound slot for gemini-web2api)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$LBIN -f $LCFG -N 1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  echo "[2/3] 启动本地 socks5 (127.0.0.1:$LPORT)"
  systemctl daemon-reload
  systemctl enable $LSVC >/dev/null 2>&1
  systemctl restart $LSVC
  sleep 2
  if ! systemctl is-active --quiet $LSVC; then
    echo "❌ 启动失败，日志："
    journalctl -u $LSVC -n 20 --no-pager 2>/dev/null || true
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
