#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
feifei.py —— 讯飞 AI 学习机「飞飞币」每日自动签到 / 明细查询 / 通知推送

版本：R1.0.7（2026-11-15 R1.0.7：与 Loon 抓包自检修正版对齐；R1.0.0 首个版本）
仓库：https://github.com/onshine/ScriptHubs

特点
  · 纯标准库，无需 pip 安装任何依赖（iSH、NAS、路由器、VPS 都能跑）
  · 多账号、Bark / Telegram / 自定义 Webhook 通知
  · 自动从 HAR 抓包文件或直接粘贴 Token 导入账号
  · 支持 crontab 一键安装，cron 表达式完全自定义
  · 输出「已签到明细」：今日状态、连续签到天数、近 7 天签到图、最近收入记录

用法
  python3 feifei.py sign                       # 每日签到（默认命令）
  python3 feifei.py sign --details 10          # 签到 + 打印最近 10 条收入明细
  python3 feifei.py sign --claim-tasks         # 顺带领取「可领取」的任务奖励
  python3 feifei.py info                       # 只查询，不签到
  python3 feifei.py details 20                 # 查看最近 20 条收入明细
  python3 feifei.py import --har xx.har         # 从抓包文件导入账号
  python3 feifei.py import --token v01_xxx --name 学习机
  python3 feifei.py cron --set "0 8 * * *"     # 安装/更新定时任务（自定义 cron）
  python3 feifei.py cron --show                # 查看当前定时任务
  python3 feifei.py cron --remove              # 移除定时任务
  python3 feifei.py notify-test                # 测试通知通道

配置文件：脚本同目录 config.json（可用 --config 或环境变量 FEIFEI_CONFIG 指定）
"""

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SCRIPT_VERSION = "1.0.7"
API_HOST = "https://api.xunfeixxj.com"
APPID = "H5APP"
UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6_1 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148")
ORIGIN = "https://xxj.xunfei.cn"
CRON_MARK = "# feifei-cron"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFIG = os.path.join(SCRIPT_DIR, "config.json")

EP_SUMMARY = "/aiapp/points/homePage/getPointsAndRemind"
EP_SIGN = "/aiapp/points/sign/insert"
EP_TASKS = "/aiapp/taskCenter/pointsTask/getTaskList"
EP_RECEIVE = "/aiapp/taskCenter/pointsTask/receivePoints"
EP_DETAIL = "/aiapp/points/homePage/getPointsDetailList"


# --------------------------------------------------------------------------- #
# 配置
# --------------------------------------------------------------------------- #
DEFAULT_CONFIG_DATA = {
    "accounts": [],
    "notify": {
        "bark": {"url": "", "group": "飞飞币", "sound": "", "icon": ""},
        "telegram": {"bot_token": "", "chat_id": ""},
        "webhook": {"url": "", "method": "POST"},
        "only_on_error": False,
    },
}


def load_config(path):
    if not os.path.exists(path):
        return json.loads(json.dumps(DEFAULT_CONFIG_DATA))
    with open(path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    base = json.loads(json.dumps(DEFAULT_CONFIG_DATA))
    for k, v in cfg.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            base[k].update(v)
        else:
            base[k] = v
    return base


def save_config(path, cfg):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    try:
        os.chmod(path, 0o600)  # 里面有 token，收紧权限
    except Exception:
        pass


# --------------------------------------------------------------------------- #
# 接口
# --------------------------------------------------------------------------- #
class ApiError(Exception):
    pass


def api(token, path, payload=None, timeout=20):
    """POST 明文模式（不带 ?c=3.0 时服务端接受明文 JSON，无需加密/base 头）"""
    body = json.dumps(payload or {}, separators=(",", ":")).encode()
    req = urllib.request.Request(
        API_HOST + path, data=body, method="POST",
        headers={
            "content-type": "application/json",
            "appid": APPID,
            "authorization": token if token.lower().startswith("bearer ") else "Bearer " + token,
            "accept": "application/json, text/plain, */*",
            "accept-language": "zh-CN,zh-Hans;q=0.9",
            "origin": ORIGIN,
            "referer": ORIGIN + "/",
            "user-agent": UA,
        })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        code = e.code
        body = e.read().decode("utf-8", "replace").strip()
        if code in (401, 482, 483):
            raise ApiError("登录态失效（HTTP %d），请用家长端 App 打开一次飞飞币页面后重新抓取 Token"
                           % code)
        raise ApiError("HTTP %d: %s" % (code, body[:200] or "空响应"))
    except urllib.error.URLError as e:
        raise ApiError("网络错误：%s" % e.reason)
    try:
        js = json.loads(raw)
    except ValueError:
        raise ApiError("响应不是 JSON：%s" % raw[:200])
    if js.get("status") not in (0, None):
        raise ApiError(js.get("msg") or ("接口返回 status=%s" % js.get("status")))
    return js


def get_summary(token):
    return api(token, EP_SUMMARY, {}).get("data") or {}


def get_tasks(token):
    return (api(token, EP_TASKS, {}).get("data") or {}).get("taskList") or []


def do_sign(token):
    return api(token, EP_SIGN, {}).get("data") or {}


def receive_task(token, task_code):
    return api(token, EP_RECEIVE, {"taskCode": task_code})


def get_details(token, n=10):
    data = api(token, EP_DETAIL,
               {"changeType": 1, "pageSize": max(n, 10), "cursor": 0}).get("data") or {}
    return (data.get("detailList") or [])[:n]


# --------------------------------------------------------------------------- #
# 通知
# --------------------------------------------------------------------------- #
def _http_send(url, data=None, headers=None, method=None, timeout=15):
    req = urllib.request.Request(url, data=data, headers=headers or {},
                                 method=method or ("POST" if data else "GET"))
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")[:300]


def notify_bark(cfg, title, content):
    url = (cfg.get("url") or "").strip().rstrip("/")
    if not url:
        return False, "未配置"
    try:
        payload = {"title": title, "body": content, "group": cfg.get("group") or "飞飞币"}
        if cfg.get("sound"):
            payload["sound"] = cfg["sound"]
        if cfg.get("icon"):
            payload["icon"] = cfg["icon"]
        # 兼容官方 api.day.app/KEY 与自建 bark 服务
        target = url if url.endswith("/push") else url + "/push"
        _http_send(target, json.dumps(payload).encode(),
                   {"Content-Type": "application/json; charset=utf-8"})
        return True, "ok"
    except Exception as e:
        return False, str(e)


def notify_telegram(cfg, title, content):
    bot = (cfg.get("bot_token") or "").strip()
    chat = str(cfg.get("chat_id") or "").strip()
    if not bot or not chat:
        return False, "未配置"
    try:
        text = ("*%s*\n%s" % (title, content)).replace(".", "．")
        body = urllib.parse.urlencode({
            "chat_id": chat, "text": text, "parse_mode": "Markdown",
            "disable_web_page_preview": "true",
        }).encode()
        _http_send("https://api.telegram.org/bot%s/sendMessage" % bot, body,
                   {"Content-Type": "application/x-www-form-urlencoded"})
        return True, "ok"
    except Exception as e:
        return False, str(e)


def notify_webhook(cfg, title, content):
    url = (cfg.get("url") or "").strip()
    if not url:
        return False, "未配置"
    try:
        _http_send(url,
                   json.dumps({"title": title, "content": content,
                               "text": title + "\n" + content}).encode(),
                   {"Content-Type": "application/json"}, method=cfg.get("method") or "POST")
        return True, "ok"
    except Exception as e:
        return False, str(e)


def push(cfg, title, content):
    n = cfg.get("notify") or {}
    results = []
    for name, fn in (("bark", notify_bark), ("telegram", notify_telegram),
                     ("webhook", notify_webhook)):
        sub = n.get(name) or {}
        if not sub or not any(str(v).strip() for k, v in sub.items() if k != "group"):
            continue
        ok, msg = fn(sub, title, content)
        results.append((name, ok, msg))
        print("  通知 %-9s %s" % (name, "✅" if ok else "❌ " + msg))
    if not results:
        print("  （未配置任何通知通道，跳过推送）")
    return results


# --------------------------------------------------------------------------- #
# 报文组装
# --------------------------------------------------------------------------- #
def fmt_ts(ms):
    try:
        return time.strftime("%m-%d %H:%M", time.localtime(int(ms) / 1000))
    except Exception:
        return "-"


def sign_board(sign_list):
    """把最近 7 天转成 11-09○ 11-10● 形式"""
    parts = []
    for it in sign_list or []:
        d = str(it.get("dateText") or "")
        if len(d) != 8:
            continue
        mark = "●" if it.get("signState") else "○"
        parts.append("%s-%s%s" % (d[4:6], d[6:8], mark))
    return "  ".join(parts)


def run_account(acc, cfg, args):
    name = acc.get("name") or "默认账号"
    token = (acc.get("token") or "").strip()
    if not token:
        return name, False, "【%s】未配置 Token" % name, "飞飞币签到"

    print("\n▶ %s" % name)
    lines = []
    ok = True
    gained = 0

    before = get_summary(token)
    total_before = before.get("totalPoints", 0)
    signed_today = False
    for it in before.get("signList") or []:
        if it.get("isToday") == 1 and it.get("signState") == 1:
            signed_today = True

    # ---- 签到 ----
    if args.command in ("sign", "run"):
        if signed_today:
            print("  今日已签到")
            lines.append("☑️ 今日已签到")
        else:
            data = do_sign(token)
            gained = int(data.get("points") or 0)
            if gained > 0:
                print("  签到成功 +%d" % gained)
                lines.append("✅ 签到成功 +%d 飞飞币" % gained)
            else:
                print("  签到接口已调用（返回 0 币，可能今日已签或活动未开始）")
                lines.append("ℹ️ 签到接口已调用，返币 0（可能已签到）")
        # ---- 顺手领取可领取任务 ----
        if args.claim_tasks:
            try:
                claimed = []
                for t in get_tasks(token):
                    if t.get("state") == 1:  # 1=可领取
                        try:
                            receive_task(token, t.get("taskCode"))
                            claimed.append("%s +%s" % (t.get("taskTitle"), t.get("taskPoints")))
                            gained += int(t.get("taskPoints") or 0)
                        except ApiError as e:
                            print("  领取「%s」失败：%s" % (t.get("taskTitle"), e))
                if claimed:
                    print("  领取任务：%s" % "、".join(claimed))
                    lines.append("🎁 领取任务：" + "、".join(claimed))
            except ApiError as e:
                print("  任务列表获取失败：%s" % e)

    # ---- 汇总 ----
    after = get_summary(token)
    total = after.get("totalPoints", total_before)
    total_sign = after.get("totalSignDays", 0)
    today_task = after.get("todayTaskPoints", 0)
    print("  飞飞币 %s（今日任务可得 %s，连续签到 %s 天）" % (total, today_task, total_sign))
    if not lines:
        lines.append("ℹ️ 当前飞飞币 %s" % total)
    lines.append("💰 飞飞币：%s（今日任务可得 %s）" % (total, today_task))
    lines.append("📅 连续签到：%s 天" % total_sign)
    board = sign_board(after.get("signList") or before.get("signList"))
    if board:
        lines.append("🗓 " + board)

    # ---- 明细 ----
    n_detail = args.details if args.details is not None else (10 if args.command == "run" else 0)
    if n_detail:
        try:
            details = get_details(token, n_detail)
            if details:
                lines.append("📋 最近明细：")
                for d in details:
                    lines.append("   %s  +%s  %s" % (
                        fmt_ts(d.get("changeTime")), d.get("changePoints"),
                        d.get("changeTitle") or "-"))
        except ApiError as e:
            print("  明细获取失败：%s" % e)

    body = "\n".join(lines)
    title = "飞飞币签到" if args.command in ("sign", "run") else "飞飞币查询"
    return name, ok, "[%s]\n%s" % (name, body), title


# --------------------------------------------------------------------------- #
# HAR 导入
# --------------------------------------------------------------------------- #
def import_from_har(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        har = json.load(f)
    entries = (har.get("log") or {}).get("entries") or []
    token = None
    for e in reversed(entries):  # 取最后一次的 token（最新）
        url = (e.get("request") or {}).get("url") or ""
        if "api.xunfeixxj.com" not in url:
            continue
        for h in (e["request"].get("headers") or []):
            if h.get("name", "").lower() == "authorization" and "v01_" in h.get("value", ""):
                token = h["value"]
                break
        if token:
            break
    if not token:
        raise SystemExit("❌ HAR 里没找到 api.xunfeixxj.com 的 Authorization，请确认抓包覆盖了飞飞币页面")
    return token


def cmd_import(cfg, args, path):
    if args.har:
        token = import_from_har(args.har)
        print("🔍 已从 HAR 提取 Token（%d 字符）" % len(token))
    elif args.token:
        token = args.token.strip()
    else:
        token = input("请粘贴 Authorization（v01_ 开头，可带 Bearer 前缀）：").strip()
    if not token:
        raise SystemExit("❌ Token 为空")
    if not token.lower().startswith("bearer "):
        token = "Bearer " + token

    name = args.name or time.strftime("账号%m%d-%H%M")
    cfg["accounts"] = [a for a in cfg.get("accounts", []) if a.get("name") != name]
    cfg["accounts"].append({"name": name, "token": token, "enabled": True})
    save_config(path, cfg)
    print("✅ 已保存账号「%s」到 %s" % (name, path))

    # 立刻验证
    try:
        s = get_summary(token)
        print("✅ 验证通过：飞飞币 %s，连续签到 %s 天" %
              (s.get("totalPoints"), s.get("totalSignDays")))
    except ApiError as e:
        print("⚠️ 验证失败：%s" % e)


# --------------------------------------------------------------------------- #
# cron
# --------------------------------------------------------------------------- #
def _crontab_read():
    try:
        out = subprocess.run(["crontab", "-l"], capture_output=True, text=True)
        return out.stdout if out.returncode == 0 else ""
    except FileNotFoundError:
        return None


def _crontab_write(text):
    p = subprocess.run(["crontab", "-"], input=text, text=True, capture_output=True)
    if p.returncode != 0:
        raise SystemExit("❌ 写入 crontab 失败：%s" % (p.stderr or p.stdout))


def cmd_cron(args, config_path):
    cur = _crontab_read()
    if cur is None:
        raise SystemExit("❌ 当前环境没有 crontab 命令（iSH 可 apk add busybox-suid；\n"
                         "   iOS 上更推荐用 Minis 定时任务或「快捷指令」自动化）")
    kept = [ln for ln in cur.splitlines() if CRON_MARK not in ln]

    if args.show:
        print("当前 feifei 定时任务：")
        hit = [ln for ln in cur.splitlines() if CRON_MARK in ln]
        print("\n".join(hit) if hit else "  （无）")
        return
    if args.remove:
        _crontab_write("\n".join(kept).strip() + "\n")
        print("✅ 已移除 feifei 定时任务")
        return

    expr = args.set or "0 8 * * *"
    if len(expr.split()) != 5:
        raise SystemExit("❌ cron 表达式必须是 5 段，例如 \"0 8 * * *\"（每天 08:00）")
    py = shutil.which("python3") or "python3"
    log = args.log or os.path.join(SCRIPT_DIR, "feifei.log")
    cmd = '%s %s sign --details 5 >> %s 2>&1' % (
        py, os.path.join(SCRIPT_DIR, "feifei.py"), log)
    if os.path.abspath(config_path) != os.path.abspath(DEFAULT_CONFIG):
        cmd = cmd.replace("sign", "-c %s sign" % config_path, 1)
    line = "%s %s  # feifei-cron 飞飞币每日签到" % (expr, cmd)
    _crontab_write("\n".join(kept + [line]).strip() + "\n")
    print("✅ 已安装定时任务：\n   %s\n   日志：%s" % (line, log))
    print("   提示：crontab 精度只到分钟；若系统时间非东八区，脚本按手机/服务器本地时区判断「今天」。")


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser(
        description="讯飞 AI 学习机 飞飞币 每日自动签到",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("command", nargs="?", default="sign",
                    choices=["sign", "run", "info", "details", "import",
                             "cron", "notify-test"],
                    help="sign=签到（默认） info=查询 details=明细 import=导入账号 cron=定时任务")
    ap.add_argument("-c", "--config", default=os.environ.get("FEIFEI_CONFIG") or DEFAULT_CONFIG)
    ap.add_argument("-a", "--account", help="只处理指定名称的账号")
    ap.add_argument("--details", nargs="?", const=10, type=int, default=None,
                    help="附带最近 N 条收入明细（默认 10）")
    ap.add_argument("--claim-tasks", action="store_true", help="顺带领取「可领取」状态的任务奖励")
    ap.add_argument("--no-notify", action="store_true", help="只打印，不推送")
    ap.add_argument("--token", help="import 用：直接给 Authorization")
    ap.add_argument("--har", help="import 用：从 HAR 抓包文件提取 Token")
    ap.add_argument("--name", help="import 用：账号备注名")
    ap.add_argument("--set", help='cron 用：cron 表达式，如 "0 8 * * *"')
    ap.add_argument("--show", action="store_true", help="cron 用：查看")
    ap.add_argument("--remove", action="store_true", help="cron 用：移除")
    ap.add_argument("--log", help="cron 用：日志文件路径")
    args = ap.parse_args()

    cfg = load_config(args.config)

    if args.command == "import":
        return cmd_import(cfg, args, args.config)
    if args.command == "cron":
        return cmd_cron(args, args.config)

    if args.command == "notify-test":
        print("发送测试通知…")
        push(cfg, "飞飞币通知测试", "如果你看到这条消息，说明通知通道已打通 ✅")
        return

    accounts = [a for a in cfg.get("accounts", []) if a.get("enabled", True)]
    if args.account:
        accounts = [a for a in accounts if a.get("name") == args.account]
    if not accounts:
        raise SystemExit("❌ 没有可用账号。先执行：\n"
                         "   python3 feifei.py import --har 抓包.har\n"
                         "   python3 feifei.py import --token v01_xxxx --name 学习机")

    if args.command == "details":
        args.details = args.details or 20
        args.command = "info"

    msgs, titles, failed = [], set(), 0
    for acc in accounts:
        try:
            r = run_account(acc, cfg, args)
            name, ok, msg, _t = r
            msgs.append(msg)
        except ApiError as e:
            failed += 1
            print("  ❌ %s" % e)
            msgs.append("[%s]\n❌ %s" % (acc.get("name") or "默认账号", e))
        except Exception as e:  # noqa: BLE001
            failed += 1
            print("  ❌ 未预期错误：%r" % e)
            msgs.append("[%s]\n❌ 未预期错误：%r" % (acc.get("name") or "默认账号", e))

    content = "\n\n".join(msgs)
    title = "飞飞币签到" if args.command in ("sign", "run") else "飞飞币查询"
    if failed:
        title += "（%d 个账号异常）" % failed

    # 终端输出
    print("\n" + "=" * 46)
    print(content)
    print("=" * 46)

    only_err = (cfg.get("notify") or {}).get("only_on_error")
    if not args.no_notify and not (only_err and not failed):
        print("\n推送通知：")
        push(cfg, title, content)

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
