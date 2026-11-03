/**
 * 网上国网会话恢复
 * @Version: R1.0.0
 * @Updated: 2026-11-03
 * 手动、每次最多一次登录。保留原设备 seed/AppGuid；不自动签到、不循环重登。
 * 账号与密码只在 Loon 插件设置或已保存存储中读取，凭据和验证码原文均不输出。
 */
(function () {
  const SCRIPT_VERSION = "R1.0.0";
  const KEY_SESS = "sgcc_session", KEY_DEV = "sgcc_device", KEY_PHONE = "sgcc_phone", KEY_PASS = "sgcc_password";
  const KEY_PEND = "sgcc_sms_pending", KEY_SMS = "sgcc_sms", KEY_SMS_DAY = "sgcc_sms_day";
  const KEY_RISK = "sgcc_risk_until", KEY_STATUS = "sgcc_status";
  const P_LOGIN = "emss-uia-center-front/member/c2/f01", P_SMS = "emss-uia-center-front/member/c1/f01";
  const report = {
    version: SCRIPT_VERSION, requestAttempts: 0, loginRequests: 0, smsRequests: 0,
    storageWrites: 0, deviceIdentityPreserved: true, signInAttempted: false, credentialsOutput: false
  };
  let finished = false;
  let DEV = null;
  function finish() {
    if (finished) return;
    finished = true;
    const text = JSON.stringify(report, null, 2);
    console.log(text);
    if (typeof $done === "function") $done({ title: "网上国网会话恢复 " + SCRIPT_VERSION, content: text });
  }
  function stop(code, note) { const e = new Error("recovery_stopped"); e.safeCode = code; e.safeNote = note; throw e; }
  function readRaw(key) {
    try { return $persistentStore.read(key); } catch (_) { stop("local_store_unreadable", "无法读取 Loon 本地存储。"); }
  }
  function writeRaw(value, key) {
    let ok;
    try { ok = $persistentStore.write(value, key); } catch (_) { stop("local_store_write_failed", "写入登录会话失败；未继续重试。"); }
    if (ok === false) stop("local_store_write_failed", "写入登录会话失败；未继续重试。");
    report.storageWrites++;
  }
  function readJSON(key, required) {
    const raw = readRaw(key);
    if (!raw) { if (required) stop("local_record_missing", "缺少所需本地记录。"); return null; }
    let v; try { v = JSON.parse(raw); } catch (_) { stop("local_record_invalid", "本地记录不是有效 JSON。"); }
    if (!v || typeof v !== "object" || Array.isArray(v)) stop("local_record_invalid", "本地记录结构异常。");
    return v;
  }
  function readArgs() {
    if (typeof $argument === "undefined" || !$argument) return {};
    if (typeof $argument === "string") { try { return JSON.parse($argument); } catch (_) { return {}; } }
    return typeof $argument === "object" ? $argument : {};
  }
  function safeCode(v) {
    const text = String(v == null ? "" : v);
    return /^-?\d{1,12}$/.test(text) || /^RK\d{1,4}$/i.test(text) ? text.toUpperCase() : "unknown";
  }
  function classify(code, message) {
    const text = String(message || "");
    const risk = text.match(/\bRK\d{1,4}\b/i);
    const safe = safeCode(code);
    report.code = safe;
    report.riskCode = /^RK\d{1,4}$/i.test(safe) ? safe : risk ? risk[0].toUpperCase() : null;
    return report.riskCode ? "risk" : code === "4006" ? "need_sms" : "fail";
  }
  function deriveGuid(seed) {
    const out = [], label = "wsgw-turing-profile-v1\0app-guid";
    let counter = 0;
    while (out.length < 60) {
      const count = new Uint8Array(4);
      new DataView(count.buffer).setUint32(0, counter++);
      for (const v of hmacSha256(seed, concat(u8(label), count))) out.push(v);
    }
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    return out.slice(0, 60).map(v => alphabet[v % 62]).join("");
  }
  function verifiedResponseKey(hex) {
    const raw = hex.toLowerCase().startsWith("04") ? hex.slice(2) : hex;
    if (raw.length < 194 || raw.length % 2 !== 0) stop("response_key_invalid", "响应密钥格式异常。");
    const point = [BigInt("0x" + raw.slice(0, 64)), BigInt("0x" + raw.slice(64, 128))];
    if (point.some(v => v < 0n || v >= SM2_P) || mod(point[1] * point[1] - point[0] * point[0] * point[0] - SM2_A * point[0] - SM2_B, SM2_P) !== 0n) stop("response_key_point_invalid", "响应密钥不在预期曲线上。");
    const shared = ptMul(BigInt("0x" + CLIENT_PRIV), point);
    if (!shared) stop("response_key_invalid", "响应密钥无效。");
    const plain = sm2DecryptKey(hex, CLIENT_PRIV);
    const digest = toHex(sm3(concat(b32(shared[0]), plain, b32(shared[1]))));
    if (digest.toLowerCase() !== raw.slice(128, 192).toLowerCase()) stop("response_key_integrity_failed", "响应密钥完整性校验失败。");
    return utf8dec(plain);
  }
  function headers(options) {
    const loginP = options && options.loginP;
    const h = {
      "Content-Type": "application/json; charset=UTF-8",
      timeStamp: loginP ? cnNow().s14 : reqTimestamp(),
      t: "", userid: "0", AppGuid: DEV.guid, AppGuidNew: appGuidNew(),
      security: "android", appcode: "WSGW-SG1001-APP", datacenter: "99", AccessMethod: "App",
      deviceTokenTX: DEV.tok.token, deviceTokenTXTime: DEV.tok.time, province: "",
      version: "3.2.3", wsgwType: "android", ip: "127.0.0.1", os: "android", "User-Agent": "okhttp/3.14.9"
    };
    if (loginP) h.md5 = loginMd5(loginP);
    return h;
  }
  function call(path, payload, options) {
    if (report.requestAttempts >= 2) stop("request_budget_exhausted", "本次恢复已达到请求上限。");
    report.requestAttempts++;
    return new Promise(resolve => {
      let settled = false;
      const settle = value => { if (settled) return; settled = true; clearTimeout(timer); resolve(value); };
      const timer = setTimeout(() => settle({ timedOut: true }), 25000);
      try {
        $httpClient.post({ url: SG_BASE + path, headers: headers(options), body: buildBody(payload),
          node: "DIRECT", timeout: 20000, "auto-redirect": false, "auto-cookie": false, insecure: false },
          (err, response, body) => settle({ networkError: !!err, response, body }));
      } catch (_) { settle({ networkError: true }); }
    });
  }
  function buildBody(payload) {
    const key = toHex(randomBytes(16)), timestamp = String(Date.now());
    const data = sm4EncryptHex(JSON.stringify(payload), key);
    const skey = sm2EncryptKey(key, SERVER_PUB);
    return JSON.stringify({ data, sign: sm3hex(skey + data + timestamp), skey, timestamp });
  }
  function decode(result) {
    if (result.timedOut) stop("network_timeout", "本次登录请求未在时限内取得响应；没有重试。");
    if (result.networkError) stop("network_or_tls_error", "未取得可判断的响应；没有重试。");
    const status = Number(result.response && (result.response.status || result.response.statusCode));
    report.httpStatus = Number.isInteger(status) && status >= 100 && status <= 599 ? status : null;
    if (report.httpStatus !== null && report.httpStatus >= 300 && report.httpStatus < 300 + 100) stop("redirect_not_followed", "服务端返回重定向，已停止。");
    if (typeof result.body !== "string" || !result.body || result.body.length > 1048576) stop("response_unreadable", "响应无法识别；没有重试。");
    let outer; try { outer = JSON.parse(result.body); } catch (_) { stop("response_unreadable", "响应无法识别；没有重试。"); }
    if (!outer || typeof outer !== "object" || Array.isArray(outer)) stop("response_unreadable", "响应结构异常。");
    if (!outer.respKey || !outer.encryptData) {
      const c = String(outer.code == null ? "" : outer.code);
      return { layer: "outer", code: c, message: outer.message, data: {}, good: c === "1" };
    }
    report.encryptedEnvelopePresent = true;
    const keyText = verifiedResponseKey(String(outer.respKey));
    let response; try { response = JSON.parse(utf8dec(sm4DecryptHex(String(outer.encryptData), keyText))); } catch (_) { stop("response_decryption_failed", "响应解密或格式校验失败。"); }
    if (!response || typeof response !== "object" || Array.isArray(response)) stop("response_unreadable", "响应结构异常。");
    const data = response.data && typeof response.data === "object" && !Array.isArray(response.data) ? response.data : {};
    const service = data.srvrt && typeof data.srvrt === "object" ? data.srvrt : null;
    const code = service ? String(service.resultCode == null ? "" : service.resultCode) : String(response.code == null ? "" : response.code);
    return { layer: "encrypted", code, message: service ? service.resultMessage : response.message, data, good: service ? code === "0000" : code === "1" };
  }
  async function main() {
    if (typeof $persistentStore === "undefined" || !$persistentStore || typeof $persistentStore.read !== "function") stop("not_in_loon", "必须在 Loon 内运行。");
    if (typeof $persistentStore.write !== "function") stop("store_write_unavailable", "Loon 存储不可写，无法保存新会话。");
    if (typeof $httpClient === "undefined" || !$httpClient || typeof $httpClient.post !== "function") stop("http_api_unavailable", "Loon HTTP 接口不可用。");
    const args = readArgs();
    const now = Date.now();
    let until; try { until = Number(readRaw(KEY_RISK) || 0); } catch (_) { stop("local_store_unreadable", "无法读取本地冷却状态。"); }
    if (!Number.isFinite(until)) stop("local_cooldown_invalid", "本地冷却状态异常。");
    if (until > now) { report.cooldownRemainingMinutes = Math.ceil((until - now) / 60000); stop("local_cooldown_active", "原签到脚本的本地冷却仍在生效，请到期后再试。"); }

    let s; try { s = JSON.parse(readRaw(KEY_SESS) || "null"); } catch (_) { s = "invalid"; }
    if (s === "invalid") { report.forceAuthorized = false; stop("local_session_invalid", "当前会话记录损坏；未自动清空或重登。"); }
    report.existingSessionRecord = s && typeof s === "object" && !Array.isArray(s) ? "object" : "empty";
    const user = String(args.phone || readRaw(KEY_PHONE) || "").replace(/\D/g, "").replace(/^86(?=1\d{10}$)/, "");
    const pass = String(args.password || readRaw(KEY_PASS) || "");
    if (!/^1\d{10}$/.test(user)) stop("account_unavailable", "插件里没有可用的登录手机号；请在 Loon 插件设置填写。");
    if (!pass.trim()) stop("password_unavailable", "插件里没有可用的登录密码；请在 Loon 插件设置填写。");
    report.accountMasked = user.slice(0, 3) + "****" + user.slice(-4);

    const d = readJSON(KEY_DEV, true);
    if (typeof d.seed !== "string" || !/^[A-Za-z0-9+/]{43}=$/.test(d.seed)) stop("device_seed_invalid", "原设备 seed 不可用；为避免改变身份，本次不继续。");
    const seed = b64dec(d.seed); if (seed.length !== 32) stop("device_seed_invalid", "原设备 seed 长度异常；本次不继续。");
    const tok = d.tok;
    if (!tok || typeof tok.token !== "string" || !/^v3:[A-Za-z0-9+/]+=*$/.test(tok.token)) stop("cached_device_token_invalid", "原设备缓存令牌不可用；本次不继续。");
    const created = Number(tok.ts), seconds = Number(tok.time), age = now - created;
    if (!Number.isFinite(created) || created <= 0 || age < 0 || age >= 4 * 3600000) stop("device_cache_stale_or_clock_invalid", "原设备缓存已过期或时间异常；本次不继续，避免改变身份。");
    if (typeof tok.time !== "string" || !/^\d{10}$/.test(tok.time) || Math.abs(seconds * 1000 - created) >= 2000) stop("device_timestamp_mismatch", "原设备缓存时间不一致；本次不继续。");
    report.deviceSeedRetained = true;
    report.cachedDeviceAgeHours = Math.round(age / 3600000 * 100) / 100;
    DEV = { guid: deriveGuid(seed), tok: { token: tok.token, time: tok.time }, seed };

    const expected = s && typeof s === "object" && typeof s.token === "string" && s.token ? s.user : (args.force === "true" || args.force === true ? user : null);
    if (expected && String(expected).replace(/\D/g, "") !== user) stop("account_mismatch", "插件里的手机号与现有会话账号不一致；为避免切换账号，本次不继续。");
    if (!expected) stop("force_not_authorized", "当前没有可确认的旧会话账号；如确需重建，请把插件里「强制重建」设为开。");

    const pend = readJSON(KEY_PEND, false);
    const sms = String(args.sms || readRaw(KEY_SMS) || "").replace(/\D/g, "");
    const pendOk = pend && pend.user === user && Number.isFinite(Number(pend.ts)) && now - Number(pend.ts) < 15 * 60000;
    const usedSms = pendOk && /^\d{6}$/.test(sms) && sms !== pend.used;

    const todayKey = new Date(now + 8 * 3600000).toISOString().slice(0, 10);
    const dayRec = readJSON(KEY_SMS_DAY, false);
    report.todaySmsCount = dayRec && dayRec.date === todayKey ? Number(dayRec.count) || 0 : 0;

    report.phase = usedSms ? "login_with_sms" : "login";
    report.loginRequests++;
    const params = loginParams(user, pass, usedSms ? sms : "", usedSms ? String(pend.codeKey) : "");
    const first = decode(await call(P_LOGIN, params, { loginP: params }));
    let outcome = first.good ? "ok" : classify(first.code, first.message);
    if (outcome === "risk") { saveFail("risk", first.code); stop("login_risk_control", "登录被返回 RK 风控/校验码；已停止，不重试、不发送更多短信。"); }
    if (outcome === "need_sms" && !usedSms) {
      if (report.todaySmsCount >= 1) stop("sms_daily_limit", "今天已发送过验证码；不再重复发送。");
      report.smsRequests++;
      const smsPayload = { uscInfo: { tenant: "state_grid", member: "2202", devciceId: "000000", devciceName: "sdk_gphone64_arm64", devciceIp: "127.0.0.1" },
        quInfo: { voiceCodeFlag: false, account: user, sendType: 0, businessType: "logindevice" } };
      const sent = decode(await call(P_SMS, smsPayload, {}));
      if (!sent.good) { saveFail("sms", sent.code); stop("sms_send_failed", "验证码发送未成功；没有重试。"); }
      const codeKey = sent.data && sent.data.bizrt && sent.data.bizrt.codeKey;
      if (!codeKey || typeof codeKey !== "string") stop("sms_codekey_missing", "验证码响应缺少校验标识；未写入待验证状态。");
      writeRaw(JSON.stringify({ user, codeKey: String(codeKey), ts: now, used: sms }), KEY_PEND);
      writeRaw(JSON.stringify({ date: todayKey, count: report.todaySmsCount + 1 }), KEY_SMS_DAY);
      report.result = "sms_required";
      report.note = "已发送一次验证码；请把收到的 6 位验证码填入插件设置，然后重新运行本恢复入口一次。不会自动继续。";
      return;
    }
    if (outcome === "need_sms" && usedSms) { saveFail("sms", first.code); stop("sms_verification_failed", "验证码未被接受；本次停止，不重试。"); }
    if (outcome !== "ok") { saveFail("login", first.code); stop("login_rejected", "登录未成功；已停止，不重试。"); }

    const biz = first.data.bizrt || {};
    if (!biz.token || typeof biz.token !== "string") { saveFail("login", "no_token"); stop("login_no_token", "登录响应没有可用凭证；未写入任何会话。"); }
    let ui = biz.userInfo; if (Array.isArray(ui)) ui = ui[0]; ui = ui || {};
    const userId = String(ui.userId || biz.userId || "0");
    if (!userId || userId === "0" || /[\r\n]/.test(userId)) { saveFail("login", "bad_user_id"); stop("session_fields_invalid", "登录响应字段异常；未覆盖原会话。"); }
    const life = Number(biz.tokenExpireTime) || 1296000;
    const sess = { user, token: String(biz.token), userId, province: String(ui.addressProvince || ""), exp: now + life * 1000 };
    writeRaw(JSON.stringify(sess), KEY_SESS);
    writeRaw("", KEY_SMS);
    report.sessionRebuilt = true;
    report.sessionDays = Math.round(life / 86400);
    report.result = "session_rebuilt";
    report.note = "已用原设备身份重建登录会话。本次没有尝试签到；如再报 RK001，需要另行判断，不能继续循环重登。";

    function saveFail(kind, code) {
      try {
        $persistentStore.write(JSON.stringify({ s: "fail", msg: "会话恢复:" + kind + ":" + safeCode(code), t: now }).slice(0, 500), KEY_STATUS);
        report.storageWrites++;
      } catch (_) { report.statusWriteFailed = true; }
    }
  }

  // Reused helper code from the bundled sgcc.js; no Env wrapper, no device-token generation,
// no sign-in call. Seed and cached device token are read from storage unchanged.
/*
 * MIT License
 *
 * Copyright (c) 2026 stevenjoezhang
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
function utf8enc(s){const o=[];for(let i=0;i<s.length;i++){let c=s.charCodeAt(i);if(c>=0xd800&&c<0xdc00&&i+1<s.length){const d=s.charCodeAt(i+1);if(d>=0xdc00&&d<0xe000){c=0x10000+((c-0xd800)<<10)+(d-0xdc00);i++;}}if(c<0x80)o.push(c);else if(c<0x800)o.push(0xc0|(c>>6),0x80|(c&63));else if(c<0x10000)o.push(0xe0|(c>>12),0x80|((c>>6)&63),0x80|(c&63));else o.push(0xf0|(c>>18),0x80|((c>>12)&63),0x80|((c>>6)&63),0x80|(c&63));}return new Uint8Array(o);}
function utf8dec(b){let s='';for(let i=0;i<b.length;){const c=b[i++];let cp;if(c<0x80)cp=c;else if(c<0xe0)cp=((c&31)<<6)|(b[i++]&63);else if(c<0xf0){cp=((c&15)<<12)|((b[i++]&63)<<6)|(b[i++]&63);}else{cp=((c&7)<<18)|((b[i++]&63)<<12)|((b[i++]&63)<<6)|(b[i++]&63);}if(cp>0xffff){cp-=0x10000;s+=String.fromCharCode(0xd800+(cp>>10),0xdc00+(cp&1023));}else s+=String.fromCharCode(cp);}return s;}
function u8(x){ if(x instanceof Uint8Array) return x; if(typeof x==='string') return utf8enc(x); return new Uint8Array(x);}
function toHex(b){let s='';for(let i=0;i<b.length;i++)s+=b[i].toString(16).padStart(2,'0');return s;}
function fromHex(h){const b=new Uint8Array(h.length/2);for(let i=0;i<b.length;i++)b[i]=parseInt(h.substr(i*2,2),16);return b;}
function rotl(x,n){n&=31;return ((x<<n)|(x>>>(32-n)))>>>0;}

/* ===== MD5 ===== */
function md5(input){
  const msg=u8(input);
  const S=[7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21];
  const Kt=[];for(let i=0;i<64;i++)Kt[i]=(Math.floor(Math.abs(Math.sin(i+1))*4294967296))>>>0;
  const ml=msg.length;const bl=ml*8;
  const withpad=((ml+8)>>6)+1;const buf=new Uint8Array(withpad*64);
  buf.set(msg);buf[ml]=0x80;const dv=new DataView(buf.buffer);
  dv.setUint32(buf.length-8,bl>>>0,true);dv.setUint32(buf.length-4,Math.floor(bl/4294967296)>>>0,true);
  let a0=0x67452301,b0=0xefcdab89,c0=0x98badcfe,d0=0x10325476;
  for(let off=0;off<buf.length;off+=64){
    const M=[];for(let i=0;i<16;i++)M[i]=dv.getUint32(off+i*4,true);
    let A=a0,B=b0,C=c0,D=d0;
    for(let i=0;i<64;i++){let F,g;
      if(i<16){F=(B&C)|((~B>>>0)&D);g=i;}
      else if(i<32){F=(D&B)|((~D>>>0)&C);g=(5*i+1)&15;}
      else if(i<48){F=B^C^D;g=(3*i+5)&15;}
      else{F=C^(B|(~D>>>0));g=(7*i)&15;}
      F=(F+A+Kt[i]+M[g])>>>0;A=D;D=C;C=B;B=(B+rotl(F,S[i]))>>>0;
    }
    a0=(a0+A)>>>0;b0=(b0+B)>>>0;c0=(c0+C)>>>0;d0=(d0+D)>>>0;
  }
  const out=new Uint8Array(16);const o=new DataView(out.buffer);
  o.setUint32(0,a0,true);o.setUint32(4,b0,true);o.setUint32(8,c0,true);o.setUint32(12,d0,true);
  return out;
}
const md5hex=x=>toHex(md5(x));


/* ===== SHA-256 / HMAC ===== */
function sha256(input){
  const msg=u8(input);
  const K=[0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];
  let H=[0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
  const ml=msg.length;const bl=ml*8;
  const withpad=((ml+8)>>6)+1;const buf=new Uint8Array(withpad*64);
  buf.set(msg);buf[ml]=0x80;const dv=new DataView(buf.buffer);
  dv.setUint32(buf.length-4,bl>>>0);dv.setUint32(buf.length-8,Math.floor(bl/4294967296)>>>0);
  const w=new Array(64);
  for(let off=0;off<buf.length;off+=64){
    for(let i=0;i<16;i++)w[i]=dv.getUint32(off+i*4);
    for(let i=16;i<64;i++){const s0=rotl(w[i-15],25)^rotl(w[i-15],14)^(w[i-15]>>>3);const s1=rotl(w[i-2],15)^rotl(w[i-2],13)^(w[i-2]>>>10);w[i]=(w[i-16]+s0+w[i-7]+s1)>>>0;}
    let [a,b,c,d,e,f,g,h]=H;
    for(let i=0;i<64;i++){const S1=rotl(e,26)^rotl(e,21)^rotl(e,7);const ch=(e&f)^((~e>>>0)&g);const t1=(h+S1+ch+K[i]+w[i])>>>0;const S0=rotl(a,30)^rotl(a,19)^rotl(a,10);const maj=(a&b)^(a&c)^(b&c);const t2=(S0+maj)>>>0;h=g;g=f;f=e;e=(d+t1)>>>0;d=c;c=b;b=a;a=(t1+t2)>>>0;}
    H=[(H[0]+a)>>>0,(H[1]+b)>>>0,(H[2]+c)>>>0,(H[3]+d)>>>0,(H[4]+e)>>>0,(H[5]+f)>>>0,(H[6]+g)>>>0,(H[7]+h)>>>0];
  }
  const out=new Uint8Array(32);const o=new DataView(out.buffer);
  for(let i=0;i<8;i++)o.setUint32(i*4,H[i]);
  return out;
}
function hmacSha256(key,msg){
  key=u8(key);msg=u8(msg);
  if(key.length>64)key=sha256(key);
  const k=new Uint8Array(64);k.set(key);
  const ip=new Uint8Array(64),op=new Uint8Array(64);
  for(let i=0;i<64;i++){ip[i]=k[i]^0x36;op[i]=k[i]^0x5c;}
  const inner=sha256(concat(ip,msg));
  return sha256(concat(op,inner));
}
function concat(...arrs){let n=0;for(const a of arrs)n+=a.length;const o=new Uint8Array(n);let p=0;for(const a of arrs){o.set(a,p);p+=a.length;}return o;}

/* ===== SM3 ===== */
function sm3(input){
  const m=u8(input);const len=m.length;const bitLen=len*8;
  const padLen=((len%64)<56?56:120)-(len%64);
  const buf=new Uint8Array(len+padLen+8);buf.set(m);buf[len]=0x80;
  const dv=new DataView(buf.buffer);
  dv.setUint32(buf.length-4,bitLen>>>0);dv.setUint32(buf.length-8,Math.floor(bitLen/4294967296)>>>0);
  let V=[0x7380166f,0x4914b2b9,0x172442d7,0xda8a0600,0xa96f30bc,0x163138aa,0xe38dee4d,0xb0fb0e4e];
  for(let b=0;b<buf.length;b+=64){
    const W=new Array(68),W1=new Array(64);
    for(let i=0;i<16;i++)W[i]=dv.getUint32(b+i*4);
    for(let i=16;i<68;i++){const x=W[i-16]^W[i-9]^rotl(W[i-3],15);W[i]=(x^rotl(x,15)^rotl(x,23)^rotl(W[i-13],7)^W[i-6])>>>0;}
    for(let i=0;i<64;i++)W1[i]=(W[i]^W[i+4])>>>0;
    let [A,B,C,D,E,F,G,H]=V;
    for(let j=0;j<64;j++){const Tj=j<16?0x79cc4519:0x7a879d8a;const SS1=rotl((rotl(A,12)+E+rotl(Tj,j))>>>0,7);const SS2=(SS1^rotl(A,12))>>>0;const FF=j<16?(A^B^C):((A&B)|(A&C)|(B&C));const GG=j<16?(E^F^G):((E&F)|((~E>>>0)&G));const TT1=(FF+D+SS2+W1[j])>>>0;const TT2=(GG+H+SS1+W[j])>>>0;D=C;C=rotl(B,9);B=A;A=TT1;H=G;G=rotl(F,19);F=E;E=(TT2^rotl(TT2,9)^rotl(TT2,17))>>>0;}
    V=[(V[0]^A)>>>0,(V[1]^B)>>>0,(V[2]^C)>>>0,(V[3]^D)>>>0,(V[4]^E)>>>0,(V[5]^F)>>>0,(V[6]^G)>>>0,(V[7]^H)>>>0];
  }
  const out=new Uint8Array(32);const o=new DataView(out.buffer);for(let i=0;i<8;i++)o.setUint32(i*4,V[i]);return out;
}
const sm3hex=x=>toHex(sm3(x));
// sm3 kdf: z is bytes
function sm3kdf(z,klen){let ct=1;let out=new Uint8Array(0);const n=Math.ceil(klen/32);for(let i=0;i<n;i++){const cnt=new Uint8Array(4);new DataView(cnt.buffer).setUint32(0,ct);out=concat(out,sm3(concat(z,cnt)));ct++;}return out.slice(0,klen);}

/* ===== SM4 ECB PKCS7 ===== */
const SM4_SBOX=fromHex('d690e9fecce13db716b614c228fb2c05 2b679a762abe04c3aa441326498606999c4250f491ef987a33540b43edcfac62 e4b31ca9c908e89580df94fa758f3fa6 4707a7fcf37317ba83593c19e6854fa8 686b81b27164da8bf8eb0f4b70569d35 1e240e5e6358d1a225227c3b01217887 d40046579fd327524c3602e7a0c4c89e eabf8ad240c738b5a3f7f2cef96115a1 e0ae5da49b341a55ad933230f58cb1e3 1df6e22e8266ca60c02923ab0d534e6f d5db3745defd8e2f03ff6a726d6c5b51 8d1baf92bbddbc7f11d95c411f105ad8 0ac13188a5cd7bbd2d74d012b8e5b4b0 8969974a0c96777e65b9f109c56ec684 18f07dec3adc4d2079ee5f3ed7cb3948'.replace(/\s/g,''));
const SM4_CK=[0x00070e15,0x1c232a31,0x383f464d,0x545b6269,0x70777e85,0x8c939aa1,0xa8afb6bd,0xc4cbd2d9,0xe0e7eef5,0xfc030a11,0x181f262d,0x343b4249,0x50575e65,0x6c737a81,0x888f969d,0xa4abb2b9,0xc0c7ced5,0xdce3eaf1,0xf8ff060d,0x141b2229,0x30373e45,0x4c535a61,0x686f767d,0x848b9299,0xa0a7aeb5,0xbcc3cad1,0xd8dfe6ed,0xf4fb0209,0x10171e25,0x2c333a41,0x484f565d,0x646b7279];
const SM4_FK=[0xa3b1bac6,0x56aa3350,0x677d9197,0xb27022dc];
function sm4tau(a){return ((SM4_SBOX[(a>>>24)&0xff]<<24)|(SM4_SBOX[(a>>>16)&0xff]<<16)|(SM4_SBOX[(a>>>8)&0xff]<<8)|SM4_SBOX[a&0xff])>>>0;}
function sm4L(b){return (b^rotl(b,2)^rotl(b,10)^rotl(b,18)^rotl(b,24))>>>0;}
function sm4Lp(b){return (b^rotl(b,13)^rotl(b,23))>>>0;}
function sm4Key(key){const MK=[];for(let i=0;i<4;i++)MK[i]=((key[i*4]<<24)|(key[i*4+1]<<16)|(key[i*4+2]<<8)|key[i*4+3])>>>0;const K=[MK[0]^SM4_FK[0],MK[1]^SM4_FK[1],MK[2]^SM4_FK[2],MK[3]^SM4_FK[3]];const rk=[];for(let i=0;i<32;i++){const t=(K[i+1]^K[i+2]^K[i+3]^SM4_CK[i])>>>0;const r=(K[i]^sm4Lp(sm4tau(t)))>>>0;K[i+4]=r;rk[i]=r;}return rk;}
function sm4Block(rk,inp,enc){let X=[((inp[0]<<24)|(inp[1]<<16)|(inp[2]<<8)|inp[3])>>>0,((inp[4]<<24)|(inp[5]<<16)|(inp[6]<<8)|inp[7])>>>0,((inp[8]<<24)|(inp[9]<<16)|(inp[10]<<8)|inp[11])>>>0,((inp[12]<<24)|(inp[13]<<16)|(inp[14]<<8)|inp[15])>>>0];for(let i=0;i<32;i++){const k=enc?rk[i]:rk[31-i];const t=(X[i+1]^X[i+2]^X[i+3]^k)>>>0;X[i+4]=(X[i]^sm4L(sm4tau(t)))>>>0;}const o=[X[35],X[34],X[33],X[32]];const out=new Uint8Array(16);for(let i=0;i<4;i++){out[i*4]=(o[i]>>>24)&0xff;out[i*4+1]=(o[i]>>>16)&0xff;out[i*4+2]=(o[i]>>>8)&0xff;out[i*4+3]=o[i]&0xff;}return out;}
function sm4EncryptEcb(data,key){const rk=sm4Key(key);const pad=16-(data.length%16);const buf=new Uint8Array(data.length+pad);buf.set(data);for(let i=data.length;i<buf.length;i++)buf[i]=pad;const out=new Uint8Array(buf.length);for(let i=0;i<buf.length;i+=16)out.set(sm4Block(rk,buf.subarray(i,i+16),true),i);return out;}
function sm4DecryptEcb(data,key){const rk=sm4Key(key);const out=new Uint8Array(data.length);for(let i=0;i<data.length;i+=16)out.set(sm4Block(rk,data.subarray(i,i+16),false),i);const pad=out[out.length-1];return out.slice(0,out.length-pad);}
// App: key text 32 hex chars, uses first 16 ASCII bytes as key
function sm4KeyBytes(keyText){return u8(keyText.slice(0,16));}
function sm4EncryptHex(plain,keyText){return toHex(sm4EncryptEcb(u8(plain),sm4KeyBytes(keyText))).toUpperCase();}
function sm4DecryptHex(hex,keyText){return sm4DecryptEcb(fromHex(hex),sm4KeyBytes(keyText));}

/* ===== AES-256 ECB (check code) ===== */
// robust AES sbox
function aesSboxCompute(){const sbox=new Uint8Array(256);let p=1,q=1;do{p=p^(p<<1)^((p&0x80)?0x11b:0);p&=0xff;q^=q<<1;q^=q<<2;q^=q<<4;q&=0xff;if(q&0x80)q^=0x09;const xf=q^((q<<1)|(q>>>7))^((q<<2)|(q>>>6))^((q<<3)|(q>>>5))^((q<<4)|(q>>>4));sbox[p]=(xf^0x63)&0xff;}while(p!==1);sbox[0]=0x63;return sbox;}
const ASB=aesSboxCompute();
function aesExpand(key){const Nk=8,Nr=14,w=new Uint8Array(4*4*(Nr+1));w.set(key);const rcon=[0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36,0x6c,0xd8,0xab,0x4d];let i=Nk;const tmp=new Uint8Array(4);while(i<4*(Nr+1)){for(let k=0;k<4;k++)tmp[k]=w[(i-1)*4+k];if(i%Nk===0){const t=tmp[0];tmp[0]=ASB[tmp[1]]^rcon[i/Nk-1];tmp[1]=ASB[tmp[2]];tmp[2]=ASB[tmp[3]];tmp[3]=ASB[t];}else if(i%Nk===4){for(let k=0;k<4;k++)tmp[k]=ASB[tmp[k]];}for(let k=0;k<4;k++)w[i*4+k]=w[(i-Nk)*4+k]^tmp[k];i++;}return {w,Nr};}
function xtime(a){return ((a<<1)^((a&0x80)?0x11b:0))&0xff;}
function aesEncryptBlock(st,w,Nr){const s=st.slice();for(let k=0;k<16;k++)s[k]^=w[k];for(let r=1;r<Nr;r++){for(let k=0;k<16;k++)s[k]=ASB[s[k]];// shiftrows (column-major state: s[r+4c])
    aesShift(s);aesMix(s);for(let k=0;k<16;k++)s[k]^=w[r*16+k];}
  for(let k=0;k<16;k++)s[k]=ASB[s[k]];aesShift(s);for(let k=0;k<16;k++)s[k]^=w[Nr*16+k];return s;}
function aesShift(s){const t=[s[0],s[5],s[10],s[15],s[4],s[9],s[14],s[3],s[8],s[13],s[2],s[7],s[12],s[1],s[6],s[11]];for(let i=0;i<16;i++)s[i]=t[i];}
function aesMix(s){for(let c=0;c<4;c++){const o=c*4;const a0=s[o],a1=s[o+1],a2=s[o+2],a3=s[o+3];s[o]=xtime(a0)^(xtime(a1)^a1)^a2^a3;s[o+1]=a0^xtime(a1)^(xtime(a2)^a2)^a3;s[o+2]=a0^a1^xtime(a2)^(xtime(a3)^a3);s[o+3]=(xtime(a0)^a0)^a1^a2^xtime(a3);}}
function aes256EcbEncrypt(data,key){const {w,Nr}=aesExpand(key);const pad=16-(data.length%16);const buf=new Uint8Array(data.length+pad);buf.set(data);for(let i=data.length;i<buf.length;i++)buf[i]=pad;const out=new Uint8Array(buf.length);for(let i=0;i<buf.length;i+=16)out.set(aesEncryptBlock(buf.subarray(i,i+16),w,Nr),i);return out;}


/* ===== SM2 ===== */
const SM2_P=BigInt('0xFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFF');
const SM2_A=BigInt('0xFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFC');
const SM2_B=BigInt('0x28E9FA9E9D9F5E344D5A9E4BCF6509A7F39789F515AB8F92DDBCBD414D940E93');
const SM2_GX=BigInt('0x32C4AE2C1F1981195F9904466A39C9948FE30BBFF2660BE1715A4589334C74C7');
const SM2_GY=BigInt('0xBC3736A2F4F6779C59BDCEE36B692153D0A9877CC62A474002DF32E52139F0A0');
function mod(a,m){return ((a%m)+m)%m;}
function inv(a,m){let [old_r,r]=[mod(a,m),m];let [old_s,s]=[1n,0n];while(r!==0n){const q=old_r/r;[old_r,r]=[r,old_r-q*r];[old_s,s]=[s,old_s-q*s];}return mod(old_s,m);}
function ptAdd(P,Q){if(!P)return Q;if(!Q)return P;const [x1,y1]=P,[x2,y2]=Q;if(x1===x2&&mod(y1+y2,SM2_P)===0n)return null;let l;if(x1===x2&&y1===y2){l=mod((3n*x1*x1+SM2_A)*inv(2n*y1,SM2_P),SM2_P);}else{l=mod((y2-y1)*inv(mod(x2-x1,SM2_P),SM2_P),SM2_P);}const x3=mod(l*l-x1-x2,SM2_P);const y3=mod(l*(x1-x3)-y1,SM2_P);return [x3,y3];}
function ptMul(k,P){let R=null,N=P;while(k>0n){if(k&1n)R=ptAdd(R,N);N=ptAdd(N,N);k>>=1n;}return R;}
const G=[SM2_GX,SM2_GY];
function b32(n){let h=n.toString(16).padStart(64,'0');return fromHex(h);}
// encrypt 32-char key text ascii -> "04"+C1C3C2 hex (mode 1)
function sm2EncryptKey(keyText,serverPubHex){const msg=u8(keyText);let pub=serverPubHex;if(pub.length===130)pub=pub.slice(2);const px=BigInt('0x'+pub.slice(0,64)),py=BigInt('0x'+pub.slice(64));
  let k,C1,xy;do{k=BigInt('0x'+toHex(randomBytes(32)))%SM2_P;if(k===0n)continue;C1=ptMul(k,G);xy=ptMul(k,[px,py]);}while(!C1||!xy);
  const x2=b32(xy[0]),y2=b32(xy[1]);const t=sm3kdf(concat(x2,y2),msg.length);let ok=false;for(const b of t)if(b!==0){ok=true;break;}if(!ok)return sm2EncryptKey(keyText,serverPubHex);
  const C2=new Uint8Array(msg.length);for(let i=0;i<msg.length;i++)C2[i]=msg[i]^t[i];
  const C3=sm3(concat(x2,msg,y2));
  const c1hex=b32(C1[0]).length?toHex(b32(C1[0]))+toHex(b32(C1[1])):'';
  return '04'+toHex(concat(b32(C1[0]),b32(C1[1]),C3,C2));
}
function sm2DecryptKey(wrapHex,privHex){let w=wrapHex.toLowerCase().startsWith('04')?wrapHex.slice(2):wrapHex;const C1=[BigInt('0x'+w.slice(0,64)),BigInt('0x'+w.slice(64,128))];const C3=w.slice(128,192);const C2=fromHex(w.slice(192));const d=BigInt('0x'+privHex);const xy=ptMul(d,C1);const x2=b32(xy[0]),y2=b32(xy[1]);const t=sm3kdf(concat(x2,y2),C2.length);const M=new Uint8Array(C2.length);for(let i=0;i<C2.length;i++)M[i]=C2[i]^t[i];return M;}

/* ===== random ===== */
function randomBytes(n){if(typeof globalThis!=='undefined'&&globalThis.crypto&&globalThis.crypto.getRandomValues){const b=new Uint8Array(n);globalThis.crypto.getRandomValues(b);return b;}const b=new Uint8Array(n);for(let i=0;i<n;i++)b[i]=Math.floor(Math.random()*256);return b;}


function b64dec(s){const A='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';s=s.replace(/=+$/,'');const out=[];let buf=0,bits=0;for(const ch of s){buf=(buf<<6)|A.indexOf(ch);bits+=6;if(bits>=8){bits-=8;out.push((buf>>bits)&0xff);}}return new Uint8Array(out);}

const ALNUM='0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';

function randStr(n,alpha=ALNUM){const r=randomBytes(n*2);let s='';for(let i=0;i<n;i++)s+=alpha[((r[i*2]<<8)|r[i*2+1])%alpha.length];return s;}

const SG_BASE = 'https://csc-service.sgcc.com.cn:28630/';

const SERVER_PUB = '0409C10D38CF7B4E28097EAAA519E3157C9B4E72194CD13BD11932CE40ED5624AFEFF27F78893E4C4FC2029DA147AB6CEAE0CDC8E3A547EFCDC5AB91757FE1CA60';

const CLIENT_PRIV = '50C4AF48DF75808050729977AA6BC127DC21A404755C660B94222F9D50FA4A75';

const CHECK_KEY = 'LNPO+ISJ+QeqNemFK+3OMUdexSn2i6pB';

function cnNow() { const d = new Date(Date.now() + 8 * 3600000); const p = (n, l = 2) => String(n).padStart(l, '0'); return { s14: `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}`, ms: p(d.getUTCMilliseconds(), 3), y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: d.getUTCDate() }; }

function reqTimestamp() { const n = cnNow(); return n.s14 + n.ms + randStr(6, '0123456789'); }

function appGuidNew() { const n = cnNow(); return randStr(40, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789') + n.s14 + n.ms + String(100 + (randomBytes(2)[0] * 256 + randomBytes(1)[0]) % 900); }

function javaHash(s) { let h = 0; for (let i = 0; i < s.length; i++) h = (Math.imul(31, h) + s.charCodeAt(i)) >>> 0; return h; }
function hashMapOrder(v) {
  if (Array.isArray(v)) return v.map(hashMapOrder);
  if (v && typeof v === 'object') {
    const buckets = {};
    Object.keys(v).forEach((k) => { let h = javaHash(k); h = (h ^ (h >>> 16)) >>> 0; const b = h & 15; (buckets[b] = buckets[b] || []).push(k); });
    const o = {};
    Object.keys(buckets).map(Number).sort((a, b) => a - b).forEach((b) => buckets[b].forEach((k) => { o[k] = hashMapOrder(v[k]); }));
    return o;
  }
  return v;
}

function loginMd5(params) { return md5hex(Object.keys(params).sort().map((k) => k + JSON.stringify(hashMapOrder(params[k]))).join('')); }

function checkCode(account) {
  let r = 0n; const rb = randomBytes(8); for (const b of rb) r = (r << 8n) | BigInt(b); r &= (1n << 63n) - 1n;
  return String(r).padStart(24, '0') + toHex(aes256EcbEncrypt(u8(`${account}${Date.now()}`), u8(CHECK_KEY)));
}
function uscInfo(dev) { return { isEncrypt: 'false', devciceIp: '127.0.0.1', devciceId: '000000', tenant: 'state_grid', member: '2202', optSys: 'Android 13', operatorType: '', devciceName: 'sdk_gphone64_arm64', pushId: '000000,000000' }; }
function loginParams(account, password, code, codeKey) {
  return {
    quInfo: { code: code || '', codeKey: codeKey || '', account, password: md5hex(password), optSys: 'Android', pushId: '000000,000000', addressCity: '', addressProvince: '', addressRegion: '' },
    uscInfo: uscInfo(),
    checkCode: checkCode(account),
    avalonValidCode: '',
  };
}





  main().catch(e => {
    report.result = "stopped";
    report.stopReason = e && e.safeCode ? e.safeCode : "protocol_or_runtime_error";
    report.note = e && e.safeNote ? e.safeNote : "本次恢复已停止；没有循环重试、没有发送额外短信。";
  }).finally(finish);
})();
