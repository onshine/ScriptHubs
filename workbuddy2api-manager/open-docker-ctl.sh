#!/usr/bin/env bash
# workbuddy-manager 面板「docker 控制能力」开关脚本 R1.0.0
#
# 作用：开启 / 关闭 / 诊断 面板容器对宿主 docker 的控制能力。
#       开启后，面板的「一键更新上游」按钮可用（等价于宿主执行
#       docker compose pull && docker compose up -d --force-recreate）。
#
# 版本记录见同目录 README.md「版本记录」表。
#
# ── 它到底在做什么（先读这段，再决定要不要开）────────────────
#
# 面板镜像【内置了 docker CLI 与 compose 插件】，官方 compose 里
# /var/run/docker.sock 那行本来就【默认挂着】（见上游仓库注释：
# 「挂上 docker.sock 后即可在容器内重建上游容器」）。
#
# 但官方没覆盖一个中间态：
#   套接字属主 = root:docker(995)，权限 660
#   面板容器进程 uid = 10001(app)，【既不是 root，也不在 docker 组】
#   → 挂上了却读不到，报 permission denied
#   → 面板把这个错误笼统显示成「宿主未安装 docker，或未挂载 docker.sock」
#      （误导性极强：明明挂着，报的却是"未挂载"）
#
# 本脚本做的就是在 compose 里补一行 group_add，把宿主 docker 组的 GID
# 授予面板容器，让【本来就挂着的】套接字真正生效。
#
# ── 安全权衡（重要，别跳过）───────────────────────────────
#
# 挂 docker.sock = 把宿主 root 权限交给面板容器（它能起特权容器、
# 能挂载宿主根目录）。面板里存着全部账号凭据，一旦被攻破，
# 丢的是整台服务器。
#
# 但要注意上游作者的论证：这【不是新增的风险等级】——
# 官方部署路径（deploy/install.sh + systemd）本来就是 root 运行
# （systemd 单元无 User=、安装脚本要求 root），而 root 进程本来就能
# `docker run -v /:/host` 拿到宿主文件系统。两种部署的权限等价。
#
# 所以本脚本【不替你判断】该不该开，只负责正确地开/关/诊断。
# 决策依据：
#   · 自用测试机 / 面板不对外 → 开，省事
#   · 面板曾暴露公网、或多人共用 → 别开，用命令行更新（README 5.9）
#
# 用法：
#   ./open-docker-ctl.sh status     # 诊断当前状态（默认，只读不改）
#   ./open-docker-ctl.sh on         # 开启（补 group_add 并重建面板）
#   ./open-docker-ctl.sh off        # 关闭（移除 group_add 并重建面板）
#   ./open-docker-ctl.sh --help
#
set -uo pipefail

SCRIPT_VERSION="R1.0.0"

MG_DIR="${WB_MANAGER_DIR:-/opt/workbuddy/workbuddy-manager}"
MG_CONTAINER="${WB_MANAGER_CONTAINER:-workbuddy-manager}"
UPSTREAM_CONTAINER="${WB2API_CONTAINER:-workbuddy2api}"
COMPOSE_FILE="$MG_DIR/docker-compose.yml"

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

usage() {
  cat <<EOF
workbuddy-manager 面板「docker 控制能力」开关脚本 $SCRIPT_VERSION

用法：
  $0 status    诊断当前状态（默认）
  $0 on        开启：补 group_add 并重建面板容器
  $0 off       关闭：移除 group_add 并重建面板容器
  $0 --help    显示本帮助

环境变量（一般不用改）：
  WB_MANAGER_DIR       面板目录，默认 /opt/workbuddy/workbuddy-manager
  WB_MANAGER_CONTAINER 面板容器名，默认 workbuddy-manager
  WB2API_CONTAINER     上游容器名，默认 workbuddy2api

开启后：面板「一键更新上游」按钮可用（等价宿主跑 compose 命令）。
关闭后：相关按钮降级为界面提示「请到宿主机操作」，不会静默失败。

⚠️ 开启 = 把宿主 root 权限交给面板容器。请先读脚本头部说明再决定。
EOF
}

# ------------------------------ 诊断 ------------------------------------------
do_status() {
  banner "面板 docker 控制能力诊断  ($SCRIPT_VERSION)"

  # ① 容器在不在
  local st
  st="$(docker inspect -f '{{.State.Status}}' "$MG_CONTAINER" 2>/dev/null || echo missing)"
  if [ "$st" != "running" ]; then
    err "面板容器 $MG_CONTAINER 未运行（状态：$st）"
    return 1
  fi
  ok "面板容器运行中"

  # ② 套接字有没有挂进去
  local mount
  mount="$(docker inspect "$MG_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/var/run/docker.sock"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)"
  if [ -z "$mount" ]; then
    warn "套接字【未挂载】到面板容器"
    inf "  修法：在 $COMPOSE_FILE 的 volumes 里加一行"
    inf "        - /var/run/docker.sock:/var/run/docker.sock"
    inf "        （官方 compose 默认就有这一行，别注释掉）"
    SOCK_MOUNTED=0
  else
    ok "套接字已挂载：$mount -> /var/run/docker.sock"
    SOCK_MOUNTED=1
  fi

  # ③ 容器 uid / 组
  local idout uid gids
  idout="$(docker exec "$MG_CONTAINER" id 2>/dev/null || echo '')"
  if [ -n "$idout" ]; then
    uid="$(printf '%s' "$idout" | sed -n 's/.*uid=\([0-9]*\).*/\1/p')"
    gids="$(printf '%s' "$idout" | sed -n 's/.*groups=//p')"
    inf "容器身份：$idout"
    if [ "$uid" = "0" ]; then
      ok "容器以 root 运行 —— 无需 group_add 即可访问套接字"
      HAS_ROOT=1
    else
      HAS_ROOT=0
    fi
  else
    warn "拿不到容器内身份（docker exec 失败？）"
    uid=''; gids=''; HAS_ROOT=0
  fi

  # ④ 宿主 docker 组 GID
  local hostgid
  hostgid="$(getent group docker 2>/dev/null | cut -d: -f3)"
  if [ -z "$hostgid" ]; then
    warn "宿主没有 docker 组（getent group docker 为空）"
    hostgid=''
  else
    inf "宿主 docker 组 GID：$hostgid"
  fi

  # ⑤ compose 里有没有 group_add
  local in_compose=0
  if [ -f "$COMPOSE_FILE" ]; then
    if grep -qE '^[[:space:]]*group_add:' "$COMPOSE_FILE"; then
      in_compose=1
      ok "compose 里【有】 group_add（配置层已开启）"
    else
      inf "compose 里【没有】group_add（配置层未开启）"
    fi
  else
    warn "找不到 $COMPOSE_FILE，跳过配置检查"
  fi

  # ⑥ 决定性证据：容器内真的能调通 docker 吗
  printf '\n'
  local probe
  probe="$(docker exec "$MG_CONTAINER" docker ps 2>&1 | head -3 || true)"
  if printf '%s' "$probe" | grep -q "permission denied"; then
    err "容器内 docker 调用失败：permission denied  ← 权限问题"
    inf "  → 本脚本解决的就是这个：补 group_add（见下方结论）"
    SOCK_WORKS=0
  elif printf '%s' "$probe" | grep -qE "command not found|not found"; then
    err "容器内没有 docker CLI"
    inf "  → 这【不是】权限问题，加 group_add 无效！"
    inf "  → 说明面板镜像版本不对（官方镜像内置了 CLI），需换回官方镜像"
    SOCK_WORKS=0
  elif printf '%s' "$probe" | grep -qE '^CONTAINER ID'; then
    ok "容器内 docker 调用成功 —— 「一键更新」可用 ✅"
    SOCK_WORKS=1
  else
    warn "容器内 docker 输出未识别："
    printf '        %s\n' "$probe"
    SOCK_WORKS=0
  fi

  # ------------------------------ 结论 ----------------------------------------
  printf '\n'
  banner "结论"
  if [ "${SOCK_WORKS:-0}" = "1" ]; then
    printf '%s  ✅ 「一键更新」已可用。无需操作。%s\n' "$G" "$N"
    printf '     在面板「设置 → 系统更新」即可看到按钮生效。\n'
    printf '     想关闭：%s off\n\n' "$0"
    return 0
  fi

  if [ "${SOCK_MOUNTED:-0}" = "0" ]; then
    printf '%s  ⚠️  套接字没挂载 —— 先按上面提示在 compose 里补 volumes 那行。%s\n' "$Y" "$N"
    printf '     补完执行：cd %s && docker compose up -d --force-recreate %s\n\n' "$MG_DIR" "$MG_CONTAINER"
    return 1
  fi

  if [ "${HAS_ROOT:-0}" = "1" ]; then
    printf '%s  ⚠️  容器已是 root 却调不通 docker —— 检查镜像里有没有 docker CLI。%s\n\n' "$Y" "$N"
    return 1
  fi

  if [ -z "$hostgid" ]; then
    printf '%s  ⚠️  拿不到宿主 docker 组 GID，无法自动补组。%s\n\n' "$Y" "$N"
    return 1
  fi

  printf '%s  可行：套接字已挂载，但容器 uid=%s 非 root 且不在 docker 组。%s\n' "$Y" "${uid:-?}" "$N"
  printf '        补一行 group_add（GID=%s）即可让已挂的套接字生效：\n' "$hostgid"
  printf '        %s on\n\n' "$0"
  printf '  ⚠️  开启前请确认：这台机器是自用测试机吗？面板有没有暴露过公网？\n'
  printf '     开启 = 把宿主 root 权限交给面板容器（详见脚本头部说明）。\n\n'
  return 1
}

# ------------------------------ 前提校验 --------------------------------------
precheck() {
  [ "$(id -u)" -eq 0 ] || die "请用 root 运行（需要改 compose 与 docker 操作）"
  command -v docker >/dev/null 2>&1 || die "宿主机没有 docker"
  [ -f "$COMPOSE_FILE" ] || die "找不到 $COMPOSE_FILE（用 WB_MANAGER_DIR 指定面板目录）"
  docker inspect "$MG_CONTAINER" >/dev/null 2>&1 || die "面板容器 $MG_CONTAINER 不存在"
}

# ------------------------------ 写入 group_add --------------------------------
# 用 python 精确插入/移除，避免 sed 破坏 YAML 结构
write_group_add() {
  local action="$1" gid="$2"
  python3 - "$COMPOSE_FILE" "$action" "$gid" <<'PYEOF'
import re, sys

path, action, gid = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding="utf-8").read()

# 已存在则在原处替换 GID，保证多次执行幂等
existing = re.search(r'^([ \t]*)group_add:\n(?:[ \t]*-[^\n]*\n)+', s, re.M)

if action == "on":
    if existing:
        indent = existing.group(1)
        block = '%sgroup_add:\n%s  - "%s"\n' % (indent, indent, gid)
        s = s[:existing.start()] + block + s[existing.end():]
        print("UPDATED")     # 已有 group_add，只更新 GID
    else:
        anchor = "      - /var/run/docker.sock:/var/run/docker.sock\n"
        if anchor not in s:
            print("ERR_NO_ANCHOR")
            sys.exit(2)
        addition = (
            anchor
            + "\n"
            + "    # docker 组权限：套接字属主 root:docker(%s) 660，本容器 uid=10001\n" % gid
            + "    # 既非 root 也不在 docker 组 → 挂上了却报 permission denied（界面\n"
            + "    # 会误显示成「未挂载 docker.sock」）。补组权限让已挂的套接字生效。\n"
            + "    # 关闭方式：同目录 open-docker-ctl.sh off\n"
            + "    group_add:\n"
            + '      - "%s"\n' % gid
        )
        s = s.replace(anchor, addition, 1)
        print("ADDED")
elif action == "off":
    if not existing:
        print("ALREADY_OFF")
        sys.exit(0)
    # ON 在 socket 行之后插入了「空行 + 4 行注释 + group_add + 其子项」。
    # OFF 需要精确反向：删掉 group_add 块，再向前吃掉本脚本的 4 行注释，
    # 以及注释之前、插入时一并带入的那一个空行。
    markers = ("docker 组权限", "既非 root 也不在 docker 组",
               "会误显示成", "关闭方式：同目录 open-docker-ctl.sh")
    start = existing.start()
    lines = s[:start].split("\n")
    # lines[-1] 是 group_add 行前那个换行产生的空尾元素，先去掉
    if lines and lines[-1] == "":
        lines.pop()
    # 从尾部吃掉本脚本插入的 4 行注释
    while lines and re.match(r'^\s*#', lines[-1]) \
            and any(m in lines[-1] for m in markers):
        lines.pop()
    # 再吃掉 ON 插入时一并带入的那一个空行，并还原原文件
    # 「socket 行之后本来就有一个空行」的留白
    if lines and lines[-1].strip() == "":
        lines.pop()
        head = "\n".join(lines) + "\n\n"
        head = head[:-1]      # 末尾换行交由 tail 开头的那一个补足
    else:
        head = "\n".join(lines)   # 形态异常（非本脚本插入）则不强行补
    tail = s[existing.end():]
    s = head + tail
    s = head + tail
    # 清掉可能留下的连续空行（3+ 换行压成 2）
    s = re.sub(r'\n{3,}', '\n\n', s)
    print("REMOVED")
else:
    print("ERR_ACTION")
    sys.exit(2)

open(path, "w", encoding="utf-8").write(s)
PYEOF
}

# ------------------------------ 开关主逻辑 ------------------------------------
do_toggle() {
  local action="$1"
  precheck

  local gid
  gid="$(getent group docker 2>/dev/null | cut -d: -f3)"
  if [ "$action" = "on" ]; then
    [ -n "$gid" ] || die "拿不到宿主 docker 组 GID（getent group docker 为空）—— 无法开启"
    banner "开启面板 docker 控制能力  (docker 组 GID=$gid)"
  else
    banner "关闭面板 docker 控制能力"
    gid="${gid:-995}"
  fi

  # 备份
  local bk="$COMPOSE_FILE.bak-$(date +%F-%H%M%S)"
  cp "$COMPOSE_FILE" "$bk" || die "备份失败，已中止"
  ok "已备份：$bk"

  # 改写
  local res
  res="$(write_group_add "$action" "$gid")" || {
    err "改写 compose 失败：$res"
    inf "正在回滚..."
    cp "$bk" "$COMPOSE_FILE" && warn "已回滚到原文件"
    exit 1
  }
  case "$res" in
    ADDED)       ok "已写入 group_add" ;;
    UPDATED)     ok "group_add 已存在，GID 更新为 $gid" ;;
    REMOVED)     ok "已移除 group_add" ;;
    ALREADY_OFF) ok "本来就没有 group_add，无需改动" ;;
    *)           warn "改写结果：$res" ;;
  esac

  # 校验 YAML 仍然合法（有 python yaml 就校验，没有就跳过）
  if python3 -c "import yaml" 2>/dev/null; then
    if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1],encoding='utf-8'))" "$COMPOSE_FILE" 2>/dev/null; then
      ok "YAML 语法校验通过"
    else
      err "YAML 语法校验失败！正在回滚..."
      cp "$bk" "$COMPOSE_FILE" && warn "已回滚" && exit 1
    fi
  else
    warn "（未装 pyyaml，跳过 YAML 校验）"
  fi

  # 重建
  inf "重建面板容器（force-recreate；绝不用 down，避免误删匿名卷）..."
  ( cd "$MG_DIR" && docker compose up -d --force-recreate "$MG_CONTAINER" ) \
    || { err "重建失败，可用 $bk 回滚"; exit 1; }
  ok "容器已重建"

  inf "等待 8s 让服务就绪..."
  sleep 8

  # 复验
  printf '\n'
  do_status
}

# ------------------------------ 入口 ------------------------------------------
case "${1:-status}" in
  status|"") do_status ;;
  on)        do_toggle on ;;
  off)       do_toggle off ;;
  -h|--help|help) usage ;;
  *) die "未知参数：$1（用 --help 查看用法）" ;;
esac
