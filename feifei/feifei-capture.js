/*
 * feifei-capture.js — R1.0.0 —— 自动抓取「飞飞币」接口的登录在凭证（Authorization）
 *
 * 由 feifei.plugin 的 [Rewrite] http-request 触发：
 *   学习机家长端 App 打开「飞飞币」页面时，脚本把 Authorization 写入
 *   $persistentStore 的 feifei_token，feifei.js 直接复用。
 * 抓包只发生在本机、只存本地 Loon 存储，不上传任何地方。
 */

(function () {
  if (!$request) return $done({});
  var h = $request.headers || {};
  var auth = "";
  for (var k in h) {
    if (k.toLowerCase() === "authorization") { auth = h[k]; break; }
  }
  if (auth && /v01_|Bearer/i.test(auth)) {
    var old = $persistentStore.read("feifei_token") || "";
    if (old !== auth) {
      $persistentStore.write(auth, "feifei_token");
      console.log("[feifei] 已更新 Token " + auth.slice(0, 24) + "…");
    }
  }
  $done({});
})();
