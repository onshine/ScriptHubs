#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""9NB 签到接口探测器：找出签到组件真正提交的地址与参数。

用法：python3 probe_9nb.py
它会用已保存的 Cookie 登录，然后探测常见签到端点，并打印首页里签到组件
相关的 HTML 片段，供确定真实提交方式。
"""
import os
import re
import ssl
import json
import urllib.parse
import urllib.request

BASE = "https://9nb.de"
UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
      "AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1")
COOKIE_FILE = os.path.expanduser("~/.9nb_cookies.json")

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(opener, url, method="GET", cookie="", body=None, referer=""):
    headers = {"User-Agent": UA, "Accept": "text/html,application/xhtml+xml,*/*"}
    if cookie:
        headers["Cookie"] = cookie
    if referer:
        headers["Referer"] = referer
    data = body.encode() if isinstance(body, str) else body
    if method == "POST":
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with opener.open(req, timeout=25) as r:
            return r.status, dict(r.headers), r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        raw = e.read()
        if e.code in (301, 302, 303, 307, 308):
            raw = b""
        return e.code, dict(e.headers), raw.decode("utf-8", "replace")
    except Exception as e:
        return 0, {}, f"__ERROR__ {type(e).__name__}: {e}"


def main():
    # 读取登录时保存的 Cookie
    cookie = ""
    if os.path.exists(COOKIE_FILE):
        try:
            with open(COOKIE_FILE, encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                for v in data.values():
                    if isinstance(v, str) and "bbs_auth=" in v:
                        cookie = v
                        break
                    if isinstance(v, dict) and "bbs_auth=" in str(v.get("cookie", "")):
                        cookie = v["cookie"]
                        break
        except Exception as e:
            print("读取 Cookie 文件失败:", e)
    if not cookie:
        print("未找到已保存的 Cookie，请先运行: python3 9nb_checkin.py --dry-run")
        return
    print("已加载 Cookie:", ", ".join(p.split("=")[0] for p in cookie.split("; ")))
    print()

    op = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(context=ctx))

    print("=" * 60)
    print("1) 首页里签到组件相关 HTML")
    print("=" * 60)
    st, hd, html = request(op, BASE + "/", cookie=cookie)
    print(f"GET / -> HTTP {st}, {len(html)} 字节")
    for kw in ["nb-checkin", "checkin", "签到", "data-slot"]:
        for m in re.finditer(re.escape(kw), html, re.I):
            seg = html[max(0, m.start() - 200):m.start() + 300]
            seg = re.sub(r"\s+", " ", seg)
            print(f"\n--- 命中 '{kw}' ---\n{seg[:480]}")
            break

    print()
    print("=" * 60)
    print("2) 探测常见签到端点（GET）")
    print("=" * 60)
    paths = ["/nb_checkin", "/checkin", "/signin", "/api/checkin",
             "/api/nb_checkin", "/nb-checkin/checkin", "/check-in",
             "/index.php?c=checkin", "/plugin/checkin", "/sign"]
    for p in paths:
        st, hd, body = request(op, BASE + p, cookie=cookie)
        flag = ""
        if st in (301, 302, 303):
            flag = f" -> {hd.get('Location', '')}"
        elif st == 200 and len(body) > 100:
            flag = f" ({len(body)}字节)"
        print(f"  GET {p:32s} HTTP {st}{flag}")

    print()
    print("=" * 60)
    print("3) 页面里出现的所有 data-* 与 form 信息（找提交目标）")
    print("=" * 60)
    for m in re.finditer(r"<form[^>]*>", html, re.I):
        print("  FORM:", re.sub(r"\s+", " ", m.group(0))[:220])
    attrs = sorted(set(re.findall(r'(data-[a-z0-9-]+)=(?:"[^"]*"|\'[^\']*\')', html, re.I)))
    for a in attrs[:40]:
        print("  DATA:", a[0], "=", a[1][:80])

    print()
    print("=" * 60)
    print("4) 页面内联脚本里出现的 URL / fetch / POST 目标")
    print("=" * 60)
    urls = sorted(set(re.findall(r'["\'](/[a-zA-Z0-9_\-/]{2,40})["\']', html)))
    for u in urls:
        if any(k in u.lower() for k in ["check", "sign", "click", "action", "api", "plugin"]):
            print("  URL:", u)
    print("  (以上为包含 check/sign/api/plugin 等关键词的路径)")

    print()
    print("提示：把以上全部输出贴回给 Minis，即可确定签到接口。")


if __name__ == "__main__":
    main()
