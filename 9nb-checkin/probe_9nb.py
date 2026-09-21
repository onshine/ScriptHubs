#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""9NB 签到接口探测：定位真实的签到 URL、CSRF 与提交参数。

用法：
    1) 先确保已用 9nb_checkin.py 登录并保存 Cookie
    2) python3 probe_9nb.py
输出会保存到 probe_result.txt，直接把这个文件内容发出来即可。
"""
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://9nb.de"
UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
      "AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1")
COOKIE_FILE = os.path.expanduser("~/.9nb_cookies.json")

OUT = []


def log(msg=""):
    print(msg)
    OUT.append(str(msg))


def load_cookie():
    if not os.path.exists(COOKIE_FILE):
        return ""
    try:
        with open(COOKIE_FILE, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return ""
    if isinstance(data, dict):
        for v in data.values():
            if isinstance(v, str) and "bbs_auth=" in v:
                return v
            if isinstance(v, dict) and "cookie" in v:
                return v["cookie"]
    return ""


ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx))


def get(path, cookie):
    req = urllib.request.Request(BASE + path, headers={
        "User-Agent": UA, "Cookie": cookie,
        "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
    })
    try:
        with opener.open(req, timeout=25) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, f"[请求异常] {type(e).__name__}: {e}"


def main():
    cookie = load_cookie()
    log(f"已加载 Cookie：{cookie[:80]}{'...' if len(cookie) > 80 else ''}")
    if not cookie:
        log("未找到 Cookie，请先运行 9nb_checkin.py --dry-run 完成一次登录")
        return 1

    status, home = get("/", cookie)
    log(f"\n首页 HTTP={status}，长度 {len(home)}")
    if "退出登录" not in home and "bbs_auth" not in cookie:
        log("警告：首页看起来未登录，后续结果可能无效")

    # 1) 登录后是否包含签到组件
    log("\n1) 搜索签到组件相关标记")
    keys = ["checkin", "check-in", "签到", "sign_in", "signin", "nb_checkin"]
    for kw in keys:
        n = len(re.findall(re.escape(kw), home, re.I))
        if n:
            log(f"   命中 {kw!r}：{n} 次")

    # 2) 打印签到组件附近的 HTML，这是定位 URL/参数的关键
    log("\n2) 签到相关 HTML 片段（每个关键词最多 3 段，每段 400 字符）")
    shown = 0
    for kw in ["checkin", "签到", "signin"]:
        for m in list(re.finditer(re.escape(kw), home, re.I))[:3]:
            seg = home[max(0, m.start() - 250):m.start() + 350]
            seg = re.sub(r"\s+", " ", seg).strip()
            log(f"   [{kw}] ...{seg}...")
            shown += 1
    if not shown:
        log("   未找到任何签到相关片段")

    # 3) 所有 data-* 属性（组件配置通常在这里）
    log("\n3) 页面中的 data-* 属性（去重，最多 30 条）")
    attrs = sorted(set(re.findall(r'(data-[a-zA-Z0-9_-]+)="([^"]{0,120})"', home)))
    for k, v in attrs[:30]:
        log(f"   {k} = {v}")
    if not attrs:
        log("   无 data-* 属性")

    # 4) 所有 form 及其字段
    log("\n4) 页面中的 form 定义")
    forms = re.findall(r"<form[^>]*>.*?</form>", home, re.S | re.I)
    for i, f in enumerate(forms[:5], 1):
        action = (re.search(r'action="([^"]*)"', f) or [None, "(无)"])[1]
        method = (re.search(r'method="([^"]*)"', f) or [None, "(无)"])[1]
        hidden = re.findall(r'name="([^"]+)"\s+value="([^"]{0,60})"', f)
        log(f"   form{i}: action={action} method={method}")
        for n, v in hidden[:8]:
            log(f"      {n} = {v[:60]}")
    if not forms:
        log("   页面无 form 标签（提交可能由 JS 发起）")

    # 5) 内联脚本里出现的路径
    log("\n5) 内联脚本中的 URL 候选")
    urls = sorted(set(re.findall(r'["\'](/[a-zA-Z0-9_\-/?=&.]{2,60})["\']', home)))
    hot = [u for u in urls if re.search(r"check|sign|api|plugin|user|point|reward|lottery", u, re.I)]
    for u in hot[:25]:
        log(f"   {u}")
    if not hot:
        log("   无匹配候选，全部路径（前 25 条）：")
        for u in urls[:25]:
            log(f"   {u}")

    # 6) 探测常见端点（GET，只判存在性）
    log("\n6) 探测常见签到端点")
    cands = [
        "/nb_checkin", "/nb_checkin/", "/nb-checkin", "/checkin", "/check_in",
        "/signin", "/sign_in", "/api/checkin", "/api/nb_checkin",
        "/plugin/nb_checkin", "/plugins/nb_checkin", "/checkin/index",
    ]
    for p in cands:
        st, body = get(p, cookie)
        mark = "  <== 可能是签到入口" if st == 200 and len(body) > 200 else ""
        log(f"   GET {p:<24} HTTP={st} 长度={len(body)}{mark}")

    # 7) 页面里是否有积分/余额数字（用于后续校验签到是否生效）
    log("\n7) 页面中的积分数值候选")
    for pat in [r"(\d+)\s*积分", r"积分[^0-9]{0,6}(\d+)", r"balance[\"']?\s*[:=]\s*(\d+)"]:
        found = re.findall(pat, home)
        if found:
            log(f"   匹配 {pat!r}：{found[:8]}")

    with open("probe_result.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(OUT))
    log("\n结果已保存到 probe_result.txt，请把该文件内容发出来")
    return 0


if __name__ == "__main__":
    sys.exit(main())
