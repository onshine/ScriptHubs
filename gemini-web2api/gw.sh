#!/bin/sh
# gemini-web2api 统一管理入口 R1.6.0
#
# 一条命令搞定所有操作，自动拉取最新子脚本（不受 CDN 缓存影响）：
#   curl -fsSL https://raw.githubusercontent.com/onshine/ScriptHubs/main/gemini-web2api/gw.sh | sh
#
# 也支持免交互：
#   ./gw.sh master          部署主控
#   ./gw.sh outbound        把本机做成出口
#   ./gw.sh addproxy <url>  加出口到代理池
#   ./gw.sh local           让主控自己也成为一个出口槽
#   ./gw.sh check           代理池体检
#   ./gw.sh fix             一键修复（禁用坏代理）
#   ./gw.sh status          状态总览
#   ./gw.sh creds           查看 Token / API Key / 面板地址
#   ./gw.sh rotate          轮换 API Key
#   ./gw.sh openport        放行防火墙端口
#   ./gw.sh clearstatic     清空「静态代理」兜底设置
#   ./gw.sh uninstall       卸载主控
#
# 仓库：https://github.com/onshine/ScriptHubs/tree/main/gemini-web2api
set -e
SCRIPT_VERSION="R1.8.1"
RAWBASE="https://raw.githubusercontent.com/onshine/ScriptHubs/main/gemini-web2api"
WORK=/usr/local/share/gemini-web2api
DIR=/opt/gemini-web2api

[ "$(id -u)" = "0" ] || { echo "请用 root 运行（sudo -i 后再执行）"; exit 1; }
command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl; }

mkdir -p "$WORK"

# 探测本机公网 IP。单一来源（如 ipify）可能被 CDN/劫持返回错误结果，
# 故多源交叉验证：取出现次数最多的那个。
pub_v4() {
  for u in https://ipv4.icanhazip.com https://api.ipify.org \
           https://ifconfig.me/ip https://checkip.amazonaws.com; do
    r=$(curl -4 -s --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')
    case "$r" in
      [0-9]*.[0-9]*.[0-9]*.[0-9]*) echo "$r" ;;
    esac
  done | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}
pub_v6() {
  for u in https://ipv6.icanhazip.com https://api64.ipify.org https://ifconfig.co; do
    r=$(curl -6 -s --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')
    case "$r" in
      *:*) echo "$r" ;;
    esac
  done | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}
# 本机网卡上的地址（最可靠，不依赖外部服务）
local_v4() { ip -4 addr show scope global 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1; }
local_v6() { ip -6 addr show scope global 2>/dev/null | sed -n 's/.*inet6 \([0-9a-fA-F:]*\)\/.*/\1/p' | grep -v '^fe80' | grep -v '^fd' | head -1; }

# 拉取子脚本（带时间戳绕开 raw CDN 缓存），返回本地路径
fetch() {
  _f="$1"
  if ! curl -fsSL -o "$WORK/$_f" "$RAWBASE/$_f?$(date +%s)$$"; then
    echo "❌ 下载 $_f 失败，检查网络或 GitHub 可达性" >&2
    return 1
  fi
  chmod +x "$WORK/$_f"
  echo "$WORK/$_f"
}

run() {  # run <脚本名> [参数...]
  _s="$1"; shift
  echo "→ 获取最新 $_s ..."
  _p=$(fetch "$_s") || return 1
  _v=$(grep -m1 'SCRIPT_VERSION=' "$_p" | sed 's/.*"\(.*\)".*/\1/')
  echo "→ 运行 $_s ($_v)"
  echo
  "$_p" "$@"
}

show_status() {
  echo "================= 状态总览 ================="
  if systemctl list-unit-files gemini-web2api.service >/dev/null 2>&1 \
     && [ -f /etc/systemd/system/gemini-web2api.service ]; then
    ACT=$(systemctl is-active gemini-web2api 2>/dev/null || echo inactive)
    echo "主控服务    : $ACT"
    if [ -f "$DIR/.credentials" ]; then
      . "$DIR/.credentials"
      [ -n "$PORT" ] || PORT=8084
      echo "端口        : $PORT"
      LS=$(ss -tlnH "sport = :$PORT" 2>/dev/null | awk '{print $4}' | head -1)
      echo "监听        : ${LS:-未监听}"
      H=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null || echo FAIL)
      case "$H" in *'"ok"'*) echo "健康检查    : ✅ ok" ;; *) echo "健康检查    : ❌ $H" ;; esac
      A=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' \
          -H "Authorization: Bearer $API_KEY" \
          "http://127.0.0.1:$PORT/v1/models" 2>/dev/null || echo 000)
      case "$A" in 200) echo "API Key     : ✅ 可用" ;; *) echo "API Key     : ❌ HTTP $A" ;; esac
      N=$(curl -s --max-time 8 -H "Authorization: Bearer $ADMIN_TOKEN" \
          "http://127.0.0.1:$PORT/admin/api/proxies" 2>/dev/null \
          | grep -o '"id"' | wc -l)
      echo "代理池      : $N 个"
      [ "$N" = "0" ] && echo "              （池空 = 走主控本机 IP 直连，正常）"
      # 静态代理是隐藏坑：池全满/熔断时会回退到它，填错会让请求失败
      SP=$(curl -s --max-time 8 -H "Authorization: Bearer $ADMIN_TOKEN" \
           "http://127.0.0.1:$PORT/admin/api/config" 2>/dev/null \
           | python3 -c 'import json,sys; print(json.load(sys.stdin).get("config",{}).get("proxy",""))' 2>/dev/null)
      if [ -n "$SP" ]; then
        echo "静态代理    : ⚠️ $SP"
        echo "              （池全满时的兜底出口；不用请执行 ./gw.sh clearstatic）"
      fi
      LV4=$(local_v4); LV6=$(local_v6)
      PV4=$(pub_v4);   PV6=$(pub_v6)
      echo "-------------------------------------------"
      echo "Admin Token : $ADMIN_TOKEN"
      echo "API Key     : $API_KEY"
      echo "-------------------------------------------"
      echo "网卡 IPv4   : ${LV4:-无}"
      echo "网卡 IPv6   : ${LV6:-无}"
      [ -n "$PV4" ] && [ "$PV4" != "$LV4" ] && \
        echo "公网 IPv4   : $PV4  (与网卡不同 = NAT 或探测被劫持)"
      echo "-------------------------------------------"
      # 客户端该用哪个地址：优先网卡上的真实地址
      UV4="${LV4:-$PV4}"; UV6="${LV6:-$PV6}"
      if [ -n "$UV4" ]; then
        echo "API 地址    : http://$UV4:$PORT/v1"
        echo "管理面板    : http://$UV4:$PORT/admin"
      fi
      if [ -n "$UV6" ]; then
        echo "API (IPv6)  : http://[$UV6]:$PORT/v1"
      fi
      echo "-------------------------------------------"
      # 外部可达性：从本机走公网地址回连自己，能通才说明客户端也能连
      if [ -n "$UV4" ]; then
        EC=$(curl -4 -s --max-time 8 -o /dev/null -w '%{http_code}' \
             "http://$UV4:$PORT/" 2>/dev/null || echo 000)
        case "$EC" in
          200) echo "外部可达(v4): ✅ 通" ;;
          000) echo "外部可达(v4): ❌ 不通 — 防火墙/安全组未放行 $PORT" ;;
          *)   echo "外部可达(v4): ⚠️ HTTP $EC" ;;
        esac
      fi
      if [ -n "$UV6" ]; then
        EC6=$(curl -6 -s --max-time 8 -o /dev/null -w '%{http_code}' \
              "http://[$UV6]:$PORT/" 2>/dev/null || echo 000)
        case "$EC6" in
          200) echo "外部可达(v6): ✅ 通" ;;
          000) echo "外部可达(v6): ❌ 不通" ;;
          *)   echo "外部可达(v6): ⚠️ HTTP $EC6" ;;
        esac
      fi
    else
      echo "凭据文件    : ❌ 缺失"
    fi
  else
    echo "主控服务    : 未安装"
  fi
  for s in danted-gw danted-local; do
    if [ -f /etc/systemd/system/$s.service ]; then
      echo "出口服务    : $s = $(systemctl is-active $s 2>/dev/null || echo inactive)"
    fi
  done
  echo "==========================================="
}

show_creds() {
  if [ ! -f "$DIR/.credentials" ]; then
    # 凭据文件丢了就从 systemd 单元恢复
    U=/etc/systemd/system/gemini-web2api.service
    if [ -f "$U" ] && grep -q '^Environment=ADMIN_TOKEN=' "$U"; then
      echo "（.credentials 缺失，从 systemd 单元恢复）"
      sed -n 's/^Environment=//p' "$U" > "$DIR/.credentials"
      echo "PORT=$(sed -n 's/.*--port \([0-9]*\).*/\1/p' "$U" | head -1)" >> "$DIR/.credentials"
      chmod 600 "$DIR/.credentials"
    else
      echo "❌ 找不到凭据，主控可能未安装"; return 1
    fi
  fi
  . "$DIR/.credentials"
  [ -n "$PORT" ] || PORT=8084
  V4=$(local_v4); [ -n "$V4" ] || V4=$(pub_v4)
  V6=$(local_v6); [ -n "$V6" ] || V6=$(pub_v6)
  echo "================= 凭据 ================="
  echo "Admin Token : $ADMIN_TOKEN"
  echo "API Key     : $API_KEY"
  echo "端口        : $PORT"
  echo "----------------------------------------"
  [ -n "$V4" ] && { echo "面板 : http://$V4:$PORT/admin"; echo "API  : http://$V4:$PORT/v1"; }
  [ -n "$V6" ] && { echo "面板 : http://[$V6]:$PORT/admin"; echo "API  : http://[$V6]:$PORT/v1"; }
  echo "----------------------------------------"
  echo "客户端填法: Base URL 用上面 API 地址，API Key 用上面那个"
  echo "文件位置  : $DIR/.credentials"
  echo "========================================"
}

rotate_key() {
  [ -f "$DIR/.credentials" ] || { echo "❌ 主控未安装"; return 1; }
  . "$DIR/.credentials"
  [ -n "$PORT" ] || PORT=8084
  echo "⚠️ 轮换后所有客户端都要改配置。"
  printf "确认轮换 API Key？[y/N] "
  read -r yn
  [ "$yn" = "y" ] || [ "$yn" = "Y" ] || { echo "已取消"; return 0; }
  NEW="sk-gemini-$(tr -dc 'a-f0-9' < /dev/urandom | head -c 40)"
  # API_KEY 由环境变量锁定，需改 systemd 单元后重启
  U=/etc/systemd/system/gemini-web2api.service
  sed -i "s|^Environment=API_KEY=.*|Environment=API_KEY=$NEW|" "$U"
  sed -i "s|^API_KEY=.*|API_KEY=$NEW|" "$DIR/.credentials"
  systemctl daemon-reload
  systemctl restart gemini-web2api
  sleep 3
  C=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $NEW" "http://127.0.0.1:$PORT/v1/models" 2>/dev/null || echo 000)
  echo
  if [ "$C" = "200" ]; then
    echo "✅ 轮换成功，新 API Key："
    echo "   $NEW"
  else
    echo "⚠️ 轮换后自测返回 HTTP $C，检查: journalctl -u gemini-web2api -n 20"
    echo "   新 Key: $NEW"
  fi
}

open_port() {
  [ -f "$DIR/.credentials" ] || { echo "❌ 主控未安装"; return 1; }
  . "$DIR/.credentials"; [ -n "$PORT" ] || PORT=8084
  echo "放行端口 $PORT ..."
  DONE=0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    ufw allow "$PORT"/tcp >/dev/null 2>&1 && { echo "  ✅ ufw 已放行"; DONE=1; }
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && { echo "  ✅ firewalld 已放行"; DONE=1; }
  fi
  # iptables 直接插规则（很多小鸡是裸 iptables）
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
    echo "  ✅ iptables 已插入 ACCEPT 规则"
    DONE=1
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null \
      || ip6tables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
    echo "  ✅ ip6tables 已插入 ACCEPT 规则"
  fi
  [ "$DONE" = "1" ] || echo "  ⚠️ 未检测到防火墙工具，可能本来就没拦"
  echo
  echo "⚠️ 若你的 VPS 商家有面板级安全组（Oracle/AWS/GCP/阿里云等），"
  echo "   还需去商家控制台放行 TCP $PORT，系统内放行不够。"
  echo
  V4=$(local_v4); [ -n "$V4" ] || V4=$(pub_v4)
  if [ -n "$V4" ]; then
    C=$(curl -4 -s --max-time 8 -o /dev/null -w '%{http_code}' "http://$V4:$PORT/" 2>/dev/null || echo 000)
    case "$C" in
      200) echo "自测 http://$V4:$PORT/ → ✅ 可达" ;;
      *)   echo "自测 http://$V4:$PORT/ → ❌ 仍不可达 (HTTP $C)，检查商家安全组" ;;
    esac
  fi
}

clear_static() {
  [ -f "$DIR/.credentials" ] || { echo "❌ 主控未安装"; return 1; }
  . "$DIR/.credentials"; [ -n "$PORT" ] || PORT=8084
  B="http://127.0.0.1:$PORT"; A="Authorization: Bearer $ADMIN_TOKEN"
  command -v python3 >/dev/null 2>&1 || { echo "需要 python3"; return 1; }

  echo "检查「静态代理」设置..."
  echo "（它是代理池全满/全熔断时的兜底出口。填了坏地址会导致请求失败，"
  echo "  且面板请求记录的出口列会误显示为「直连」）"
  echo
  CUR=$(curl -s --max-time 10 -H "$A" "$B/admin/api/config" 2>/dev/null)
  [ -n "$CUR" ] || { echo "❌ 读取配置失败"; return 1; }
  VAL=$(printf '%s' "$CUR" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("config",{}).get("proxy",""))' 2>/dev/null)
  if [ -z "$VAL" ]; then
    echo "✅ 静态代理已是空的，无需处理"
    return 0
  fi
  echo "当前值: $VAL"
  printf "清空它？[y/N] "
  read -r yn
  [ "$yn" = "y" ] || [ "$yn" = "Y" ] || { echo "已取消"; return 0; }

  # PUT 是整体替换，必须先读全量配置再只改 proxy 一项
  printf '%s' "$CUR" | python3 -c '
import json,sys
c=json.load(sys.stdin).get("config",{})
c["proxy"]=""
json.dump(c,sys.stdout)' > /tmp/gw_cfg.json 2>/dev/null
  curl -s --max-time 10 -X PUT -H "$A" -H "Content-Type: application/json" \
    -d @/tmp/gw_cfg.json "$B/admin/api/config" 2>/dev/null \
  | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("❌ 响应解析失败"); sys.exit()
print("✅ 已清空静态代理" if d.get("ok") else "❌ 失败: "+json.dumps(d,ensure_ascii=False))'
  rm -f /tmp/gw_cfg.json
}

do_uninstall() {
  printf "确认卸载主控？数据库和凭据都会删除 [y/N] "
  read -r yn
  [ "$yn" = "y" ] || [ "$yn" = "Y" ] || { echo "已取消"; return 0; }
  systemctl disable --now gemini-web2api >/dev/null 2>&1 || true
  pkill -f "$DIR/gemini-web2api" >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/gemini-web2api.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
  rm -rf "$DIR"
  userdel gemini >/dev/null 2>&1 || true
  echo "✅ 主控已卸载"
  printf "同时卸载本机的出口服务(socks5)？[y/N] "
  read -r yn2
  if [ "$yn2" = "y" ] || [ "$yn2" = "Y" ]; then
    for s in danted-gw danted-local; do
      systemctl disable --now $s >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/$s.service
    done
    rm -f /etc/danted-gw.conf /etc/danted-local.conf
    systemctl daemon-reload >/dev/null 2>&1 || true
    echo "✅ 出口服务已卸载"
  fi
}

# ── 免交互子命令 ─────────────────────────────────────────────
case "$1" in
  master)    shift; run install.sh "$@";  exit $? ;;
  outbound)  shift; run outbound.sh "$@"; exit $? ;;
  addproxy)  shift; run addproxy.sh "$@"; exit $? ;;
  local)     run addproxy.sh --local;     exit $? ;;
  check)     run checkproxy.sh;           exit $? ;;
  fix)       run checkproxy.sh --disable; exit $? ;;
  status)    show_status;                 exit 0  ;;
  creds|token) show_creds;                exit $? ;;
  rotate)    rotate_key;                  exit $? ;;
  openport|firewall) open_port;           exit $? ;;
  clearstatic|nostatic) clear_static;     exit $? ;;
  uninstall) do_uninstall;                exit 0  ;;
  ""|menu)   : ;;
  *) echo "未知命令: $1"
     echo "可用: master outbound addproxy local check fix status creds rotate openport clearstatic uninstall"; exit 1 ;;
esac

# ── 交互菜单 ─────────────────────────────────────────────────
while :; do
  echo
  echo "╔══════════════════════════════════════════╗"
  echo "║   gemini-web2api 管理面板  $SCRIPT_VERSION      ║"
  echo "╚══════════════════════════════════════════╝"
  echo "  1) 部署主控（提供 OpenAI 兼容 API）"
  echo "  2) 把本机做成出口（装 socks5）"
  echo "  3) 加一个出口到代理池"
  echo "  4) 让主控自己也成为出口槽"
  echo "  5) 代理池体检"
  echo "  6) 一键修复（禁用被封的代理）"
  echo "  7) 状态总览（含 Token / API Key / 面板地址）"
  echo "  8) 查看凭据（Token / API Key）"
  echo "  9) 轮换 API Key"
  echo " 10) 放行防火墙端口（客户端连不上时用）"
  echo " 11) 清空「静态代理」兜底设置"
  echo " 12) 卸载"
  echo "  0) 退出"
  echo
  printf "选择 [0-12]: "
  read -r c
  echo
  case "$c" in
    1) run install.sh || true ;;
    2) run outbound.sh || true ;;
    3) printf "粘贴出口机给的 socks5 地址：\n> "
       read -r u
       [ -n "$u" ] && { printf "起个名字（回车用默认）：\n> "; read -r nm; run addproxy.sh "$u" "$nm" || true; } \
                   || echo "地址为空，已取消" ;;
    4) run addproxy.sh --local || true ;;
    5) run checkproxy.sh || true ;;
    6) run checkproxy.sh --disable || true ;;
    7) show_status ;;
    8) show_creds ;;
    9) rotate_key ;;
    10) open_port ;;
    11) clear_static ;;
    12) do_uninstall ;;
    0) echo "再见"; exit 0 ;;
    *) echo "无效选择" ;;
  esac
done
