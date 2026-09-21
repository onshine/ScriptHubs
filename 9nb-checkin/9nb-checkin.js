/*
 * 9NB.DE 多账号自动登录签到
 * 版本: 2026-09-15.r2.34.0
 * 默认每天 08:00 执行；账号去重；账号间随机等待 0-5 分钟。
 * 账号密码仅用于 Loon 本地登录，不会上传或输出密码。
 */

const SCRIPT_VERSION = "2026-09-15.r2.34.0";
const NAME = "9NB签到";
const BASE = "https://9nb.de";
const STORE_KEY = "9nb_checkin_browser_cookies";
// 签到入口：9NB 的签到组件挂在首页/顶栏，独立 /nb_checkin 路径实测 404。
const CHECKIN_PATH = "/";
// 脚本自身请求是否强制直连（绕开 MITM）。
// 默认 false：走 MITM，使 http-response 规则能拦截脚本发起的 302 并读到 bbs_auth。
// 若总是报 "certificate verify failed"，把它改成 true（此时必须已有捕获的 Cookie）。
const USE_DIRECT = false;
const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1";
// 静态资源后缀：捕获脚本必须立即放行，绝不参与处理，否则会破坏响应导致浏览器下载文件。
const STATIC_EXT = /\.(?:css|js|mjs|json|map|png|jpe?g|gif|webp|avif|svg|ico|bmp|woff2?|ttf|otf|eot|mp3|mp4|webm|ogg|wav|pdf|zip|gz|rar|7z|txt|xml)(?:$|[?#])/i;

(async () => {
  try {
    // 拦截触发（http-request / http-response）优先于 cron，避免误跑签到流程。
    if (typeof $request !== "undefined" && $request) return captureCookie();
    if (typeof $response !== "undefined" && $response) return captureCookie();
    console.log(`[9NB签到] 脚本版本 ${SCRIPT_VERSION}（MITM捕获+DIRECT回退）`);
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
  if (!raw) Object.keys(saved).forEach((key, i) => { const x = saved[key]; if (x && x.cookie && /bbs_auth=/.test(x.cookie)) list.push({username: x.username || `账号${i + 1}`, cookie: x.cookie, password: ""}); });
  if (raw) raw.split(/[|\n]+/).map(x => x.trim()).filter(Boolean).forEach((item, index) => {
    const p = item.indexOf(":");
    if (p <= 0) return;
    const username = item.slice(0, p).trim();
    const value = item.slice(p + 1).trim();
    if (!username || list.some(x => x.username === username)) return;
    if (/(?:^|[; ]+)bbs_auth=/.test(value)) list.push({username, cookie: value, password: ""});
    else {
      // Argument 提供的是密码；同时尝试匹配 MITM 捕获到的同账号 Cookie。
      const captured = Object.keys(saved).map(k => saved[k]).find(x => x && x.cookie && x.username === username);
      list.push({username, cookie: captured ? captured.cookie : "", password: value});
    }
  });
  const seen = new Set();
  return list.filter(x => { const key = x.username + "\u001f" + (x.cookie || ""); if (seen.has(key)) return false; seen.add(key); return true; });
}

async function runAccount(account) {
  let cookie = account.cookie || "";
  // 路线A：优先使用 MITM 捕获到的 Cookie，避免依赖 Loon 拿不到的 302 Set-Cookie。
  if (cookie && /bbs_auth=/.test(cookie)) {
    console.log(`[${account.username}] 使用已捕获Cookie（MITM）：${cookieNames(cookie)}`);
  } else if (account.password) {
    console.log(`[${account.username}] 未找到已捕获Cookie，尝试模拟登录（Loon可能丢失302 Set-Cookie）`);
    try {
      cookie = await login(account.username, account.password);
      // login 返回的 Cookie 可能因 Loon 跟随重定向而缺失 bbs_auth。
      // 此时 http-response 规则已把 302 的 Set-Cookie 存进 store，等它落盘后再读。
      if (!/bbs_auth=/.test(cookie)) {
        const captured = await waitCapturedCookie(account.username, 3000);
        if (captured) {
          console.log(`[${account.username}] 从捕获规则取得完整Cookie：${cookieNames(captured)}`);
          cookie = captured;
        }
      }
      if (/bbs_auth=/.test(cookie)) {
        saveAccount(account.username, cookie);
        console.log(`[${account.username}] 模拟登录成功，Cookie已保存`);
      }
    } catch (e) {
      const captured = await waitCapturedCookie(account.username, 3000);
      if (captured) {
        console.log(`[${account.username}] 登录请求报错，但已从捕获规则取得Cookie：${cookieNames(captured)}`);
        cookie = captured;
        saveAccount(account.username, cookie);
      } else {
        throw new Error(`无可用Cookie，且模拟登录失败：${e && e.message ? e.message : e}`);
      }
    }
  }
  if (!cookie) throw new Error("没有Cookie且未提供密码");
  console.log(`[${account.username}] 使用Cookie：${cookieNames(cookie)}`);
  console.log(`[${account.username}] GET /nb_checkin 验证登录状态`);
  let page = await request("GET", BASE + "/nb_checkin", cookie);
  console.log(`[${account.username}] 签到页登录状态=${isLoginPage(page) ? "未登录" : "已登录"}`);
  if (isLoginPage(page)) {
    if (!account.password) throw new Error("Cookie已失效，请在Loon开启MITM后重新登录9NB以捕获Cookie");
    console.log(`[${account.username}] Cookie失效，使用Argument密码重新登录`);
    cookie = await login(account.username, account.password);
    saveAccount(account.username, cookie);
    page = await request("GET", BASE + CHECKIN_PATH, cookie);
  }
  if (isLoginPage(page)) throw new Error("Cookie已失效或未捕获成功，请在Loon开启MITM后重新登录9NB");
  const beforeBalance = extractBalance(page);
  const buttons = checkinButtons(page);
  console.log(`[${account.username}] 签到按钮：${buttons || "今日已签到或页面未提供按钮"}`);
  const csrf = extractCsrf(page) || account.csrf || "";
  const done = /今日已签到|今日已经签到|已完成签到|nb-checkin-entry-done/.test(page);
  let message = "今天已经签到";
  let reward = "无（已签到）";
  if (!done) {
    if (!csrf) throw new Error("签到页未找到动态CSRF，请确认已登录并可正常访问签到入口");
    console.log(`[${account.username}] 执行试试手气签到（${CHECKIN_PATH}）`);
    const result = await request("POST", BASE + CHECKIN_PATH, cookie, `_csrf=${encodeURIComponent(csrf)}&mode=random`);
    const text = stripHtml(result).replace(/\s+/g, " ").trim();
    if (isLoginPage(text)) throw new Error("Cookie已失效");
    if (/错误|失败|异常/.test(text) && !/签到成功/.test(text)) throw new Error(text.slice(0, 120));
    message = "签到成功";
    reward = extractReward(text) || "5积分（直接签到）";
  }
  const after = await request("GET", BASE + CHECKIN_PATH, cookie);
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
  const response = await loginPost(BASE + "/login", initialCookie, body);
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
    // 兜底：Loon 若跟随了重定向，Set-Cookie 会丢失，但响应体会是登录后的首页，
    // 首页 HTML 中存在用户名/登出入口即可判定登录实际成功。
    const body = String(response.body || "");
    if (/\/logout|退出登录|我的主页|个人资料/.test(body) && !/请登录后发帖/.test(body)) {
      console.log(`[${username}] 未取到bbs_auth，但响应体已是登录态首页，改用Cookie捕获模式继续`);
      throw new Error("登录成功但未取到Cookie：请在Loon中添加9NB的Cookie捕获脚本（MITM https://9nb.de）");
    }
    const raw = body.replace(/\s+/g, " ").slice(0, 300);
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
  const req = typeof $request !== "undefined" && $request ? $request : null;
  const resp = typeof $response !== "undefined" && $response ? $response : null;
  const url = String((req && req.url) || (resp && resp.url) || "");
  // 只监听 9nb.de
  if (!/^https?:\/\/(?:[^/]*\.)?9nb\.de(?:\/|$)/i.test(url)) return;
  // 静态资源立即放行（规则已收窄到 /login，这里是二重保险）。
  if (STATIC_EXT.test(url)) return;
  const h = (req && req.headers) || {};
  const reqCookie = h.Cookie || h.cookie || "";
  const respHeaders = (resp && resp.headers) ? resp.headers : null;
  const respCookie = respHeaders ? cookieHeaderValues(respHeaders).join("; ") : "";
  const merged = mergeCookies(respHeaders || {}, reqCookie);
  const cookie = /bbs_auth=/.test(merged) ? merged : (/bbs_auth=/.test(reqCookie) ? reqCookie : "");
  if (!cookie || !/bbs_auth=/.test(cookie)) {
    if (respCookie || reqCookie) {
      const names = cookieNames(merged || respCookie || reqCookie);
      if (names) console.log(`[捕获] ${url} 未含bbs_auth（${names}），继续监听`);
    } else {
      const st = resp ? (resp.status || resp.statusCode || "?") : "?";
      console.log(`[捕获] ${url} HTTP=${st} 无Cookie，继续监听`);
    }
    return;
  }
  console.log(`[捕获] 检测到登录Cookie：${cookieNames(cookie)}，准备保存`);
  const all = typeof $persistentStore !== "undefined" ? parseJSON($persistentStore.read(STORE_KEY), {}) : {};
  const auth = (cookie.match(/(?:^|;\s*)bbs_auth=([^;]+)/i) || [])[1];
  if (!auth) return;
  const key = "auth_" + auth;
  // 尽量从响应体识别登录用户名，便于与 Argument 中的账号自动对应。
  const body = (resp && resp.body) ? String(resp.body) : "";
  const detected = detectUsername(body);
  if (!all[key]) {
    all[key] = {username: detected || ("账号" + (Object.keys(all).length + 1)), cookie, updatedAt: Date.now()};
    if (typeof $persistentStore !== "undefined") $persistentStore.write(JSON.stringify(all), STORE_KEY);
    console.log(`[捕获] 已保存9NB登录Cookie（${all[key].username}），当前共${Object.keys(all).length}个账号`);
  } else {
    all[key].cookie = cookie;
    if (detected) all[key].username = detected;
    all[key].updatedAt = Date.now();
    if (typeof $persistentStore !== "undefined") $persistentStore.write(JSON.stringify(all), STORE_KEY);
    console.log(`[捕获] 已更新9NB登录Cookie（${all[key].username}），当前共${Object.keys(all).length}个账号`);
  }
}
// 从登录后页面里识别当前用户名（9NB 顶栏/侧栏会渲染用户名与 /user/N 链接）。
function detectUsername(html) {
  if (!html) return "";
  const text = stripHtml(html).replace(/\s+/g, " ");
  const m = text.match(/(?:我的主页|个人资料|退出登录|个人中心)[^A-Za-z0-9\u4e00-\u9fa5]{0,20}([A-Za-z0-9_\u4e00-\u9fa5]{2,20})/);
  if (m) return m[1].trim();
  return "";
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
    // 脚本请求默认走 MITM 出口：这样 http-response 能拦截到自己发起的 302 并读到 Set-Cookie。
    // 若 MITM 导致 TLS 校验失败，可把 USE_DIRECT 改为 true 改为直连（此时需用已捕获的 Cookie）。
    const opts = {url, headers, body};
    if (USE_DIRECT) opts.node = "DIRECT";
    if (followRedirect === false) opts.followRedirect = false;
    const cb = (err, resp, data) => err ? reject(normalizeError(err)) : resolve({body: data || "", headers: resp && resp.headers ? resp.headers : {}, status: resp && (resp.status || resp.statusCode) ? (resp.status || resp.statusCode) : 0});
    if (typeof $httpClient !== "undefined") return method === "GET" ? $httpClient.get(opts, cb) : $httpClient.post(opts, cb);
    if (typeof $task !== "undefined") return $task.fetch({url, method, headers, body}).then(r => resolve({body: r.body || "", headers: r.headers || {}, status: r.statusCode || 0})).catch(e => reject(normalizeError(e)));
    reject(new Error("不支持的脚本环境"));
  });
}
// 把 Loon 冗长的 SSL 报错翻译成可操作的提示。
// 登录后（或登录报错后）轮询 store，等待 http-response 规则把 bbs_auth 写入。
function waitCapturedCookie(username, timeoutMs) {
  return new Promise(resolve => {
    const deadline = Date.now() + timeoutMs;
    const tick = () => {
      const found = findCapturedCookie(username);
      if (found) return resolve(found);
      if (Date.now() >= deadline) return resolve("");
      setTimeout(tick, 300);
    };
    tick();
  });
}
function loadStore() {
  if (typeof $persistentStore === "undefined") return {};
  try {
    return JSON.parse($persistentStore.read(STORE_KEY) || "{}") || {};
  } catch (_) {
    return {};
  }
}
function findCapturedCookie(username) {
  const all = loadStore();
  const vals = Object.keys(all).map(k => all[k]).filter(x => x && x.cookie && /bbs_auth=/.test(x.cookie));
  const byName = vals.find(x => x.username === username);
  return (byName || vals[0] || {}).cookie || "";
}
function normalizeError(err) {
  const msg = String(err && err.message ? err.message : err);
  if (/certificate verify failed|SSL handshake|TLSError/i.test(msg)) {
    return new Error("TLS握手失败：脚本请求被自己的MITM拦截（Loon不支持脚本请求本机MITM的域名）。请关闭9nb.de的MITM后重试，或改用VPS方案。");
  }
  return err instanceof Error ? err : new Error(msg);
}
// Loon 的 $httpClient 可能忽略 followRedirect:false，此时 302 被跟随、Set-Cookie 丢失。
// 用 curl 风格的探测：先原样发一次，若状态变成 200 且响应像首页，则说明重定向被跟随。
async function loginPost(url, cookie, body) {
  const res = await requestResponse("POST", url, cookie, body, false);
  if (res.status === 302 || res.status === 301 || res.status === 303 || res.status === 307 || res.status === 308) return res;
  // 未拿到 302：可能是 Loon 忽略了 followRedirect，需要从响应头找回跳转信息。
  const loc = headerValue(res.headers, "location");
  if (loc) return res;
  console.log(`[诊断] Loon 未返回302（实际HTTP=${res.status || "未知"}），尝试用 $task.fetch 重试`);
  if (typeof $task !== "undefined") {
    try {
      const r = await $task.fetch({url, method: "POST", headers: {"User-Agent": UA, "Accept": "text/html,*/*", "Referer": BASE + "/login", "Origin": BASE, "Cookie": cookie || "", "Content-Type": "application/x-www-form-urlencoded"}, body, followRedirect: false});
      return {body: r.body || "", headers: r.headers || {}, status: r.statusCode || 0};
    } catch (e) {
      console.log(`[诊断] $task.fetch 重试失败：${e && e.message ? e.message : e}`);
    }
  }
  return res;
}
