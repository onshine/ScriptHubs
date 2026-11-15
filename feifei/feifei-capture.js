/*
 * feifei-capture.js — R1.0.4 —— 自动抓取「飞飞币」接口的登录凭证（Authorization）
 *
 * 由 Feifei.plugin 的 request 规则触发，把 Authorization 写进 $persistentStore 的
 * feifei_token，feifei.js 直接复用。抓包只在本机、只存 Loon 本地存储。
 *
 * R1.0.4 自检升级（★ 用来证明 MITM 到底通不通，不需要打开 App）：
 *   · 新增「页面命中」分支：用 Safari 打开 https://xxj.xunfei.cn/h5-reward-shopping/
 *     若收到「MITM 已生效」通知 → 证书/解密这一层没问题，问题在 App 那条链路
 *     若什么都没收到 → MITM 确实没生效（证书未信任 / 主机名不在列表 / 未重载配置）
 *
 * R1.0.3 自检升级：
 *   · 每命中一次就写心跳（feifei_last_hit / feifei_last_url），签到脚本读它来判断
 *     「规则从没触发」还是「触发了但没凭证」——这是排查 MITM 是否生效的关键依据
 *   · Authorization 找不到时，扫一遍所有请求头，任何含 v01_ 的值都当凭证兜底
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
  var base = url.split("?")[0];

  /* 心跳：只要规则被触发就记一笔，签到脚本据此判断 MITM 有没有生效 */
  try {
    $persistentStore.write(String(Date.now()), "feifei_last_hit");
    $persistentStore.write(base, "feifei_last_url");
  } catch (e) { }

  var auth = "";
  for (var k in h) {
    if (k.toLowerCase() === "authorization") { auth = String(h[k] || ""); break; }
  }
  if (!auth) {                       // 兜底：任何头里带 v01_ 的都算
    for (var k2 in h) {
      var v = String(h[k2] || "");
      if (/v01_[A-Za-z0-9_\-\.]{10,}/.test(v)) { auth = v; console.log("[feifei-capture] 从头部 " + k2 + " 兜底取到凭证"); break; }
    }
  }
  console.log("[feifei-capture] hit " + base);

  /* ---- 没找到 Authorization ---- */
  if (!auth) {
    var isApi = /xunfeixxj\.com/.test(base);
    console.log("[feifei-capture] 未找到 Authorization，header keys=" + Object.keys(h).join(","));
    if ($persistentStore.read(KEY_MISS) !== today()) {
      $persistentStore.write(today(), KEY_MISS);
      if (isApi) {
        notify("飞飞币 · 自检", "命中接口但没有 Authorization",
          "解密正常，但这条请求里没有凭证。\n在家长端「飞飞币」页面下拉刷新一次；仍如此就在插件里手填 Token。");
      } else {
        notify("飞飞币 · 自检", "MITM 已生效 ✅",
          "已成功解密并命中页面请求：" + base + "\n说明证书与解密都没问题。\n→ 剩下的问题在 App 那条链路：确认你是在「装了 Loon 的这台设备」上打开的飞飞币页面。");
      }
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
