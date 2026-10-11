/***************************************************************
 *  车来了 · 每日签到（7天连续签）  |  Loon http-request + cron 脚本
 *  ------------------------------------------------------------
 *  SCRIPT_VERSION : R1.0.6
 *  适配           : 车来了 iOS App 7.6.3（web.chelaile.net.cn/api/op-activity-api/daily-act/*）
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
 *  实测结论（2026-10-11 基于真实 HAR 逆向 + 在线逐条验证）：
 *    · 凭证只需两个参数：udid + accountId
 *      —— secret / cityId / s 均可省略；只给 udid 会拿到「匿名」数据
 *         （signRewards[0].status = unsigned），必须带 accountId 才能识别本人
 *    · Cookie 完全不需要
 *    · 请求里的 sign / signature / nonce / h5TimeStamp 是装饰性的，服务端不校验
 *      （伪造或直接不带都返回 200）
 *    · 唯一硬性要求：请求头里必须存在 Referer（值不校验，缺失则返回 400）
 *
 *  设计原则：
 *    · 抓包钩子只读 URL、不碰 body（requires-body=false），用裸 $done() 原样放行
 *    · 判断「今天是否已签」以 signRewards[].signDate == 今天 为准，
 *      不能只看 status=="signed"（那是周期内状态，昨天签的今天也会是 signed）
 *    · 任何异常一律不写坏数据、不误报成功
 ***************************************************************/

const SCRIPT_VERSION = "R1.0.6";
const NAME = "车来了签到";
const STORE_KEY = "chelaile_checkin_cred";
const WARN_KEY = "chelaile_checkin_warn";
const HIT_KEY = "chelaile_checkin_hit";
const NOTICE_KEY = "chelaile_checkin_notice";
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
function notify(title, subtitle, body) {
  if (typeof $notify !== "undefined") return $notify(title, subtitle, body);                  // Surge
  if (typeof $notification !== "undefined") return $notification.post(title, subtitle, body); // Loon / QX
}
function readArg() {
  if (typeof $argument === "undefined") return {};
  let a = $argument;
  if (typeof a === "string") { try { a = JSON.parse(a); } catch (_) { return {}; } }
  if (!a || typeof a !== "object") return {};
  // 兼容位置数组写法 argument=[{udid},{accountId},...]
  if (Array.isArray(a)) {
    return { udid: a[0], accountId: a[1], notify_when_signed: a[2], notify_on_capture: a[3], debug: a[4] };
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
function mask(v) { v = String(v || ""); return v.length > 8 ? v.slice(0, 6) + "***len=" + v.length : v; }

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
  if (!/web\.chelaile\.net\.cn\//.test(url)) return done({});

  const arg = readArg();
  const WANT_CAPTURE_NOTIFY = String(arg.notify_on_capture) !== "false";   // 默认开
  const DEBUG = String(arg.debug) === "true";

  // 【诊断】首次命中时提示一次：用来区分「MITM 没生效」和「抓到了但解析不出凭证」
  {
    let hit = false;
    try { hit = $persistentStore.read(HIT_KEY) === "1"; } catch (_) {}
    if (!hit) {
      log("[钩子] 首次命中: " + url.slice(0, 200));
      try { $persistentStore.write("1", HIT_KEY); } catch (_) {}
      notify(NAME, "✅ 钩子已触发", "已成功拦到车来了的请求，说明 MITM 工作正常。\n\n" + url.slice(0, 150));
    } else {
      log("[钩子] 命中: " + url.slice(0, 200));
    }
  }

  const q = pickQuery(url);

  if (q.udid && q.accountId) {
    const old = storeRead();
    const changed = !old || old.udid !== q.udid || old.accountId !== q.accountId;
    if (changed) {
      storeWrite({ udid: q.udid, accountId: q.accountId, updatedAt: Date.now() });
      log(`已捕获凭证 udid=${mask(q.udid)} accountId=${q.accountId}`);
    }
    if (WANT_CAPTURE_NOTIFY) {
      let last = "";
      try { last = $persistentStore.read(NOTICE_KEY) || ""; } catch (_) {}
      const today = localDate();
      if (changed) {
        try { $persistentStore.write(today, NOTICE_KEY); } catch (_) {}
        notify(NAME, "✅ 已获取签到凭证", `udid: ${mask(q.udid)}\naccountId: ${q.accountId}\n\n凭证已保存，之后每天自动签到，无需再操作。`);
      } else if (last !== today) {
        try { $persistentStore.write(today, NOTICE_KEY); } catch (_) {}
        notify(NAME, "✅ 凭证正常", `已成功拦到车来了的请求，凭证可用。\nudid: ${mask(q.udid)}\naccountId: ${q.accountId}\n\n（每天首次打开签到页提示一次，可在插件开关里关闭）`);
      }
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
  const WANT_SIGNED_NOTIFY = String(arg.notify_when_signed) !== "false";   // 默认开启，显式传 false 才关闭
  log(`脚本版本 ${SCRIPT_VERSION}`);

  // 凭证优先级：Argument 手填 > 抓包存储
  const saved = storeRead();
  const cred = {
    udid: (arg.udid && String(arg.udid).trim()) || (saved && saved.udid) || "",
    accountId: (arg.accountId && String(arg.accountId).trim()) || (saved && saved.accountId) || "",
  };
  if (!cred.udid || !cred.accountId) {
    const msg = "缺少凭证。请先打开车来了 App → 进入「每日签到」页一次（脚本会自动抓取），"
      + "或在插件 Argument 里手动填写 udid / accountId。";
    log(msg);
    notify(NAME, "⚠️ 未配置凭证", msg);
    return done();
  }
  log(`凭证来源: ${(arg.udid && String(arg.udid).trim()) ? "Argument" : "抓包存储"}  udid=${mask(cred.udid)} accountId=${cred.accountId}`);

  // ---- 4.1 查配置，判断今天是否已签 ----
  const cfgR = await httpGetJSON(API + "config?" + qs(cred));
  if (DEBUG) log("config 原始响应: " + String(cfgR._raw || "").slice(0, 400));
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
  if (DEBUG) log("signin 原始响应: " + String(sigR._raw || "").slice(0, 400));
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
  } else {
    const why = sigR._err ? sigR._err : (errmsg || `status=${status} HTTP ${sigR._http}`);
    log("签到失败: " + why);
    notify(NAME, "❌ 签到失败", String(why).slice(0, 120));
  }
  return done();
}
