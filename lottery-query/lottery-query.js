/*
五种彩票近15期 + 今日开奖号码
支持 Quantumult X / Loon / Surge
仓库：https://github.com/onshine/ScriptHubs/tree/main/lottery-query
*/

const LIMIT = 15;
const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1";

(async () => {
  const tasks = [
    ["双色球", () => fetchCwl("ssq"), formatSsq],
    ["大乐透", () => fetchSport("85"), formatDlt],
    ["福彩3D", () => fetchCwl("3d"), format3d],
    ["排列三", () => fetchSport("35"), formatPl3],
    ["七乐彩", () => fetchCwl("qlc"), formatQlc]
  ];

  for (const [name, loader, formatter] of tasks) {
    try {
      console.log("查询" + name);
      const rows = (await loader()).slice(0, LIMIT);
      if (!rows.length) throw new Error("接口未返回开奖数据");
      outputSection(name, rows, formatter);
    } catch (e) {
      const message = "查询失败：" + (e && e.message ? e.message : String(e));
      console.log("【" + name + "】\n" + message);
      notify("彩票查询 · " + name, "", message);
    }
  }
})().catch(e => {
  console.log(e);
  notify("彩票查询", "脚本执行错误", e.message || String(e));
}).finally(done);

function outputSection(name, rows, formatter) {
  const history = rows.map((x, i) => {
    return (i + 1) + ". " + issueOf(x) + "  " + dateOf(x) + "  " + formatter(x);
  }).join("\n");
  const todayRow = rows.find(x => dateOf(x) === today());
  const current = todayRow
    ? issueOf(todayRow) + "  " + formatter(todayRow)
    : "今日未开奖（或开奖数据暂未更新）";
  const body = "【最近15期】\n" + history + "\n\n【今日开奖号码】\n" + current;
  console.log("\n========== " + name + " ==========\n" + body + "\n");
  notify("彩票查询 · " + name, "最近15期 / 今日开奖号码", body);
}

async function fetchCwl(name) {
  // 福彩网旧入口 /cwl_admin/kjxx/ 已被网宿 WAF 拦截（403）。
  // 优先使用官网当前前端入口；保留兼容入口，遇到风控或改版时自动切换。
  const query = "?name=" + name + "&issueCount=" + LIMIT;
  const urls = [
    "https://www.cwl.gov.cn/cwl_admin/front/cwlkj/search/kjxx/findDrawNotice" + query,
    "http://www.cwl.gov.cn/cwl_admin/front/cwlkj/search/kjxx/findDrawNotice" + query,
    "https://www.cwl.gov.cn/cwl_admin/kjxx/findDrawNotice" + query
  ];
  const headers = {
    "Accept": "application/json, text/javascript, */*; q=0.01",
    "Accept-Language": "zh-CN,zh;q=0.9",
    "Referer": "https://www.cwl.gov.cn/ygkj/wqkjgg/",
    "User-Agent": UA,
    "X-Requested-With": "XMLHttpRequest"
  };
  let errors = [];
  for (const url of urls) {
    try {
      const json = parseJson(await get(url, headers), name);
      if (json.state !== 0 || !Array.isArray(json.result) || !json.result.length) {
        throw new Error(json.message || "数据结构异常");
      }
      return json.result;
    } catch (e) {
      errors.push((e && e.message) || String(e));
    }
  }
  throw new Error("福彩接口均不可用（" + errors.join(" / ") + "）");
}

async function fetchSport(gameNo) {
  const url = "https://webapi.sporttery.cn/gateway/lottery/getHistoryPageListV1.qry?gameNo=" + gameNo + "&provinceId=0&pageSize=" + LIMIT + "&isVerify=1&pageNo=1";
  const body = await get(url, {
    "Accept": "application/json, text/plain, */*",
    "Referer": "https://www.lottery.gov.cn/",
    "User-Agent": UA
  });
  const json = parseJson(body, gameNo);
  if (!json.value || !Array.isArray(json.value.list)) throw new Error("体彩接口数据结构异常");
  return json.value.list;
}

function formatSsq(x) {
  return "红 " + normalize(x.red) + "｜蓝 " + normalize(x.blue);
}
function formatDlt(x) {
  const a = numbers(x.lotteryDrawResult);
  return "前 " + a.slice(0, 5).join(" ") + "｜后 " + a.slice(5, 7).join(" ");
}
function format3d(x) {
  const a = numbers(x.red);
  return a.join(" ") + "｜和值 " + a.reduce((s, n) => s + Number(n), 0);
}
function formatPl3(x) {
  const a = numbers(x.lotteryDrawResult);
  return a.join(" ") + "｜和值 " + a.reduce((s, n) => s + Number(n), 0);
}
function formatQlc(x) {
  return "基本 " + normalize(x.red) + "｜特别 " + normalize(x.blue);
}
function numbers(value) {
  return String(value || "").trim().split(/[\s,，]+/).filter(Boolean);
}
function normalize(value) {
  return numbers(value).join(" ");
}
function issueOf(x) {
  return String(x.code || x.issue || x.lotteryDrawNum || "未知期号");
}
function dateOf(x) {
  return String(x.date || x.lotteryDrawTime || x.lotterySaleEndtime || "").slice(0, 10);
}
function today() {
  const d = new Date();
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return y + "-" + m + "-" + day;
}
function parseJson(body, source) {
  try { return JSON.parse(body); }
  catch (_) { throw new Error(source + " 返回内容不是有效 JSON"); }
}

function get(url, headers) {
  if (typeof $task !== "undefined") {
    return $task.fetch({ url, method: "GET", headers }).then(r => {
      if (r.statusCode < 200 || r.statusCode >= 300) throw new Error("HTTP " + r.statusCode);
      return r.body;
    });
  }
  return new Promise((resolve, reject) => {
    $httpClient.get({ url, headers }, (err, resp, body) => {
      if (err) return reject(err);
      const code = resp.status || resp.statusCode;
      if (code < 200 || code >= 300) return reject(new Error("HTTP " + code));
      resolve(body);
    });
  });
}
function notify(title, subtitle, body) {
  if (typeof $notify !== "undefined") $notify(title, subtitle, body);
  else if (typeof $notification !== "undefined") $notification.post(title, subtitle, body);
}
function done() {
  if (typeof $done !== "undefined") $done();
}
