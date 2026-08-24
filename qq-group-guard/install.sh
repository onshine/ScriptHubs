#!/bin/sh
# qq-group-guard 一键安装 / 管理入口 R1.0.0
#
# 一条命令搞定所有操作：
#   curl -fsSL https://raw.githubusercontent.com/onshine/ScriptHubs/main/qq-group-guard/install.sh | sh
#
# 也支持免交互子命令：
#   ./install.sh install          安装 + 交互式生成配置 + 装 systemd timer
#   ./install.sh install --quiet  安装但不交互（用环境变量 QGG_* 提供参数）
#   ./install.sh config           重新编辑配置
#   ./install.sh test             以 report 模式试跑一次（绝不踢人）
#   ./install.sh run              立即执行一次（按配置的 mode）
#   ./install.sh mode <m>         切换 report / lenient / strict
#   ./install.sh timer <cron>     修改定时周期（如 "0 */6 * * *"）
#   ./install.sh status           查看状态、下次运行时间、观察期名单
#   ./install.sh logs             查看最近日志
#   ./install.sh pending          查看/清空观察期记录
#   ./install.sh update           升级脚本本体（保留配置）
#   ./install.sh uninstall        卸载（默认保留配置与数据）
#
# 仓库：https://github.com/onshine/ScriptHubs/tree/main/qq-group-guard
set -e
SCRIPT_VERSION="R1.0.0"
RAWBASE="https://raw.githubusercontent.com/onshine/ScriptHubs/main/qq-group-guard"

DIR=/opt/qq-group-guard
CONF_DIR=/etc/qq-group-guard
CONF=$CONF_DIR/config.json
STATE_DIR=/var/lib/qq-group-guard
LOG_DIR=/var/log/qq-group-guard
BIN=/usr/local/bin/qq-group-guard
SVC=qq-group-guard

C_G='\033[32m'; C_Y='\033[33m'; C_R='\033[31m'; C_B='\033[36m'; C_0='\033[0m'
ok()   { printf "${C_G}✔${C_0} %s\n" "$1"; }
warn() { printf "${C_Y}!${C_0} %s\n" "$1"; }
err()  { printf "${C_R}✘${C_0} %s\n" "$1" >&2; }
info() { printf "${C_B}·${C_0} %s\n" "$1"; }
line() { printf '%s\n' "----------------------------------------------------------------"; }

[ "$(id -u)" = "0" ] || { err "请用 root 运行（sudo -i 后再执行）"; exit 1; }

# ── 依赖 ─────────────────────────────────────────────────────
PKG=""
if   command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
elif command -v yum     >/dev/null 2>&1; then PKG=yum
elif command -v apk     >/dev/null 2>&1; then PKG=apk
fi

pkg_install() {
  case "$PKG" in
    apt) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
    dnf) dnf install -y -q "$@" ;;
    yum) yum install -y -q "$@" ;;
    apk) apk add --no-cache -q "$@" ;;
    *)   err "未识别的包管理器，请手动安装：$*"; return 1 ;;
  esac
}

ensure_deps() {
  command -v curl    >/dev/null 2>&1 || pkg_install curl
  command -v python3 >/dev/null 2>&1 || pkg_install python3
  command -v python3 >/dev/null 2>&1 || { err "python3 安装失败，请手动安装后重试"; exit 1; }
  # 脚本只用标准库，无需 pip 依赖
  ok "依赖就绪（python3 $(python3 -c 'import sys;print(".".join(map(str,sys.version_info[:3])))'))"
}

# ── 下载脚本本体（带时间戳绕开 raw CDN 5 分钟缓存）───────────
fetch_main() {
  mkdir -p "$DIR"
  # 若与本脚本同目录已有本体（git clone 场景），优先用本地
  _self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "")
  if [ -n "$_self_dir" ] && [ -f "$_self_dir/qq-group-guard.py" ]; then
    cp "$_self_dir/qq-group-guard.py" "$DIR/qq-group-guard.py.new"
    info "使用本地脚本：$_self_dir/qq-group-guard.py"
  else
    if ! curl -fsSL -o "$DIR/qq-group-guard.py.new" "$RAWBASE/qq-group-guard.py?$(date +%s)$$"; then
      err "下载 qq-group-guard.py 失败，检查网络或 GitHub 可达性"
      exit 1
    fi
  fi
  python3 -m py_compile "$DIR/qq-group-guard.py.new" 2>/dev/null || {
    err "下载的脚本语法校验失败，已中止（未覆盖旧版本）"; rm -f "$DIR/qq-group-guard.py.new"; exit 1; }
  # 原子替换，避免运行中文件被覆盖导致的 Text file busy
  mv "$DIR/qq-group-guard.py.new" "$DIR/qq-group-guard.py"
  chmod 755 "$DIR/qq-group-guard.py"
  ln -sf "$DIR/qq-group-guard.py" "$BIN"
  ok "脚本已安装：$DIR/qq-group-guard.py（$BIN）"
}

# ── 交互式生成配置 ───────────────────────────────────────────
ask() { # ask <提示> <默认值> <变量名>
  printf "  %s [%s]: " "$1" "$2"
  read -r _a || _a=""
  [ -z "$_a" ] && _a="$2"
  eval "$3=\"\$_a\""
}

json_arr() { # 逗号分隔 -> JSON 字符串数组
  printf '%s' "$1" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' |
    sed 's/"/\\"/g; s/^/    "/; s/$/",/' | sed '$ s/,$//'
}

json_num_arr() { # 逗号分隔 -> JSON 数字数组（群号 / QQ 号）
  printf '%s' "$1" | tr ',' '\n' | sed 's/[^0-9]//g' | grep -v '^$' |
    sed 's/^/    /; s/$/,/' | sed '$ s/,$//'
}

gen_config() {
  mkdir -p "$CONF_DIR" "$STATE_DIR" "$LOG_DIR"

  # 已有配置时读出来做默认值
  OLD() { [ -f "$CONF" ] && python3 -c "
import json,sys
try: c=json.load(open('$CONF'))
except Exception: c={}
v=c.get('$1','$2')
print(','.join(map(str,v)) if isinstance(v,list) else v)
" 2>/dev/null || printf '%s' "$2"; }

  D_API=$(OLD api_base "http://127.0.0.1:5700")
  D_TOKEN=$(OLD token "")
  D_GROUP=$(OLD group_id "")
  D_KW=$(OLD keywords "")
  D_MODE=$(OLD mode "report")
  D_HOURS=$(OLD grace_hours 48)
  D_ROUNDS=$(OLD grace_rounds 2)
  D_NEW=$(OLD new_member_days 3)
  D_WL=$(OLD whitelist "")
  D_SELF=$(OLD self_qq 0)
  D_MAXK=$(OLD max_kick 5)
  D_RATIO=$(OLD max_ratio 30)
  D_INT=$(OLD interval 1.5)
  D_WARN=$(OLD warn_in_group true)

  line
  echo " qq-group-guard 配置向导 $SCRIPT_VERSION"
  line
  echo " 直接回车 = 用方括号里的默认值"
  echo
  echo " ── 连接 OneBot（go-cqhttp / NapCat / Lagrange 的 HTTP 端口）──"
  ask "OneBot HTTP 地址"  "$D_API"   V_API
  ask "access_token（无则留空）" "$D_TOKEN" V_TOKEN
  echo
  echo " ── 巡检目标 ──"
  ask "群号（多个用英文逗号分隔）" "$D_GROUP" V_GROUP
  ask "合规关键词（含任一即合规，逗号分隔；re: 前缀=正则）" "$D_KW" V_KW
  ask "机器人自己的 QQ 号（防自踢，0=不设）" "$D_SELF" V_SELF
  echo
  echo " ── 模式：report=只报告 / lenient=宽容 / strict=严格 ──"
  ask "运行模式" "$D_MODE" V_MODE
  echo
  echo " ── 宽容参数（lenient 模式生效）──"
  ask "观察期小时数（改名宽限时间）" "$D_HOURS" V_HOURS
  ask "连续命中几轮才踢" "$D_ROUNDS" V_ROUNDS
  ask "新人入群保护天数" "$D_NEW" V_NEW
  ask "观察期是否在群内 @ 提醒 (true/false)" "$D_WARN" V_WARN
  echo
  echo " ── 安全阀 ──"
  ask "永不处理的 QQ 号白名单（逗号分隔，可空）" "$D_WL" V_WL
  ask "单轮最多踢几人（0=不限）" "$D_MAXK" V_MAXK
  ask "不合规占比熔断阈值 %（0=关闭）" "$D_RATIO" V_RATIO
  ask "踢人间隔秒数（防风控）" "$D_INT" V_INT

  if [ -z "$V_GROUP" ] || [ -z "$V_KW" ]; then
    err "群号与关键词都不能为空（关键词为空脚本会拒绝运行，防清群事故）"
    exit 1
  fi

  {
    echo '{'
    printf '  "api_base": "%s",\n' "$V_API"
    printf '  "token": "%s",\n' "$V_TOKEN"
    echo '  "group_id": ['
    json_num_arr "$V_GROUP"
    echo '  ],'
    echo '  "keywords": ['
    json_arr "$V_KW"
    echo '  ],'
    printf '  "mode": "%s",\n' "$V_MODE"
    printf '  "grace_hours": %s,\n' "$V_HOURS"
    printf '  "grace_rounds": %s,\n' "$V_ROUNDS"
    printf '  "new_member_days": %s,\n' "$V_NEW"
    printf '  "veteran_days": 0,\n'
    echo '  "whitelist": ['
    json_num_arr "$V_WL"
    echo '  ],'
    printf '  "skip_admin": true,\n'
    printf '  "skip_title": true,\n'
    printf '  "self_qq": %s,\n' "$V_SELF"
    printf '  "interval": %s,\n' "$V_INT"
    printf '  "max_kick": %s,\n' "$V_MAXK"
    printf '  "max_ratio": %s,\n' "$V_RATIO"
    printf '  "breaker_min": 5,\n'
    printf '  "reject_add": false,\n'
    printf '  "warn_in_group": %s,\n' "$V_WARN"
    printf '  "warn_template": "请在 {hours} 小时内把群名片改成含「{keywords}」的格式，否则将被移出本群。",\n'
    printf '  "timeout": 20,\n'
    printf '  "state_dir": "%s",\n' "$STATE_DIR"
    printf '  "log_dir": "%s"\n' "$LOG_DIR"
    echo '}'
  } > "$CONF.tmp"

  python3 -c "import json;json.load(open('$CONF.tmp'))" || { err "生成的配置不是合法 JSON"; exit 1; }
  mv "$CONF.tmp" "$CONF"
  chmod 600 "$CONF"   # 内含 token，禁止其他用户读
  ok "配置已写入 $CONF（权限 600）"
}

# ── systemd timer ────────────────────────────────────────────
has_systemd() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }

cron_to_oncalendar() {
  # 支持最常用的几种 cron，其余回退为每 6 小时
  case "$1" in
    "0 */6 * * *")  echo "*-*-* 00,06,12,18:00:00" ;;
    "0 */12 * * *") echo "*-*-* 00,12:00:00" ;;
    "0 */4 * * *")  echo "*-*-* 00,04,08,12,16,20:00:00" ;;
    "0 */2 * * *")  echo "*-*-* 00/2:00:00" ;;
    "0 * * * *")    echo "hourly" ;;
    "0 3 * * *")    echo "*-*-* 03:00:00" ;;
    "0 9 * * *")    echo "*-*-* 09:00:00" ;;
    "0 21 * * *")   echo "*-*-* 21:00:00" ;;
    *)
      # "分 时 * * *" 通用解析
      _m=$(echo "$1" | awk '{print $1}'); _h=$(echo "$1" | awk '{print $2}')
      case "$_h" in
        \*/[0-9]*) echo "*-*-* 00/${_h#*/}:$(printf '%02d' "${_m:-0}"):00" ;;
        [0-9]*)    echo "*-*-* $(printf '%02d' "$_h"):$(printf '%02d' "${_m:-0}"):00" ;;
        *)         echo "*-*-* 00,06,12,18:00:00" ;;
      esac ;;
  esac
}

install_timer() {
  _cron="${1:-0 */6 * * *}"
  _cal=$(cron_to_oncalendar "$_cron")

  if has_systemd; then
    cat > /etc/systemd/system/$SVC.service <<EOF
[Unit]
Description=QQ Group Card Guard ($SCRIPT_VERSION)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 $DIR/qq-group-guard.py --config $CONF --yes --json $STATE_DIR/last_result.json
StandardOutput=append:$LOG_DIR/run.log
StandardError=append:$LOG_DIR/run.log
# 最小权限加固
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$STATE_DIR $LOG_DIR
MemoryMax=128M
CPUQuota=30%
EOF
    cat > /etc/systemd/system/$SVC.timer <<EOF
[Unit]
Description=QQ Group Card Guard timer ($_cron)

[Timer]
OnCalendar=$_cal
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now $SVC.timer >/dev/null 2>&1
    ok "systemd timer 已启用：$_cal（cron: $_cron）"
    echo "$_cron" > "$CONF_DIR/cron"
  else
    # 回退 crontab
    _cmd="/usr/bin/python3 $DIR/qq-group-guard.py --config $CONF --yes >> $LOG_DIR/run.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v 'qq-group-guard.py'; echo "$_cron $_cmd" ) | crontab -
    ok "crontab 已安装：$_cron"
    echo "$_cron" > "$CONF_DIR/cron"
  fi
}

# ── 子命令 ───────────────────────────────────────────────────
cmd_install() {
  ensure_deps
  fetch_main
  mkdir -p "$STATE_DIR" "$LOG_DIR"
  if [ "$1" = "--quiet" ] || [ "$1" = "-q" ]; then
    [ -f "$CONF" ] || { err "--quiet 模式需要 $CONF 已存在，或先跑一次交互配置"; exit 1; }
    info "跳过配置向导，沿用现有 $CONF"
  else
    gen_config
  fi
  ask_cron=${QGG_CRON:-}
  if [ -z "$ask_cron" ]; then
    printf "  定时周期 cron [0 */6 * * *]: "; read -r ask_cron || ask_cron=""
    [ -z "$ask_cron" ] && ask_cron="0 */6 * * *"
  fi
  install_timer "$ask_cron"
  line
  ok "安装完成！强烈建议先跑一次 report 模式确认名单："
  echo "    qq-group-guard --config $CONF --mode report"
  echo "  或： $0 test"
  line
  cmd_status
}

cmd_test() {
  [ -f "$CONF" ] || { err "未找到配置 $CONF，请先运行：$0 install"; exit 1; }
  info "以 report 模式试跑（绝对不会踢人）..."
  python3 "$DIR/qq-group-guard.py" --config "$CONF" --mode report
}

cmd_run() {
  [ -f "$CONF" ] || { err "未找到配置 $CONF"; exit 1; }
  python3 "$DIR/qq-group-guard.py" --config "$CONF" --yes --json "$STATE_DIR/last_result.json"
}

cmd_mode() {
  _m="$1"
  case "$_m" in
    report|lenient|strict) ;;
    *) err "模式只能是 report / lenient / strict"; exit 1 ;;
  esac
  python3 - "$CONF" "$_m" <<'PY'
import json,sys
p,m=sys.argv[1],sys.argv[2]
c=json.load(open(p)); c['mode']=m
json.dump(c,open(p,'w'),ensure_ascii=False,indent=2)
print(f"mode -> {m}")
PY
  ok "已切换为 $_m 模式"
}

cmd_timer() { install_timer "$1"; }

cmd_status() {
  line
  echo " qq-group-guard $SCRIPT_VERSION 状态"
  line
  [ -f "$DIR/qq-group-guard.py" ] && ok "脚本：$DIR/qq-group-guard.py" || warn "脚本未安装"
  if [ -f "$CONF" ]; then
    ok "配置：$CONF"
    python3 - "$CONF" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
print(f"    模式      : {c.get('mode')}")
print(f"    OneBot    : {c.get('api_base')}")
print(f"    Token     : {'已设置' if c.get('token') else '未设置'}")
print(f"    群号      : {c.get('group_id')}")
print(f"    关键词    : {c.get('keywords')}")
print(f"    观察期    : {c.get('grace_hours')}h / {c.get('grace_rounds')} 轮")
print(f"    新人保护  : {c.get('new_member_days')} 天")
print(f"    白名单    : {c.get('whitelist') or '无'}")
print(f"    单轮上限  : {c.get('max_kick')} 人")
print(f"    熔断阈值  : {c.get('max_ratio')}% 且 >= {c.get('breaker_min')} 人")
PY
  else
    warn "配置未生成，运行：$0 install"
  fi
  [ -f "$CONF_DIR/cron" ] && info "定时周期：$(cat "$CONF_DIR/cron")"
  if has_systemd; then
    systemctl is-enabled $SVC.timer >/dev/null 2>&1 && ok "timer 已启用" || warn "timer 未启用"
    systemctl list-timers $SVC.timer --no-pager 2>/dev/null | sed -n '2p'
  fi
  _n=$(ls "$STATE_DIR"/pending_*.json 2>/dev/null | wc -l)
  [ "$_n" -gt 0 ] && info "观察期文件 $_n 个（$0 pending 查看）"
  line
}

cmd_logs() {
  if [ -f "$LOG_DIR/run.log" ]; then tail -n "${1:-60}" "$LOG_DIR/run.log"
  elif has_systemd;                 then journalctl -u $SVC.service -n "${1:-60}" --no-pager
  else warn "暂无日志"; fi
}

cmd_pending() {
  if [ "$1" = "clear" ]; then
    rm -f "$STATE_DIR"/pending_*.json
    ok "观察期记录已清空（所有人重新从第 1 轮开始计时）"
    return
  fi
  _f=$(ls "$STATE_DIR"/pending_*.json 2>/dev/null || true)
  [ -z "$_f" ] && { info "暂无观察期记录"; return; }
  for f in $_f; do
    echo "── $f"
    python3 - "$f" <<'PY'
import json,sys,time
d=json.load(open(sys.argv[1])); now=int(time.time())
if not d: print("   (空)")
for uid,v in d.items():
    h=(now-int(v.get('first',now)))/3600
    print(f"   {uid}  {v.get('name','')}  第{v.get('rounds',0)}轮  已过 {h:.1f}h")
PY
  done
  info "清空：$0 pending clear"
}

cmd_update() {
  ensure_deps
  if has_systemd; then systemctl stop $SVC.service 2>/dev/null || true; fi
  fetch_main
  ok "已升级到最新版本（配置与观察期数据保留）"
}

cmd_uninstall() {
  printf "是否同时删除配置与数据？(yes 删除 / 回车保留): "; read -r _p || _p=""
  if has_systemd; then
    systemctl disable --now $SVC.timer 2>/dev/null || true
    rm -f /etc/systemd/system/$SVC.service /etc/systemd/system/$SVC.timer
    systemctl daemon-reload
  fi
  crontab -l 2>/dev/null | grep -v 'qq-group-guard.py' | crontab - 2>/dev/null || true
  rm -f "$BIN"
  rm -rf "$DIR"
  if [ "$_p" = "yes" ]; then
    rm -rf "$CONF_DIR" "$STATE_DIR" "$LOG_DIR"
    ok "已完全卸载（含配置与数据）"
  else
    ok "已卸载程序，配置保留在 $CONF，数据保留在 $STATE_DIR"
  fi
}

menu() {
  while :; do
    line
    echo " qq-group-guard $SCRIPT_VERSION 管理菜单"
    line
    echo "  1) 安装 / 重新配置"
    echo "  2) report 模式试跑（不踢人，推荐先做）"
    echo "  3) 立即执行一次"
    echo "  4) 切换模式 report / lenient / strict"
    echo "  5) 修改定时周期"
    echo "  6) 查看状态"
    echo "  7) 查看日志"
    echo "  8) 查看 / 清空观察期名单"
    echo "  9) 升级脚本"
    echo "  0) 卸载"
    echo "  q) 退出"
    printf "请选择: "; read -r c || exit 0
    case "$c" in
      1) cmd_install ;;
      2) cmd_test ;;
      3) cmd_run ;;
      4) printf "输入模式 (report/lenient/strict): "; read -r m; cmd_mode "$m" ;;
      5) printf "输入 cron (如 0 */6 * * *): "; read -r cr; cmd_timer "$cr" ;;
      6) cmd_status ;;
      7) cmd_logs ;;
      8) printf "输入 clear 清空，回车仅查看: "; read -r a; cmd_pending "$a" ;;
      9) cmd_update ;;
      0) cmd_uninstall; exit 0 ;;
      q|Q) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

case "${1:-}" in
  install)   shift; cmd_install "$@" ;;
  config)    gen_config ;;
  test)      cmd_test ;;
  run)       cmd_run ;;
  mode)      cmd_mode "$2" ;;
  timer)     cmd_timer "$2" ;;
  status)    cmd_status ;;
  logs)      cmd_logs "$2" ;;
  pending)   cmd_pending "$2" ;;
  update)    cmd_update ;;
  uninstall) cmd_uninstall ;;
  -v|--version) echo "qq-group-guard installer $SCRIPT_VERSION" ;;
  -h|--help) sed -n '2,30p' "$0" ;;
  "")        menu ;;
  *)         err "未知子命令：$1（-h 查看帮助）"; exit 1 ;;
esac
