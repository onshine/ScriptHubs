#!/bin/sh
# gemini-web2api 代理池体检 R1.4.1
# 逐个测试池中代理能否连通 Google，可选自动禁用坏的
#
# 用法（主控机上跑）：
#   ./checkproxy.sh              只体检，打印结果
#   ./checkproxy.sh --disable    体检并自动禁用连不上 Google 的代理
#
# 仓库：https://github.com/onshine/ScriptHubs/tree/main/gemini-web2api
set -e
SCRIPT_VERSION="R1.4.1"
DIR="/opt/gemini-web2api"

[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }
[ -f "$DIR/.credentials" ] || { echo "找不到 $DIR/.credentials，请先跑 install.sh"; exit 1; }
. "$DIR/.credentials"
[ -n "$PORT" ] || PORT=8084
API="http://127.0.0.1:$PORT/admin/api/proxies"
AUTH="Authorization: Bearer $ADMIN_TOKEN"

DISABLE=0
[ "$1" = "--disable" ] && DISABLE=1

echo "=== 代理池体检 $SCRIPT_VERSION ==="
RAW=$(curl -s -H "$AUTH" "$API")
[ -n "$RAW" ] || { echo "无法读取代理池，检查服务是否运行"; exit 1; }

# 用 python3 解析 JSON（比 sed 可靠）
if ! command -v python3 >/dev/null 2>&1; then
  echo "需要 python3 解析结果：apt install -y python3"; exit 1
fi

echo "$RAW" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for it in d.get("items",[]):
    print("%s\t%s\t%s\t%s" % (it.get("id"), it.get("name","?"), it.get("url",""), it.get("enabled")))
' > /tmp/gwproxies.txt

TOTAL=$(wc -l < /tmp/gwproxies.txt)
echo "共 $TOTAL 个代理，开始逐个测试（每个最多 25 秒）"
echo

OK=0; BAD=0
while IFS="$(printf '\t')" read -r ID NAME URL EN; do
  [ -n "$URL" ] || continue
  printf "%-18s " "$NAME"
  # 1) 出口 IP
  IP=$(curl -s --max-time 12 --proxy "$URL" https://api64.ipify.org 2>/dev/null || echo "")
  if [ -z "$IP" ]; then
    echo "❌ 代理不通（服务挂了/密码错/端口未放行）"
    BAD=$((BAD+1))
    [ "$DISABLE" = "1" ] && curl -s -X POST -H "$AUTH" "$API/$ID/toggle" >/dev/null 2>&1
    continue
  fi
  # 2) Google 连通性
  CODE=$(curl -s --max-time 20 --proxy "$URL" -o /dev/null -w '%{http_code}' \
         https://gemini.google.com/ 2>/dev/null || echo 000)
  case "$CODE" in
    2*|3*)
      case "$IP" in
        *:*) echo "✅ v6 出口 $IP  Google=$CODE" ;;
        *)   echo "✅ v4 出口 $IP  Google=$CODE" ;;
      esac
      OK=$((OK+1)) ;;
    000)
      echo "❌ 出口 $IP 能上网，但连不上 Google"
      BAD=$((BAD+1))
      [ "$DISABLE" = "1" ] && curl -s -X POST -H "$AUTH" "$API/$ID/toggle" >/dev/null 2>&1 ;;
    *)
      echo "⚠️ 出口 $IP  Google 返回 $CODE（可能被风控）"
      BAD=$((BAD+1)) ;;
  esac
done < /tmp/gwproxies.txt
rm -f /tmp/gwproxies.txt

echo
echo "=============================================="
echo "  可用: $OK   有问题: $BAD   共: $TOTAL"
if [ "$BAD" -gt 0 ] && [ "$DISABLE" != "1" ]; then
  echo "  自动禁用坏代理: ./checkproxy.sh --disable"
fi
if [ "$OK" = "0" ]; then
  echo
  echo "  ⚠️ 没有可用代理！代理池非空时上游不回退直连，"
  echo "     服务会一直失败。请禁用全部坏代理或清空池子："
  echo "     ./checkproxy.sh --disable"
fi
echo "=============================================="
