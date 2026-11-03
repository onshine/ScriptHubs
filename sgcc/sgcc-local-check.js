/**
 * 网上国网本地体检
 * @Version: R1.0.1
 * @Updated: 2026-11-03
 * 只读 $persistentStore；不发 HTTP 请求、不登录、不发短信、不修改存储。
 * 输出仅包含状态、相对时间和比较结果，不输出手机号、密码、token、用户ID或设备令牌。
 */
(function () {
  const SCRIPT_VERSION = "R1.0.1";
  const report = { version: SCRIPT_VERSION, networkRequests: 0, storageWrites: 0 };
  const now = Date.now();
  function read(key) {
    try { return $persistentStore.read(key); } catch (_) { throw new Error("local_store_read_failed"); }
  }
  function readJSON(key) {
    const raw = read(key);
    if (!raw) return { state: "empty", value: null };
    try {
      const v = JSON.parse(raw);
      return { state: v && typeof v === "object" && !Array.isArray(v) ? "object" : "invalid", value: v };
    } catch (_) { return { state: "invalid", value: null }; }
  }
  function present(v) { return v !== null && v !== undefined && String(v).length > 0; }
  function validID(v) { return present(v) && String(v) !== "0" && String(v) !== "undefined" && String(v) !== "null"; }
  function same(a, b) { return present(a) && present(b) ? String(a) === String(b) : null; }
  try {
    if (typeof $persistentStore === "undefined" || !$persistentStore || typeof $persistentStore.read !== "function") {
      report.status = "store_unavailable";
      report.note = "必须在 Loon 内运行；当前环境不能读取 Loon 存储。";
      console.log(JSON.stringify(report, null, 2));
      return;
    }
    const sessionRecord = readJSON("sgcc_session");
    const deviceRecord = readJSON("sgcc_device");
    const appRecord = readJSON("sgcc_data");
    const s = sessionRecord.state === "object" ? sessionRecord.value : {};
    const d = deviceRecord.state === "object" ? deviceRecord.value : {};
    const a = appRecord.state === "object" ? appRecord.value : {};
    const tok = d.tok && typeof d.tok === "object" ? d.tok : {};
    const exp = Number(s.exp);
    report.session = {
      record: sessionRecord.state,
      tokenPresent: present(s.token),
      accountPresent: present(s.user),
      userIdPresent: present(s.userId),
      userIdNonzero: validID(s.userId),
      provincePresent: present(s.province),
      locallyExpiresInDays: Number.isFinite(exp) && exp > 0 ? Math.round((exp - now) / 86400000 * 100) / 100 : null,
      serverValidity: "UNKNOWN: 本地有效期不能证明服务端仍认可"
    };
    const created = Number(tok.ts);
    const tokenTime = Number(tok.time);
    report.device = {
      record: deviceRecord.state,
      seedPresent: present(d.seed),
      deviceTokenPresent: present(tok.token),
      v3Token: typeof tok.token === "string" && tok.token.indexOf("v3:") === 0,
      tokenAgeHours: Number.isFinite(created) && created > 0 ? Math.round((now - created) / 3600000 * 100) / 100 : null,
      tokenTimestampConsistent: created > 0 && tokenTime > 0 ? Math.abs(tokenTime * 1000 - created) < 2000 : null
    };
    report.capturedApp = {
      record: appRecord.state,
      tokenPresent: present(a.t),
      userIdNonzero: validID(a.userid || a.userId),
      sameUserIdAsScript: same(a.userid || a.userId, s.userId),
      sameTokenAsScript: same(a.t, s.token),
      note: "不同客户端的 token 可以不同；比较结果不单独判定故障"
    };
    const riskUntil = Number(read("sgcc_risk_until"));
    report.localCooldownMinutes = Number.isFinite(riskUntil) && riskUntil > now ? Math.ceil((riskUntil - now) / 60000) : 0;
    report.loon = { runningMode: "unknown", note: "Loon DIRECT 不排除家庭网关另行代理" };
    if (typeof $config !== "undefined" && $config && typeof $config.getConfig === "function") {
      const cfg = JSON.parse($config.getConfig() || "{}");
      const modes = { 0: "DIRECT", 1: "RULE", 2: "GLOBAL_PROXY" };
      report.loon.runningMode = modes[cfg.running_model] || "unknown";
    }
    console.log(JSON.stringify(report, null, 2));
    if (typeof $notification !== "undefined" && $notification && typeof $notification.post === "function") {
      $notification.post("网上国网本地体检", "只读完成：零网络请求、零存储修改", "凭证记录=" + report.session.record + "；用户ID非零=" + report.session.userIdNonzero + "；设备记录=" + report.device.record + "。详细结果见日志，不包含任何凭据。");
    }
  } catch (_) {
    report.status = "check_incomplete";
    report.note = "读取或解析诊断状态中断；不输出异常原文，请确认在 Loon 内运行并允许读取存储。";
    console.log(JSON.stringify(report, null, 2));
  } finally {
    if (typeof $done === "function") $done({ title: "网上国网本地体检 " + SCRIPT_VERSION, content: JSON.stringify(report, null, 2) });
  }
})();
