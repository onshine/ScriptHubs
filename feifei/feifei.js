/*
 * feifei.js —— 讯飞 AI 学习机「飞飞币」每日自动签到（Loon / Surge / Stash 通用脚本）
 *
 * 版本：R1.0.8
 * 更新：2026-11-15 R1.0.8 通知排版重做：余额/连签/今日可赚 一行一目了然，7 天签到压缩成
 *       「10● 11● 12○」并标注月份，明细标题去掉「完成…任务奖励」前后缀，账号名进标题。
 *       R1.0.7 抓包自检只对接口域名提示（页面/图片不再占用每日提示额度）。
 *       R1.0.6 收尾加固：无论成功/异常/卡住都一定会 $done() 并打「完成」日志，
 *       不再出现 Loon 里一直显示「运行中」。
 *       R1.0.5 Token 解析加固：从整段 JSON/配置文件里也能准确抠出 v01_ 凭证，
 *       自动去重、跳过无效项（之前把粘进来的整份 config.json 当成了 26 个账号）。
 *       R1.0.4 配合抓包自检：Safari 打开 H5 页面即可验证 MITM（见 README）。
 *       R1.0.3 全链路日志（每步打印到 Loon 日志）+ 缺 Token 时自动读取抓包心跳，
 *       直接告诉你是「规则没触发」还是「触发但没取到凭证」。
 *       R1.0.2 抓凭证脚本加自检提示（命中/未命中都会说清楚），匹配放宽到 *.xunfeixxj.com。
 *       R1.0.1 插件改用 Loon 官方 v2 Script 语法（cron ${cron} 参数化，
 *       签到时间可在插件设置页直接改）；参数改为位置数组解析，兼容对象写法。
 *       R1.0.0 首个版本：每日签到、任务奖励领取、签到明细（近 7 天打卡图 + 最近收入流水）、
 *       Loon 通知 + Bark / Telegram、Token 自动抓取（feifei-capture.js）、登录态失效提示
 * 仓库：https://github.com/onshine/ScriptHubs
 *
 * 运行方式：type=cron（见 feifei.plugin），或手动在 Loon 里点「运行」
 * Token 来源优先级：
 *    1. 插件 [Argument] 里的 token（形如 Bearer v01_xxx，可多个，用 ; 或换行分隔，支持「名字|token」）
 *    2. 抓包自动保存的 Token（$persistentStore 的 feifei_token，由 feifei-capture.js 写入）
 *
 * 通知：Loon 系统通知 + 可选 Bark / Telegram
 */

var SCRIPT_VERSION = "1.0.8";
var API = "https://api.xunfeixxj.com";
var UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148";
var KEY_TOKEN = "feifei_token";

if (typeof $done === "undefined") { var $done = function () { }; } /* 便于本地/Node 测试 */
console.log("[feifei] v" + SCRIPT_VERSION);
function log(m) { try { console.log("[feifei] " + m); } catch (e) { } }
function storeRead(k) {
  try { return (typeof $persistentStore !== "undefined" && $persistentStore.read) ? $persistentStore.read(k) : null; }
  catch (e) { return null; }
}
function tail(t) { return t ? "…" + String(t).slice(-4) : "(空)"; }

var __finished = false;
function finish(reason) {
  if (__finished) return;
  __finished = true;
  log("完成" + (reason ? "（" + reason + "）" : ""));
  try { $done(); } catch (e) { }
}
function safeNotify(title, sub, body) {
  try { $notification.post(title, sub || "", body || ""); log("通知已提交: " + title); }
  catch (e) { log("✗ 通知失败: " + (e && e.message ? e.message : e)); }
}

/* Loon v2 语法 script(url, {${a},${b}}) 传进来的是「位置数组」；
   旧式对象写法也兼容。 */
function readArg() {
  var a;
  try { a = typeof $argument === "undefined" ? {} : $argument; } catch (e) { a = {}; }
  if (typeof a === "string") { try { a = JSON.parse(a); } catch (e) { return {}; } }
  if (!a || typeof a !== "object") return {};
  if (Array.isArray(a)) {
    if (a.length === 1 && a[0] && typeof a[0] === "object" && !Array.isArray(a[0])) return a[0];
    return { token: a[0], bark_url: a[1], tg_bot: a[2], tg_chat: a[3], details: a[4], claim_tasks: a[5] };
  }
  return a;
}
var arg = readArg();

function headers(tok) {
  return {
    "content-type": "application/json",
    "appid": "H5APP",
    "authorization": tok,
    "accept": "application/json, text/plain, */*",
    "accept-language": "zh-CN,zh-Hans;q=0.9",
    "origin": "https://xxj.xunfei.cn",
    "referer": "https://xxj.xunfei.cn/",
    "user-agent": UA
  };
}

function post(tok, path, body) {
  var t0 = Date.now();
  return new Promise(function (resolve, reject) {
    $httpClient.post(
      { url: API + path, headers: headers(tok), body: JSON.stringify(body || {}) },
      function (error, response, data) {
        var ms = Date.now() - t0;
        if (error) { log("✗ " + path + " 网络错误(" + ms + "ms): " + error); return reject(new Error("网络错误: " + error)); }
        var st = response && response.status;
        if (st === 401 || st === 482 || st === 483) { log("✗ " + path + " 登录态失效 HTTP " + st); return reject(new Error("TOKEN_EXPIRED")); }
        var js;
        try { js = JSON.parse(data); } catch (e) { return reject(new Error("响应非 JSON: " + String(data).slice(0, 80))); }
        if (js.status && js.status !== 0) { log("✗ " + path + " status=" + js.status + " " + (js.msg || "")); return reject(new Error(js.msg || ("status=" + js.status))); }
        log("✓ " + path + " " + ms + "ms");
        resolve(js.data || {});
      }
    );
  });
}

function httpPost(url, bodyStr, ctype) {
  return new Promise(function (resolve) {
    $httpClient.post({ url: url, headers: { "Content-Type": ctype || "application/json; charset=utf-8" }, body: bodyStr },
      function (error, response, data) { resolve(!error && response && response.status < 400); });
  });
}

function ts2str(ms) {
  var d = new Date(Number(ms));
  var p = function (n) { return (n < 10 ? "0" : "") + n; };
  return p(d.getMonth() + 1) + "-" + p(d.getDate()) + " " + p(d.getHours()) + ":" + p(d.getMinutes());
}

function signedToday(sum) {
  var list = sum.signList || [];
  for (var i = 0; i < list.length; i++) if (list[i].isToday === 1 && list[i].signState === 1) return true;
  return false;
}

function normTok(t) {
  t = String(t || "").trim();
  if (!t) return "";
  return /^bearer\s/i.test(t) ? t : "Bearer " + t;
}

function extractTokens(raw) {
  var out = [], seen = {}, m;
  var re = /v01_[A-Za-z0-9_\-\.]{20,}/g;
  while ((m = re.exec(raw))) {
    var t = "Bearer " + m[0];
    if (!seen[t]) { seen[t] = 1; out.push({ name: "飞飞币", token: t }); }
  }
  return out;
}

function loadAccounts() {
  var raw = String(arg.token || "").trim();
  var src = "插件参数";
  if (!raw) { raw = String(storeRead(KEY_TOKEN) || "").trim(); src = "本地存储"; }
  if (!raw) return [];
  log("token 来源=" + src + "，原始长度 " + raw.length + " 字符");

  /* 1) 整份 JSON（含 accounts 数组）—— 直接从配置文件复制过来也能用 */
  try {
    var js = JSON.parse(raw);
    if (js && js.accounts && js.accounts.length) {
      var list = js.accounts.filter(function (a) { return a && a.enabled !== false; })
        .map(function (a) { return { name: a.name || "飞飞币", token: normTok(a.token) }; })
        .filter(function (a) { return /^Bearer v01_/.test(a.token); });
      if (list.length) { log("按配置文件格式解析出 " + list.length + " 个账号"); return list; }
    }
  } catch (e) { }

  /* 2) 「名字|token」多行/分号分隔 */
  var lines = raw.split(/[\n;]+/).map(function (x) { return x.trim(); })
    .filter(function (x) { return x; });
  var out = [], seen = {};
  lines.forEach(function (line) {
    var name = "飞飞币", tok = line;
    if (line.indexOf("|") > 0) {
      var p = line.split("|");
      name = p[0].trim() || name;
      tok = p.slice(1).join("|").trim();
    }
    tok = normTok(tok);
    if (!/^Bearer v01_/.test(tok)) return;            // 跳过粘错的碎片
    if (seen[tok]) return;                            // 去重
    seen[tok] = 1;
    out.push({ name: name, token: tok });
  });
  if (out.length) { log("按多行/分号格式解析出 " + out.length + " 个账号"); return out; }

  /* 3) 兜底：正则从任意文本里抠 v01_ 凭证（粘了整份 JSON、说明文字也能用） */
  out = extractTokens(raw);
  log(out.length ? ("兜底正则从中抠出 " + out.length + " 个凭证") : "✗ 没解析出任何有效 Token");
  return out;
}

function shortTitle(t) {
  t = String(t || "-");
  t = t.replace(/^完成/, "").replace(/任务奖励$/, "").replace(/奖励$/, "");
  return t.length > 16 ? t.slice(0, 16) + "…" : t;
}

/* 近 7 天签到：同月只显示日，跨月显示月日 */
function board(sum) {
  var list = (sum.signList || []).filter(function (x) { return String(x.dateText || "").length === 8; });
  if (!list.length) return "";
  var mon = list[0].dateText.slice(4, 6), same = true;
  list.forEach(function (x) { if (x.dateText.slice(4, 6) !== mon) same = false; });
  return list.map(function (x) {
    var d = x.dateText;
    var label = same ? d.slice(6, 8) : (d.slice(4, 6) + "/" + d.slice(6, 8));
    return label + (x.signState ? "●" : "○");
  }).join(" ") + (same ? "  (" + Number(mon) + "月)" : "");
}

function runOne(acc, detailsN, claimTasks) {
  var delta = 0, status = "", extra = [];
  return post(acc.token, "/aiapp/points/homePage/getPointsAndRemind", {})
    .then(function (sum) {
      var p = [];
      if (signedToday(sum)) {
        status = "☑️ 今日已签到";
      } else {
        p.push(post(acc.token, "/aiapp/points/sign/insert", {}).then(function (d) {
          var pts = Number(d.points || 0);
          delta += pts;
          status = pts > 0 ? ("✅ 签到成功  +" + pts) : "ℹ️ 签到已调用（返币 0）";
        }).catch(function (e) {
          status = "❌ 签到失败";
          extra.push("签到：" + e.message);
        }));
      }
      if (claimTasks) {
        p.push(post(acc.token, "/aiapp/taskCenter/pointsTask/getTaskList", {}).then(function (d) {
          var tasks = (d.taskList || []).filter(function (t) { return t.state === 1; });
          if (!tasks.length) return;
          return Promise.all(tasks.map(function (t) {
            return post(acc.token, "/aiapp/taskCenter/pointsTask/receivePoints", { taskCode: t.taskCode })
              .then(function () {
                delta += Number(t.taskPoints || 0);
                extra.push("🎁 " + shortTitle(t.taskTitle) + "  +" + t.taskPoints);
              })
              .catch(function (e) { extra.push("✗ 领取「" + shortTitle(t.taskTitle) + "」失败：" + e.message); });
          }));
        }).catch(function () { }));
      }
      return Promise.all(p);
    })
    .then(function () {
      return post(acc.token, "/aiapp/points/homePage/getPointsAndRemind", {});
    })
    .then(function (sum) {
      var res = { name: acc.name, status: status || "ℹ️ 已查询", delta: delta, sum: sum, extra: extra };
      if (!detailsN) return res;
      return post(acc.token, "/aiapp/points/homePage/getPointsDetailList",
        { changeType: 1, pageSize: Math.max(detailsN, 10), cursor: 0 }).then(function (d) {
          res.details = (d.detailList || []).slice(0, detailsN);
          return res;
        }).catch(function () { return res; });
    });
}

/* 单个账号的正文 */
function formatAccount(res) {
  var sum = res.sum || {};
  var out = [];
  var deltaTxt = res.delta ? ("（本次 +" + res.delta + "）") : "";
  out.push("💰 余额  " + (sum.totalPoints || 0) + " 飞飞币" + deltaTxt);
  out.push("🔥 连签  " + (sum.totalSignDays || 0) + " 天     🎯 今日可赚 " + (sum.todayTaskPoints || 0));
  var b = board(sum);
  if (b) { out.push(""); out.push("📅 近 7 天签到"); out.push(b); }
  if (res.extra && res.extra.length) { out.push(""); out.push(res.extra.join("\n")); }
  if (res.details && res.details.length) {
    out.push(""); out.push("📋 最近变动");
    res.details.forEach(function (it) {
      var full = ts2str(it.changeTime);                       // "11-16 09:39"
      var now = new Date();
      var isToday = full.indexOf((now.getMonth() < 9 ? "0" : "") + (now.getMonth() + 1) + "-" +
        (now.getDate() < 10 ? "0" : "") + now.getDate()) === 0;
      out.push("  " + (isToday ? full.slice(6) : full) + "  +" + it.changePoints + "  " + shortTitle(it.changeTitle));
    });
  }
  return out.join("\n");
}

function notifyBark(title, content) {
  var url = String(arg.bark_url || "").trim();
  if (!url) return Promise.resolve(false);
  url = url.replace(/\/+$/, "");
  if (!/\/push$/.test(url)) url += "/push";
  return httpPost(url, JSON.stringify({ title: title, body: content, group: "飞飞币" }));
}

function notifyTG(title, content) {
  var bot = String(arg.tg_bot || "").trim(), chat = String(arg.tg_chat || "").trim();
  if (!bot || !chat) return Promise.resolve(false);
  var body = "chat_id=" + encodeURIComponent(chat) +
    "&text=" + encodeURIComponent(title + "\n" + content) +
    "&disable_web_page_preview=true";
  return httpPost("https://api.telegram.org/bot" + bot + "/sendMessage", body,
    "application/x-www-form-urlencoded");
}

(function main() {
  var accounts = loadAccounts();
  log("账号数 " + accounts.length + "，明细条数 " + (arg.details || 5));
  if (!accounts.length && String(arg.token || "").trim()) {
    var rawTok = String(arg.token || "").trim();
    log("✗ Token 栏有 " + rawTok.length + " 字符，但没解析出 v01_ 凭证");
    safeNotify("飞飞币 · Token 无效", "没解析出有效凭证",
      "Token 栏里有 " + rawTok.length + " 字符，但找不到 v01_ 开头的凭证。\n→ 只粘贴 Bearer v01_… 这一段就行，不用整份配置文件。");
    finish("Token 无效");
    return;
  }
  if (!accounts.length) {
    var hitAt = Number(storeRead("feifei_last_hit") || 0);
    var hitUrl = String(storeRead("feifei_last_url") || "");
    var hitTxt = hitAt ? (new Date(hitAt).toLocaleString() + "  " + hitUrl) : "从未命中";
    log("抓包心跳: " + hitTxt);
    var advice = hitAt
      ? "规则已触发过，但没取到 Authorization。→ 到家长端「飞飞币」页面下拉刷新一次；仍不行就在插件里手填 Token。"
      : "规则从未触发，说明请求没被 MITM 解密。→ ①插件已启用 ②Loon 设置→MitM 开关开 + 证书已装 + iOS「证书信任设置」已信任 ③改完插件后把 VPN 开关关掉再打开。";
    log(advice);
    safeNotify("飞飞币 · 缺 Token", "抓包心跳：" + (hitAt ? "有命中" : "从未命中"),
      "最近命中接口：" + hitTxt + "\n\n" + advice);
    finish("缺 Token");
    return;
  }
  var detailsN = Number(arg.details || 5);
  var claimTasks = arg.claim_tasks === true || String(arg.claim_tasks || "false").toLowerCase() === "true";

  accounts.forEach(function (a) {
    log("[ " + a.name + " ] token " + a.token.length + " 字符 " + tail(a.token) + (arg.token ? "" : "（抓包自动获取）"));
  });
  var jobs = accounts.map(function (acc) {
    return runOne(acc, detailsN, claimTasks)
      .then(function (res) { return res; })
      .catch(function (e) {
        var m = e.message === "TOKEN_EXPIRED"
          ? "登录态失效，请用家长端 App 打开一次「飞飞币」页面以重新抓取"
          : e.message;
        return { name: acc.name, status: "❌ " + m, failed: true, sum: {} };
      });
  });

  try { setTimeout(function () { finish("看门狗超时"); }, 30000); } catch (e) { }

  Promise.all(jobs).then(function (results) {
    var failed = results.some(function (r) { return r.failed || /❌/.test(r.status || ""); });
    var title, sub = "", body, pushBody;
    if (results.length === 1) {
      var r0 = results[0];
      title = r0.name && r0.name !== "飞飞币" ? ("飞飞币 · " + r0.name) : "飞飞币";
      sub = r0.status;
      body = r0.failed ? "" : formatAccount(r0);
    } else {
      title = "飞飞币 · " + results.length + " 个账号";
      body = results.map(function (r) {
        return "▎" + r.name + "  " + r.status + "\n" + (r.failed ? "" : formatAccount(r));
      }).join("\n\n");
    }
    pushBody = sub ? (sub + (body ? "\n\n" + body : "")) : body;
    log("结果: " + pushBody.replace(/\n+/g, " / ").slice(0, 160));
    safeNotify(title, sub, body);
    return Promise.all([notifyBark(title, pushBody), notifyTG(title, pushBody)]);
  }).then(function () {
    finish();
  }, function (e) {
    log("✗ 未预期异常: " + (e && e.message ? e.message : e));
    safeNotify("飞飞币签到", "运行异常", String(e && e.message ? e.message : e));
    finish("异常");
  });
})();
