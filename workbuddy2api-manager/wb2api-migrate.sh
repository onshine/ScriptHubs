#!/usr/bin/env bash
# ==============================================================================
# workbuddy2api 上游镜像迁移脚本  wb2api-migrate.sh  R1.0.0
#
# 背景：上游 Sliverkiss/workbuddy2api 已删库，GHCR 镜像同步失效
#       （ghcr.io/sliverkiss/workbuddy2api → 403 DENIED）。
#       本是"官方原版"的延续仓库为 HanawaBanana/workbuddy2api，
#       有 CI 自动构建并推送 ghcr.io/hanawabanana/workbuddy2api。
#
# 本脚本把正在跑的网关从旧镜像切到延续仓库镜像，全程自检 + 失败自动回滚。
#
# 用法：
#   ./wb2api-migrate.sh              # 执行迁移（默认）
#   ./wb2api-migrate.sh --check      # 只做迁移前体检，不改任何东西
#   ./wb2api-migrate.sh --rollback   # 用最近一次备份回滚
#
# ⚠️ 迁移会重建网关容器 —— 若你的当前会话模型正跑在这个网关上，
#    执行瞬间会断线（脚本会自己跑完，不需要你在场）。
# ==============================================================================
set -uo pipefail

SCRIPT_VERSION="R1.0.0"
BK_DIR=""                          # do_backup 经此回传备份路径

DIR="${WB2API_DIR:-/opt/workbuddy/workbuddy2api}"
OLD_IMAGE="${WB2API_OLD_IMAGE:-ghcr.io/sliverkiss/workbuddy2api:latest}"
NEW_IMAGE="${WB2API_NEW_IMAGE:-ghcr.io/hanawabanana/workbuddy2api:latest}"
CTR="${WB2API_CONTAINER:-workbuddy2api}"
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
  printf '%s======================================================%s%s\n' "$B" "$N" "$N"
}

# ------------------------------ 读取 api_key / 账号数 -------------------------
read_apikey() {
  python3 -c "
import json,sys
try:
    print(json.load(open('$DIR/config.json',encoding='utf-8')).get('api_key',''))
except Exception:
    print('')
" 2>/dev/null
}

# 拉 /status，成功时把 JSON 写到 $1，并回显账号数
fetch_status() {
  local out="$1" key
  key="$(read_apikey)"
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
print(d.get("total", 0), d.get("healthy", 0), d.get("disabled", 0))
PYEOF
}

# ------------------------------ 迁移前体检 ------------------------------------
do_precheck() {
  banner "迁移前体检  ($SCRIPT_VERSION)"
  local rc=0

  [ "$(id -u)" -eq 0 ] || { err "请用 root 运行"; rc=1; }
  command -v docker >/dev/null 2>&1 || { err "没有 docker"; rc=1; }
  [ -f "$COMPOSE" ] || { err "找不到 $COMPOSE"; rc=1; }
  [ "$rc" -eq 0 ] || return 1
  ok "环境就绪（root / docker / compose）"

  # 当前镜像
  local cur
  cur="$(docker inspect -f '{{.Config.Image}}' "$CTR" 2>/dev/null || echo '')"
  if [ -z "$cur" ]; then
    warn "容器 $CTR 不存在（可能未部署）"
  else
    inf "当前镜像：$cur"
    if [ "$cur" = "$OLD_IMAGE" ]; then
      ok "与预期的旧镜像一致"
    else
      warn "与预期旧镜像（$OLD_IMAGE）不同 —— 请确认 compose 里的 image 行"
    fi
  fi

  # 新镜像可达性
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    "https://ghcr.io/token?scope=repository:hanawabanana/workbuddy2api:pull&service=ghcr.io" 2>/dev/null)"
  if [ "$code" = "200" ]; then ok "新镜像仓库可匿名拉取（ghcr.io/hanawabanana/workbuddy2api）"
  else err "新镜像仓库不可达（HTTP $code）—— 检查网络/DNS/代理"; rc=1; fi

  # 账号池基线
  local st
  st="$(fetch_status /tmp/wb-check-status.json 2>/dev/null)"
  if [ -n "$st" ]; then
    set -- $st
    ok "账号池：total=$1 healthy=$2 disabled=$3"
    if [ "$1" -eq 0 ]; then err "账号数为 0 —— 现在就是异常的，先修好再迁移"; rc=1; fi
  else
    err "拿不到 /status —— 网关没起来？api_key 读不到？"; rc=1
  fi

  # auths 属主
  local wrong
  wrong="$(find "$DIR/auths" -maxdepth 1 -name '*.json' ! -user 10001 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$wrong" -gt 0 ]; then
    warn "有 $wrong 个 auth 文件属主不是 10001（会被静默跳过）"
    inf "  修法：chown -R 10001:10001 $DIR/auths"
  else
    ok "auths 属主正确"
  fi

  # 监听地址（bridge 模式应有 127.0.0.1 映射）
  local lst
  lst="$(ss -lntp 2>/dev/null | grep -E "[:.]${PORT}\b" || true)"
  if [ -z "$lst" ]; then
    warn "看不到 $PORT 监听（正常吗？）"
  elif printf '%s' "$lst" | grep -qE "(0\.0\.0\.0|\*|\[::\]):${PORT}"; then
    err "★ $PORT 绑到了通配地址，已暴露公网！"
    printf '        %s\n' "$lst"; rc=1
  else
    ok "监听仅回环（$PORT）"
  fi

  printf '\n'
  if [ "$rc" -eq 0 ]; then printf '%s  ✅ 体检通过，可以迁移%s\n\n' "$G" "$N"
  else printf '%s  ⚠️  体检有 FAIL 项，建议先解决%s\n\n' "$Y" "$N"; fi
  return $rc
}

# ------------------------------ 备份 ------------------------------------------
do_backup() {
  local ts="$1"
  local bk="$BK_ROOT/wb2api-preimage-$ts"
  mkdir -p "$bk" || return 1
  inf "备份到 $bk ..."
  ( cd "$DIR" && tar czf "$bk/payload.tar.gz" auths data config.json docker-compose.yml ) || return 1
  [ -s "$bk/payload.tar.gz" ] || return 1

  # 校验：能列出内容，且含关键三项
  local list
  list="$(tar tzf "$bk/payload.tar.gz" 2>/dev/null)" || return 1
  for need in auths/ data/ config.json docker-compose.yml; do
    printf '%s' "$list" | grep -q "^$need" || { err "备份不完整：缺 $need"; return 1; }
  done
  local n
  n="$(printf '%s' "$list" | grep -c '^auths/.*\.json$')"
  [ "$n" -gt 0 ] || { err "备份里没有 auths/*.json"; return 1; }
  ok "备份完成并校验通过（auth 文件 $n 个，$(du -h "$bk/payload.tar.gz" | cut -f1)）"
  BK_DIR="$bk"                       # 经全局变量回传，避免 $(...) 捕获到提示文字
  echo "$bk" > /tmp/wb2api-last-backup.txt
  return 0
}

# ------------------------------ 自检 ------------------------------------------
# 全部通过返回 0；$1 = 期望账号数
post_check() {
  local want="$1" st h fail=0

  st="$(docker inspect -f '{{.State.Status}}' "$CTR" 2>/dev/null || echo missing)"
  if [ "$st" = "running" ]; then ok "容器 running"
  else err "容器状态：$st"; fail=1; fi

  h="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CTR" 2>/dev/null || echo unknown)"
  case "$h" in
    healthy) ok "健康检查 healthy" ;;
    starting) warn "健康检查 starting（还在启动窗口）" ;;
    none) warn "无 healthcheck" ;;
    *) err "健康检查：$h"; fail=1 ;;
  esac

  st="$(fetch_status /tmp/wb-post-status.json 2>/dev/null)"
  if [ -z "$st" ]; then
    err "/status 无法访问"; fail=1
  else
    set -- $st
    if [ "$1" -eq "$want" ]; then ok "账号数 $1 == 基线 $want"
    else err "账号数 $1 != 基线 $want（auth 不兼容的典型症状）"; fail=1; fi
    if [ "$2" -gt 0 ]; then ok "健康账号 $2"
    else err "没有任何健康账号"; fail=1; fi
  fi

  local lst
  lst="$(ss -lntp 2>/dev/null | grep -E "[:.]${PORT}\b" || true)"
  if printf '%s' "$lst" | grep -qE "(0\.0\.0\.0|\*|\[::\]):${PORT}"; then
    err "★ $PORT 绑到通配地址，已暴露公网！"; fail=1
  elif [ -n "$lst" ]; then
    ok "监听仍仅回环"
  else
    warn "看不到 $PORT 监听"
  fi

  return $fail
}

# ------------------------------ 迁移 ------------------------------------------
do_migrate() {
  do_precheck || { err "体检未通过，已中止（未做任何改动）"; exit 1; }

  local ts bk want
  ts="$(date +%F-%H%M%S)"
  banner "执行迁移  $OLD_IMAGE  →  $NEW_IMAGE"

  # 基线账号数
  want="$(fetch_status /tmp/wb-pre-status.json 2>/dev/null | awk '{print $1}')"
  [ -n "$want" ] && [ "$want" -gt 0 ] 2>/dev/null || die "拿不到基线账号数，中止"
  ok "基线账号数：$want"

  # 备份
  do_backup "$ts" || die "备份失败 —— 不备份不迁移，已中止"
  bk="$BK_DIR"
  ok "备份目录：$bk"

  # 旧镜像 ID（回滚参考）
  docker inspect -f '{{.Image}}' "$CTR" > "$bk/old-image-id.txt" 2>/dev/null || true
  inf "旧镜像 ID：$(cat "$bk/old-image-id.txt" 2>/dev/null)"

  # 改 compose
  cp "$COMPOSE" "$bk/docker-compose.yml.orig"
  if grep -q "$NEW_IMAGE" "$COMPOSE"; then
    ok "compose 已是新镜像，跳过改写"
  else
    sed -i "s|^\([[:space:]]*image:[[:space:]]*\).*workbuddy2api.*$|\1$NEW_IMAGE|" "$COMPOSE"
    if grep -q "$NEW_IMAGE" "$COMPOSE"; then
      ok "compose 已改：image → $NEW_IMAGE"
    else
      cp "$bk/docker-compose.yml.orig" "$COMPOSE"
      die "compose 改写失败，已还原"
    fi
  fi

  # 拉镜像（失败不动容器）
  inf "拉取新镜像..."
  if ! ( cd "$DIR" && docker compose pull ); then
    cp "$bk/docker-compose.yml.orig" "$COMPOSE"
    die "镜像拉取失败，compose 已还原，服务未受影响"
  fi
  ok "镜像拉取完成"

  # 重建
  inf "重建容器（force-recreate，不用 down）..."
  if ! ( cd "$DIR" && docker compose up -d --force-recreate ); then
    warn "重建命令失败，尝试回滚..."
    cp "$bk/docker-compose.yml.orig" "$COMPOSE"
    ( cd "$DIR" && docker compose up -d --force-recreate ) || true
    die "迁移失败已回滚（详见 $bk）"
  fi
  ok "容器已重建"

  # 自检（最多 3 轮，每轮等 30s）
  local round good=1
  for round in 1 2 3; do
    printf '\n'
    banner "自检 第 $round/3 轮（等 30s）"
    sleep 30
    if post_check "$want"; then good=0; break; fi
    good=1
    [ "$round" -lt 3 ] && warn "本轮未全过，再等 30s 重试..."
  done

  printf '\n'
  if [ "$good" -eq 0 ]; then
    banner "✅ 迁移成功"
    printf '  镜像：%s\n' "$NEW_IMAGE"
    printf '  备份：%s\n' "$bk"
    printf '  回滚：%s --rollback\n\n' "$0"
    return 0
  fi

  # 回滚
  banner "⚠️  自检未通过 —— 自动回滚"
  cp "$bk/docker-compose.yml.orig" "$COMPOSE"
  inf "compose 已还原，重建回旧镜像..."
  ( cd "$DIR" && docker compose up -d --force-recreate ) || die "回滚重建也失败了，请手动处理（备份在 $bk）"
  sleep 30
  printf '\n'; banner "回滚后状态"
  post_check "$want" || warn "回滚后仍未全绿，请人工检查"
  printf '\n  备份保留在：%s\n\n' "$bk"
  return 1
}

# ------------------------------ 回滚 ------------------------------------------
do_rollback() {
  local bk
  bk="$(cat /tmp/wb2api-last-backup.txt 2>/dev/null || true)"
  [ -n "$bk" ] && [ -d "$bk" ] || {
    bk="$(ls -1dt "$BK_ROOT"/wb2api-preimage-* 2>/dev/null | head -1)"
  }
  [ -n "$bk" ] && [ -d "$bk" ] || die "找不到备份目录"
  banner "回滚  (备份：$bk)"
  [ -f "$bk/docker-compose.yml.orig" ] || die "备份里没有 docker-compose.yml.orig"
  cp "$bk/docker-compose.yml.orig" "$COMPOSE" && ok "compose 已还原"
  ( cd "$DIR" && docker compose up -d --force-recreate ) || die "重建失败"
  sleep 30
  printf '\n'; post_check "$(fetch_status /tmp/x.json 2>/dev/null | awk '{print $1}')" || true
}

# ------------------------------ 入口 ------------------------------------------
case "${1:-migrate}" in
  migrate|"") do_migrate ;;
  --check|check) do_precheck ;;
  --rollback|rollback) do_rollback ;;
  -h|--help|help)
    sed -n '3,18p' "$0" | cut -c3-; exit 0 ;;
  *) die "未知参数：$1（用 --help 查看用法）" ;;
esac
