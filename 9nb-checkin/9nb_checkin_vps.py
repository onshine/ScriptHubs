#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
9NB.DE 多账号自动签到（VPS 版）

为什么需要 VPS 版：
  Loon 无法对 9nb.de 完成 MITM 解密（该站走 Cloudflare，解密后响应损坏，
  Safari 表现为"下载文件 document"）。而 9NB 登录成功/失败都返回 302，
  且 Set-Cookie 只挂在 302 那一跳，Loon 的 $httpClient / $task.fetch 都会
  强制跟随重定向从而丢失 bbs_auth。本脚本用 Python 直连，手工处理 302，
  可稳定拿到会话 Cookie。

用法：
  1. 填写下面的 ACCOUNTS
  2. 先跑一次 dry-run 确认能登录：  python3 9nb_checkin.py --dry-run
  3. 正式签到：                      python3 9nb_checkin.py
  4. 加 crontab（每天 08:00）：
     0 8 * * * /usr/bin/python3 /root/9nb_checkin.py >> /var/log/9nb.log 2>&1
"""

import argparse
import json
import os
import random
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://9nb.de"
CHECKIN_PATH = "/nb_checkin"
# 签到模式：random=试试手气(1~15分)，fixed=直接签到(+5分)
CHECKIN_MODE = "random"
UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")

# ============ 配置区：填写你的账号 ============
# 支持多条，格式 ("用户名", "密码")
ACCOUNTS = [
    # ("user1", "你的密码"),
    # ("user2", "你的密码"),
    # ("user3", "你的密码"),
]

# 账号之间随机等待的秒数范围（避免同 IP 短时间多次登录）
JITTER_RANGE = (0, 300)

# Cookie 缓存文件：登录成功后保存，避免每次都重新登录
COOKIE_FILE = os.path.expanduser("~/.9nb_cookies.json")

# 通知（可选）：留空则只打印，不发推送。
# 推荐用环境变量配置，避免把密钥写进代码：
#   BARK_URL           Bark 推送地址，例如 https://api.day.app/你的Key
#   TG_BOT_TOKEN       Telegram 机器人 token
#   TG_CHAT_ID         Telegram 接收者 chat id
BARK_URL = os.environ.get("BARK_URL", "")
TG_BOT_TOKEN = os.environ.get("TG_BOT_TOKEN", "")
TG_CHAT_ID = os.environ.get("TG_CHAT_ID", "")
# 是否每次都推送（否则仅在签到/异常时才推）
NOTIFY_ALWAYS = os.environ.get("NOTIFY_ALWAYS", "1") not in ("0", "false", "False")
# =============================================


def build_opener():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None  # 关键：不跟随 302，才能读到 Set-Cookie

    op = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(context=ctx))
    return op


def raw_request(op, url, method="GET", cookie="", body=None, referer=None):
    """返回 (status, headers, text)，不跟随重定向。"""
    headers = {"User-Agent": UA, "Accept": "text/html,application/xhtml+xml,*/*;q=0.8"}
    if cookie:
        headers["Cookie"] = cookie
    if referer:
        headers["Referer"] = referer
    data = None
    if body is not None:
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        data = body.encode() if isinstance(body, str) else body
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        r = op.open(req, timeout=25)
        return r.status, r.headers, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read().decode("utf-8", "replace")


COOKIE_ATTRS = {"expires", "max-age", "path", "domain", "samesite", "secure", "httponly", "version", "comment"}


def collect_cookies(headers, prev=""):
    """合并 Set-Cookie 与已有 Cookie。

    注意：Set-Cookie 之间用逗号分隔，而 expires 的值里本身含逗号
    （Mon, 21 Sep 2026 ...），因此不能按逗号拆分，必须逐个头解析。
    """
    jar = {}
    for item in re.split(r";\s*", prev or ""):
        if "=" in item:
            k, v = item.split("=", 1)
            k = k.strip()
            if k and k.lower() not in COOKIE_ATTRS:
                jar[k] = v.strip()
    for raw in (headers.get_all("Set-Cookie") or []):
        # 有些服务端会把多条 Set-Cookie 合并为一个头，用 ", xxx=" 形式连接。
        parts = re.split(r",\s*(?=[A-Za-z0-9_\-.#]+\s*=)", raw)
        for part in parts:
            first = part.split(";", 1)[0]  # 只取 name=value，忽略属性段
            if "=" not in first:
                continue
            k, v = first.split("=", 1)
            k, v = k.strip(), v.strip()
            if not k or k.lower() in COOKIE_ATTRS:
                continue
            if v and v.lower() != "deleted":
                jar[k] = v
    return "; ".join(f"{k}={v}" for k, v in jar.items())


def get_cookie_names(cookie):
    return ",".join(k for k in (x.split("=")[0].strip() for x in (cookie or "").split(";") if "=" in x))


def decode_form_error(headers):
    """登录失败时 __form_error 是 base64({"message":"..."})。"""
    for raw in (headers.get_all("Set-Cookie") or []):
        m = re.search(r"__form_error=([^;,\s]+)", raw)
        if m:
            try:
                import base64
                js = base64.b64decode(urllib.parse.unquote(m.group(1))).decode("utf-8", "replace")
                return json.loads(js).get("message", "")
            except Exception:
                return ""
    return ""


def login(op, username, password, verbose=True):
    """返回 (cookie, error)。"""
    if verbose:
        print(f"[{username}] 1/4 GET /login")
    status, headers, html = raw_request(op, BASE + "/login")
    if verbose:
        print(f"[{username}] 2/4 HTTP={status}，Cookie={get_cookie_names(collect_cookies(headers)) or '无'}")
    csrf = (re.search(r'name="_csrf" value="([^"]+)"', html) or [None, ""])[1]
    if not csrf:
        return "", "登录页未找到 CSRF（站点结构可能已变化）"
    init_cookie = collect_cookies(headers)
    if verbose:
        print(f"[{username}] 3/4 CSRF=已获取，准备 POST /login")

    body = urllib.parse.urlencode({"_csrf": csrf, "username": username, "password": password})
    status, headers, html = raw_request(op, BASE + "/login", "POST", init_cookie, body, BASE + "/login")
    cookie = collect_cookies(headers, init_cookie)
    location = headers.get("Location", "") or ""
    if verbose:
        print(f"[{username}] 4/4 POST HTTP={status}，Location={location or '无'}，Cookie={get_cookie_names(cookie) or '无'}")

    if "/form_error" in location or "__form_error" in str(headers.get_all("Set-Cookie")):
        return "", decode_form_error(headers) or "用户名或密码错误"

    if "bbs_auth=" not in cookie:
        # 有些情况下成功但 Location 为空，用 Cookie 验证
        if status in (301, 302, 303, 307, 308) and "bbs_csrf=" in cookie:
            return "", f"登录未返回 bbs_auth（HTTP {status}，Location={location or '无'}）"
        return "", f"登录响应未返回 Cookie（HTTP {status}）"
    return cookie, ""


def is_login_page(text):
    """判断是否被踢回登录页。

    注意：签到页本身也含 name="_csrf"（签到表单），因此不能只看 csrf。
    真正的登录页特征是密码输入框 / 登录标题。
    """
    if not text:
        return False
    if 'name="password"' in text or "type=\"password\"" in text:
        return True
    if "请登录后发帖" in text and "退出登录" not in text:
        return True
    if "<title>登录" in text or "<title> 登录" in text:
        return True
    return False


def extract_username(text):
    """从页面里识别登录用户名（用于确认登录的是哪个账号）。"""
    m = re.search(r'<a[^>]*href="/user/(\d+)"[^>]*>([^<]{2,30})</a>', text)
    if m:
        return m.group(2).strip()
    m = re.search(r"退出登录[^A-Za-z0-9\u4e00-\u9fa5]{0,20}([A-Za-z0-9_\u4e00-\u9fa5]{2,20})", text)
    return m.group(1).strip() if m else ""


def extract_points(text):
    """抓取用户积分。签到页侧栏形如：<div class="nb-checkin-drawer-rank">庶民 · 积分 200</div>"""
    patterns = [
        r'积分\s*</?[^>]*>?\s*(\d+)',
        r"积分\s*(\d+)",
        r"（?积分\s*[:：]?\s*(\d+)",
        r"(\d+)\s*积分",
    ]
    for p in patterns:
        m = re.search(p, text)
        if m:
            return m.group(1)
    return ""


def extract_reward(text):
    """从签到结果页提取本次获得的积分，例如 '签到成功，获得 8 积分'。"""
    patterns = [
        r"获得\s*(\d+)\s*积分",
        r"奖励\s*(\d+)\s*积分",
        r"签到成功[^0-9]{0,20}(\d+)\s*积分",
        r"(\d+)\s*积分",
    ]
    for p in patterns:
        m = re.search(p, text)
        if m:
            return m.group(1) + "积分"
    return ""


def checkin(op, username, cookie, verbose=True):
    """访问签到入口并提交。返回结果文案。"""
    status, headers, html = raw_request(op, BASE + CHECKIN_PATH, cookie=cookie)
    location = headers.get("Location", "") or ""
    if verbose:
        print(f"[{username}] 访问 {CHECKIN_PATH}：HTTP={status}，"
              f"Location={location or '无'}，长度={len(html)}，"
              f"Cookie={get_cookie_names(cookie)}")
    if status in (301, 302, 303):
        # 未登录访问 /nb_checkin 会 302 回 /login
        return None, f"Cookie 已失效（跳转 {location}），需重新登录"
    if is_login_page(html):
        return None, f"Cookie 已失效（返回登录页，HTTP={status}，长度={len(html)}），需重新登录"

    who = extract_username(html)
    if verbose:
        print(f"[{username}] 登录态确认：{who or '已登录'}")

    done = bool(re.search(r"今日已签到|今日已经签到|已完成签到|nb-checkin-entry-done|明日再来", html))
    if done:
        return {"message": "今天已经签到", "reward": "无（已签到）", "points": extract_points(html)}, ""

    csrf = (re.search(r'name="_csrf"\s+value="([^"]+)"', html)
            or re.search(r'tokenValue\s*=\s*"([^"]+)"', html)
            or [None, ""])[1]
    if not csrf:
        return None, "签到页未找到 CSRF，无法提交"

    # 实测签到表单：POST /nb_checkin  _csrf=<token>  mode=random|fixed
    # 服务器返回 302（空 body），所以奖励金额改由调用方用积分差值回填。
    body = urllib.parse.urlencode({"_csrf": csrf, "mode": CHECKIN_MODE})
    st, hd, resp = raw_request(op, BASE + CHECKIN_PATH, "POST", cookie, body, BASE + CHECKIN_PATH)
    text = re.sub(r"<[^>]+>", " ", resp)
    text = re.sub(r"\s+", " ", text).strip()

    if re.search(r"错误|失败|异常", text) and "签到成功" not in text:
        return None, f"签到失败：{text[:120]}"
    reward = extract_reward(text)
    if verbose:
        if text:
            print(f"[{username}] 签到响应：{text[:150]}")
        else:
            print(f"[{username}] 签到已提交（HTTP={st}），以积分变化为准")
    return {"message": "签到成功", "reward": reward, "points": extract_points(text)}, ""


def load_cookies():
    if os.path.exists(COOKIE_FILE):
        try:
            with open(COOKIE_FILE, encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def save_cookies(data):
    try:
        with open(COOKIE_FILE, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        os.chmod(COOKIE_FILE, 0o600)
    except Exception as e:
        print(f"警告：Cookie 保存失败 {e}")


def notify(title, content):
    """发送通知到 Bark 与 Telegram（配了哪个发哪个）。"""
    sent = []
    if BARK_URL:
        if send_bark(title, content):
            sent.append("Bark")
    if TG_BOT_TOKEN and TG_CHAT_ID:
        if send_telegram(title, content):
            sent.append("Telegram")
    return sent


def send_bark(title, content):
    base = BARK_URL.rstrip("/")
    payload = {
        "title": title,
        "body": content,
        "group": "9NB签到",
        "icon": "https://9nb.de/favicon.ico",
        "level": "active",
    }
    # 部分 Bark 服务端/CDN 会拦截 Python-urllib 的默认 UA，必须伪装。
    hdr = {"User-Agent": UA, "Accept": "application/json, text/plain, */*"}
    errors = []
    # 1) GET /{title}/{body}（兼容性最好）
    try:
        url = f"{base}/{urllib.parse.quote(title)}/{urllib.parse.quote(content[:400])}"
        req = urllib.request.Request(url, headers=hdr)
        with urllib.request.urlopen(req, timeout=15) as r:
            body = r.read().decode("utf-8", "replace")
        if _bark_ok(body):
            return True
        errors.append(f"GET 返回 {body[:120]}")
    except Exception as e:
        errors.append(f"GET {e}")
    # 2) POST /push  JSON（支持长文本）
    try:
        req = urllib.request.Request(
            f"{base}/push",
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers=dict(hdr, **{"Content-Type": "application/json; charset=utf-8"}),
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=15) as r:
            body = r.read().decode("utf-8", "replace")
        if _bark_ok(body):
            return True
        errors.append(f"POST 返回 {body[:120]}")
    except Exception as e:
        errors.append(f"POST {e}")
    print("⚠️ Bark 推送失败：" + "；".join(errors))
    return False


def _bark_ok(body):
    """Bark 成功时返回 {"code":200,...}；部分自建服务返回纯文本 1 或 success。"""
    text = (body or "").strip()
    if not text:
        return False
    try:
        return json.loads(text).get("code") == 200
    except Exception:
        return text in ("1", "success", "ok") or "success" in text.lower()


def send_telegram(title, content):
    url = f"https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage"
    payload = {
        "chat_id": TG_CHAT_ID,
        "text": f"*{title}*\n{content}",
        "parse_mode": "Markdown",
        "disable_web_page_preview": True,
    }
    try:
        req = urllib.request.Request(
            url,
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={"Content-Type": "application/json; charset=utf-8", "User-Agent": UA},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=15) as r:
            body = json.loads(r.read().decode("utf-8", "replace"))
        if body.get("ok"):
            return True
        print(f"⚠️ Telegram 推送失败：{body.get('description', body)}")
    except Exception as e:
        print(f"⚠️ Telegram 推送失败：{e}")
    return False


def parse_accounts(raw):
    """解析 '账号:密码|账号:密码' 或每行一条。"""
    items = []
    for chunk in re.split(r"[|\n]", raw or ""):
        chunk = chunk.strip()
        if not chunk or ":" not in chunk:
            continue
        name, pwd = chunk.split(":", 1)
        name, pwd = name.strip(), pwd.strip()
        if name and pwd:
            items.append((name, pwd))
    return items


ACCOUNTS_FILE = os.path.expanduser("~/.9nb_accounts")


def load_accounts_file():
    if not os.path.exists(ACCOUNTS_FILE):
        return []
    try:
        with open(ACCOUNTS_FILE, encoding="utf-8") as f:
            return parse_accounts(f.read())
    except Exception:
        return []


def save_accounts_file(accounts):
    d = os.path.dirname(ACCOUNTS_FILE)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    with open(ACCOUNTS_FILE, "w", encoding="utf-8") as f:
        for name, pwd in accounts:
            f.write(f"{name}:{pwd}\n")
    os.chmod(ACCOUNTS_FILE, 0o600)


def cmd_add(spec):
    accounts = load_accounts_file()
    added = parse_accounts(spec)
    if not added:
        print("错误：格式应为 用户名:密码")
        return 1
    for name, pwd in added:
        accounts = [(u, p) for u, p in accounts if u != name]
        accounts.append((name, pwd))
        print(f"已保存账号：{name}")
    save_accounts_file(accounts)
    print(f"账号文件：{ACCOUNTS_FILE}（共 {len(accounts)} 个账号）")
    return 0


def cmd_list():
    accounts = load_accounts_file()
    if not accounts:
        print("尚未保存任何账号")
        return 0
    print(f"已保存 {len(accounts)} 个账号（{ACCOUNTS_FILE}）：")
    for i, (name, pwd) in enumerate(accounts, 1):
        print(f"  {i}. {name}  密码长度 {len(pwd)}")
    return 0


def cmd_del(username):
    accounts = load_accounts_file()
    left = [(u, p) for u, p in accounts if u != username]
    if len(left) == len(accounts):
        print(f"未找到账号：{username}")
        return 1
    save_accounts_file(left)
    print(f"已删除账号：{username}（剩余 {len(left)} 个）")
    return 0


def main():
    ap = argparse.ArgumentParser(description="9NB.DE 自动签到")
    ap.add_argument("--dry-run", action="store_true", help="只测试登录，不签到")
    ap.add_argument("--no-jitter", action="store_true", help="账号间不随机等待")
    ap.add_argument("--account", help="只处理指定账号")
    ap.add_argument("--add", metavar="用户名:密码", help="保存一个账号到配置文件")
    ap.add_argument("--list", action="store_true", help="列出已保存的账号")
    ap.add_argument("--del-account", metavar="用户名", help="删除指定账号")
    ap.add_argument("--from-env", action="store_true", help="从环境变量 NINE_NB_ACCOUNTS 读取账号")
    ap.add_argument("--test-notify", action="store_true", help="只测试通知推送是否配置正确")
    args = ap.parse_args()

    # 管理账号，不必编辑脚本
    if args.add:
        return cmd_add(args.add)
    if args.list:
        return cmd_list()
    if args.del_account:
        return cmd_del(args.del_account)
    if args.test_notify:
        ch = notify("9NB签到测试", "如果你看到这条消息，说明推送配置正确。")
        if ch:
            print(f"✅ 推送成功：{', '.join(ch)}")
            return 0
        print("❌ 未发送任何推送。请检查环境变量 BARK_URL 或 TG_BOT_TOKEN + TG_CHAT_ID")
        return 1

    # 账号来源优先级：环境变量 > 命令行参数 > 配置文件 > 脚本内 ACCOUNTS
    accounts = []
    if args.from_env or os.environ.get("NINE_NB_ACCOUNTS"):
        raw = os.environ.get("NINE_NB_ACCOUNTS", "")
        accounts = parse_accounts(raw)
        if not accounts:
            print("错误：环境变量 NINE_NB_ACCOUNTS 为空或格式不正确")
            return 1
    if not accounts:
        accounts = load_accounts_file()
    if not accounts:
        accounts = [(u, p) for u, p in ACCOUNTS]
    if not accounts:
        print("错误：没有配置任何账号。可用以下任一方式：")
        print("  1) python3 9nb_checkin.py --add user1:你的密码")
        print("  2) NINE_NB_ACCOUNTS='user1:密码|user2:密码' python3 9nb_checkin.py")
        print("  3) 编辑脚本里的 ACCOUNTS 列表（记得去掉行首的 # ）")
        return 1

    if args.account:
        accounts = [a for a in accounts if a[0] == args.account]
        if not accounts:
            print(f"错误：未找到账号 {args.account}")
            return 1

    op = build_opener()
    cached = load_cookies()
    results = []

    for i, (username, password) in enumerate(accounts):
        print(f"\n===== 账号 {i + 1}/{len(accounts)}：{username} =====")
        if i > 0 and not args.no_jitter:
            wait = random.randint(*JITTER_RANGE)
            print(f"[{username}] 随机等待 {wait} 秒...")
            time.sleep(wait)

        cookie = cached.get(username, {}).get("cookie", "")
        if cookie and "bbs_auth=" in cookie:
            print(f"[{username}] 使用已保存 Cookie：{get_cookie_names(cookie)}")
        else:
            print(f"[{username}] 无有效 Cookie，执行登录")
            cookie, err = login(op, username, password)
            if err:
                line = f"{username}：登录失败 - {err}"
                print(f"❌ {line}")
                results.append(line)
                break  # 登录失败通常是整体问题，停止后续
            cached[username] = {"cookie": cookie, "updated_at": int(time.time())}
            save_cookies(cached)
            print(f"[{username}] 登录成功，Cookie 已保存：{get_cookie_names(cookie)}")

        if args.dry_run:
            status, headers, html = raw_request(op, BASE + "/", cookie=cookie)
            who = extract_username(html)
            ok = not is_login_page(html)
            print(f"[{username}] dry-run：HTTP={status}，识别用户={who or '未识别'}，"
                  f"{'登录态有效 ✅' if ok else 'Cookie 无效 ❌'}")
            results.append(f"{username}：登录正常（{who or '用户未识别'}）" if ok else f"{username}：Cookie 无效")
            continue

        # 签到前先记录积分，签到后对比，避免"假成功"。
        before = ""
        st, hd, page0 = raw_request(op, BASE + CHECKIN_PATH, cookie=cookie)
        if st == 200 and not is_login_page(page0):
            before = extract_points(page0)

        res, err = checkin(op, username, cookie)
        if err:
            # Cookie 失效则重新登录一次
            print(f"[{username}] {err}，尝试重新登录")
            cookie, lerr = login(op, username, password)
            if lerr:
                line = f"{username}：{err}；重新登录失败 - {lerr}"
                print(f"❌ {line}")
                results.append(line)
                continue
            cached[username] = {"cookie": cookie, "updated_at": int(time.time())}
            save_cookies(cached)
            res, err = checkin(op, username, cookie)
            if err:
                line = f"{username}：{err}"
                print(f"❌ {line}")
                results.append(line)
                continue

        after = res.get("points") or ""
        if not after:
            st, hd, page1 = raw_request(op, BASE + CHECKIN_PATH, cookie=cookie)
            if st == 200:
                after = extract_points(page1)

        # 积分对比：只有真的变了才算签到生效。
        delta = ""
        reward = res.get("reward") or ""
        if before.isdigit() and after.isdigit():
            d = int(after) - int(before)
            if d > 0:
                delta = f"（+{d}）"
                if not reward:
                    reward = f"{d}积分"
            elif res["message"] == "今天已经签到":
                delta = ""
                if not reward:
                    reward = "无（已签到）"
            else:
                delta = "（未增加 ⚠️）"

        line = (f"{username}：{res['message']}；"
                f"奖励：{reward or '未知'}；"
                f"积分：{after or before or '未知'}{delta}")
        print(f"✅ {line}")
        results.append(line)

    summary = "9NB签到结果\n" + "\n".join(results)
    print("\n" + summary)

    # 推送内容：逐账号结果 + 汇总统计
    ok = sum(1 for r in results if "失败" not in r)
    total_gain = 0
    for r in results:
        m = re.search(r"（\+(\d+)）", r)
        if m:
            total_gain += int(m.group(1))
    failed = len(results) - ok
    head = f"✅ 成功 {ok}/{len(results)}"
    if total_gain:
        head += f"，共获得 {total_gain} 积分"
    if failed:
        head += f"，失败 {failed}"
    push_body = head + "\n" + "\n".join(results)
    notify("9NB签到", push_body)
    return 0 if not any("失败" in r or "❌" in r for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
