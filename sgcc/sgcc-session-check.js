/**
 * 网上国网现有凭证单次验证
 * @Version: R1.0.0
 * @Updated: 2026-11-03
 * 手动、每次至多一笔余额查询。不登录、不发短信、不签到，不修改存储。
 * 加密辅助函数取自已有 sgcc.js；稳定 AppGuid 使用完全相同的种子派生规则。
 */
(function () {
  const SCRIPT_VERSION = "R1.0.0";
  const URL = "https://csc-service.sgcc.com.cn:28630/osg-omgmt1042/member/c1/q104051";
  const report = {
    version: SCRIPT_VERSION, endpoint: "member/c1/q104051",
    requestAttempts: 0, storageWrites: 0, loginRequests: 0, smsRequests: 0,
    redirectsAllowed: false, balanceValueOmitted: true
  };
  let finished = false;
  function finish() {
    if (finished) return;
    finished = true;
    const text = JSON.stringify(report, null, 2);
    console.log(text);
    if (typeof $done === "function") $done({ title: "网上国网单次验证 " + SCRIPT_VERSION, content: text });
  }
  function stop(code) { const e = new Error("diagnostic_stopped"); e.safeCode = code; throw e; }
  function readJSON(key) {
    let raw;
    try { raw = $persistentStore.read(key); } catch (_) { stop("local_store_unreadable"); }
    if (!raw) stop("local_record_missing");
    let v; try { v = JSON.parse(raw); } catch (_) { stop("local_record_invalid"); }
    if (!v || typeof v !== "object" || Array.isArray(v)) stop("local_record_invalid");
    return v;
  }
  function safeCode(v) {
    const text = String(v == null ? "" : v);
    return /^-?\d{1,12}$/.test(text) || /^RK\d{1,4}$/i.test(text) ? text.toUpperCase() : "unknown";
  }
  function describeFailure(code, message) {
    const text = String(message || "");
    const risk = text.match(/\bRK\d{1,4}\b/i);
    report.code = safeCode(code);
    report.riskCode = /^RK\d{1,4}$/i.test(report.code) ? report.code : risk ? risk[0].toUpperCase() : null;
    const explicit = report.code === "-200" || report.code === "-201" || /(?:token|登录凭证|会话).{0,16}(?:失效|无效|过期)|未登录|请登录|not\s*login/i.test(text);
    if (report.riskCode) {
      report.result = "risk_or_session_rejected";
      report.note = "此接口也返回 RK；仍不能单凭它区分风控与会话失效。已停止，不自动重试或重登。";
    } else if (explicit) {
      report.result = "explicit_session_rejection";
      report.note = "此接口明确提示登录/凭证无效。需另行决定是否保留原设备做一次受控重登录，本脚本不会执行。";
    } else {
      report.result = "server_rejected_or_unknown";
      report.note = "没有取得有效余额响应；未确认服务端是否认可此会话。原始消息不输出。";
    }
  }
  function deriveGuid(seed) {
    const out = [], label = "wsgw-turing-profile-v1\0app-guid";
    let counter = 0;
    while (out.length < 60) {
      const count = new Uint8Array(4);
      new DataView(count.buffer).setUint32(0, counter++);
      const bytes = hmacSha256(seed, concat(u8(label), count));
      for (const v of bytes) out.push(v);
    }
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    return out.slice(0, 60).map(v => alphabet[v % 62]).join("");
  }
  function verifiedResponseKey(hex) {
    const raw = hex.toLowerCase().startsWith("04") ? hex.slice(2) : hex;
    if (raw.length < 194 || raw.length % 2 !== 0) stop("response_key_invalid");
    const point = [BigInt("0x" + raw.slice(0, 64)), BigInt("0x" + raw.slice(64, 128))];
    if (point.some(v => v < 0n || v >= SM2_P) || mod(point[1] * point[1] - point[0] * point[0] * point[0] - SM2_A * point[0] - SM2_B, SM2_P) !== 0n) stop("response_key_point_invalid");
    const shared = ptMul(BigInt("0x" + CLIENT_PRIV), point);
    if (!shared) stop("response_key_invalid");
    const plain = sm2DecryptKey(hex, CLIENT_PRIV);
    const digest = toHex(sm3(concat(b32(shared[0]), plain, b32(shared[1]))));
    if (digest.toLowerCase() !== raw.slice(128, 192).toLowerCase()) stop("response_key_integrity_failed");
    return utf8dec(plain);
  }
  function queryOnce(options) {
    if (report.requestAttempts !== 0) stop("request_budget_exhausted");
    report.requestAttempts++;
    return new Promise(resolve => {
      let settled = false;
      const settle = value => { if (settled) return; settled = true; clearTimeout(timer); resolve(value); };
      const timer = setTimeout(() => settle({ timedOut: true }), 20000);
      try {
        $httpClient.post(options, (err, response, body) => settle({ networkError: !!err, response, body }));
      } catch (_) { settle({ networkError: true }); }
    });
  }
  async function main() {
    if (typeof $persistentStore === "undefined" || !$persistentStore || typeof $persistentStore.read !== "function") stop("not_in_loon");
    if (typeof $httpClient === "undefined" || !$httpClient || typeof $httpClient.post !== "function") stop("http_api_unavailable");
    const s = readJSON("sgcc_session"), d = readJSON("sgcc_device");
    const now = Date.now();
    let until; try { until = Number($persistentStore.read("sgcc_risk_until") || 0); } catch (_) { stop("local_store_unreadable"); }
    if (!Number.isFinite(until)) stop("local_cooldown_invalid");
    if (until > now) { report.cooldownRemainingMinutes = Math.ceil((until - now) / 60000); stop("local_cooldown_active"); }
    for (const value of [s.token, s.userId]) {
      if (typeof value !== "string" || !value.trim() || /[\r\n]/.test(value)) stop("session_fields_invalid");
    }
    if (s.userId === "0" || s.userId === "null" || s.userId === "undefined") stop("user_id_invalid");
    if (typeof s.province !== "string" || !s.province.trim() || /[\r\n]/.test(s.province)) stop("province_invalid");
    if (!Number.isFinite(Number(s.exp)) || Number(s.exp) <= now) stop("local_session_expired_or_invalid");
    if (typeof d.seed !== "string" || !/^[A-Za-z0-9+/]{43}=$/.test(d.seed)) stop("device_seed_invalid");
    const seed = b64dec(d.seed); if (seed.length !== 32) stop("device_seed_invalid");
    const t = d.tok;
    if (!t || typeof t !== "object" || typeof t.token !== "string" || !/^v3:[A-Za-z0-9+/]+=*$/.test(t.token)) stop("cached_device_token_invalid");
    if (typeof t.time !== "string" || !/^\d{10}$/.test(t.time)) stop("device_timestamp_mismatch");
    const created = Number(t.ts), seconds = Number(t.time), age = now - created;
    if (!Number.isFinite(created) || created <= 0 || age < 0 || age >= 4 * 3600000) stop("device_cache_stale_or_clock_invalid");
    if (!Number.isFinite(seconds) || seconds <= 0 || Math.abs(seconds * 1000 - created) >= 2000) stop("device_timestamp_mismatch");
    report.cachedDeviceAgeHours = Math.round(age / 3600000 * 100) / 100;
    report.preflight = "passed";
    const key = toHex(randomBytes(16)), timestamp = String(now);
    const data = sm4EncryptHex("{}", key), skey = sm2EncryptKey(key, SERVER_PUB);
    const headers = {
      "Content-Type": "application/json; charset=UTF-8", timeStamp: reqTimestamp(),
      t: s.token, userid: s.userId, AppGuid: deriveGuid(seed), AppGuidNew: appGuidNew(),
      security: "android", appcode: "WSGW-SG1001-APP", datacenter: "99", AccessMethod: "App",
      deviceTokenTX: t.token, deviceTokenTXTime: t.time, province: s.province,
      version: "3.2.3", wsgwType: "android", ip: "127.0.0.1", os: "android", "User-Agent": "okhttp/3.14.9"
    };
    const result = await queryOnce({ url: URL, headers,
      body: JSON.stringify({ data, sign: sm3hex(skey + data + timestamp), skey, timestamp }),
      node: "DIRECT", timeout: 15000, "auto-redirect": false, "auto-cookie": false, insecure: false
    });
    if (result.timedOut || result.networkError) {
      report.result = result.timedOut ? "network_timeout" : "network_or_tls_error";
      report.note = "这次网络请求未取得可判断的响应，不能据此判断 token 是否失效。没有重试。";
      return;
    }
    const status = Number(result.response && (result.response.status || result.response.statusCode));
    report.httpStatus = Number.isInteger(status) && status >= 100 && status <= 599 ? status : null;
    if (report.httpStatus !== null && report.httpStatus >= 300 && report.httpStatus < 400) {
      report.result = "redirect_not_followed";
      report.note = "服务端返回重定向，已停止，未向其他地址发送凭据。";
      return;
    }
    if (typeof result.body !== "string" || result.body.length > 524288) stop("response_unreadable");
    let outer; try { outer = JSON.parse(result.body); } catch (_) { stop("response_unreadable"); }
    if (!outer || typeof outer !== "object" || Array.isArray(outer)) stop("response_unreadable");
    if (!outer.respKey || !outer.encryptData) {
      report.responseLayer = "outer";
      describeFailure(outer.code, outer.message);
      return;
    }
    report.encryptedEnvelopePresent = true;
    const responseKey = String(outer.respKey), ciphertext = String(outer.encryptData);
    if (!/^[0-9a-f]+$/i.test(responseKey) || responseKey.length < 192 || !/^[0-9a-f]+$/i.test(ciphertext) || ciphertext.length % 32 !== 0) stop("response_envelope_invalid");
    const keyText = verifiedResponseKey(responseKey);
    if (keyText.length < 16) stop("response_key_invalid");
    let response; try { response = JSON.parse(utf8dec(sm4DecryptHex(ciphertext, keyText))); } catch (_) { stop("response_decryption_or_json_failed"); }
    if (!response || typeof response !== "object" || Array.isArray(response)) stop("response_unreadable");
    report.responseLayer = "encrypted";
    const payload = response.data && typeof response.data === "object" && !Array.isArray(response.data) ? response.data : {};
    const service = payload.srvrt && typeof payload.srvrt === "object" ? payload.srvrt : null;
    const code = service ? String(service.resultCode == null ? "" : service.resultCode) : String(response.code == null ? "" : response.code);
    const message = service ? service.resultMessage : response.message;
    if (service ? code !== "0000" : code !== "1") { describeFailure(code, message); return; }
    report.code = safeCode(code);
    report.businessCode = safeCode(payload.rtnCode);
    if (String(payload.rtnCode) === "1") {
      report.balanceNumeric = typeof payload.rtnData === "number" ? Number.isFinite(payload.rtnData) : typeof payload.rtnData === "string" && /^-?\d+(\.\d+)?$/.test(payload.rtnData);
      if (!(report.httpStatus >= 200 && report.httpStatus < 300)) {
        report.result = "http_status_unconfirmed";
        report.note = "业务层有成功码，但HTTP状态异常或缺失；不把这次响应标记为完整查询成功。";
      } else if (!report.balanceNumeric) {
        report.result = "balance_payload_unconfirmed";
        report.note = "业务层返回成功码，但余额数据缺失或结构异常。尚不能确认完整查询成功，也不能据此判 token 失效。";
      } else {
        report.result = "accepted_for_balance_query";
        report.note = "本次余额查询成功，降低全局会话失效的嫌疑；不代表签到接口风控通过。余额数值不输出，不再请求其他接口。";
      }
    } else {
      describeFailure(payload.rtnCode, payload.rtnMessage);
    }
  }

  // Protocol helpers copied from current SGCC R9; no login/SMS/Env/deviceToken generation.
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

const SERVER_PUB = '0409C10D38CF7B4E28097EAAA519E3157C9B4E72194CD13BD11932CE40ED5624AFEFF27F78893E4C4FC2029DA147AB6CEAE0CDC8E3A547EFCDC5AB91757FE1CA60';

const CLIENT_PRIV = '50C4AF48DF75808050729977AA6BC127DC21A404755C660B94222F9D50FA4A75';

function cnNow() { const d = new Date(Date.now() + 8 * 3600000); const p = (n, l = 2) => String(n).padStart(l, '0'); return { s14: `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}`, ms: p(d.getUTCMilliseconds(), 3), y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: d.getUTCDate() }; }

function reqTimestamp() { const n = cnNow(); return n.s14 + n.ms + randStr(6, '0123456789'); }

function appGuidNew() { const n = cnNow(); return randStr(40, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789') + n.s14 + n.ms + String(100 + (randomBytes(2)[0] * 256 + randomBytes(1)[0]) % 900); }


  main().catch(e => {
    report.result = "stopped";
    report.stopReason = e && e.safeCode ? e.safeCode : "protocol_or_runtime_error";
    report.note = "本次检查已停止；没有重试、重登录、发短信或修改存储。不输出异常原文。";
  }).finally(finish);
})();
