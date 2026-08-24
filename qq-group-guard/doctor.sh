#!/bin/sh
# qq-group-guard 连接诊断 —— 在 VPS 上运行，判断 OneBot 端是否就绪
echo "=============================================="
echo " OneBot 连接诊断"
echo "=============================================="

CONF=/etc/qq-group-guard/config.json
if [ -f "$CONF" ]; then
  BASE=$(python3 -c "import json;print(json.load(open('$CONF'))['api_base'])" 2>/dev/null)
  echo "配置里的地址：$BASE"
else
  BASE="http://127.0.0.1:5700"
  echo "未找到配置，用默认：$BASE"
fi
PORT=$(echo "$BASE" | sed 's|.*:||; s|/.*||')
echo

echo "--- ① 有没有程序在监听该端口 ---"
if command -v ss >/dev/null 2>&1; then
  ss -tlnp 2>/dev/null | grep -E ":$PORT\b" && echo "✔ 端口有程序监听" \
    || echo "✘ 端口 $PORT 无人监听  ← 这就是 Connection refused 的原因"
else
  netstat -tlnp 2>/dev/null | grep -E ":$PORT\b" && echo "✔ 有监听" \
    || echo "✘ 端口 $PORT 无人监听"
fi
echo

echo "--- ② 系统里有没有装 QQ 机器人 ---"
FOUND=0
for n in napcat NapCatQQ go-cqhttp Lagrange.OneBot LLOneBot shamrock; do
  if command -v "$n" >/dev/null 2>&1; then echo "  ✔ 找到命令：$n"; FOUND=1; fi
done
for d in /opt/napcat /opt/QQ /root/napcat /opt/go-cqhttp /root/go-cqhttp \
         /opt/Lagrange /root/Lagrange /opt/LLOneBot; do
  [ -d "$d" ] && { echo "  ✔ 找到目录：$d"; FOUND=1; }
done
if command -v systemctl >/dev/null 2>&1; then
  systemctl list-units --type=service --all 2>/dev/null \
    | grep -iE 'napcat|cqhttp|lagrange|onebot|llonebot' \
    && FOUND=1
fi
if command -v docker >/dev/null 2>&1; then
  echo "  Docker 容器："
  docker ps -a --format '    {{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null \
    | grep -iE 'napcat|cqhttp|lagrange|onebot' && FOUND=1 || echo "    （无相关容器）"
fi
[ "$FOUND" = "0" ] && echo "  ✘ 没有发现任何 QQ 机器人程序  ← 需要先装一个"
echo

echo "--- ③ 所有监听中的端口（看有没有别的端口开着 OneBot）---"
if command -v ss >/dev/null 2>&1; then
  ss -tlnp 2>/dev/null | awk 'NR>1{print "    "$4"  "$6}' | head -20
fi
echo

echo "--- ④ 尝试直接请求（若装在别的端口，可改这里）---"
for p in 5700 3000 6099 8080 5800; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 2 \
         -X POST "http://127.0.0.1:$p/get_login_info" 2>/dev/null)
  case "$code" in
    000) echo "    :$p  无响应" ;;
    *)   echo "    :$p  HTTP $code  ← 这个端口有东西！" ;;
  esac
done
echo
echo "=============================================="
echo " 结论"
echo "=============================================="
echo " qq-group-guard 只是「调用方」，它需要一个正在运行的"
echo " OneBot v11 机器人（NapCat / go-cqhttp / Lagrange）"
echo " 提供 HTTP 接口。上面 ① 若显示无人监听，就是还没装机器人。"
