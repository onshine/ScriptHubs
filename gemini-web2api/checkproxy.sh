#!/bin/sh
# gemini-web2api 代理池体检 R1.8.0
#
# 直接调用上游的 /admin/api/test 接口，与管理面板「连通性诊断」完全同源：
#   走完整协议路径（Chrome146 指纹 + 真 StreamGenerate 生成请求），
#   不消耗限流配额、不写入请求记录。
#
# 用法（主控机上跑）：
#   ./checkproxy.sh              体检全部代理（含直连）
#   ./checkproxy.sh --disable    体检并自动禁用真实调用失败的代理
#
# 仓库：https://github.com/onshine/ScriptHubs/tree/main/gemini-web2api
set -e
SCRIPT_VERSION="R1.8.0"
RAWBASE="https://raw.githubusercontent.com/onshine/ScriptHubs/main/gemini-web2api"
DIR="/opt/gemini-web2api"

[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }
[ -f "$DIR/.credentials" ] || { echo "找不到 $DIR/.credentials，请先部署主控"; exit 1; }
. "$DIR/.credentials"
[ -n "$PORT" ] || PORT=8084
BASE="http://127.0.0.1:$PORT"
AUTH="Authorization: Bearer $ADMIN_TOKEN"

command -v python3 >/dev/null 2>&1 || { echo "需要 python3: apt install -y python3"; exit 1; }

DISABLE=0
[ "$1" = "--disable" ] && DISABLE=1

echo "=== 代理池体检 $SCRIPT_VERSION ==="
echo "（用上游 /admin/api/test，与面板「连通性诊断」同一判据：真实生成请求）"
echo

# 取代理列表
RAW=$(curl -s --max-time 10 -H "$AUTH" "$BASE/admin/api/proxies" 2>/dev/null || echo "")
[ -n "$RAW" ] || { echo "❌ 读不到代理池，检查服务与 ADMIN_TOKEN"; exit 1; }

printf '%s' "$RAW" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
items=d.get("items",[])
for it in items:
    print("%s\t%s\t%s" % (it.get("id"), it.get("name","?"), "1" if it.get("enabled") else "0"))
' > /tmp/gw_proxies.txt || { echo "❌ 代理池 JSON 解析失败"; exit 1; }

TOTAL=$(wc -l < /tmp/gw_proxies.txt | tr -d ' ')

# 单次诊断：$1=proxy_id（0=直连），输出 "status|http_code|ms|reply|diag"
probe() {
  curl -s --max-time 90 -H "$AUTH" "$BASE/admin/api/test?proxy_id=$1" 2>/dev/null \
  | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception:
    print("parse_error|0|0||响应解析失败"); sys.exit()
print("%s|%s|%s|%s|%s" % (
    d.get("status","?"), d.get("http_code",0), d.get("total_ms",0),
    (d.get("response_text") or "").replace("\n"," ")[:40],
    (d.get("diagnostic") or "").replace("\n"," ")[:90]))
'
}

report() {  # $1=名称 $2=probe输出 $3=proxy_id $4=enabled
  _n="$1"; _r="$2"; _id="$3"; _en="$4"
  _st=$(printf '%s' "$_r" | cut -d'|' -f1)
  _hc=$(printf '%s' "$_r" | cut -d'|' -f2)
  _ms=$(printf '%s' "$_r" | cut -d'|' -f3)
  _tx=$(printf '%s' "$_r" | cut -d'|' -f4)
  _dg=$(printf '%s' "$_r" | cut -d'|' -f5)
  _tag=""
  [ "$_en" = "0" ] && _tag=" [已禁用]"
  case "$_st" in
    success)
      printf "  ✅ %-16s %sms  回复:%s%s\n" "$_n" "$_ms" "$_tx" "$_tag"
      OK=$((OK+1)) ;;
    blocked_sorry)
      printf "  🚫 %-16s 已被 Google 风控 (302→/sorry/)，需换 IP%s\n" "$_n" "$_tag"
      BAD=$((BAD+1)); KILL="$KILL $_id" ;;
    rate_limited)
      printf "  ⏳ %-16s 限流中 (HTTP %s)，稍后自动恢复%s\n" "$_n" "$_hc" "$_tag"
      WARN=$((WARN+1)) ;;
    network_error)
      printf "  ❌ %-16s 网络不可达（代理挂了/密码错/路由不通）%s\n" "$_n" "$_tag"
      BAD=$((BAD+1)); KILL="$KILL $_id" ;;
    upstream_error)
      printf "  ⚠️  %-16s 上游拒绝 (HTTP %s)%s\n" "$_n" "$_hc" "$_tag"
      printf "     %s\n" "$_dg"
      BAD=$((BAD+1)); KILL="$KILL $_id" ;;
    *)
      printf "  ⚠️  %-16s 状态=%s HTTP=%s%s\n" "$_n" "$_st" "$_hc" "$_tag"
      printf "     %s\n" "$_dg"
      WARN=$((WARN+1)) ;;
  esac
}

OK=0; BAD=0; WARN=0; KILL=""

if [ "$TOTAL" -gt 0 ]; then
  echo "代理池（$TOTAL 个），每个约 3-5 秒："
  while IFS="$(printf '\t')" read -r ID NAME EN; do
    [ -n "$ID" ] || continue
    report "$NAME" "$(probe "$ID")" "$ID" "$EN"
  done < /tmp/gw_proxies.txt
else
  echo "代理池为空 → 服务走主控本机直连"
fi
rm -f /tmp/gw_proxies.txt

echo
echo "主控直连（proxy_id=0）："
report "本机直连" "$(probe 0)" "" "1"

# 自动禁用
if [ "$DISABLE" = "1" ] && [ -n "$KILL" ]; then
  echo
  echo "禁用失败的代理:"
  for id in $KILL; do
    [ -n "$id" ] || continue
    curl -s --max-time 10 -X POST -H "$AUTH" \
      "$BASE/admin/api/proxies/$id/toggle" >/dev/null 2>&1 && echo "  已禁用 #$id"
  done
fi

echo
echo "=============================================="
echo "  可用: $OK   失败: $BAD   需观察: $WARN"
if [ "$BAD" -gt 0 ] && [ "$DISABLE" != "1" ]; then
  echo "  自动禁用失败项: ./checkproxy.sh --disable"
fi
if [ "$BAD" -gt 0 ] || [ "$WARN" -gt 0 ]; then
  echo
  echo "  🚫 = IP 被 Google 拉黑，等数十分钟~数小时或换 IP（放慢节奏无效）"
  echo "  ⏳ = 该 slot 限流中（并发5/RPM30/RPH80），等等就好"
  echo "  ❌ = 代理本身连不上，检查出口机服务与账号密码"
fi
echo "  提示: 代理池非空时上游不回退直连，池中坏代理会拖垮请求。"
echo "=============================================="
