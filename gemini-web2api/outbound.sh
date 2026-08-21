#!/bin/sh
# gemini-web2api 出口机脚本 R1.3.0 — 装 socks5，把本机 IPv6 变成出口
# 用法：sudo ./outbound.sh
# 仓库：https://github.com/onshine/ScriptHubs/tree/main/gemini-web2api
#
# 用 dante-server（Debian/Ubuntu 官方源自带，无 glibc 依赖坑）。
set -e
SCRIPT_VERSION="R1.3.3"
PORT=1080
CFG=/etc/danted-gw.conf
SVC=danted-gw

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

# ── 1. 安装 dante-server ─────────────────────────────────────
if command -v danted >/dev/null 2>&1 || command -v sockd >/dev/null 2>&1; then
  echo "[1/5] dante 已安装，跳过"
else
  echo "[1/5] 安装 dante-server"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq || true
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y dante-server; then
      echo
      echo "❌ dante-server 安装失败。若上面报的是别的包依赖冲突（unmet dependencies），"
      echo "   说明 dpkg 里有半装的包卡住了，先执行："
      echo "     dpkg --purge --force-all <那个包名>; apt --fix-broken install -y"
      echo "   然后重跑本脚本。"
      exit 1
    fi
  elif command -v yum >/dev/null 2>&1; then
    yum install -y dante-server || { echo "❌ 安装失败"; exit 1; }
  else
    echo "❌ 不支持的发行版，请手动安装 dante-server"; exit 1
  fi
fi
BIN=$(command -v danted || command -v sockd)
[ -n "$BIN" ] || { echo "❌ 找不到 danted 可执行文件"; exit 1; }
# Debian 装完自带一个默认 danted 服务，其默认配置会启动失败，先停掉避免干扰
systemctl disable --now danted >/dev/null 2>&1 || true
echo "      使用 $BIN"

# ── 2. 探测网卡 ──────────────────────────────────────────────
echo "[2/5] 探测网络"
IFACE=$(ip -o -6 route show default 2>/dev/null | awk '{print $5}' | head -1)
[ -n "$IFACE" ] || IFACE=$(ip -o -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
[ -n "$IFACE" ] || IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')
[ -n "$IFACE" ] || { echo "❌ 找不到网卡"; exit 1; }
NV6=$(ip -6 addr show scope global 2>/dev/null | grep -c inet6 || true)
echo "      网卡 $IFACE，全局 IPv6 地址 ${NV6:-0} 个"

# ── 3. 账号密码（随机，防止变成公共代理）──────────────────────
echo "[3/5] 生成代理账号"
gen() { tr -dc 'a-z0-9' < /dev/urandom | head -c "${1:-16}"; }
USER="gw$(gen 6)"
PASS=$(gen 20)
# dante 用系统用户认证：建一个不能登录 shell 的专用用户
id "$USER" >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin "$USER"
echo "$USER:$PASS" | chpasswd

# ── 4. 配置 ──────────────────────────────────────────────────
echo "[4/5] 写配置"
# external 写网卡名 → dante 按目标地址族自动选源地址：
# 目标是 v6 就从本机 v6 出，这正是要的「IPv6 出口」。
cat > "$CFG" <<EOF
# gemini-web2api 出口 $SCRIPT_VERSION
logoutput: syslog
internal: 0.0.0.0 port = $PORT
internal: :: port = $PORT
external: $IFACE
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

cat > /etc/systemd/system/$SVC.service <<EOF
[Unit]
Description=Dante socks5 (gemini-web2api outbound)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN -f $CFG -N 1
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $SVC >/dev/null 2>&1
systemctl restart $SVC
sleep 2

# ── 5. 自检 ──────────────────────────────────────────────────
echo "[5/5] 自检"
if ! systemctl is-active --quiet $SVC; then
  echo "❌ 启动失败，最近日志："
  journalctl -u $SVC -n 25 --no-pager 2>/dev/null || true
  echo
  echo "手动排查：$BIN -f $CFG -d"
  exit 1
fi
ss -tlnH "sport = :$PORT" 2>/dev/null | awk '{print "      监听: "$4}' | sort -u

V6=$(curl -6 -s --max-time 8 https://api64.ipify.org 2>/dev/null || echo "")
V4=$(curl -4 -s --max-time 8 https://api.ipify.org 2>/dev/null || echo "")
OUT=$(curl -s --max-time 15 --proxy "socks5h://$USER:$PASS@127.0.0.1:$PORT" \
      https://api64.ipify.org 2>/dev/null || echo "")

echo
echo "=============================================================="
if [ -n "$OUT" ]; then
  echo "  ✅ 出口机就绪（代理实测可用，出口 IP: $OUT）"
else
  echo "  ⚠️ 服务已启动，但本机代理自测未通"
  echo "     排查: journalctl -u $SVC -n 30"
fi
echo "  本机 IPv6   : ${V6:-无}"
echo "  本机 IPv4   : ${V4:-无（纯 v6 机）}"
echo "--------------------------------------------------------------"
echo "  复制下面这一整行，拿到主控机用："
echo
if [ -n "$V6" ]; then
  echo "  socks5h://$USER:$PASS@[$V6]:$PORT"
else
  echo "  socks5h://$USER:$PASS@$V4:$PORT"
fi
echo
echo "  ⚠️ 密码只显示这一次，请立刻复制保存"
echo "  服务管理: systemctl status $SVC"
echo "=============================================================="
