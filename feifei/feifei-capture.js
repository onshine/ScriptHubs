/*
 * feifei-capture.js — R1.0.2 —— 自动抓取「飞飞币」接口的登录凭证（Authorization）
 *
 * 由 Feifei.plugin 的 request 规则触发，把 Authorization 写进 $persistentStore 的
 * feifei_token，feifei.js 直接复用。抓包只在本机、只存 Loon 本地存储。
 *
 * R1.0.2 自检：
 *   · 命中接口并取到凭证 → 首次/换新凭证时推一条「已获取登录凭证」（同样的凭证只提示一次）
 *   · 命中接口但没找到 Authorization → 每天提示一次（说明 MITM 已通、但凭证不在这个头里）
 *   · 规则完全没触发 → 不会有任何提示（说明 MITM 没解密，见 README 排查）
 */

(function () {
  var KEY = "feifei_token";
  var KEY_AT = "feifei_token_at";
  var KEY_SEEN = "feifei_token_seen";
  var KEY_MISS = "feifei_token_miss";

  function hash(s) {
    var h = 0;
    for (var i = 0; i < s.length; i++) { h = (h * 31 + s.charCodeAt(i)) >>> 0; }
    return h.toString(16) + "-" + s.length;
  }

  function today() {
    var d = new Date();
    return d.getFullYear() + "-" + (d.getMonth() + 1) + "-" + d.getDate();
  }

  function notify(title, sub, body) {
    try { if (typeof $notification !== "undefined" && $notification.post) $notification.post(title, sub, body); } catch (e) { }
  }

  function finish() { $done({}); }

  if (typeof $request === "undefined" || !$request) return finish();

  var url = $request.url || "";
  var h = $request.headers || {};
  var auth = "";
  for (var k in h) {
    if (k.toLowerCase() === "authorization") { auth = String(h[k] || ""); break; }
  }
  console.log("[feifei-capture] hit " + url.split("?")[0]);

  /* ---- 没找到 Authorization：说明 MITM 通了但位置不对，每天提示一次 ---- */
  if (!auth) {
    console.log("[feifei-capture] 未找到 Authorization，header keys=" + Object.keys(h).join(","));
    if ($persistentStore.read(KEY_MISS) !== today()) {
      $persistentStore.write(today(), KEY_MISS);
      notify("飞飞币 · 抓包自检", "命中接口但没有 Authorization",
        "MITM 已生效，但这条请求里没有凭证。\n请在家长端「飞飞币」页面下拉刷新一次再试；若仍提示，说明这个页面的凭证另有来源。");
    }
    return finish();
  }

  auth = auth.trim();
  if (!/v01_|Bearer/i.test(auth)) {
    console.log("[feifei-capture] Authorization 格式不认识，忽略");
    return finish();
  }
  if (!/^bearer\s/i.test(auth)) auth = "Bearer " + auth;

  var hh = hash(auth);
  var old = $persistentStore.read(KEY) || "";

  if (old === auth) {
    $persistentStore.write(String(Date.now()), KEY_AT);   // 续期时间，便于排查
    console.log("[feifei-capture] 凭证未变化，已刷新时间戳");
    return finish();
  }

  $persistentStore.write(auth, KEY);
  $persistentStore.write(String(Date.now()), KEY_AT);
  console.log("[feifei-capture] 已保存凭证，尾部 ****" + auth.slice(-4) + "，长度 " + auth.length);

  if ($persistentStore.read(KEY_SEEN) !== hh) {
    $persistentStore.write(hh, KEY_SEEN);
    notify("飞飞币 · 已获取登录凭证",
      old ? "凭证已更新" : "凭证已保存",
      "尾部 ****" + auth.slice(-4) + "（长度 " + auth.length + "）\n现在可以在插件里点「飞飞币签到」运行了。");
  }
  finish();
})();
