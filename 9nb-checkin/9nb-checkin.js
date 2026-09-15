/*
 * 9NB.DE 多账号自动登录签到
 * 版本: 2026-09-15.r2.0.0
 * 默认每天 08:00 执行；账号去重；账号间随机等待 0-5 分钟。
 * 账号密码仅用于 Loon 本地登录，不会上传或输出密码。
 */

const SCRIPT_VERSION = "2026-09-15.r2.0.0";
const NAME = "9NB签到";
const BASE = "https://9nb.de";
const STORE_KEY = "9nb_checkin_accounts";
const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1";

(async () => {
  try {
    if (typeof $request !== "undefined" && $request) return captureCookie();
    const input = readArgument();
    const accounts = loadAccounts(input);
    if (!accounts.length) throw new Error("请在Argument填写账号密码，格式：账号:密码|账号:密码");
    const results = [];
    for (let i = 0; i < accounts.length; i++) {
      if (i > 0) {
        const wait = randomInt(0, 300);
        console.log(`账号${i + 1}将在${wait}秒后签到`);
        await sleep(wait * 1000);
      }
      try {
        const r = await runAccount(accounts[i]);
        results.push(`账号${i + 1}（${r.username}）：${r.message}；奖励：${r.reward}；余额：${r.balance}`);
      } catch (e) {
        results.push(`账号${i + 1}：失败 - ${e && e.message ? e.message : String(e)}`);
      }
    }
    finish("9NB签到结果", results.join("\n"), results.some(x => /失败/.test(x)));
  } catch (e) {
    finish("签到失败", e && e.message ? e.message : String(e), true);
  }
})().finally(() => { if (typeof $done === "function") $done(); });

function readArgument() {
  let a = typeof $argument !== "undefined" && $argument ? $argument : {};
  // Loon 不同版本对 Argument 的注入形式不同：可能是对象，也可能是 JSON 字符串。
  if (typeof a === "string") {
    const raw = a.trim();
    try { a = JSON.parse(raw); } catch (_) {
      // 兼容直接传入「账号:密码|账号:密码」的情况
      return raw;
    }
  }
  if (!a || typeof a !== "object") return "";
  return String(a.accounts || a.account || a.cookies || a.cookie || "").trim();
}

function loadAccounts(raw) {
  const saved = typeof $persistentStore !== "undefined" ? parseJSON($persistentStore.read(STORE_KEY), {}) : {};
  const list = [];
  if (raw) {
    raw.split("|").map(x => x.trim()).filter(Boolean).forEach(item => {
      const p = item.indexOf(":");
      if (p <= 0) return;
      const username = item.slice(0, p).trim();
      const password = item.slice(p + 1);
      if (!username || !password || list.some(x => x.username === username)) return;
      list.push({username, password, cookie: saved[username]?.cookie || ""});
    });
  } else {
    Object.keys(saved).forEach(username => list.push({username, cookie: saved[username].cookie || ""}));
  }
  return list;
}

async function runAccount(account) {
  let cookie = account.cookie || "";
  if (!cookie || !account.password) {
    if (!account.password) throw new Error("未提供密码，且本地没有已保存Cookie");
    cookie = await login(account.username, account.password);
    saveAccount(account.username, cookie);
  }
  let page = await request("GET", BASE + "/nb_checkin", cookie);
  if (isLoginPage(page)) {
    if (!account.password) throw new Error("Cookie已失效，请在Argument补充密码");
    cookie = await login(account.username, account.password);
    saveAccount(account.username, cookie);
    page = await request("GET", BASE + "/nb_checkin", cookie);
  }
  if (isLoginPage(page)) throw new Error("登录失败，请检查账号密码");
  const beforeBalance = extractBalance(page);
  const csrf = extractCsrf(page);
  if (!csrf) throw new Error("未找到签到CSRF");
  let message = "今天已经签到";
  let reward = "无（已签到）";
  if (!/今日已签到|今日已经签到|已完成签到/.test(page)) {
    const result = await request("POST", BASE + "/nb_checkin", cookie, `_csrf=${encodeURIComponent(csrf)}&mode=fixed`);
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
  const loginPage = await request("GET", BASE + "/login", "");
  const csrf = extractCsrf(loginPage);
  if (!csrf) throw new Error("登录页未找到CSRF");
  const body = `_csrf=${encodeURIComponent(csrf)}&username=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}`;
  const response = await requestResponse("POST", BASE + "/login", "", body);
  const cookie = mergeCookies(response.headers, "");
  if (!cookie || !/bbs_auth=/.test(cookie)) throw new Error("登录失败或未获得登录Cookie");
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
  if (!/9nb\.de\/nb_checkin(?:[/?]|$)/i.test(url)) return;
  const h = $request.headers || {};
  const cookie = h.Cookie || h.cookie || "";
  if (cookie && /bbs_auth=/.test(cookie)) console.log("✅ 已捕获9NB登录Cookie（账号密码登录模式会优先自动登录）");
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
  let values = headers && (headers["set-cookie"] || headers["Set-Cookie"] || []);
  if (!Array.isArray(values)) values = [values];
  values.forEach(v => String(v).split(/,\s*(?=[^;,=]+=[^;,]+)/).forEach(x => { const m = x.match(/^\s*([^=;]+)=([^;]*)/); if (m && m[1] !== "Path" && m[1] !== "Expires") out[m[1]] = m[2]; }));
  return Object.keys(out).map(k => `${k}=${out[k]}`).join("; ");
}
function stripHtml(s) { return String(s).replace(/<script[\s\S]*?<\/script>/gi, "").replace(/<style[\s\S]*?<\/style>/gi, "").replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " "); }
function parseJSON(s, fallback) { try { return s ? JSON.parse(s) : fallback; } catch (_) { return fallback; } }
function randomInt(a, b) { return Math.floor(Math.random() * (b - a + 1)) + a; }
function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }
function finish(title, body, bad) { console.log((bad ? "❌ " : "✅ ") + title + "：\n" + body); if (typeof $notification !== "undefined") $notification.post(NAME, title, body); }
function request(method, url, cookie, body) { return requestResponse(method, url, cookie, body).then(x => x.body); }
function requestResponse(method, url, cookie, body) {
  return new Promise((resolve, reject) => {
    const headers = {"User-Agent": UA, "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", "Referer": BASE + "/nb_checkin", "Cookie": cookie || "", "Content-Type": "application/x-www-form-urlencoded"};
    const opts = {url, headers, body};
    const cb = (err, resp, data) => err ? reject(err) : resolve({body: data || "", headers: resp && resp.headers ? resp.headers : {}});
    if (typeof $httpClient !== "undefined") return method === "GET" ? $httpClient.get(opts, cb) : $httpClient.post(opts, cb);
    if (typeof $task !== "undefined") return $task.fetch({url, method, headers, body}).then(r => resolve({body: r.body || "", headers: r.headers || {}})).catch(reject);
    reject(new Error("不支持的脚本环境"));
  });
}
