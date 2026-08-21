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
#   ./gw.sh uninstall       卸载主控
#
# 仓库：https://github.com/onshine/ScriptHubs/tree/main/gemini-web2api
set -e
SCRIPT_VERSION="R1.6.0"
RAWBASE="https://raw.githubusercontent.com/onshine/ScriptHubs/main/gemini-web2api"
WORK=/usr/local/share/gemini-web2api
DIR=/opt/gemini-web2api

[ "$(id -u)" = "0" ] || { echo "请用 root 运行（sudo -i 后再执行）"; exit 1; }
command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl; }

mkdir -p "$WORK"

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
      V4=$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || echo 无)
      echo "面板        : http://$V4:$PORT/admin"
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
  uninstall) do_uninstall;                exit 0  ;;
  ""|menu)   : ;;
  *) echo "未知命令: $1"; echo "可用: master outbound addproxy local check fix status uninstall"; exit 1 ;;
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
  echo "  7) 状态总览"
  echo "  8) 卸载"
  echo "  0) 退出"
  echo
  printf "选择 [0-8]: "
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
    8) do_uninstall ;;
    0) echo "再见"; exit 0 ;;
    *) echo "无效选择" ;;
  esac
done
