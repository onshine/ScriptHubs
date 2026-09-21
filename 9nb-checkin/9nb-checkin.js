/*
 * 9NB.DE 多账号自动登录签到
 * 版本: 2026-09-15.r2.22.0
 * 默认每天 08:00 执行；账号去重；账号间随机等待 0-5 分钟。
 * 账号密码仅用于 Loon 本地登录，不会上传或输出密码。
 */

const SCRIPT_VERSION = "2026-09-15.r2.22.0";
const NAME = "9NB签到";
const BASE = "https://9nb.de";
const STORE_KEY = "9nb_checkin_browser_cookies";
const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1";

(async () => {
  try {
    if (typeof $request !== "undefined" && $request) return captureCookie();
    const input = readArgument();
    const accounts = loadAccounts(input);
    console.log(`[参数] 读取到${accounts.length}个账号配置`);
    if (!accounts.length) throw new Error("未读取到账号。请在Argument填写：账号:密码|账号:密码；例如：武则天:密码|LOL:密码");
    const results = [];
    for (let i = 0; i < accounts.length; i++) {
      console.log(`账号${i + 1}（${accounts[i].username}）开始处理`);
      if (i > 0) {
        const wait = randomInt(0, 300);
        console.log(`账号${i + 1}将在${wait}秒后签到`);
        await sleep(wait * 1000);
      }
      try {
        const r = await runAccount(accounts[i]);
        const line = `账号${i + 1}（${r.username}）：${r.message}；奖励：${r.reward}；余额：${r.balance}`;
        console.log(line);
        results.push(line);
      } catch (e) {
        const line = `账号${i + 1}（${accounts[i].username}）：失败 - ${e && e.message ? e.message : String(e)}`;
        console.log(line);
        results.push(line);
        if (/登录|Cookie/.test(line)) {
          console.log("登录失败，停止后续账号，避免继续等待并产生误导");
          break;
        }
      }
    }
    finish("9NB签到结果", results.join("\n"), results.some(x => /失败/.test(x)));
  } catch (e) {
    finish("签到失败", e && e.message ? e.message : String(e), true);
  }
})().finally(() => { if (typeof $done === "function") $done(); });

function readArgument() {
  // Loon 3.5 可能注入 object、JSON string、数组，个别情况下直接注入账号字符串。
  let a = typeof $argument !== "undefined" ? $argument : undefined;
  if ((a === undefined || a === null || a === "") && typeof $arguments !== "undefined") a = $arguments;
  if (Array.isArray(a)) {
    const objects = a.filter(x => x && typeof x === "object" && !Array.isArray(x));
    if (objects.length) a = Object.assign({}, ...objects);
    else {
      const parts = [];
      for (let i = 0; i < a.length; i += 2) {
        const username = String(a[i] || "").trim();
        const password = String(a[i + 1] || "");
        if (username) parts.push(username + ":" + password);
      }
      return parts.join("|");
    }
  }
  if (typeof a === "string") {
    const raw = a.trim();
    if (!raw) return {};
    try { a = JSON.parse(raw); } catch (_) { return {accounts: raw}; }
    if (Array.isArray(a)) {
      const objects = a.filter(x => x && typeof x === "object" && !Array.isArray(x));
      if (objects.length) a = Object.assign({}, ...objects);
      else {
        const parts = [];
        for (let i = 0; i < a.length; i += 2) {
          const username = String(a[i] || "").trim();
          const password = String(a[i + 1] || "");
          if (username) parts.push(username + ":" + password);
        }
        return {accounts: parts.join("|")};
      }
    }
  }
  if (typeof a === "string") return {accounts: a.trim()};
  if (!a || typeof a !== "object") return "";
  const parts = [];
  for (let i = 1; i <= 5; i++) {
    const username = String(a[`account${i}`] || "").trim();
    const password = String(a[`password${i}`] || "");
    if (username) parts.push(username + ":" + password);
  }
  return (parts.join("|") || a.accounts || a.account || a.cookies || a.cookie || a.value || "").trim();
}

function loadAccounts(raw) {
  const saved = typeof $persistentStore !== "undefined" ? parseJSON($persistentStore.read(STORE_KEY), {}) : {};
  const savedList = Object.keys(saved).map(k => saved[k]).filter(x => x && x.cookie);
  const list = [];
  if (!raw) Object.keys(saved).forEach((key, i) => { const x = saved[key]; if (x && x.cookie) list.push({username: x.username || `账号${i + 1}`, cookie: x.cookie, password: ""}); });
  if (raw) raw.split(/[|\n]+/).map(x => x.trim()).filter(Boolean).forEach((item, index) => {
    const p = item.indexOf(":");
    if (p <= 0) return;
    const username = item.slice(0, p).trim();
    const value = item.slice(p + 1).trim();
    if (!username || list.some(x => x.username === username)) return;
    if (/(?:^|[; ]+)bbs_auth=/.test(value)) list.push({username, cookie: value, password: ""});
    else list.push({username, cookie: "", password: value});
  });
  const seen = new Set();
  return list.filter(x => { const key = x.username + "\u001f" + (x.cookie || ""); if (seen.has(key)) return false; seen.add(key); return true; });
}

async function runAccount(account) {
  let cookie = account.cookie || "";
  console.log(`[${account.username}] 通过Argument账号密码开始处理，忽略旧Cookie=${cookie ? "是" : "否"}`);
  if (account.password) {
    console.log(`[${account.username}] 使用Argument密码模拟登录`);
    cookie = await login(account.username, account.password);
    saveAccount(account.username, cookie);
    console.log(`[${account.username}] 模拟登录成功，Cookie已保存`);
  }
  if (!cookie) throw new Error("没有Cookie且未提供密码");
  console.log(`[${account.username}] 使用Cookie：${cookieNames(cookie)}`);
  console.log(`[${account.username}] GET /nb_checkin 验证登录状态`);
  let page = await request("GET", BASE + "/nb_checkin", cookie);
  console.log(`[${account.username}] 签到页登录状态=${isLoginPage(page) ? "未登录" : "已登录"}`);
  if (isLoginPage(page)) {
    if (!account.password) throw new Error("Cookie已失效，请重新登录该账号并再次打开签到页");
    console.log(`[${account.username}] Cookie失效，使用Argument密码重新登录`);
    cookie = await login(account.username, account.password);
    saveAccount(account.username, cookie);
    page = await request("GET", BASE + "/nb_checkin", cookie);
  }
  if (isLoginPage(page)) throw new Error("登录后验证仍失败，请检查账号密码");
  const beforeBalance = extractBalance(page);
  const buttons = checkinButtons(page);
  console.log(`[${account.username}] 签到按钮：${buttons || "今日已签到或页面未提供按钮"}`);
  const csrf = extractCsrf(page);
  if (!/今日已签到|今日已经签到|已完成签到/.test(page) && !csrf) throw new Error("签到页未找到动态CSRF");
  let message = "今天已经签到";
  let reward = "无（已签到）";
  if (!/今日已签到|今日已经签到|已完成签到/.test(page)) {
    console.log(`[${account.username}] 执行试试手气签到 mode=random`);
    const result = await request("POST", BASE + "/nb_checkin", cookie, `_csrf=${encodeURIComponent(csrf)}&mode=random`);
    const text = stripHtml(result).replace(/\s+/g, " ").trim();
    if (isLoginPage(text)) throw new Error("Cookie已失效");
    if (/错误|失败|异常/.test(text) && !/签到成功/.test(text)) throw new Error(text.slice(0, 120));
    message = "签到成功";
    reward = extractReward(text) || "5积分（直接签到）";
  }
  const after = await request("GET", BASE + "/nb_checkin", cookie);
  const balance = extractBalance(after) || beforeBalance || "未知";
  return {username: account.username, message, reward, balance};
}

async function login(username, password) {
  console.log(`[${username}] 1/6 GET /login`);
  const first = await requestResponse("GET", BASE + "/login", "");
  console.log(`[${username}] 2/6 登录页HTTP=${first.status || "未知"}，响应Cookie=${cookieHeaderNames(first.headers) || "无"}`);
  const csrf = extractCsrf(first.body);
  console.log(`[${username}] 3/6 登录页CSRF=${csrf ? "已获取" : "未获取"}`);
  if (!csrf) throw new Error("登录页未找到CSRF");
  const initialCookie = mergeCookies(first.headers, "");
  console.log(`[${username}] 4/6 准备POST /login，初始Cookie=${cookieNames(initialCookie) || "无"}`);
  const body = `_csrf=${encodeURIComponent(csrf)}&username=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}`;
  // 9NB 登录成功/失败均为 302：成功 → / ，失败 → /form_error。
  // 必须不跟随重定向，否则 Loon 会丢掉 302 那一跳的 Set-Cookie（bbs_auth）。
  const response = await requestResponse("POST", BASE + "/login", initialCookie, body, false);
  console.log(`[${username}] 5/6 登录POST HTTP=${response.status || "未知"}，响应Cookie=${cookieHeaderNames(response.headers) || "无"}`);
  const location = headerValue(response.headers, "location");
  const errCookie = headerValue(response.headers, "set-cookie") || "";
  let cookie = mergeCookies(response.headers, initialCookie);
  if (!/bbs_auth=/.test(cookie) && /__form_error=/.test(errCookie)) {
    // 失败跳转会带 __form_error，其 base64 内容里是站点返回的中文原因。
    const reason = decodeFormError(errCookie);
    throw new Error(`登录被站点拒绝：${reason || "用户名或密码错误"}${location ? "（跳转 " + location + "）" : ""}`);
  }
  if (!/bbs_auth=/.test(cookie) && /form_error/.test(location)) {
    const page = await request("GET", BASE + "/form_error", mergeCookies(response.headers, initialCookie));
    const detail = stripHtml(page).replace(/\s+/g, " ").trim();
    const m = detail.match(/操作失败[^。]{0,80}/);
    throw new Error(`登录被站点拒绝：${m ? m[0].trim() : "用户名或密码错误"}`);
  }
  console.log(`[${username}] 6/6 合并Cookie=${cookieNames(cookie) || "无"}`);
  if (!/bbs_auth=/.test(cookie)) {
    const raw = String(response.body || "").replace(/\s+/g, " ").slice(0, 300);
    console.log(`[${username}] 登录未成功，响应片段=${raw || "空"}`);
    throw new Error(`登录响应未返回Cookie${response.status ? "（HTTP " + response.status + "）" : ""}${location ? "，跳转 " + location : ""}`);
  }
  const verify = await request("GET", BASE + "/nb_checkin", cookie);
  if (isLoginPage(verify)) throw new Error("账号密码不正确或登录被拒绝");
  return cookie;
}

function saveAccount(username, cookie) {
  if (typeof $persistentStore === "undefined") return;
  const all = parseJSON($persistentStore.read(STORE_KEY), {});
  all[username] = {cookie, updatedAt: Date.now()};
  $persistentStore.write(JSON.stringify(all), STORE_KEY);
}
function captureCookie() {
  const url = String($request.url || "");
  if (!/9nb\.de\/(?:login|nb_checkin)(?:[/?]|$)/i.test(url)) return;
  const h = $request.headers || {};
  const cookie = h.Cookie || h.cookie || "";
  if (!cookie || !/bbs_auth=/.test(cookie)) return;
  console.log(`[捕获] 检测到登录Cookie：${cookieNames(cookie)}，准备保存`);
  const all = typeof $persistentStore !== "undefined" ? parseJSON($persistentStore.read(STORE_KEY), {}) : {};
  const auth = (cookie.match(/(?:^|;\s*)bbs_auth=([^;]+)/i) || [])[1];
  if (!auth) return;
  const key = "auth_" + auth;
  if (!all[key]) {
    all[key] = {username: "账号" + (Object.keys(all).length + 1), cookie, updatedAt: Date.now()};
    if (typeof $persistentStore !== "undefined") $persistentStore.write(JSON.stringify(all), STORE_KEY);
    console.log(`[捕获] 已保存9NB登录Cookie，当前共${Object.keys(all).length}个账号`);
  } else {
    all[key].cookie = cookie;
    all[key].updatedAt = Date.now();
    if (typeof $persistentStore !== "undefined") $persistentStore.write(JSON.stringify(all), STORE_KEY);
    console.log(`[捕获] 已更新已有账号Cookie，当前共${Object.keys(all).length}个账号`);
  }
}
function extractCsrf(html) {
  const m = String(html).match(/name=["']_csrf["'][^>]*value=["']([^"']+)/i) || String(html).match(/value=["']([^"']+)["'][^>]*name=["']_csrf/i);
  return m ? m[1] : "";
}
function extractReward(text) { return (String(text).match(/(?:获得|奖励|积分)[^。\n]{0,30}/) || [""])[0].trim(); }
function extractBalance(html) {
  const text = stripHtml(html).replace(/\s+/g, " ");
  const m = text.match(/(?:积分|points?)\s*[:：]?\s*(\d[\d,]*)/i) || text.match(/积分\s*(\d[\d,]*)/);
  return m ? m[1] + "积分" : "";
}
function isLoginPage(text) { return /登录|用户名|密码/.test(stripHtml(text)) && !/今日还未签到|累计签到|签到成功/.test(stripHtml(text)); }
function mergeCookies(headers, old) {
  const out = {};
  String(old || "").split(";").forEach(x => { const p = x.trim().split("="); if (p.length > 1) out[p[0]] = p.slice(1).join("="); });
  const values = cookieHeaderValues(headers);
  values.forEach(raw => {
    // HTTP/2 下 set-cookie 可能是单个字符串、数组或被逗号拼接；逐个 bbs_* 提取，不依赖逗号切分。
    const str = String(raw);
    const re = /(?:^|[;,\s])(bbs_csrf|bbs_auth|bbs_session|bbs_session_id|session|PHPSESSID)\s*=\s*([^;,\s]+)/gi;
    let m;
    while ((m = re.exec(str)) !== null) {
      const name = m[1];
      const value = m[2];
      if (value && value.toLowerCase() !== "deleted") out[name] = value;
    }
  });
  return Object.keys(out).map(k => `${k}=${out[k]}`).join("; ");
}
function cookieHeaderValues(headers) {
  if (!headers) return [];
  const keys = Object.keys(headers).filter(k => k.toLowerCase() === "set-cookie");
  if (!keys.length) return [];
  const raw = keys.map(k => headers[k]).reduce((acc, v) => acc.concat(Array.isArray(v) ? v : [v]), []);
  return raw.map(x => String(x)).filter(Boolean);
}
function checkinButtons(html) {
  const s = String(html);
  const fixed = /name=["']mode["'][^>]*value=["']fixed["']/i.test(s);
  const random = /name=["']mode["'][^>]*value=["']random["']/i.test(s);
  return [fixed ? "直接签到+5" : "", random ? "试试手气" : ""].filter(Boolean).join("、");
}
function cookieNames(cookie) { return String(cookie || "").split(";").map(x => x.trim().split("=")[0]).filter(Boolean).join(","); }
function cookieHeaderNames(headers) {
  return cookieHeaderValues(headers).map(x => String(x).match(/^\s*([^=;]+)/)).filter(Boolean).map(x => x[1]).join(",");
}
function headerValue(headers, name) {
  if (!headers) return "";
  const key = Object.keys(headers).find(k => k.toLowerCase() === name.toLowerCase());
  if (!key) return "";
  const v = headers[key];
  return String(Array.isArray(v) ? v[0] : v || "");
}
// 9NB 登录失败时下发 __form_error=base64({"message":"用户名或密码错误",...})
function decodeFormError(setCookieRaw) {
  const m = String(setCookieRaw).match(/__form_error=([^;,\s]+)/i);
  if (!m) return "";
  try {
    let b64 = decodeURIComponent(m[1]);
    // atob 返回 Latin-1 字符串，中文需按 UTF-8 字节还原。
    let bin = "";
    if (typeof atob === "function") bin = atob(b64);
    else if (typeof Buffer !== "undefined") bin = Buffer.from(b64, "base64").toString("binary");
    else return "";
    const bytes = [];
    for (let i = 0; i < bin.length; i++) bytes.push(bin.charCodeAt(i) & 0xff);
    let json = "";
    if (typeof TextDecoder !== "undefined") {
      try { json = new TextDecoder("utf-8").decode(new Uint8Array(bytes)); } catch (_) { json = ""; }
    }
    if (!json) {
      json = bytes.map(b => (b < 0x80 ? String.fromCharCode(b) : "%" + b.toString(16).padStart(2, "0"))).join("");
      try { json = decodeURIComponent(json); } catch (_) { json = ""; }
    }
    const obj = JSON.parse(json);
    return obj && obj.message ? String(obj.message) : "";
  } catch (_) {
    return "";
  }
}
function stripHtml(s) { return String(s).replace(/<script[\s\S]*?<\/script>/gi, "").replace(/<style[\s\S]*?<\/style>/gi, "").replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " "); }
function parseJSON(s, fallback) { try { return s ? JSON.parse(s) : fallback; } catch (_) { return fallback; } }
function randomInt(a, b) { return Math.floor(Math.random() * (b - a + 1)) + a; }
function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }
function finish(title, body, bad) { console.log((bad ? "❌ " : "✅ ") + title + "：\n" + body); if (typeof $notification !== "undefined") $notification.post(NAME, title, body); }
function request(method, url, cookie, body) { return requestResponse(method, url, cookie, body).then(x => x.body); }
function requestResponse(method, url, cookie, body, followRedirect = true) {
  return new Promise((resolve, reject) => {
    const headers = {"User-Agent": UA, "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", "Referer": method === "POST" && /\/login$/.test(url) ? BASE + "/login" : BASE + "/nb_checkin", "Origin": BASE, "Cookie": cookie || "", "Content-Type": "application/x-www-form-urlencoded"};
    const opts = {url, headers, body};
    if (followRedirect === false) opts.followRedirect = false;
    const cb = (err, resp, data) => err ? reject(err) : resolve({body: data || "", headers: resp && resp.headers ? resp.headers : {}, status: resp && (resp.status || resp.statusCode) ? (resp.status || resp.statusCode) : 0});
    if (typeof $httpClient !== "undefined") return method === "GET" ? $httpClient.get(opts, cb) : $httpClient.post(opts, cb);
    if (typeof $task !== "undefined") return $task.fetch({url, method, headers, body}).then(r => resolve({body: r.body || "", headers: r.headers || {}, status: r.statusCode || 0})).catch(reject);
    reject(new Error("不支持的脚本环境"));
  });
}
