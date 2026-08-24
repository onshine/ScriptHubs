/*
 * QQ 群名片守卫 qq-group-guard R1.0.1
 * 支持 Loon / Quantumult X / Surge
 * 仓库：https://github.com/onshine/ScriptHubs/tree/main/qq-group-guard
 *
 * 用途：定时巡检 QQ 群成员名片（OneBot v11 / go-cqhttp / NapCat / Lagrange HTTP API），
 *      名片不含约定关键词的成员按「宽容模式」分级处理：
 *      观察期内只提醒改名，连续多轮仍不合规才踢出；带多重误伤保护。
 *
 * 三种模式：
 *   report  只报告，绝不动手（首次部署建议先跑几天）
 *   lenient 宽容模式（默认）：模糊匹配 + 观察期 + @提醒 + 连续多轮 + 单轮上限 + 比例熔断
 *   strict  严格模式：发现即踢（仍保留白名单/管理员/比例熔断保护）
 *
 * 版本：R1.0.1（与 SCRIPT_VERSION 及 README 保持一致）
 */

const SCRIPT_VERSION = "R1.0.1";
const NAME = "QQ群名片守卫";

// ── 读取插件 argument（兼容对象 / JSON 字符串 / k=v&k=v 三种形态）──
const ARG = parseArgument();

const API_BASE = String(ARG.api_base || "").trim().replace(/\/+$/, "");
const TOKEN = String(ARG.token || "").trim();
const GROUPS = splitList(ARG.group_id).map(Number).filter((n) => n > 0);
const KEYWORDS = splitList(ARG.keywords);
const MODE = normMode(ARG.mode);
const GRACE_HOURS = numArg(ARG.grace_hours, 48, 0);
const GRACE_ROUNDS = Math.max(1, Math.floor(numArg(ARG.grace_rounds, 2, 1)));
const NEW_MEMBER_DAYS = numArg(ARG.new_member_days, 3, 0);
const VETERAN_DAYS = numArg(ARG.veteran_days, 0, 0);
const WHITELIST = splitList(ARG.whitelist).map(Number).filter((n) => n > 0);
const SKIP_ADMIN = boolArg(ARG.skip_admin, true);
const SKIP_TITLE = boolArg(ARG.skip_title, true);
const SELF_QQ = Number(ARG.self_qq || 0) || 0;
const INTERVAL = numArg(ARG.interval, 1.5, 0);
const MAX_KICK = Math.max(0, Math.floor(numArg(ARG.max_kick, 5, 0)));
const MAX_RATIO = numArg(ARG.max_ratio, 30, 0);
const BREAKER_MIN = Math.max(0, Math.floor(numArg(ARG.breaker_min, 5, 0)));
const REJECT_ADD = boolArg(ARG.reject_add, false);
const WARN_IN_GROUP = boolArg(ARG.warn_in_group, true);
const WARN_TEMPLATE = String(
  ARG.warn_template ||
    "请在 {hours} 小时内把群名片改成含「{keywords}」的格式，否则将被移出本群。"
).trim();
const NOTIFY_OK = boolArg(ARG.notify_ok, false);
const TIMEOUT = Math.max(5, numArg(ARG.timeout, 20, 5)) * 1000;

const STORE_PREFIX = "qgg_pending_";

main().catch((e) => finish(`❌ 脚本异常：${e && e.message ? e.message : e}`));

async function main() {
  const cfgErr = checkConfig();
  if (cfgErr) return finish(cfgErr);

  console.log(
    `[${NAME} ${SCRIPT_VERSION}] 模式=${MODE} 群=${GROUPS.join(",")} 关键词=${KEYWORDS.join("/")}`
  );

  const blocks = [];
  let anyAction = false;

  for (const gid of GROUPS) {
    const r = await patrolGroup(gid);
    blocks.push(r.text);
    if (r.acted) anyAction = true;
  }

  const body = blocks.join("\n\n");
  console.log(`[${NAME}] 巡检结果：\n${body}`);

  if (anyAction || NOTIFY_OK) finish(body);
  else {
    console.log(`[${NAME}] 无需处理，按配置不推送通知`);
    done();
  }
}

// ── 单群巡检 ─────────────────────────────────────────────────
async function patrolGroup(gid) {
  const lines = [`【群 ${gid}】`];
  const res = await api("get_group_member_list", { group_id: gid });
  if (!res.ok) {
    lines.push(`❌ 拉取成员失败：${res.error || "HTTP " + res.status}`);
    return { text: lines.join("\n"), acted: true };
  }
  const members = Array.isArray(res.data) ? res.data : [];
  if (!members.length) {
    lines.push("⚠️ 成员列表为空，接口异常或无权限");
    return { text: lines.join("\n"), acted: true };
  }

  const now = Math.floor(Date.now() / 1000);
  const pending = loadPending(gid);
  const nextPending = {};

  const violators = [];
  let exempt = 0;

  for (const m of members) {
    const uid = Number(m.user_id || 0);
    if (!uid) continue;
    const name = displayName(m);
    if (isCompliant(name)) continue;

    const why = exemptReason(m, uid, now);
    if (why) {
      exempt++;
      continue;
    }
    violators.push({ uid, name, role: m.role || "member", join: Number(m.join_time || 0) });
  }

  lines.push(
    `成员 ${members.length} 人 · 不合规 ${violators.length} 人 · 豁免 ${exempt} 人`
  );

  if (!violators.length) {
    lines.push("✅ 全部合规");
    savePending(gid, {});
    return { text: lines.join("\n"), acted: false };
  }

  // 熔断：不合规比例过高，几乎必然是关键词配错，绝不动手
  // 需同时满足「比例超阈值」且「人数达下限」，避免小群 3/10 就误触发
  const ratio = (violators.length / members.length) * 100;
  if (MAX_RATIO > 0 && ratio > MAX_RATIO && violators.length >= BREAKER_MIN) {
    lines.push(
      `🛑 不合规占比 ${ratio.toFixed(1)}%（${violators.length} 人）超过熔断阈值 ${MAX_RATIO}%，已中止所有踢人操作`
    );
    lines.push("   请检查 keywords 是否配置正确");
    return { text: lines.join("\n"), acted: true };
  }

  // report：只报告
  if (MODE === "report") {
    lines.push("👀 report 模式，仅报告不执行：");
    violators.slice(0, 20).forEach((v) => lines.push(`   ${v.uid}  ${v.name}`));
    if (violators.length > 20) lines.push(`   ... 另有 ${violators.length - 20} 人`);
    return { text: lines.join("\n"), acted: true };
  }

  // 分流：观察期内 vs 已到期
  const toKick = [];
  const watching = [];

  for (const v of violators) {
    if (MODE === "strict") {
      toKick.push({ ...v, rounds: 1, hours: 0 });
      continue;
    }
    const old = pending[String(v.uid)];
    const first = old && old.first ? Number(old.first) : now;
    const rounds = (old && Number(old.rounds) ? Number(old.rounds) : 0) + 1;
    const hours = (now - first) / 3600;
    const rec = { first, rounds, name: v.name };

    if (rounds >= GRACE_ROUNDS && hours >= GRACE_HOURS) {
      toKick.push({ ...v, rounds, hours });
    } else {
      nextPending[String(v.uid)] = rec;
      watching.push({ ...v, rounds, hours });
    }
  }

  if (watching.length) {
    lines.push(`⏳ 观察期 ${watching.length} 人（需满 ${GRACE_ROUNDS} 轮且 ${GRACE_HOURS}h）：`);
    watching.slice(0, 15).forEach((v) =>
      lines.push(`   ${v.uid}  ${v.name}  第${v.rounds}轮/${v.hours.toFixed(1)}h`)
    );
    if (watching.length > 15) lines.push(`   ... 另有 ${watching.length - 15} 人`);

    if (WARN_IN_GROUP) {
      const at = watching.slice(0, 10).map((v) => `[CQ:at,qq=${v.uid}]`).join(" ");
      const msg = `${at} ${renderWarn()}`;
      const s = await api("send_group_msg", { group_id: gid, message: msg });
      lines.push(s.ok ? "   已在群内 @ 提醒改名" : `   ⚠️ 提醒发送失败：${s.error || s.status}`);
    }
  }

  if (!toKick.length) {
    savePending(gid, nextPending);
    lines.push("🤝 本轮无人到期，未踢任何人");
    return { text: lines.join("\n"), acted: watching.length > 0 };
  }

  // 单轮上限
  let batch = toKick;
  if (MAX_KICK > 0 && batch.length > MAX_KICK) {
    const defer = batch.slice(MAX_KICK);
    batch = batch.slice(0, MAX_KICK);
    defer.forEach((v) => {
      nextPending[String(v.uid)] = { first: now - GRACE_HOURS * 3600, rounds: v.rounds, name: v.name };
    });
    lines.push(`🔒 单轮上限 ${MAX_KICK} 人，其余 ${defer.length} 人下轮继续`);
  }

  const ok = [];
  const fail = [];
  for (let i = 0; i < batch.length; i++) {
    const v = batch[i];
    const r = await api("set_group_kick", {
      group_id: gid,
      user_id: v.uid,
      reject_add_request: REJECT_ADD,
    });
    if (r.ok) ok.push(v);
    else {
      fail.push({ ...v, err: r.error || "HTTP " + r.status });
      // 失败的人保留在观察表里，下轮重试，不静默丢失
      nextPending[String(v.uid)] = { first: now - GRACE_HOURS * 3600, rounds: v.rounds, name: v.name };
    }
    if (i < batch.length - 1 && INTERVAL > 0) await sleep(INTERVAL * 1000);
  }

  savePending(gid, nextPending);

  lines.push(`🚪 已踢出 ${ok.length} 人${fail.length ? ` · 失败 ${fail.length} 人` : ""}`);
  ok.forEach((v) => lines.push(`   ✔ ${v.uid}  ${v.name}`));
  fail.forEach((v) => lines.push(`   ✘ ${v.uid}  ${v.name} -> ${v.err}`));
  return { text: lines.join("\n"), acted: true };
}

// ── 豁免判定（宽容模式的核心保护）─────────────────────────────
function exemptReason(m, uid, now) {
  if (SELF_QQ && uid === SELF_QQ) return "机器人自己";
  if (WHITELIST.indexOf(uid) >= 0) return "白名单";
  if (SKIP_ADMIN && (m.role === "owner" || m.role === "admin")) return "群主/管理员";
  if (SKIP_TITLE && String(m.title || "").trim()) return "有专属头衔";
  const join = Number(m.join_time || 0);
  if (join > 0) {
    const days = (now - join) / 86400;
    if (NEW_MEMBER_DAYS > 0 && days < NEW_MEMBER_DAYS) return "新人保护期";
    if (VETERAN_DAYS > 0 && days >= VETERAN_DAYS) return "老成员保护";
  }
  return "";
}

// ── 合规判定：宽松归一化后包含任一关键词即合规 ─────────────────
function isCompliant(name) {
  const n = norm(name);
  if (!n) return false; // 空名片视为不合规
  for (const kw of KEYWORDS) {
    if (/^re:/i.test(kw)) {
      try {
        if (new RegExp(kw.slice(3), "i").test(name)) return true;
      } catch (e) {
        /* 正则写错就当没配，不影响其它关键词 */
      }
      continue;
    }
    const k = norm(kw);
    if (k && n.indexOf(k) >= 0) return true;
  }
  return false;
}

// 全角转半角、去大小写、去空白/零宽/常见分隔符与装饰符号
function norm(s) {
  let t = String(s == null ? "" : s);
  t = t.replace(/[\uFF01-\uFF5E]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xfee0));
  t = t.replace(/\u3000/g, " ");
  t = t.toLowerCase();
  t = t.replace(/[\u200B-\u200D\uFEFF]/g, "");
  t = t.replace(/[\s\-_|/\\.,:;'"`~!@#$%^&*+=?<>[\]{}()【】〔〕《》「」『』·、。，！？—–]/g, "");
  return t;
}

function displayName(m) {
  const card = String(m.card || "").trim();
  return card || String(m.nickname || "").trim();
}

function renderWarn() {
  return WARN_TEMPLATE.replace(/\{hours\}/g, String(GRACE_HOURS))
    .replace(/\{rounds\}/g, String(GRACE_ROUNDS))
    .replace(/\{keywords\}/g, KEYWORDS.join(" / "));
}

// ── 配置校验（宁可不动手，也不误伤）─────────────────────────────
function checkConfig() {
  if (!API_BASE) {
    return "⚠️ 未配置 api_base\n请填写 OneBot HTTP 地址，例：http://192.168.1.10:5700";
  }
  if (!/^https?:\/\//i.test(API_BASE)) return `⚠️ api_base 必须以 http:// 或 https:// 开头：${API_BASE}`;
  if (!GROUPS.length) return "⚠️ 未配置 group_id（多个群用英文逗号分隔）";
  if (!KEYWORDS.length) {
    return "⚠️ 未配置 keywords。为防止清群事故，关键词为空时脚本拒绝运行。";
  }
  return "";
}

// ── OneBot v11 调用 ──────────────────────────────────────────
async function api(action, params) {
  const headers = { "Content-Type": "application/json" };
  if (TOKEN) headers.Authorization = `Bearer ${TOKEN}`;
  const r = await request("POST", `${API_BASE}/${action}`, headers, JSON.stringify(params || {}));
  if (!r.ok) return { ok: false, error: r.error, status: r.status, data: null };
  let j = null;
  try {
    j = JSON.parse(r.body || "{}");
  } catch (e) {
    return { ok: false, error: "响应非 JSON", status: r.status, data: null };
  }
  const st = String(j.status || "");
  if (st === "failed" || (j.retcode !== 0 && j.retcode !== 1 && j.retcode !== undefined)) {
    return { ok: false, error: j.wording || j.msg || `retcode ${j.retcode}`, status: r.status, data: null };
  }
  return { ok: true, error: null, status: r.status, data: j.data };
}

// ── 参数解析工具 ─────────────────────────────────────────────
function parseArgument() {
  if (typeof $argument === "undefined" || !$argument) return {};
  if (typeof $argument === "object") return $argument;
  const s = String($argument).trim();
  if (!s) return {};
  if (s.charAt(0) === "{") {
    try {
      return JSON.parse(s);
    } catch (e) {
      /* 继续尝试 k=v 形式 */
    }
  }
  const o = {};
  s.split("&").forEach((kv) => {
    const i = kv.indexOf("=");
    if (i > 0) o[kv.slice(0, i).trim()] = decodeURIComponent(kv.slice(i + 1));
  });
  return o;
}
function splitList(v) {
  return String(v == null ? "" : v)
    .split(/[,，\s]+/)
    .map((x) => x.trim())
    .filter(Boolean);
}
function numArg(v, dft, min) {
  const n = Number(String(v == null ? "" : v).trim());
  if (!isFinite(n)) return dft;
  return n < min ? min : n;
}
function boolArg(v, dft) {
  const s = String(v == null ? "" : v).trim().toLowerCase();
  if (!s) return dft;
  return s === "true" || s === "1" || s === "yes" || s === "y" || s === "on";
}
function normMode(v) {
  const s = String(v == null ? "" : v).trim().toLowerCase();
  if (s === "strict") return "strict";
  if (s === "report" || s === "dry" || s === "dry_run") return "report";
  return "lenient";
}
function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// ── 持久化（观察期记录）───────────────────────────────────────
function loadPending(gid) {
  const raw = readStore(STORE_PREFIX + gid);
  if (!raw) return {};
  try {
    const o = JSON.parse(raw);
    return o && typeof o === "object" ? o : {};
  } catch (e) {
    return {};
  }
}
function savePending(gid, obj) {
  writeStore(STORE_PREFIX + gid, JSON.stringify(obj || {}));
}
function readStore(key) {
  try {
    if (typeof $persistentStore !== "undefined") return $persistentStore.read(key);
    if (typeof $prefs !== "undefined") return $prefs.valueForKey(key);
  } catch (e) {
    /* ignore */
  }
  return null;
}
function writeStore(key, val) {
  try {
    if (typeof $persistentStore !== "undefined") return $persistentStore.write(val, key);
    if (typeof $prefs !== "undefined") return $prefs.setValueForKey(val, key);
  } catch (e) {
    /* ignore */
  }
}

// ── HTTP 适配层：Loon / Surge / Quantumult X ───────────────────
function request(method, url, headers, body) {
  const req = { url, headers: headers || {}, timeout: Math.floor(TIMEOUT / 1000) };
  if (body) req.body = body;

  return new Promise((resolve) => {
    if (typeof $task !== "undefined") {
      req.method = method;
      $task.fetch(req).then(
        (r) => resolve(wrap(null, r.statusCode, r.body)),
        (e) => resolve(wrap(e && e.error ? e.error : "请求失败", 0, ""))
      );
      return;
    }
    if (typeof $httpClient === "undefined") return resolve(wrap("无 HTTP 客户端", 0, ""));
    const fn = method === "POST" ? $httpClient.post : $httpClient.get;
    fn(req, (err, resp, data) => {
      resolve(wrap(err ? String(err) : null, resp ? resp.status || resp.statusCode : 0, data || ""));
    });
  });
}
function wrap(error, status, body) {
  return { ok: !error && status >= 200 && status < 300, error, status: status || 0, body: body || "" };
}

// ── 通知与结束 ───────────────────────────────────────────────
function finish(text) {
  const title = `${NAME} ${SCRIPT_VERSION}`;
  if (typeof $notify !== "undefined") $notify(title, "", text);
  else if (typeof $notification !== "undefined") $notification.post(title, "", text);
  console.log(`[${NAME}] ${text}`);
  done();
}
function done() {
  if (typeof $done !== "undefined") $done();
}
