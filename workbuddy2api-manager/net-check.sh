#!/bin/sh
# 网关容器出网测试 —— 这是关键：网关必须能连上腾讯才能转发请求
echo "═══ 1. 网关容器能否出网（对比面板）═══"
docker exec workbuddy2api sh -c '
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import urllib.request
for u in [\"https://copilot.tencent.com\",\"https://www.codebuddy.cn\",\"https://www.baidu.com\"]:
    try:
        r=urllib.request.urlopen(u,timeout=8); print(u,\"->\",r.status)
    except Exception as e:
        print(u,\"-> 失败:\",type(e).__name__,str(e)[:80])
"
  else
    echo "(容器内无 python3，用 wget 测)"
    wget -qO- -T 8 https://www.baidu.com >/dev/null && echo "baidu OK" || echo "baidu 失败"
  fi
'

echo
echo "═══ 2. 面板当前能否连上网关 ═══"
docker exec workbuddy-manager python3 -c "
import urllib.request
try:
    r=urllib.request.urlopen('http://127.0.0.1:17863/healthz',timeout=5)
    print('网关 /healthz ->', r.read().decode()[:80])
except Exception as e:
    print('连不上:', type(e).__name__, e)
"

echo
echo "═══ 3. 两个容器各在哪个网络 ═══"
for n in workbuddy2api workbuddy-manager; do
  echo -n "$n: "
  docker inspect "$n" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}({{$v.IPAddress}}) {{end}}' 2>/dev/null
  echo
done

echo
echo "═══ 4. 已有的 docker 网络列表 ═══"
docker network ls

echo
echo "═══ 5. 面板是否已恢复正常（宿主机角度）═══"
curl -s -o /dev/null -w 'panel /api/healthz: %{http_code}\n' http://127.0.0.1:17864/api/healthz
curl -s -o /dev/null -w 'gateway /healthz  : %{http_code}\n' http://127.0.0.1:17863/healthz

echo
echo "═══ 6. 完整 MASQUERADE 规则（不止前 5 行）═══"
iptables -t nat -L POSTROUTING -n -v
