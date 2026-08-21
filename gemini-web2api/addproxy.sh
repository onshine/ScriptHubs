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
SCRIPT_VERSION="R1.8.0"
RAWBASE="https://raw.githubusercontent.com/onshine/ScriptHubs/main/gemini-web2api"
DIR="/opt/gemini-web2api"

[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }
# 凭据缺失时，尝试从 systemd 单元文件恢复（早期版本可能没落盘）
if [ ! -f "$DIR/.credentials" ]; then
  UNIT=/etc/systemd/system/gemini-web2api.service
  if [ -f "$UNIT" ] && grep -q '^Environment=ADMIN_TOKEN=' "$UNIT"; then
    echo "未找到 .credentials，从 systemd 单元恢复"
    sed -n 's/^Environment=//p' "$UNIT" > "$DIR/.credentials"
    grep -q '^PORT=' "$DIR/.credentials" || \
      echo "PORT=$(sed -n 's/.*--port \([0-9]*\).*/\1/p' "$UNIT" | head -1)" >> "$DIR/.credentials"
    chmod 600 "$DIR/.credentials"
  else
    echo "找不到 $DIR/.credentials，请先跑 install.sh"; exit 1
  fi
fi
. "$DIR/.credentials"
[ -n "$PORT" ] || PORT=8084
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
  LPORT=1081
  LCFG=/etc/danted-local.conf
  LSVC=danted-local

  LENGINE=""
  if command -v danted >/dev/null 2>&1 || command -v sockd >/dev/null 2>&1; then
    LENGINE=dante; echo "[1/3] dante 已安装"
  elif command -v microsocks >/dev/null 2>&1; then
    LENGINE=microsocks; echo "[1/3] microsocks 已安装"
  else
    echo "[1/3] 安装 socks5 服务端"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y dante-server >/dev/null 2>&1 && LENGINE=dante
    elif command -v yum >/dev/null 2>&1; then
      yum install -y dante-server >/dev/null 2>&1 && LENGINE=dante
    fi
    if [ -z "$LENGINE" ]; then
      echo "      源里没有 dante，编译 microsocks"
      if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y gcc make libc6-dev >/dev/null 2>&1 || apt-get install -y build-essential >/dev/null 2>&1
      else
        yum install -y gcc make >/dev/null 2>&1
      fi
      command -v gcc >/dev/null 2>&1 || {
        echo "❌ 装不上 gcc。请先确认本脚本是最新版："
        echo "   curl -fL -o addproxy.sh \"$RAWBASE/addproxy.sh?\$(date +%s)\""
        exit 1; }
      MTAG=$(curl -fsSL https://api.github.com/repos/rofl0r/microsocks/releases/latest 2>/dev/null \
             | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
      [ -n "$MTAG" ] || MTAG=v1.0.5
      rm -rf /tmp/microsocks && mkdir -p /tmp/microsocks
      curl -fsSL "https://github.com/rofl0r/microsocks/archive/refs/tags/$MTAG.tar.gz" -o /tmp/ms.tar.gz \
        && tar xzf /tmp/ms.tar.gz -C /tmp/microsocks --strip-components=1 \
        && ( cd /tmp/microsocks && make >/dev/null 2>&1 && install -m755 microsocks /usr/local/bin/microsocks ) \
        || { echo "❌ microsocks 安装失败"; exit 1; }
      LENGINE=microsocks; echo "      ✅ microsocks $MTAG"
    fi
  fi
  systemctl disable --now danted >/dev/null 2>&1 || true

  IFACE=$(ip -o -6 route show default 2>/dev/null | awk '{print $5}' | head -1)
  [ -n "$IFACE" ] || IFACE=$(ip -o -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
  [ -n "$IFACE" ] || IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')

  gen() { tr -dc 'a-z0-9' < /dev/urandom | head -c "${1:-16}"; }
  LU="loc$(gen 6)"; LP=$(gen 20)
  id "$LU" >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin "$LU"
  echo "$LU:$LP" | chpasswd

  # 独立配置与服务名，和 outbound.sh 的出口服务(1080)共存不冲突
  if [ "$LENGINE" = "dante" ]; then
    LBIN=$(command -v danted || command -v sockd)
    id "$LU" >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin "$LU"
    echo "$LU:$LP" | chpasswd
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
    LEXEC="$LBIN -f $LCFG -N 1"
  else
    LBIN=$(command -v microsocks)
    LEXEC="$LBIN -i 127.0.0.1 -p $LPORT -u $LU -P $LP"
  fi

  cat > /etc/systemd/system/$LSVC.service <<EOF
[Unit]
Description=socks5 local outbound slot for gemini-web2api ($LENGINE)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$LEXEC
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  chmod 600 /etc/systemd/system/$LSVC.service
  echo "[2/3] 启动本地 socks5 (127.0.0.1:$LPORT)"
  systemctl daemon-reload
  systemctl enable $LSVC >/dev/null 2>&1
  systemctl restart $LSVC
  sleep 2
  if ! systemctl is-active --quiet $LSVC; then
    echo "❌ 启动失败，日志："
    journalctl -u $LSVC -n 20 --no-pager 2>/dev/null | sed 's/^/     /'
    exit 1
  fi
  echo "[3/3] 加入代理池"
  URL="socks5h://$LU:$LP@127.0.0.1:$LPORT"
  NAME="本机出口"
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

  # 只做最基本的可达性预检（能否建立 socks 连接）。
  # 真正的判据在加入池子之后用上游 /admin/api/test 做真实生成请求——
  # 「能打开 Gemini 首页」不等于「能完成 StreamGenerate」。
  echo "预检 socks 连通性..."
  OUT=$(curl -s --max-time 15 --proxy "$URL" https://api64.ipify.org 2>/dev/null || echo "")
  if [ -z "$OUT" ]; then
    echo "⚠️ 代理不可达（出口机服务未启动 / 账号密码错 / 端口未放行）"
    printf "仍然加入池子？[y/N] "
    read -r yn
    [ "$yn" = "y" ] || [ "$yn" = "Y" ] || { echo "已取消"; exit 1; }
  else
    echo "   出口 IP: $OUT"
  fi
fi

# ── 调 admin API 加入 ────────────────────────────────────────
RESP=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"name\":\"$NAME\",\"url\":\"$URL\",\"weight\":1}" "$API")
NEWID=""
case "$RESP" in
  *'"id"'*)
    NEWID=$(printf '%s' "$RESP" | sed -n 's/.*"id" *: *\([0-9]*\).*/\1/p' | head -1)
    echo "✅ 已加入代理池：$NAME (#$NEWID)" ;;
  *) echo "❌ 加入失败：$RESP"; exit 1 ;;
esac

# 用上游 /admin/api/test 做真实生成请求验证（与面板「连通性诊断」同源）
if [ -n "$NEWID" ] && command -v python3 >/dev/null 2>&1; then
  echo
  echo "真实调用验证（Chrome146 指纹 + StreamGenerate，不消耗配额）..."
  R=$(curl -s --max-time 90 -H "$AUTH" \
      "http://127.0.0.1:$PORT/admin/api/test?proxy_id=$NEWID" 2>/dev/null \
      | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("parse_error|0||"); sys.exit()
print("%s|%s|%s|%s" % (d.get("status","?"), d.get("total_ms",0),
      (d.get("response_text") or "").replace("\n"," ")[:40],
      (d.get("diagnostic") or "").replace("\n"," ")[:100]))
' || echo "probe_failed|0||")
  ST=$(printf '%s' "$R" | cut -d'|' -f1)
  MS=$(printf '%s' "$R" | cut -d'|' -f2)
  TX=$(printf '%s' "$R" | cut -d'|' -f3)
  DG=$(printf '%s' "$R" | cut -d'|' -f4)
  case "$ST" in
    success)       echo "  ✅ 真实调用成功 (${MS}ms) 回复: $TX" ;;
    blocked_sorry) echo "  🚫 该出口 IP 已被 Google 风控（302→/sorry/），建议禁用或换 IP" ;;
    rate_limited)  echo "  ⏳ 该出口限流中，稍后会恢复" ;;
    network_error) echo "  ❌ 网络不可达: $DG" ;;
    *)             echo "  ⚠️ 状态=$ST  $DG" ;;
  esac
fi

echo
list_pool
echo
echo "提示：池子里每条代理 = 一个独立 IP 槽，各自享有 并发5/RPM30/RPH80 配额。"
echo "     N 条代理 ≈ N 倍总容量。失败 5 次会自动熔断，面板可重置。"
