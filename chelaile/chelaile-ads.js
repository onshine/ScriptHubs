/***************************************************************
 *  车来了 去广告  |  Loon http-response 脚本
 *  ------------------------------------------------------------
 *  SCRIPT_VERSION : R1.0.0
 *  适配           : 车来了 iOS App（*.chelaile.net.cn / *.chelaileapp.cn 系接口）
 *  能力           : 去开屏广告、去插屏广告、去首页金刚位推广、去详情页信息流、
 *                   去公告/活动弹窗、去 LED 天气条、清空广告 SDK 投放任务
 *
 *  关键点（改脚本前务必读）：
 *    车来了的接口响应体几乎都被  **YGKJ{...}YGKJ##  （少数旧接口是 YGKJ**）包裹。
 *    本脚本一律「原样保留外壳，只替换里面的 JSON」，绝不把外壳写死。
 *    —— 写死外壳是这类去广告脚本最常见的翻车点：App 一旦换了结尾标记
 *       （## / **）就会解析失败，表现为首页空白 / 一直转圈。
 *
 *  设计原则：
 *    · 解析失败、结构异常  -> 一律 $done({}) 放行原始响应，绝不写坏数据
 *    · 只 delete / 清空广告相关字段，不碰业务字段
 *    · 所有开关来自插件 [Argument]，未传参时按默认值工作
 ***************************************************************/

const SCRIPT_VERSION = "R1.0.0";

/* ------------------------------------------------------------------
 * 0. 开关与参数
 * ------------------------------------------------------------------ */
const DEFAULTS = {
  remove_splash: true,     // 清洗启动配置：开屏 / 插屏 / 预加载广告
  remove_home_grid: true,  // 首页金刚位推广、我的页面推广位
  remove_feed: true,       // 详情页信息流 / 文章推荐 / 广告 SDK
  remove_notice: true,     // 公告、活动、LED 天气条
  block_httpdns: true,     // 移除 useHttpDns / appBackupDomains，防止绕过分流
  debug: false
};

function readArgs() {
  const cfg = Object.assign({}, DEFAULTS);
  const raw = typeof $argument === "string" ? $argument : "";
  if (!raw) return cfg;

  // Loon [Argument] 传进来的是单个 JSON，也可能是 a=b&c=d 形式，两种都兼容
  let obj = null;
  try { obj = JSON.parse(raw); } catch (_) {}
  if (!obj) {
    obj = {};
    raw.split("&").forEach(pair => {
      const i = pair.indexOf("=");
      if (i < 0) return;
      const k = pair.slice(0, i).trim();
      let v = pair.slice(i + 1).trim();
      if (v === "true") v = true; else if (v === "false") v = false;
      if (k) obj[k] = v;
    });
  }
  for (const k of Object.keys(DEFAULTS)) {
    if (obj[k] !== undefined) cfg[k] = obj[k] === "false" ? false : !!obj[k];
  }
  return cfg;
}

const CFG = readArgs();

function log(...a) {
  if (CFG.debug) console.log(`[车来了 ${SCRIPT_VERSION}]`, ...a);
}

function done(payload) {
  $done(payload || {});
}

/* ------------------------------------------------------------------
 * 1. 外壳拆装
 * ------------------------------------------------------------------ */
/**
 * 把 body 拆成 head / inner / tail：
 *   "**YGKJ{...}YGKJ##"  ->  head="**YGKJ"  inner="{...}"  tail="YGKJ##"
 * 找不到成对标记时返回 null（说明响应未包裹，按纯 JSON 处理）。
 */
function splitWrap(body) {
  const i = body.indexOf("YGKJ");
  if (i < 0) return null;
  const j = body.indexOf("YGKJ", i + 4);
  if (j < 0) return null;
  return { head: body.slice(0, i + 4), inner: body.slice(i + 4, j), tail: body.slice(j) };
}

function joinWrap(parts, newInner) {
  return parts ? parts.head + newInner + parts.tail : newInner;
}

/** 解析响应体，返回 {parts, obj}；失败返回 null */
function parseBody(body) {
  const parts = splitWrap(body);
  const text = parts ? parts.inner : body;
  try {
    const obj = JSON.parse(text);
    if (!obj || typeof obj !== "object") return null;
    return { parts, obj };
  } catch (e) {
    log("JSON 解析失败，放行原响应：", e && e.message);
    return null;
  }
}

/* ------------------------------------------------------------------
 * 2. 各接口的处理函数
 * ------------------------------------------------------------------ */

/** 从 jsonr.data 里删掉指定字段（车来了接口的标准包裹是 {jsonr:{status,data}}） */
function dropKeysFromData(obj, keys) {
  const data = obj && obj.jsonr && obj.jsonr.data;
  if (!data || typeof data !== "object" || Array.isArray(data)) return false;
  let changed = false;
  for (const k of keys) {
    if (Object.prototype.hasOwnProperty.call(data, k)) { delete data[k]; changed = true; }
  }
  return changed;
}

/** 把 jsonr.data 清成空对象；没有 jsonr 结构就整体清空 */
function emptyData(obj) {
  if (obj && obj.jsonr && typeof obj.jsonr === "object") {
    const d = obj.jsonr.data;
    if (d && typeof d === "object" && !Array.isArray(d) && Object.keys(d).length === 0) return false;
    obj.jsonr.data = {};
    return true;
  }
  if (obj && Object.keys(obj).length === 0) return false;
  for (const k of Object.keys(obj)) delete obj[k];
  return true;
}

/* --- 2.1 启动配置清洗：开屏 / 插屏（去开屏广告的核心） --------------
 * /bus-side/appToggle/getStatus 下发的 config 里带全部广告开关，
 * 删掉这些字段后 App 就不会去拉开屏/插屏素材。
 * 字段表 = 可莉(2026-10-02) 全量 + chikacya 补充（useHttpDns 等）。
 */
const SPLASH_KEYS = [
  // 开屏
  "newYear", "splashGray", "enableSplashGray", "splashAdType", "splashCloseTime",
  "sadt", "dynamicSplashTime", "splashCoverBar", "splashSkipShowType",
  "skipPopType", "skipPopTime", "skipStopDis", "enableSplashLineInfo",
  "hideCLLSkip", "bdShowSplashDialog", "bdCloseDownloadDisplay",
  "ttSplashUsePhonePixel", "splashAdPreload", "splashAdTimeout",
  // 插屏 / 弹窗
  "adPopExhibitTime", "isAdPopExhibit", "needFetchInterstitialAd", "intersitialAdPre",
  // 通用广告策略
  "adStrategy", "adConfigTriggerDelayTime", "adNeedAnimate", "nativeAdFetchType",
  "preloadAds", "disableAdAutoRefresh", "reportAdNumLimit", "shakeLeve",
  "sat", "ldrAdAnimal", "appInstallExhibitInterval",
  // 搜索页广告
  "searchAdPos", "searchPageAdType", "searchPageAdAnimation", "showTopSearchAd",
  // 信息流广告
  "feedAdClickSlipRegionType", "feedAdClickSlipShowType", "feedInfoSource",
  "feedBackCutType", "feedBackShakeType", "expressAdDelayRefreshTime",
  // 快手表盘 / 短视频推广
  "newKuaishouPicUrl", "newKuaishouShowType", "newKuaishouHigh",
  "newKuaishouFeedId", "kuaishouFeedId", "showKSVideoHeader", "supportMiniGame",
  // 福利 / 拉活 / 登录推广
  "welfareColor", "welfareAllPage", "welfareUrl", "welfareSignUrl",
  "oneLoginType", "oneLoginPopType", "oneLoginCheck", "douyinLoginType",
  // AI / 语音推广
  "aiSpeakKeywords", "aiSpeakTime", "aiSpeakPreTime", "aiSpeakAfterTime",
  "voiceSearchMode", "favGrayForAI", "scanCodeTipType",
  // 天气推广位
  "weatherGrayFlag"
];

/** 这些不是广告，但会让 App 绕过 Loon 的分流/DNS，导致去广告失效 */
const BYPASS_KEYS = ["useHttpDns", "appBackupDomains", "blacklistDomains"];

function cleanAppToggle(body) {
  const parsed = parseBody(body);
  if (!parsed) return null;
  const { parts, obj } = parsed;

  let changed = false;
  if (CFG.remove_splash && dropKeysFromData(obj, SPLASH_KEYS)) changed = true;
  if (CFG.block_httpdns && dropKeysFromData(obj, BYPASS_KEYS)) changed = true;

  if (!changed) { log("启动配置：无需改动"); return null; }
  log("启动配置：已清洗开屏/插屏/推广字段");
  return joinWrap(parts, JSON.stringify(obj));
}

/* --- 2.2 首页金刚位（/goocity/flowPos/home） ------------------------
 * advertList 里既有推广位也有功能位（站点地图、地铁）。
 * 策略：按「是否指向外部 App / 站外链接」判定推广位并剔除，保留功能位，
 *      避免像社区规则那样把功能位写死成固定 JSON（App 改版就会错位）。
 */
const EXT_LINK_ALLOW = /(^|\/\/)([a-z0-9-]+\.)*(chelaile\.net\.cn|chelaileapp\.cn)/i;

function isPromoItem(it) {
  if (!it || typeof it !== "object") return true;
  // 拉活/跳转到外部 App = 推广
  if (it.appId || it.appPath) return true;
  // 站外链接 = 推广
  const link = it.linkUrl || "";
  if (link && !EXT_LINK_ALLOW.test(link)) return true;
  return false;
}

function cleanHomeGrid(body) {
  const parsed = parseBody(body);
  if (!parsed) return null;
  const { parts, obj } = parsed;
  const data = obj && obj.jsonr && obj.jsonr.data;
  if (!data || typeof data !== "object") return null;

  const list = data.advertList;
  if (!Array.isArray(list)) { log("首页金刚位：无 advertList，跳过"); return null; }

  const kept = list.filter(it => !isPromoItem(it)).map(it => {
    // 顺手去掉推广埋点/角标字段
    const c = Object.assign({}, it);
    if ("showRedDot" in c) c.showRedDot = 0;
    return c;
  });

  // 推广位字段名可能不只 advertList，一并清理常见推广容器
  for (const k of ["adList", "ads", "promotionList", "bannerList"]) {
    if (Array.isArray(data[k])) data[k] = [];
  }

  if (kept.length === list.length && !("adList" in data) && !("ads" in data)) {
    log("首页金刚位：无推广位");
    return null;
  }
  data.advertList = kept;
  log(`首页金刚位：${list.length} -> ${kept.length}`);
  return joinWrap(parts, JSON.stringify(obj));
}

/* --- 2.3 城市列表（/goocity/city!）--------------------------------
 * 只保留功能入口，并去掉项上的推广图（picUrl / clickIconUrl）。
 */
const CITY_KEEP = ["首页", "我的", "路线规划", "附近", "查车"];

function cleanCityList(body) {
  const parsed = parseBody(body);
  if (!parsed) return null;
  const { parts, obj } = parsed;
  const data = obj && obj.jsonr && obj.jsonr.data;
  if (!data || !Array.isArray(data.cityList)) return null;

  const list = data.cityList
    .filter(it => it && CITY_KEEP.includes(it.title))
    .map(it => { delete it.picUrl; delete it.clickIconUrl; delete it.redDot; return it; });

  if (!list.length) return null;
  data.cityList = list;
  log(`城市列表：保留 ${list.length} 项`);
  return joinWrap(parts, JSON.stringify(obj));
}

/* --- 2.4 广告 SDK（adx.yg84.com）----------------------------------
 * 直接返回「没有投放任务」的合法结构，比整域 REJECT 更温和：
 * SDK 拿到空任务会安静收场，不会因连接被断而不断重试。
 */
function cleanAdSdk(body) {
  let obj;
  try { obj = JSON.parse(body); } catch (_) { return null; }
  if (!obj || typeof obj !== "object") return null;
  const url = ($request && $request.url) || "";

  let changed = false;
  if (/\/sdk\/ad\/get/i.test(url)) {
    const d = obj.data;
    if (d && typeof d === "object") {
      for (const k of ["tasks", "tasksTimeouts"]) if (Array.isArray(d[k])) { d[k] = []; changed = true; }
      if (d.serialParallelConfig && typeof d.serialParallelConfig === "object") {
        for (const k of ["floorPriceTasks", "biddingTasks", "tasks"]) {
          if (Array.isArray(d.serialParallelConfig[k])) { d.serialParallelConfig[k] = []; changed = true; }
        }
      }
    }
  } else if (/\/sdk\/ad\/setting/i.test(url)) {
    if (obj.data && typeof obj.data === "object" && Object.keys(obj.data).length) { obj.data = {}; changed = true; }
  } else if (/\/sdk\/ad\/init/i.test(url)) {
    if (obj.data && typeof obj.data === "object" && Array.isArray(obj.data.caches)) { obj.data.caches = []; changed = true; }
  }
  if (!changed) return null;
  log("广告 SDK：已清空投放任务");
  return JSON.stringify(obj);
}

/* ------------------------------------------------------------------
 * 3. 路由表
 * ------------------------------------------------------------------ */
const ROUTES = [
  // 启动配置：开屏 / 插屏（最关键）
  { re: /\/bus-side\/appToggle\/getStatus(\?|$)/i,        fn: cleanAppToggle, need: "remove_splash" },
  // 首页金刚位 / 我的页推广位
  { re: /\/goocity\/flowPos\/home(\?|$)/i,                fn: cleanHomeGrid,  need: "remove_home_grid" },
  { re: /\/goocity\/flowPos\/listByPos(\?|$)/i,           fn: emptyDataFn,    need: "remove_home_grid" },
  // 详情页信息流 / 文章推荐
  { re: /\/operative_position\/infoflow(\/getInfo)?(\?|$)/i, fn: emptyDataFn, need: "remove_feed" },
  // 注意：该接口是 Spring 风格 action（city!getCityList），不能只匹配到 "city!" 就结束
  { re: /\/goocity\/city!/i,                              fn: cleanCityList,  need: "remove_feed" },
  // 公告 / 活动 / LED 天气条
  { re: /\/goocity\/config\/notices(\?|$)/i,              fn: emptyDataFn,    need: "remove_notice" },
  { re: /\/encourage\/activity\/control(\?|$)/i,          fn: emptyDataFn,    need: "remove_notice" },
  { re: /\/led-weather\/[^/]*\/condition_brief(\?|$)/i,   fn: emptyDataFn,    need: "remove_notice" },
  // 广告 SDK（非 YGKJ 包裹，单独处理）
  { re: /^https?:\/\/adx\.yg84\.com\/sdk\/ad\//i,         fn: cleanAdSdk,     need: "remove_feed" }
];

/** 把 jsonr.data 清空的通用处理器（包一层以适配 ROUTES 统一签名） */
function emptyDataFn(body) {
  const parsed = parseBody(body);
  if (!parsed) return null;
  const { parts, obj } = parsed;
  if (!emptyData(obj)) return null;
  log("响应已清空 data");
  return joinWrap(parts, JSON.stringify(obj));
}

/* ------------------------------------------------------------------
 * 4. 入口
 * ------------------------------------------------------------------ */
(function main() {
  const url = ($request && $request.url) || "";
  let body = $response && $response.body;

  if (body instanceof Uint8Array) {
    try { body = new TextDecoder("utf-8").decode(body); } catch (_) { body = ""; }
  }
  if (!url || typeof body !== "string" || !body) return done({});

  for (const r of ROUTES) {
    if (!r.re.test(url)) continue;
    if (!CFG[r.need]) { log("命中但开关已关：", r.need); return done({}); }
    let out = null;
    try { out = r.fn(body); } catch (e) { log("处理异常，放行原响应：", e && e.message); out = null; }
    if (out && out !== body) return done({ body: out });
    return done({});
  }
  return done({});
})();
