/*
 * feifei.js —— 讯飞 AI 学习机「飞飞币」每日自动签到（Loon / Surge / Stash 通用脚本）
 *
 * 版本：R1.0.4
 * 更新：2026-11-15 R1.0.4 配合抓包自检：Safari 打开 H5 页面即可验证 MITM（见 README）。
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

var SCRIPT_VERSION = "1.0.4";
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

function board(signList) {
  var out = [];
  (signList || []).forEach(function (it) {
    var d = String(it.dateText || "");
    if (d.length !== 8) return;
    out.push(d.slice(4, 6) + "-" + d.slice(6, 8) + (it.signState ? "●" : "○"));
  });
  return out.join("  ");
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

function loadAccounts() {
  var raw = String(arg.token || "").trim();
  if (!raw) raw = String($persistentStore.read(KEY_TOKEN) || "").trim();
  if (!raw) return [];
  return raw.split(/[\n;]+/).map(function (line) {
    line = line.trim();
    if (!line) return null;
    var name = "飞飞币", tok = line;
    if (line.indexOf("|") > 0) {
      var p = line.split("|");
      name = p[0].trim() || name;
      tok = p.slice(1).join("|").trim();
    }
    tok = normTok(tok);
    return tok ? { name: name, token: tok } : null;
  }).filter(Boolean);
}

function runOne(acc, detailsN, claimTasks) {
  var lines = [];
  return post(acc.token, "/aiapp/points/homePage/getPointsAndRemind", {})
    .then(function (sum) {
      var p = [];
      if (signedToday(sum)) {
        lines.push("☑️ 今日已签到");
      } else {
        p.push(post(acc.token, "/aiapp/points/sign/insert", {}).then(function (d) {
          var pts = Number(d.points || 0);
          lines.push(pts > 0 ? "✅ 签到成功 +" + pts + " 飞飞币" : "ℹ️ 签到已调用，返币 0（可能已签到）");
        }).catch(function (e) {
          lines.push("❌ 签到失败：" + e.message);
        }));
      }
      if (claimTasks) {
        p.push(post(acc.token, "/aiapp/taskCenter/pointsTask/getTaskList", {}).then(function (d) {
          var tasks = (d.taskList || []).filter(function (t) { return t.state === 1; });
          if (!tasks.length) return;
          return Promise.all(tasks.map(function (t) {
            return post(acc.token, "/aiapp/taskCenter/pointsTask/receivePoints", { taskCode: t.taskCode })
              .then(function () { lines.push("🎁 领取：" + t.taskTitle + " +" + t.taskPoints); })
              .catch(function (e) { lines.push("❌ 领取「" + t.taskTitle + "」失败：" + e.message); });
          }));
        }).catch(function () { }));
      }
      return Promise.all(p);
    })
    .then(function () {
      return post(acc.token, "/aiapp/points/homePage/getPointsAndRemind", {});
    })
    .then(function (sum) {
      var out = lines.slice();
      out.push("💰 飞飞币：" + (sum.totalPoints || 0) + "（今日任务可得 " + (sum.todayTaskPoints || 0) + "）");
      out.push("📅 连续签到：" + (sum.totalSignDays || 0) + " 天");
      var b = board(sum.signList);
      if (b) out.push("🗓 " + b);
      if (!detailsN) return out;
      return post(acc.token, "/aiapp/points/homePage/getPointsDetailList",
        { changeType: 1, pageSize: Math.max(detailsN, 10), cursor: 0 }).then(function (d) {
          var list = (d.detailList || []).slice(0, detailsN);
          if (list.length) {
            out.push("📋 最近明细：");
            list.forEach(function (it) {
              out.push("   " + ts2str(it.changeTime) + "  +" + it.changePoints + "  " + (it.changeTitle || "-"));
            });
          }
          return out;
        }).catch(function () { return out; });
    });
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
  if (!accounts.length) {
    var hitAt = Number(storeRead("feifei_last_hit") || 0);
    var hitUrl = String(storeRead("feifei_last_url") || "");
    var hitTxt = hitAt ? (new Date(hitAt).toLocaleString() + "  " + hitUrl) : "从未命中";
    log("抓包心跳: " + hitTxt);
    var advice = hitAt
      ? "规则已触发过，但没取到 Authorization。→ 到家长端「飞飞币」页面下拉刷新一次；仍不行就在插件里手填 Token。"
      : "规则从未触发，说明请求没被 MITM 解密。→ ①插件已启用 ②Loon 设置→MitM 开关开 + 证书已装 + iOS「证书信任设置」已信任 ③改完插件后把 VPN 开关关掉再打开。";
    log(advice);
    $notification.post("飞飞币 · 缺 Token", "抓包心跳：" + (hitAt ? "有命中" : "从未命中"),
      "最近命中接口：" + hitTxt + "\n\n" + advice);
    $done();
    return;
  }
  var detailsN = Number(arg.details || 5);
  var claimTasks = arg.claim_tasks === true || String(arg.claim_tasks || "false").toLowerCase() === "true";

  accounts.forEach(function (a) { log("[ " + a.name + " ] token " + a.token.length + " 字符 " + tail(a.token)); });
  var jobs = accounts.map(function (acc) {
    return runOne(acc, detailsN, claimTasks)
      .then(function (lines) { return "[ " + acc.name + " ]\n" + lines.join("\n"); })
      .catch(function (e) {
        var m = e.message === "TOKEN_EXPIRED"
          ? "登录态失效，请用家长端 App 打开一次飞飞币页面以重新抓取 Token"
          : e.message;
        return "[ " + acc.name + " ]\n❌ " + m;
      });
  });

  Promise.all(jobs).then(function (all) {
    var content = all.join("\n\n");
    var failed = /❌/.test(content);
    var title = "飞飞币签到" + (failed ? "（异常）" : "");
    $notification.post(title, "", content);
    Promise.all([notifyBark(title, content), notifyTG(title, content)]).then(function () { $done(); });
  }).catch(function (e) {
    $notification.post("飞飞币签到", "运行异常", String(e && e.message ? e.message : e));
    $done();
  });
})();
