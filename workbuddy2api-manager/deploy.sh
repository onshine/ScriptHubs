#!/usr/bin/env sh
# ─────────────────────────────────────────────────────────────
# 兼容外壳 —— 本目录主脚本已更名为 workbuddy2api.sh
#
# 保留这个文件是为了让已经习惯旧命令的人不受影响：
#     ./deploy.sh status        ← 旧命令，仍然可用
#     ./workbuddy2api.sh status ← 新命令，推荐使用
#
# 本文件不再包含任何逻辑，只做参数透传。
# 想删掉它也可以，但那会让旧命令失效 —— 建议留着（体积可忽略）。
# ─────────────────────────────────────────────────────────────
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ ! -f "$DIR/workbuddy2api.sh" ]; then
  echo "错误：找不到 $DIR/workbuddy2api.sh" >&2
  echo "请重新拉取本目录（README 里有下载命令）。" >&2
  exit 1
fi

exec sh "$DIR/workbuddy2api.sh" "$@"
