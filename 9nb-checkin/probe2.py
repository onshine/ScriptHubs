#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""探测 /nb_checkin 签到页的真实结构：CSRF、表单、提交地址、按钮。"""
import json, os, re, ssl, sys, html as ihtml
import urllib.request, urllib.error, urllib.parse

BASE = "https://9nb.de"
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1"
STOREFILE = os.path.expanduser("~/.9nb_cookies.json")

def get_cookie():
    if not os.path.exists(STOREFILE):
        print("请先运行 9nb_checkin.py --dry-run 完成一次登录"); sys.exit(1)
    data = json.load(open(STOREFILE, encoding="utf-8"))
    if isinstance(data, dict):
        for k, v in data.items():
            if isinstance(v, dict) and v.get("cookie"):
                return v["cookie"]
    print("Cookie 文件格式无法识别：", list(data)[:5] if isinstance(data, dict) else type(data)); sys.exit(1)

ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx))

def fetch(url, cookie, method="GET", data=None):
    headers = {"User-Agent": UA, "Accept": "text/html,*/*", "Cookie": cookie, "Referer": BASE + "/"}
    if data is not None:
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        r = opener.open(req, timeout=25)
        return r.status, r.read().decode("utf-8", "replace"), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), e.headers
    except Exception as e:
        return 0, "", e

cookie = get_cookie()
print("=" * 70)
print("加载 Cookie ...")
print("=" * 70)

status, page, hdrs = fetch(BASE + "/nb_checkin", cookie)
print(f"\nGET /nb_checkin -> HTTP {status}, {len(page)} 字节\n")
if status != 200:
    print("签到页取不到内容，无法继续"); sys.exit(1)

out = open(os.path.expanduser("~/nb_checkin_page.html"), "w", encoding="utf-8")
out.write(page); out.close()
print(f"签到页已保存到 ~/nb_checkin_page.html（{len(page)} 字节）\n")

# 1) 表单
print("1) form 标签")
for m in re.finditer(r"<form[^>]*>", page, re.I):
    print("   " + m.group(0)[:300])
if not re.search(r"<form", page, re.I):
    print("   （无 form，提交由 JS 发起）")

# 2) 隐藏字段 / input
print("\n2) input 字段")
for m in re.finditer(r"<input[^>]*>", page, re.I):
    print("   " + m.group(0)[:250])

# 3) 按钮
print("\n3) button / 签到按钮")
for m in re.finditer(r"<button[^>]*>.*?</button>", page, re.I | re.S):
    print("   " + re.sub(r"\s+", " ", m.group(0))[:300])
for m in re.finditer(r"<a[^>]*nb-checkin[^>]*>", page, re.I):
    print("   A: " + re.sub(r"\s+", " ", m.group(0))[:300])

# 4) CSRF 相关
print("\n4) CSRF 相关片段")
for kw in ["csrf", "CSRF", "token", "nonce"]:
    for m in list(re.finditer(kw, page))[:4]:
        s = max(0, m.start() - 150); e = min(len(page), m.start() + 200)
        seg = re.sub(r"\s+", " ", page[s:e])
        print(f"   [{kw}] ...{seg}...")
        print()

# 5) data-* 属性（签到页专属）
print("5) 签到页 data-* 属性")
seen = set()
for m in re.finditer(r'data-[a-zA-Z0-9_-]+\s*=\s*"[^"]*"', page):
    v = m.group(0)
    if v not in seen:
        seen.add(v)
        print("   " + v[:200])

# 6) 内联脚本里的 URL 与提交逻辑
print("\n6) 内联脚本中的 URL")
urls = set()
for m in re.finditer(r'["\'](/[a-zA-Z0-9_/?=&.-]{2,60})["\']', page):
    u = m.group(1)
    if not re.search(r"\.(css|js|png|jpg|svg|ico|webp|woff2?)$", u, re.I):
        urls.add(u)
for u in sorted(urls):
    print("   " + u)

# 7) 签到状态文案
print("\n7) 签到状态相关文案")
for kw in ["今日已签到", "已经签到", "签到成功", "试试手气", "连续签到", "已连续", "签到"]:
    idxs = [m.start() for m in re.finditer(kw, page)]
    if idxs:
        s = max(0, idxs[0] - 180); e = min(len(page), idxs[0] + 220)
        seg = re.sub(r"\s+", " ", page[s:e])
        print(f"   [{kw}] ...{seg}...")
        print()

# 8) 积分
print("8) 积分数字")
for m in re.finditer(r"积分[^0-9]{0,8}(\d+)", page):
    print("   积分=" + m.group(1))

print("\n完成。请把以上全部输出贴回。")
