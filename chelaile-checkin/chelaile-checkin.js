/***************************************************************
 *  车来了 · 每日签到（7天连续签）  |  Loon http-request + cron 脚本
 *  ------------------------------------------------------------
 *  SCRIPT_VERSION : R1.0.12
 *  适配           : 车来了 iOS App 7.6.6（web.chelaile.net.cn/api/op-activity-api/daily-act/*）
 *
 *  R1.0.12 变更：
 *    · [Argument] 的 desc 里写进 cron 格式示例（顺序是「分 时 日 月 周」，分在前时在后；
 *      并说明逗号是「多个值」不是分隔符）—— 填错顺序是最常见的手误。
 *    · 新增 cron 频率自检：估算一天触发次数，超过 6 次就推一条提醒（每天只提醒一次）。
 *      典型手误 `01,00 * * * *`（本意 00:01）实际是「每小时第 0 和第 1 分」= 一天 48 次。
 *
 *  R1.0.11 变更（★ 修「cron 从来不执行」）：
 *    · 插件改为官方 v2 Script 语法（Loon 3.5.1/983+），cron 用 ${cron} 而不是旧式 {cron}。
 *      依据：官方「本地/远程/插件 能力对照表」里 **动态 Cron 只有插件作用域支持**，
 *      且官方示例只给 `cron ${cronExpression} then script(...)` 这一种写法；
 *      Plugin.md 明确「Cron 表达式无效时，对应脚本不会执行」。
 *      旧语法 {cron} 在 cron 位置不被识别为参数 -> 表达式成了字面量 -> 无效 -> 静默不执行。
 *      （这也解释了为什么把参数值改成「每 5 分钟」依然没用：坏的是占位符，不是值。）
 *    · 新增 backup_silent：兜底那趟在当天已签时静默，避免每天两条通知。
 *
 *  R1.0.10 变更（★ 修「7.6.6 起抓凭证通知没了」）：
 *    · 抓包钩子匹配范围从「只挂 web.chelaile.net.cn」放宽到**车来了全部域名
 *      + 它的 HTTPDNS 直连 IP**（api / cdn.api / *.chelaileapp.cn / 124.70.194.16 / 124.71.153.172）。
 *      原因：7.6.6 起 accountId / secret 常常不再进 URL（改由 App 原生桥 userLogIn 提供），
 *      签到 H5 页可能只带 udid → 老钩子收不全 → 不落盘、也不发通知。
 *    · 改为**合并式采集**：本条 URL 有什么就收什么，缺的用已存的补，三件套凑齐才落盘。
 *    · 修一个真 bug：通知块里引用了已改名的变量（changed），会抛 ReferenceError 被外层
 *      catch 吞掉 —— 这本身就表现为「脚本没反应、不弹通知」。
 *
 *  R1.0.8 变更：
 *    · 通知：优先 $notification.post（Loon/Surge/Stash 的标准 API），$notify 作 QX 兜底；
 *      全程 try/catch，并把「已发送通知 / 无可用接口 / 发送失败」写进运行日志；
 *      cron 启动时打印通知环境，一眼可判。
 *    ⚠️ 更正一条写错的说明：曾记成「$notify（QX 的 API）会短路掉通知」——**那不对**。
 *      Loon 官方「公开 API 清单」里**只有 $notification.post，没有 $notify**；
 *      带 typeof 守卫时两种顺序都安全（守卫会跳过不存在的那个）。
 *      真正要注意的是：**别写不带守卫的 $notify(...)**，在 Loon 上会抛 ReferenceError。
 *    · 默认执行时间改为每天 00:01，另加一条 08:05 静默补签兜底（见插件）
 *
 *  R1.0.7 变更（★ 修「签到一直失败」）：
 *    · 实测发现 signin 与 config 的鉴权**不一样**：
 *        - config 只要 udid + accountId 就能读
 *        - signin 还**必须**带 secret 和 s，否则一律返回
 *          {"status":"0002","errmsg":"非法请求"} —— 而 0002 一直被我误判成「凭证伪造」
 *      现在抓包钩子会一并收下 secret / s，cron 三个接口都带上。
 *    · s 只要非空即可（实测填 "1" 也能签到成功），默认 "1"。
 *    · 0002 现在会提示「secret 缺失，请重新打开一次每日签到页」而不是笼统报错。
 *    · 通知：优先 $notification.post，$notify 作 QX 兜底（全程 try/catch + 日志留痕）。
 *    ⚠️ 更正一条写错的说明：曾记成「$notify（QX 的 API）会短路掉通知」——**那不对**。
 *      Loon 官方「公开 API 清单」里**只有 $notification.post，没有 $notify**；
 *      带 typeof 守卫时两种顺序都安全（守卫会跳过不存在的那个）。
 *      真正要注意的是：**别写不带守卫的 $notify(...)**，在 Loon 上会抛 ReferenceError。
 *    · cron 启动时打印通知环境（$notification / $notify 的类型），一眼可判。
 *    · ★ 修插件传参与脚本解析不一致：插件写的是 argument=[{"udid":…,"accountId":…}]，
 *      而脚本原来按「位置数组」解析，会把整个对象当成 udid（"[object Object]"）。
 *      现在两种形态都兼容，并加了值类型守卫。
 *    · ⚠️ 安全：日志与通知里的 URL 一律脱敏（原来「首次命中」会把带 secret 的完整
 *      URL 推成通知，锁屏直接可见）。debug 默认改为关。
 *
 *  R1.0.6 变更：
 *    · 抓凭证通知改为「凭证变化时提示」+「每天首次打开签到页提示一次」，
 *      解决「凭证早就存好了，再开 App 毫无提示、以为失效」的疑虑。
 *      仍然只读 URL 不碰 body，可用 notify_on_capture 开关关闭。
 *
 *  R1.0.5 变更：
 *    · 恢复 [Argument] 里的 switch 开关写法（抓到凭证时通知 / 已签到也通知 / 调试日志）；
 *      cron、udid、accountId 仍保持纯文本值（input,"…" 会导致 Loon 解析不出条目）。
 *      脚本逻辑未变。
 *
 *  R1.0.4 变更：
 *    · 插件 [Argument] 改用纯文本值写法（与 9nb 插件一致），去掉 input,"..."；
 *      [Script] 段去掉全部注释行，与实测可用插件格式完全对齐。
 *    · readArg 兼容对象 / 位置数组两种传参形态。
 *    · 「首次命中」诊断通知改为无条件触发（只提示一次），便于定位钩子是否工作。
 *
 *  R1.0.3 变更：
 *    · 抓包匹配范围放宽到整个 web.chelaile.net.cn（原来只匹配 /api/op-activity-api/），
 *      这样打开签到页本身就会命中。
 *    · 新增「首次命中」诊断通知（debug=开时）。
 *
 *  R1.0.2 变更：
 *    · 抓到凭证后**推送通知**（R1.0.1 只写运行日志，用户看不到任何反馈）；
 *      可用 notify_on_capture=false 关闭。同一个凭证只提示一次，不刷屏。
 *    · 钩子被命中但 URL 里缺 accountId 时，提示一次排查线索。
 *
 *  R1.0.1 变更：
 *    · notify_when_signed 默认改为「开」——当天已签到时也推送通知；
 *      脚本侧同步改为「未显式传 false 即通知」，避免手动挂载时静默。
 *
 *  实测结论（2026-10-11 初判 + 2026-10-12 修正，均在线逐条验证）：
 *    · 读接口 config：只需 udid + accountId
 *    · 写接口 signin：额外**必须**带 secret + s
 *        - 只给 udid + accountId        → 0002 非法请求
 *        - 补上 secret（缺 s）          → 400 Missing Request Parameter: s
 *        - 补上 secret + s（s 随便填）  → 00 签到成功 ／ 1002 今日已签到
 *      ⚠️ 原先把 0002 当成「凭证伪造」，是错的 —— 0002 的真实含义是「缺 secret」。
 *    · H5 页面里 sdkCall("crypto") 算的 signature、以及 nonce/h5TimeStamp，
 *      服务端**并不校验**（那套只走 App 原生桥，网页里没有 JS 兜底，我们复现不了，
 *      但也不需要复现）。
 *    · Cookie 完全不需要
 *    · 唯一硬性请求头要求：必须存在 Referer（值不校验，缺失则返回 400）
 *
 *  设计原则：
 *    · 抓包钩子只读 URL、不碰 body（requires-body=false），用裸 $done() 原样放行
 *    · 判断「今天是否已签」以 signRewards[].signDate == 今天 为准，
 *      不能只看 status=="signed"（那是周期内状态，昨天签的今天也会是 signed）
 *    · 任何异常一律不写坏数据、不误报成功
 ***************************************************************/

const SCRIPT_VERSION = "R1.0.12";
const NAME = "车来了签到";
const STORE_KEY = "chelaile_checkin_cred";
const WARN_KEY = "chelaile_checkin_warn";
const HIT_KEY = "chelaile_checkin_hit";
const NOTICE_KEY = "chelaile_checkin_notice";
const CRONWARN_KEY = "chelaile_checkin_cronwarn";
const API = "https://web.chelaile.net.cn/api/op-activity-api/daily-act/";
const REFERER = "https://web.chelaile.net.cn/app-relate/everyday-sign/index.html";
const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Chelaile/7.6.3";
// 静态资源后缀：钩子万一命中必须立即放行，绝不参与处理，否则会破坏响应
const STATIC_EXT = /\.(?:css|js|mjs|json|map|png|jpe?g|gif|webp|avif|svg|ico|bmp|woff2?|ttf|otf|eot|mp3|mp4|webm|ogg|wav|pdf|zip|gz|rar|7z|txt|xml)(?:$|[?#])/i;

/* ------------------------------------------------------------------
 * 0. 宿主适配
 * ------------------------------------------------------------------ */
function done(payload) { if (typeof $done !== "undefined") $done(payload || {}); }
function log(s) { console.log(`[${NAME}] ${s}`); }
// ⚠️ 顺序很重要：Loon / Surge 的标准 API 是 $notification.post，
// 而 $notify 是 Quantumult X 的写法。原来把 $notify 放在前面，
// 一旦宿主里存在 $notify（哪怕只是兼容空壳），就会短路掉真正能用的接口 → 通知静默消失。
function notifyEnv() {
  let a = "无", b = "无";
  try { a = typeof $notification + (($notification && typeof $notification.post === "function") ? ".post✅" : ".post❌"); } catch (_) {}
  try { b = typeof $notify; } catch (_) {}
  return `$notification=${a} $notify=${b}`;
}
function notify(title, subtitle, body) {
  try {
    if (typeof $notification !== "undefined" && $notification
        && typeof $notification.post === "function") {
      $notification.post(title, subtitle, body);
      log(`已发送通知: ${subtitle}`);
      return;
    }
    if (typeof $notify === "function") {                 // Quantumult X
      $notify(title, subtitle, body);
      log(`已发送通知(QX): ${subtitle}`);
      return;
    }
    log(`⚠️ 无可用通知接口（${notifyEnv()}），仅写日志: ${subtitle}`);
  } catch (e) {
    log(`⚠️ 通知发送失败: ${(e && e.message ? e.message : e)}（${notifyEnv()}）`);
  }
}
function readArg() {
  if (typeof $argument === "undefined") return {};
  let a = $argument;
  if (typeof a === "string") { try { a = JSON.parse(a); } catch (_) { return {}; } }
  if (!a || typeof a !== "object") return {};
  // Loon 的 argument=[{...}] 会解析成「只含一个对象的数组」，这时要按对象处理；
  // 也要兼容真正的位置数组写法 argument=[{udid},{accountId},...]
  if (Array.isArray(a)) {
    if (a.length === 1 && a[0] && typeof a[0] === "object" && !Array.isArray(a[0])) return a[0];
    return { udid: a[0], accountId: a[1], secret: a[2], s: a[3],
             notify_when_signed: a[4], notify_on_capture: a[5], backup_silent: a[6], debug: a[7] };
  }
  return a;
}
function storeRead() {
  if (typeof $persistentStore === "undefined") return null;
  try { return JSON.parse($persistentStore.read(STORE_KEY) || "null"); } catch (_) { return null; }
}
function storeWrite(obj) {
  if (typeof $persistentStore === "undefined") return;
  $persistentStore.write(JSON.stringify(obj), STORE_KEY);
}
function httpGetJSON(url) {
  return new Promise((resolve) => {
    if (typeof $httpClient === "undefined") return resolve({ _err: "no $httpClient" });
    $httpClient.get({ url, headers: { "User-Agent": UA, Referer: REFERER, Accept: "application/json, text/plain, */*" } },
      (err, resp, body) => {
        if (err) return resolve({ _err: String(err) });
        const code = (resp && (resp.status || resp.statusCode)) || 0;
        let txt = body;
        if (txt instanceof Uint8Array) { try { txt = new TextDecoder("utf-8").decode(txt); } catch (_) { txt = ""; } }
        if (typeof txt !== "string") txt = String(txt == null ? "" : txt);
        // 车来了部分接口会包一层 **YGKJ{...}YGKJ##，这里剥掉
        const m = txt.match(/\*\*YGKJ([\s\S]*?)YGKJ##/);
        if (m) txt = m[1];
        let json = null;
        try { json = JSON.parse(txt); } catch (_) {}
        resolve({ _http: code, _raw: txt, json });
      });
  });
}

/* ------------------------------------------------------------------
 * 1. 工具
 * ------------------------------------------------------------------ */
function localDate(d) {
  d = d || new Date();
  const p = (n) => (n < 10 ? "0" : "") + n;
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}
function qs(obj) {
  return Object.keys(obj).filter((k) => obj[k] !== undefined && obj[k] !== null && obj[k] !== "")
    .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(obj[k])}`).join("&");
}
function pickQuery(url) {
  const out = {};
  const i = String(url).indexOf("?");
  if (i < 0) return out;
  String(url).slice(i + 1).split("&").forEach((kv) => {
    const j = kv.indexOf("=");
    if (j < 0) return;
    try { out[decodeURIComponent(kv.slice(0, j))] = decodeURIComponent(kv.slice(j + 1)); } catch (_) {}
  });
  return out;
}
// 参数取值守卫：只接受字符串/数字，拿到对象一律当空（防止传参错位把 "[object Object]" 当凭证用）
function argVal(v) {
  if (v == null) return "";
  if (typeof v === "object") return "";
  const t = String(v).trim();
  return /^\[object /i.test(t) ? "" : t;
}
function mask(v) { v = String(v || ""); return v.length > 8 ? v.slice(0, 6) + "***len=" + v.length : v; }
// 日志/通知里出现的 URL 必须脱敏 —— 凭证就在 query 里，直接推通知等于把 secret 贴到锁屏上
function maskUrl(u) {
  return String(u || "").replace(/([?&])(udid|accountId|secret|s|token|signature)=([^&]*)/gi,
    (m, sep, k, val) => sep + k + "=" + mask(decodeURIComponentSafe(val)));
}
function decodeURIComponentSafe(v) {
  try { return decodeURIComponent(v); } catch (_) { return v; }
}

/* ------------------------------------------------------------------
 * 2. 入口
 * ------------------------------------------------------------------ */
(async () => {
  try {
    if (typeof $request !== "undefined" && $request) return onCapture();
    if (typeof $response !== "undefined" && $response) return done({});
    return await onCron();
  } catch (e) {
    log("异常: " + (e && e.message ? e.message : e));
    return done({});
  }
})();

/* ------------------------------------------------------------------
 * 3. 抓包钩子：从 App 自己的请求里收下 udid / accountId
 *    —— 只在 daily-act 路径命中时才存，且绝不改动请求
 * ------------------------------------------------------------------ */
function onCapture() {
  const url = ($request && $request.url) || "";
  if (STATIC_EXT.test(url)) return done({});          // 二重保险：静态资源一律放行
  // 车来了的所有域名 + 它的 HTTPDNS 直连 IP（HTTP 请求不需要 MITM 也能看见 URL）
  // 注意：chelaile.net.cn 与 chelaileapp.cn 结构不同，必须显式列举，不能用 chelaile(app)?\.cn 糊
  if (!/(^|\/\/)([a-z0-9-]+\.)*(chelaile\.net\.cn|chelaileapp\.cn)\b|^https?:\/\/124\.(?:70\.194\.16|71\.153\.172)\b/i.test(url)) {
    return done({});
  }

  const arg = readArg();
  const WANT_CAPTURE_NOTIFY = String(arg.notify_on_capture) !== "false";   // 默认开

  // 【诊断】首次命中时提示一次：用来区分「MITM 没生效」和「抓到了但解析不出凭证」
  {
    let hit = false;
    try { hit = $persistentStore.read(HIT_KEY) === "1"; } catch (_) {}
    const masked = maskUrl(url).slice(0, 200);
    if (!hit) {
      log("[钩子] 首次命中: " + masked);
      try { $persistentStore.write("1", HIT_KEY); } catch (_) {}
      notify(NAME, "\u2705 钩子已触发", "已成功拦到车来了的请求，说明 MITM 工作正常。\n\n" + masked.slice(0, 150));
    } else {
      log("[钩子] 命中: " + masked);
    }
  }

  // \u2605 合并式采集：App 7.6.6 起 udid / accountId / secret 常常分散在不同请求里
  //   （签到 H5 页可能只带 udid，accountId + secret 改由原生桥 userLogIn 提供、不再进 URL）。
  //   所以「本条 URL 有什么就收什么」，缺的用已存的补，三件套凑齐才落盘。
  const q = pickQuery(url);
  const old = storeRead() || {};
  const next = {
    udid: q.udid || old.udid || "",
    accountId: q.accountId || old.accountId || "",
    secret: q.secret || old.secret || "",
    s: q.s || old.s || "",
  };
  const complete = !!(next.udid && next.accountId && next.secret);
  if (!complete) {
    const lack = [!next.udid ? "udid" : "", !next.accountId ? "accountId" : "", !next.secret ? "secret" : ""]
      .filter(Boolean).join(" ");
    log(`[钩子] 片段（本条 URL 未带: ${lack}）`);
    return done({});
  }

  const changed = !old.udid || old.udid !== next.udid || old.accountId !== next.accountId
    || (old.secret || "") !== next.secret || (old.s || "") !== next.s;
  if (changed) {
    storeWrite(Object.assign({}, next, { updatedAt: Date.now() }));
    log(`已捕获凭证 udid=${mask(next.udid)} accountId=${next.accountId} secret=${mask(next.secret)}`);
  }

  if (WANT_CAPTURE_NOTIFY) {
    let last = "";
    try { last = $persistentStore.read(NOTICE_KEY) || ""; } catch (_) {}
    const today = localDate();
    if (changed) {
      try { $persistentStore.write(today, NOTICE_KEY); } catch (_) {}
      notify(NAME, "\u2705 已获取签到凭证",
        `udid: ${mask(next.udid)}\naccountId: ${next.accountId}\nsecret: 已捕获\n\n凭证已保存，之后每天自动签到，无需再操作。`);
    } else if (last !== today) {
      try { $persistentStore.write(today, NOTICE_KEY); } catch (_) {}
      notify(NAME, "\u2705 凭证正常",
        `已成功拦到车来了的请求，凭证可用。\nudid: ${mask(next.udid)}\naccountId: ${next.accountId}\n\n（每天首次打开车来了提示一次，可在插件开关里关闭）`);
    }
  }
  return done({});
}

/* ------------------------------------------------------------------
 * 4. cron：签到
 * ------------------------------------------------------------------ */
async function onCron() {
  const arg = readArg();
  const DEBUG = String(arg.debug) === "true";
  // 兜底那趟传 backup_silent：当天已签时静默（避免每天两条通知）
  const BACKUP_SILENT = arg.backup_silent === true || String(arg.backup_silent) === "true";
  const WANT_SIGNED_NOTIFY = !BACKUP_SILENT && String(arg.notify_when_signed) !== "false";
  log(`脚本版本 ${SCRIPT_VERSION}  通知环境: ${notifyEnv()}`);

  // 频率自检：cron 写错（最常见是把「分 时」顺序搞反、或用逗号当分隔符）会导致一天跑几十次。
  // 脚本本身是幂等的（已签即跳过），但会刷通知、也不像正常用户行为，所以提醒一次。
  checkCronSanity();

  // 凭证优先级：Argument 手填 > 抓包存储
  const saved = storeRead();
  const cred = {
    udid: argVal(arg.udid) || (saved && saved.udid) || "",
    accountId: argVal(arg.accountId) || (saved && saved.accountId) || "",
    secret: argVal(arg.secret) || (saved && saved.secret) || "",
    // s 只要非空即可（实测填 1 也能签到成功），所以给个默认值兜底
    s: argVal(arg.s) || (saved && saved.s) || "1",
  };
  if (!cred.udid || !cred.accountId) {
    const msg = "缺少凭证。请先打开车来了 App → 进入「每日签到」页一次（脚本会自动抓取），"
      + "或在插件 Argument 里手动填写 udid / accountId / secret。";
    log(msg);
    notify(NAME, "⚠️ 未配置凭证", msg);
    return done();
  }
  // secret 是 signin 的硬性要求（少了必返回 0002 非法请求），单独提示
  if (!cred.secret) {
    const msg = "缺少 secret（签到接口必须带，少了会返回「0002 非法请求」）。"
      + "请打开车来了 App →「每日签到」页面一次，脚本会自动抓取；"
      + "或在插件 Argument 里手动填写 secret。";
    log(msg);
    notify(NAME, "⚠️ 缺少 secret", msg);
    return done();
  }
  log(`凭证来源: ${argVal(arg.udid) ? "Argument" : "抓包存储"}  `
    + `udid=${mask(cred.udid)} accountId=${cred.accountId} secret=${mask(cred.secret)}`);

  // ---- 4.1 查配置，判断今天是否已签 ----
  const cfgR = await httpGetJSON(API + "config?" + qs(cred));
  if (DEBUG) log("config 原始响应: " + maskUrl(String(cfgR._raw || "")).slice(0, 400));
  const cfg = cfgR.json;
  if (!cfg || !cfg.data || !Array.isArray(cfg.data.signRewards)) {
    const why = cfgR._err ? cfgR._err : (cfg && cfg.errmsg) ? cfg.errmsg : `HTTP ${cfgR._http}`;
    log("读取活动配置失败: " + why);
    notify(NAME, "❌ 读取活动配置失败", String(why).slice(0, 120));
    return done();
  }

  const today = localDate();
  const rewards = cfg.data.signRewards;
  const signedToday = rewards.some((r) => r && r.signDate === today);
  const signDays = (cfg.data.userStatus && cfg.data.userStatus.signDays) || 0;
  const todayReward = rewards.find((r) => r && r.signDate === today);
  log(`今天=${today} 已签=${signedToday} 连续=${signDays}天 周期状态=[${rewards.map((r) => r.status).join(",")}]`);

  if (signedToday) {
    const body = `今日已签到 ✅\n连续签到 ${signDays} 天`
      + (todayReward ? `\n今日奖励：${todayReward.rewardValue} 金币` : "");
    if (WANT_SIGNED_NOTIFY) notify(NAME, "今日已签到", body);
    return done();
  }

  // ---- 4.2 执行签到 ----
  const sigR = await httpGetJSON(API + "signin?" + qs(cred));
  if (DEBUG) log("signin 原始响应: " + maskUrl(String(sigR._raw || "")).slice(0, 400));
  const sig = sigR.json;
  const status = sig && sig.status;
  const errmsg = (sig && sig.errmsg) || "";

  if (status === "00") {
    const rw = (sig.data && sig.data.rewardValue) ? sig.data.rewardValue : "?";
    const type = (sig.data && sig.data.rewardType) === "coin" ? "金币" : ((sig.data && sig.data.rewardType) || "奖励");
    log(`签到成功，奖励 ${rw} ${type}`);
    notify(NAME, "✅ 签到成功", `获得 ${rw} ${type}\n连续签到 ${signDays + 1} 天`);
  } else if (status === "1002" || /已签到/.test(errmsg)) {
    log("服务端提示今日已签到");
    notify(NAME, "今日已签到", errmsg || "已在其他地方完成签到");
  } else if (status === "0002") {
    const msg = "服务端返回「0002 非法请求」—— 按实测，这通常意味着 secret 不对或已过期。"
      + "请打开车来了 App →「每日签到」页一次让脚本重新抓取凭证。";
    log("签到失败: 0002 非法请求（secret 缺失或失效）");
    notify(NAME, "❌ 签到失败", msg);
  } else {
    const why = sigR._err ? sigR._err : (errmsg || `status=${status} HTTP ${sigR._http}`);
    log("签到失败: " + why);
    notify(NAME, "❌ 签到失败", String(why).slice(0, 120));
  }
  return done();
}

/* ------------------------------------------------------------------
 * 5. cron 频率自检
 *    最常见的手误：把「分 时」写反，或用逗号分隔时和分。
 *    例：`01,00 * * * *` 本意「00:01」，实际是「每小时的第 0 和第 1 分」= 一天 48 次。
 *    这里按「每天触发次数」估算，超过阈值就提醒（每天最多提醒一次，不刷屏）。
 * ------------------------------------------------------------------ */
function countsPerDay(field, total) {
  // 返回该字段一天内命中的次数；field 为 cron 的某一段
  const f = String(field || "*").trim();
  if (f === "*") return total;
  if (/^\*\/(\d+)$/.test(f)) {
    const step = parseInt(f.split("/")[1], 10);
    return step > 0 ? Math.ceil(total / step) : total;
  }
  // 逗号列举 / 单值 / 区间，粗略数一下
  let n = 0;
  for (const part of f.split(",")) {
    if (!part) continue;
    const m = part.match(/^(\d+)-(\d+)$/);
    if (m) n += Math.max(0, parseInt(m[2], 10) - parseInt(m[1], 10) + 1);
    else n += 1;
  }
  return n || total;
}

function checkCronSanity() {
  let expr = "";
  try { expr = String($script && $script.cron ? $script.cron : "").trim(); } catch (_) {}
  if (!expr) return;                       // 宿主没暴露就跳过，不影响签到
  const seg = expr.split(/\s+/);
  let min, hour;
  if (seg.length === 6) { min = seg[1]; hour = seg[2]; }      // 秒 分 时 日 月 周
  else if (seg.length === 5) { min = seg[0]; hour = seg[1]; } // 分 时 日 月 周
  else return;

  const perDay = countsPerDay(min, 60) * countsPerDay(hour, 24);
  if (perDay <= 6) return;                 // 一天 6 次以内属正常（含双次签到 + 兜底）

  log(`⚠️ cron「${expr}」估算一天会触发约 ${perDay} 次，可能写错了`);
  let last = "";
  try { last = $persistentStore.read(CRONWARN_KEY) || ""; } catch (_) {}
  const today = localDate();
  if (last === today) return;              // 每天只提醒一次
  try { $persistentStore.write(today, CRONWARN_KEY); } catch (_) {}
  notify(NAME, "⚠️ 定时设置可能写错了",
    `当前：${expr}\n估算一天触发约 ${perDay} 次。\n\n`
    + `顺序是「分 时 日 月 周」，分在前、时在后：\n`
    + `· 1 0 * * *  → 每天 00:01\n`
    + `· 30 8 * * * → 每天 08:30\n\n`
    + `逗号是「多个值」（如 8,20 两个小时都跑），不是用来分隔时和分。\n`
    + `签到本身是幂等的（已签即跳过），但建议改回每天 1～2 次。`);
}
