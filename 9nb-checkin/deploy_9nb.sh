#!/bin/sh
# 9NB.DE 签到 —— VPS 一键部署脚本
# 用法：sh deploy_9nb.sh
set -e

echo "=== 9NB.DE 签到 VPS 部署 ==="

# 1. 检查 python3
if ! command -v python3 >/dev/null 2>&1; then
  echo "[1/4] 安装 python3..."
  if command -v apt >/dev/null 2>&1; then
    apt update -qq && apt install -y python3
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3
  else
    echo "请手动安装 python3"; exit 1
  fi
else
  echo "[1/4] python3 已存在：$(python3 -V)"
fi

# 2. 下载脚本
TARGET=/root/9nb_checkin.py
echo "[2/4] 下载签到脚本到 $TARGET"
if [ -f ./9nb_checkin_vps.py ]; then
  cp ./9nb_checkin_vps.py "$TARGET"
else
  curl -fsSL -o "$TARGET" \
    https://raw.githubusercontent.com/onshine/ScriptHubs/main/9nb-checkin/9nb_checkin_vps.py
fi
chmod +x "$TARGET"
python3 -m py_compile "$TARGET" && echo "    语法检查通过"

# 3. 提示填写账号
echo "[3/4] 请编辑账号："
echo "    vi $TARGET"
echo "    找到 ACCOUNTS = [ ... ] 填写用户名和密码"

# 4. 安装 crontab
echo "[4/4] 配置定时任务（每天 08:00）"
CRON_LINE="0 8 * * * /usr/bin/python3 $TARGET >> /var/log/9nb.log 2>&1"
if crontab -l 2>/dev/null | grep -qF "$TARGET"; then
  echo "    已存在定时任务，跳过"
else
  (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
  echo "    已添加：$CRON_LINE"
fi

cat <<'EOF'

=== 部署完成 ===

接下来：
1. 编辑脚本填写账号：
     vi /root/9nb_checkin.py

2. 先测试登录（不签到）：
     python3 /root/9nb_checkin.py --dry-run

   看到「登录态有效 ✅」说明账号密码正确。

3. 正式跑一次：
     python3 /root/9nb_checkin.py

4. 查看定时任务：
     crontab -l

5. 查看日志：
     tail -f /var/log/9nb.log

如果第 2 步显示「登录失败」，把输出贴出来，多半是站点登录接口结构需要微调。
EOF
