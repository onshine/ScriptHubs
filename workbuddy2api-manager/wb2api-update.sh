#!/usr/bin/env bash
# ==============================================================================
# workbuddy2api 上游更新脚本  wb2api-update.sh  R1.0.0
#
# 适用：**镜像式部署** —— compose 里写的是
#         image: ghcr.io/hanawabanana/workbuddy2api:latest
#       （本套件 workbuddy2api.sh 生成的 compose 就是这种）
#
# 为什么不点面板的「一键更新 → 上游」：
#   面板的 update_upstream() 只支持两种上游形态 ——
#     ① 上游目录是 git 仓库（它跑 git fetch/reset）
#     ② 上游源码随面板 Release 分发（install.sh 装的，它 docker compose build）
#   镜像式部署两者都不是，面板会直接跳过（「不是 git 仓库，跳过上游更新」）。
#   这不是故障，是部署形态不匹配。镜像式部署的正确更新动作就是本脚本做的：
#       docker compose pull && docker compose up -d --force-recreate
#
# 用法：
#   ./wb2api-update.sh              # 更新（默认）
#   ./wb2api-update.sh --check      # 只体检，不更新
#   ./wb2api-update.sh --rollback   # 从最近备份恢复 auths/data/config/compose
#
# 自检含「面板 → 网关连通性」：bridge 模式下重建容器会丢掉运行时加的共享网卡，
# 表现为面板「上游连接：不可用」而网关自己健康 —— 详见 README 5.11。
# ==============================================================================
set -uo pipefail

SCRIPT_VERSION="R1.0.0"
BK_DIR=""

DIR="${WB2API_DIR:-/opt/workbuddy/workbuddy2api}"
CTR="${WB2API_CONTAINER:-workbuddy2api}"
PANEL_CTR="${WB_MANAGER_CONTAINER:-workbuddy-manager}"
PORT="${WB2API_PORT:-17863}"
COMPOSE="$DIR/docker-compose.yml"
BK_ROOT="${WB2API_BACKUP_DIR:-/root}"

if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; N=$'\033[0m'
else
  R=''; G=''; Y=''; B=''; N=''
fi
ok()   { printf '%s  [OK]  %s%s\n' "$G" "$*" "$N"; }
warn() { printf '%s  [WARN]%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '%s  [FAIL]%s %s\n' "$R" "$N" "$*"; }
inf()  { printf '%s  [ .. ]%s %s\n' "$B" "$N" "$*"; }
die()  { err "$*"; exit 1; }
banner() {
  printf '\n%s======================================================%s\n' "$B" "$N"
  printf '%s  %s%s\n' "$B" "$*" "$N"
  printf '%s======================================================%s\n' "$B" "$N"
}

# ------------------------------ 账号池 ----------------------------------------
fetch_status() {
  local out="$1" key
  key="$(python3 -c "
import json
try: print(json.load(open('$DIR/config.json',encoding='utf-8')).get('api_key',''))
except Exception: print('')
" 2>/dev/null)"
  [ -n "$key" ] || return 1
  python3 - "$key" "$PORT" "$out" <<'PYEOF'
import json, sys, urllib.request
key, port, out = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request("http://127.0.0.1:%s/status" % port,
                             headers={"Authorization": "Bearer " + key})
try:
    d = json.load(urllib.request.urlopen(req, timeout=8))
except Exception as e:
    sys.stderr.write("status error: %s\n" % e); sys.exit(1)
json.dump(d, open(out, "w"))
print(d.get("total", 0), d.get("healthy", 0))
PYEOF
}

# ------------------------------ 面板 → 网关 ------------------------------------
# 返回 0=通 / 1=不通（非网络原因）/ 2=疑似共享网络丢失（可自动修复）
panel_link_check() {
  docker inspect "$PANEL_CTR" >/dev/null 2>&1 || { inf "无面板容器，跳过上游连通性检查"; return 0; }
  local base
  base="$(docker exec "$PANEL_CTR" printenv WB2API_BASE 2>/dev/null || true)"
  [ -n "$base" ] || { warn "面板未设置 WB2API_BASE，跳过"; return 0; }
  local code
  code="$(docker exec "$PANEL_CTR" sh -c \
    "curl -s -o /dev/null -w '%{http_code}' --max-time 6 '${base}/healthz'" 2>/dev/null || true)"
  [ "$code" = "200" ] && { ok "面板 → 网关连通（$base）"; return 0; }
  err "面板 → 网关不通（$base → HTTP ${code:-000}）"
  case "$base" in
    *localhost*|*127.0.0.1*|*host.docker.internal*) return 1 ;;
  esac
  return 2
}

repair_panel_link() {
  local panel_nets gw_nets net fixed=0
  panel_nets="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$PANEL_CTR" 2>/dev/null || true)"
  gw_nets="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$CTR" 2>/dev/null || true)"
  for net in $panel_nets; do
    case "$net" in *_default) continue ;; esac
    case " $gw_nets " in *" $net "*) continue ;; esac
    inf "把网关接回共享网络 $net ..."
    if docker network connect "$net" "$CTR" --alias "$CTR" 2>/dev/null; then
      ok "已接入 $net"; fixed=1
    else warn "接入 $net 失败"; fi
  done
  [ "$fixed" -eq 1 ] && warn "⚠️ 运行时补回只是权宜 —— 永久修复请把网络写进 compose（见 README 5.11）"
  return 0
}

# ------------------------------ 自检 ------------------------------------------
post_check() {
  local want="$1" st fail=0

  st="$(docker inspect -f '{{.State.Status}}' "$CTR" 2>/dev/null || echo missing)"
  [ "$st" = "running" ] && ok "容器 running" || { err "容器状态：$st"; fail=1; }

  st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CTR" 2>/dev/null || echo unknown)"
  case "$st" in
    healthy) ok "健康检查 healthy" ;;
    starting) warn "健康检查 starting（还在启动窗口）" ;;
    none) warn "无 healthcheck" ;;
    *) err "健康检查：$st"; fail=1 ;;
  esac

  st="$(fetch_status /tmp/wb-up-post.json 2>/dev/null)"
  if [ -z "$st" ]; then
    err "/status 无法访问"; fail=1
  else
    set -- $st
    if [ "$1" -eq "$want" ] 2>/dev/null; then ok "账号数 $1 == 更新前 $want"
    else err "账号数 $1 != 更新前 $want"; fail=1; fi
    [ "$2" -gt 0 ] && ok "健康账号 $2" || { err "没有任何健康账号"; fail=1; }
  fi

  local lst
  lst="$(ss -lntp 2>/dev/null | grep -E "[:.]${PORT}\b" || true)"
  if printf '%s' "$lst" | grep -qE "(0\.0\.0\.0|\*|\[::\]):${PORT}"; then
    err "★ $PORT 绑到通配地址，已暴露公网！"; fail=1
  elif [ -n "$lst" ]; then ok "监听仍仅回环"
  else warn "看不到 $PORT 监听"; fi

  local plrc=0
  panel_link_check || plrc=$?
  if [ "$plrc" -eq 2 ]; then
    warn "疑似共享网络丢失 —— 自动补回"
    repair_panel_link; sleep 3
    local plrc2=0
    panel_link_check >/dev/null 2>&1 || plrc2=$?
    if [ "$plrc2" -eq 0 ]; then ok "补回后：面板 → 网关已连通"
    else err "补回后仍不通 —— 检查网关 compose 的 networks 段"; fail=1; fi
  elif [ "$plrc" -ne 0 ]; then
    fail=1
  fi

  return $fail
}

# ------------------------------ 体检 ------------------------------------------
do_precheck() {
  banner "更新前体检  ($SCRIPT_VERSION)"
  local rc=0

  [ "$(id -u)" -eq 0 ] || { err "请用 root 运行"; rc=1; }
  command -v docker >/dev/null 2>&1 || { err "没有 docker"; rc=1; }
  [ -f "$COMPOSE" ] || { err "找不到 $COMPOSE"; rc=1; }
  [ "$rc" -eq 0 ] || return 1
  ok "环境就绪（root / docker / compose）"

  # 部署形态识别
  if grep -qE '^[[:space:]]*build:' "$COMPOSE" 2>/dev/null; then
    warn "compose 用的是 build:（本地构建源码），本脚本按「镜像式」流程也可能可行，"
    inf "  但更推荐用面板的一键更新（它能同步源码并重建）"
  fi
  local img
  img="$(grep -E '^[[:space:]]*image:' "$COMPOSE" 2>/dev/null | head -1 | awk '{print $2}')"
  [ -n "$img" ] && ok "上游镜像：$img"

  local cur
  cur="$(docker inspect -f '{{.Config.Image}}' "$CTR" 2>/dev/null || echo '')"
  [ -n "$cur" ] && inf "当前容器镜像：$cur"

  # 可拉取性
  local repo="${img#ghcr.io/}"; repo="${repo%%:*}"
  if [ -n "$repo" ]; then
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' \
      "https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io" 2>/dev/null)"
    [ "$code" = "200" ] && ok "镜像仓库可匿名拉取（$repo）" \
      || { err "镜像仓库不可达（HTTP $code）"; rc=1; }
  fi

  local st
  st="$(fetch_status /tmp/wb-up-pre.json 2>/dev/null)"
  if [ -n "$st" ]; then
    set -- $st
    ok "账号池：total=$1 healthy=$2"
    [ "$1" -gt 0 ] || { err "账号数为 0 —— 先修好再更新"; rc=1; }
  else
    err "拿不到 /status"; rc=1
  fi

  local wrong
  wrong="$(find "$DIR/auths" -maxdepth 1 -name '*.json' ! -user 10001 2>/dev/null | wc -l | tr -d ' ')"
  [ "$wrong" -gt 0 ] && warn "有 $wrong 个 auth 文件属主不是 10001（会被静默跳过）" \
                     || ok "auths 属主正确"

  # 共享网络：recreate 会丢掉运行时加的网卡 —— 提前预警
  local base
  base="$(docker exec "$PANEL_CTR" printenv WB2API_BASE 2>/dev/null || true)"
  case "$base" in
    ""|*localhost*|*127.0.0.1*|*host.docker.internal*) : ;;
    *)
      if grep -qE '^[[:space:]]*networks:' "$COMPOSE" 2>/dev/null; then
        ok "网关 compose 已声明 networks 段（重建不会丢共享网络）"
      else
        warn "网关 compose 未声明 networks 段，而面板用容器名访问它（$base）"
        inf "  → 更新后会出现「上游连接：不可用」；脚本自检会自动补回，"
        inf "    但建议写进 compose 永久修复（见 README 5.11）"
      fi ;;
  esac

  printf '\n'
  [ "$rc" -eq 0 ] && printf '%s  ✅ 体检通过，可以更新%s\n\n' "$G" "$N" \
                  || printf '%s  ⚠️  体检有 FAIL 项，建议先解决%s\n\n' "$Y" "$N"
  return $rc
}

# ------------------------------ 备份 ------------------------------------------
do_backup() {
  local ts="$1" bk="$BK_ROOT/wb2api-update-$ts"
  mkdir -p "$bk" || return 1
  inf "备份到 $bk ..."
  ( cd "$DIR" && tar czf "$bk/payload.tar.gz" auths data config.json docker-compose.yml ) || return 1
  [ -s "$bk/payload.tar.gz" ] || return 1
  local list
  list="$(tar tzf "$bk/payload.tar.gz" 2>/dev/null)" || return 1
  for need in auths/ data/ config.json docker-compose.yml; do
    printf '%s' "$list" | grep -q "^$need" || { err "备份不完整：缺 $need"; return 1; }
  done
  local n
  n="$(printf '%s' "$list" | grep -c '^auths/.*\.json$')"
  [ "$n" -gt 0 ] || { err "备份里没有 auths/*.json"; return 1; }
  ok "备份完成并校验通过（auth $n 个，$(du -h "$bk/payload.tar.gz" | cut -f1)）"
  BK_DIR="$bk"
  echo "$bk" > /tmp/wb2api-update-last-backup.txt
  # 只留最近 5 份
  ls -1dt "$BK_ROOT"/wb2api-update-* 2>/dev/null | tail -n +6 | xargs -r rm -rf
  return 0
}

# ------------------------------ 更新 ------------------------------------------
do_update() {
  do_precheck || { err "体检未通过，已中止（未做任何改动）"; exit 1; }

  local ts want bk img_before img_after
  ts="$(date +%F-%H%M%S)"
  banner "执行更新  ($SCRIPT_VERSION)"

  want="$(fetch_status /tmp/wb-up-pre.json 2>/dev/null | awk '{print $1}')"
  [ -n "$want" ] && [ "$want" -gt 0 ] 2>/dev/null || die "拿不到账号数基线，中止"
  ok "账号数基线：$want"

  do_backup "$ts" || die "备份失败 —— 不备份不更新，已中止"
  bk="$BK_DIR"
  ok "备份目录：$bk"

  img_before="$(docker inspect -f '{{.Image}}' "$CTR" 2>/dev/null || echo '')"
  echo "$img_before" > "$bk/before-image-id.txt"

  inf "拉取镜像（失败即中止，不碰容器）..."
  if ! ( cd "$DIR" && docker compose pull ); then
    die "镜像拉取失败，服务未受影响（compose 未改动）"
  fi
  ok "镜像拉取完成"

  inf "重建容器（force-recreate；不用 down）..."
  ( cd "$DIR" && docker compose up -d --force-recreate ) || die "重建失败，可用 $0 --rollback"
  ok "容器已重建"

  local round good=1
  for round in 1 2 3; do
    printf '\n'; banner "自检 第 $round/3 轮（等 30s）"
    sleep 30
    if post_check "$want"; then good=0; break; fi
    good=1
    [ "$round" -lt 3 ] && warn "本轮未全过，再等 30s 重试..."
  done

  img_after="$(docker inspect -f '{{.Image}}' "$CTR" 2>/dev/null || echo '')"
  printf '\n'
  if [ "$good" -eq 0 ]; then
    banner "✅ 更新完成"
    printf '  镜像 %s → %s\n' "${img_before:0:19}" "${img_after:0:19}"
    [ "$img_before" = "$img_after" ] && printf '  （镜像未变，说明本来就是最新版）\n'
    printf '  备份：%s\n' "$bk"
    printf '  回滚：%s --rollback\n\n' "$0"
    return 0
  fi

  banner "⚠️  自检未通过 —— 服务可能仍可用，但请人工确认"
  printf '  备份：%s\n' "$bk"
  printf '  回滚：%s --rollback\n' "$0"
  printf '  看日志：docker logs --tail 50 %s\n\n' "$CTR"
  return 1
}

# ------------------------------ 回滚 ------------------------------------------
do_rollback() {
  local bk
  bk="$(cat /tmp/wb2api-update-last-backup.txt 2>/dev/null || true)"
  [ -n "$bk" ] && [ -d "$bk" ] || bk="$(ls -1dt "$BK_ROOT"/wb2api-update-* 2>/dev/null | head -1)"
  [ -n "$bk" ] && [ -d "$bk" ] || die "找不到备份目录"
  banner "回滚  (备份：$bk)"
  ( cd "$bk" && tar xzf payload.tar.gz -C "$DIR" ) || die "解压失败"
  chown -R 10001:10001 "$DIR/auths" 2>/dev/null || true
  ok "已恢复 auths / data / config.json / docker-compose.yml"
  ( cd "$DIR" && docker compose up -d --force-recreate ) || die "重建失败"
  sleep 25
  printf '\n'; post_check "$(fetch_status /tmp/wb-up-rb.json 2>/dev/null | awk '{print $1}')" || true
}

case "${1:-update}" in
  update|"") do_update ;;
  --check|check) do_precheck ;;
  --rollback|rollback) do_rollback ;;
  -h|--help|help) sed -n '3,20p' "$0" | cut -c3-; exit 0 ;;
  *) die "未知参数：$1（用 --help 查看用法）" ;;
esac
