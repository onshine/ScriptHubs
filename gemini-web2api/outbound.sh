#!/bin/sh
# gemini-web2api 出口机脚本 R1.3.0 — 装 socks5，把本机 IPv6 变成出口
# 用法：sudo ./outbound.sh
# 仓库：https://github.com/onshine/ScriptHubs/tree/main/gemini-web2api
#
# 用 dante-server（Debian/Ubuntu 官方源自带，无 glibc 依赖坑）。
set -e
SCRIPT_VERSION="R1.8.0"
RAWBASE="https://raw.githubusercontent.com/onshine/ScriptHubs/main/gemini-web2api"
PORT=1080
CFG=/etc/danted-gw.conf
SVC=danted-gw

# --force-v6：强制绑定 IPv6 出口（默认交由系统选路，更稳）
FORCE_V6=0
for a in "$@"; do
  [ "$a" = "--force-v6" ] && FORCE_V6=1
done

[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }
echo "=== 出口机部署 $SCRIPT_VERSION ==="

command -v curl >/dev/null 2>&1 || { apt-get update && apt-get install -y curl; }

# ── 0. 自愈：清掉早期版本装坏的 3proxy ───────────────────────
# R1.2.0 曾尝试装官方 3proxy deb，它要 glibc>=2.38 而 Debian 12 只有 2.36，
# 结果 dpkg 停在"已解包未配置"状态，会卡住后续所有 apt 安装。
if command -v dpkg >/dev/null 2>&1; then
  BROKEN=$(dpkg -l 3proxy 2>/dev/null | awk '/^[a-z]{1,2}[A-Z]/{print $2}' | head -1)
  if [ -n "$BROKEN" ]; then
    echo "[0/5] 检测到残留的损坏 3proxy，清理中"
    systemctl disable --now 3proxy >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/3proxy.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    dpkg --purge --force-all 3proxy >/dev/null 2>&1 || true
    apt-get --fix-broken install -y >/dev/null 2>&1 || true
    echo "      已清理"
  fi
fi

# ── 1. 安装 socks5 服务端 ────────────────────────────────────
# 优先 dante-server（源里有就用）；没有则编译 microsocks
# （极简 socks5，只依赖 gcc，支持 -b 绑定出口 IP）
ENGINE=""
if command -v danted >/dev/null 2>&1 || command -v sockd >/dev/null 2>&1; then
  ENGINE=dante; echo "[1/5] dante 已安装"
elif command -v microsocks >/dev/null 2>&1; then
  ENGINE=microsocks; echo "[1/5] microsocks 已安装"
else
  echo "[1/5] 安装 socks5 服务端"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq || true
    if DEBIAN_FRONTEND=noninteractive apt-get install -y dante-server >/dev/null 2>&1; then
      ENGINE=dante; echo "      ✅ dante-server (apt)"
    fi
  elif command -v yum >/dev/null 2>&1; then
    yum install -y dante-server >/dev/null 2>&1 && ENGINE=dante
  fi
  # 回退：编译 microsocks
  if [ -z "$ENGINE" ]; then
    echo "      源里没有 dante，改为编译 microsocks"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get install -y gcc make libc6-dev >/dev/null 2>&1 || \
        apt-get install -y build-essential >/dev/null 2>&1
    else
      yum install -y gcc make >/dev/null 2>&1 || \
        yum groupinstall -y "Development Tools" >/dev/null 2>&1
    fi
    command -v gcc >/dev/null 2>&1 || { echo "❌ 装不上 gcc，无法继续"; exit 1; }
    MTAG=$(curl -fsSL https://api.github.com/repos/rofl0r/microsocks/releases/latest 2>/dev/null \
           | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$MTAG" ] || MTAG=v1.0.5
    rm -rf /tmp/microsocks && mkdir -p /tmp/microsocks
    curl -fsSL "https://github.com/rofl0r/microsocks/archive/refs/tags/$MTAG.tar.gz" \
      -o /tmp/ms.tar.gz || { echo "❌ 下载 microsocks 源码失败"; exit 1; }
    tar xzf /tmp/ms.tar.gz -C /tmp/microsocks --strip-components=1 || { echo "❌ 解包失败"; exit 1; }
    ( cd /tmp/microsocks && make >/dev/null 2>&1 && install -m755 microsocks /usr/local/bin/microsocks ) \
      || { echo "❌ 编译失败"; exit 1; }
    command -v microsocks >/dev/null 2>&1 || { echo "❌ microsocks 安装失败"; exit 1; }
    ENGINE=microsocks; echo "      ✅ microsocks $MTAG (源码编译)"
  fi
fi
# Debian 装完自带一个空配置 danted 服务会反复失败，停掉避免干扰
systemctl disable --now danted >/dev/null 2>&1 || true

# ── 2. 探测网络 ──────────────────────────────────────────────
echo "[2/5] 探测网络"
IFACE=$(ip -o -6 route show default 2>/dev/null | awk '{print $5}' | head -1)
[ -n "$IFACE" ] || IFACE=$(ip -o -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
[ -n "$IFACE" ] || IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')
[ -n "$IFACE" ] || { echo "❌ 找不到网卡"; exit 1; }
# 探测出口地址族并实测 Google 可达性。
# 实测结论：Google 对机房 IPv6 段封锁远严于 IPv4——v6 常见 302→/sorry/
# 或 BardErrorInfo[1060]（连上但拒绝生成）。所以默认优先 IPv4 出口。
# 另注意 microsocks 未设 -b 时 addr_choose 直接取 getaddrinfo 首项，
# glibc 双栈默认 v6 在前，会无条件走 v6 且不回退 v4 → network unreachable。
BINDV6=$(ip -6 addr show scope global 2>/dev/null \
         | sed -n 's/.*inet6 \([0-9a-fA-F:]*\)\/.*/\1/p' \
         | grep -v '^fe80' | grep -v '^fd' | head -1)
BINDV4=$(ip -4 addr show scope global 2>/dev/null \
         | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1)

probe() {  # $1=-4|-6 → 打印 HTTP 状态码，被风控则打印 SORRY
  _h=$(curl "$1" -s -i --max-time 10 https://gemini.google.com/ 2>/dev/null | head -12 || echo "")
  _c=$(printf '%s' "$_h" | sed -n 's|^HTTP/[0-9.]* \([0-9]*\).*|\1|p' | head -1)
  _l=$(printf '%s' "$_h" | sed -n 's/^[Ll]ocation: *//p' | head -1)
  case "$_l" in *sorry*|*captcha*) echo SORRY; return;; esac
  echo "${_c:-000}"
}

V4OK=0; V6OK=0
if [ -n "$BINDV4" ]; then
  R4=$(probe -4); [ "$R4" = "200" ] && V4OK=1
  echo "      IPv4 $BINDV4 → Google: $R4"
fi
if [ -n "$BINDV6" ]; then
  R6=$(probe -6); [ "$R6" = "200" ] && V6OK=1
  echo "      IPv6 $BINDV6 → Google: $R6"
fi

# 选出口：默认优先可用的 IPv4；--force-v6 才在 v6 可用时强制走 v6
BINDADDR=""; FAMILY=""
if [ "$FORCE_V6" = "1" ] && [ "$V6OK" = "1" ]; then
  BINDADDR="$BINDV6"; FAMILY=IPv6
elif [ "$V4OK" = "1" ]; then
  BINDADDR="$BINDV4"; FAMILY=IPv4
elif [ "$V6OK" = "1" ]; then
  BINDADDR="$BINDV6"; FAMILY=IPv6
fi

if [ -n "$BINDADDR" ]; then
  echo "      ✅ 选定出口: $FAMILY $BINDADDR"
else
  echo "      ⚠️ 两个地址族都无法正常访问 Google（可能该机 IP 已被风控）"
  echo "         仍会部署，但加进主控代理池后请求会失败。"
  # 有 v4 就默认绑 v4，避免 microsocks 无条件走不通的 v6
  BINDADDR="${BINDV4:-$BINDV6}"
  [ -n "$BINDV4" ] && FAMILY=IPv4 || FAMILY=IPv6
fi

# ── 3. 账号密码（随机，防止变成公共代理）──────────────────────
echo "[3/5] 生成代理账号"
gen() { tr -dc 'a-z0-9' < /dev/urandom | head -c "${1:-16}"; }
USER="gw$(gen 6)"
PASS=$(gen 20)

# ── 4. 配置并启动 ────────────────────────────────────────────
echo "[4/5] 配置并启动 ($ENGINE)"
if [ "$ENGINE" = "dante" ]; then
  BIN=$(command -v danted || command -v sockd)
  # dante 用系统用户认证
  id "$USER" >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin "$USER"
  echo "$USER:$PASS" | chpasswd
  # external 指定 v6 地址 → 出站强制从该 v6 发起；无 v6 时退回网卡名
  EXT="${BINDADDR:-$IFACE}"
  cat > "$CFG" <<EOF
# gemini-web2api 出口 $SCRIPT_VERSION
logoutput: syslog
internal: 0.0.0.0 port = $PORT
internal: :: port = $PORT
external: $EXT
socksmethod: username
user.privileged: root
user.unprivileged: nobody
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
client pass {
    from: ::/0 to: ::/0
    log: error
}
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    socksmethod: username
    log: error
}
socks pass {
    from: ::/0 to: ::/0
    socksmethod: username
    log: error
}
EOF
  chmod 644 "$CFG"
  EXECLINE="$BIN -f $CFG -N 1"
else
  # microsocks：-b 绑定出口地址，-i 监听地址
  BIN=$(command -v microsocks)
  # 必须显式 -b：未绑定时 addr_choose 取 getaddrinfo 首项（glibc 双栈 v6 优先），
  # 会无条件走 v6 且不回退 v4，v6 不通即 network unreachable。
  if [ -n "$BINDADDR" ]; then
    EXECLINE="$BIN -i :: -p $PORT -u $USER -P $PASS -b $BINDADDR"
  else
    EXECLINE="$BIN -i :: -p $PORT -u $USER -P $PASS"
  fi
fi

cat > /etc/systemd/system/$SVC.service <<EOF
[Unit]
Description=socks5 outbound for gemini-web2api ($ENGINE)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$EXECLINE
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
chmod 600 /etc/systemd/system/$SVC.service   # microsocks 密码在命令行，锁权限

systemctl daemon-reload
systemctl enable $SVC >/dev/null 2>&1
systemctl restart $SVC
sleep 2

# ── 5. 自检 ──────────────────────────────────────────────────
echo "[5/5] 自检"
if ! systemctl is-active --quiet $SVC; then
  echo "❌ 启动失败，最近日志："
  journalctl -u $SVC -n 25 --no-pager 2>/dev/null | sed 's/^/     /'
  echo
  echo "手动排查：$EXECLINE"
  exit 1
fi
ss -tlnH "sport = :$PORT" 2>/dev/null | awk '{print "      监听: "$4}' | sort -u

V6=$(curl -6 -s --max-time 8 https://api64.ipify.org 2>/dev/null || echo "")
V4=$(curl -4 -s --max-time 8 https://api.ipify.org 2>/dev/null || echo "")
# 通过自己的代理测出口 IP，确认认证与转发都正常
OUT=$(curl -s --max-time 15 --proxy "socks5h://$USER:$PASS@127.0.0.1:$PORT" \
      https://api64.ipify.org 2>/dev/null || echo "")

echo
echo "=============================================================="
if [ -n "$OUT" ]; then
  case "$OUT" in
    *:*) echo "  ✅ 出口机就绪 — 走 IPv6 出口: $OUT" ;;
    *)   echo "  ✅ 出口机就绪 — 走 IPv4 出口: $OUT"
         [ -n "$BINDV6" ] && echo "     ⚠️ 本机有 v6 但出口是 v4，检查 v6 出网: curl -6 https://api64.ipify.org" ;;
  esac
else
  echo "  ⚠️ 服务已启动，但本机代理自测未通"
  echo "     排查: journalctl -u $SVC -n 30"
fi
echo "  引擎        : $ENGINE"
echo "  选定出口    : ${FAMILY:-自动} ${BINDADDR:-}"
echo "  本机 IPv6   : ${V6:-无}"
echo "  本机 IPv4   : ${V4:-无}"
echo "--------------------------------------------------------------"
echo "  复制下面这一整行，拿到主控机用："
echo
if [ -n "$V4" ]; then
  echo "  socks5h://$USER:$PASS@$V4:$PORT"
  [ -n "$V6" ] && { echo; echo "  主控走 IPv6 连本机可用这个（入口 v6，出口仍是上面选定的）："; \
                    echo "  socks5h://$USER:$PASS@[$V6]:$PORT"; }
else
  echo "  socks5h://$USER:$PASS@[$V6]:$PORT"
fi
echo
echo "  ⚠️ 密码只显示这一次，请立刻复制保存"
echo "  服务管理: systemctl status $SVC"
echo "=============================================================="
