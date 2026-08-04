/**
 * 林里 · 每日签到与鸭币兑换 (R11 免维护版)
 *
 * 首次抓取:打开「林里」小程序 → 进入签到页,自动抓取 Cookie
 * 后续更新:R11 起无需再手动打开小程序——token 临期/失效时,脚本自动请求
 *           商城接口触发 Loon 抓包规则,实时刷新凭据后重试签到
 * 定时任务:每日签到;BoxJS 可分别开启免单券 / 周边兑换
 *
 * @Author: MaYIHEI <https://github.com/MaYIHEI/paperclip>
 * @Channel: Telegram 频道 https://t.me/mayihei
 * @Updated: 2026-07-16
 *
 * ===== Loon =====
 * [MITM]
 * hostname = webapi.qmai.cn
 * [Script]
 * http-request ^https:\/\/webapi\.qmai\.cn\/web\/(cmk-center\/sign\/(activityInfo|userSignStatistics|userSignRecordCalendar)|catering\/common\/common-info|mall-apiserver\/integral\/(home\/index|item\/goods(\/detail)?)) tag=林里 Cookie, script-path=https://raw.githubusercontent.com/MaYIHEI/paperclip/refs/heads/main/miniprogram/linli/linli.js, requires-body=true, img-url=https://raw.githubusercontent.com/MaYIHEI/pin/refs/heads/main/app/linli.png
 * cron "0 10 * * *" script-path=https://raw.githubusercontent.com/MaYIHEI/paperclip/refs/heads/main/miniprogram/linli/linli.js, tag=林里签到兑换, img-url=https://raw.githubusercontent.com/MaYIHEI/pin/refs/heads/main/app/linli.png, enable=true
 *
 * ===== Surge =====
 * [MITM]
 * hostname = webapi.qmai.cn
 * [Script]
 * 林里 Cookie = type=http-request,pattern=^https:\/\/webapi\.qmai\.cn\/web\/(cmk-center\/sign\/(activityInfo|userSignStatistics|userSignRecordCalendar)|catering\/common\/common-info|mall-apiserver\/integral\/(home\/index|item\/goods(\/detail)?)),requires-body=true,max-size=0,script-path=https://raw.githubusercontent.com/MaYIHEI/paperclip/refs/heads/main/miniprogram/linli/linli.js,img-url=https://raw.githubusercontent.com/MaYIHEI/pin/refs/heads/main/app/linli.png
 * 林里签到兑换 = type=cron,cronexp=0 10 * * *,timeout=60,script-path=https://raw.githubusercontent.com/MaYIHEI/paperclip/refs/heads/main/miniprogram/linli/linli.js,img-url=https://raw.githubusercontent.com/MaYIHEI/pin/refs/heads/main/app/linli.png
 *
 * ===== Quantumult X =====
 * [MITM]
 * hostname = webapi.qmai.cn
 * [rewrite_local]
 * ^https:\/\/webapi\.qmai\.cn\/web\/(cmk-center\/sign\/(activityInfo|userSignStatistics|userSignRecordCalendar)|catering\/common\/common-info|mall-apiserver\/integral\/(home\/index|item\/goods(\/detail)?)) url script-request-body https://raw.githubusercontent.com/MaYIHEI/paperclip/refs/heads/main/miniprogram/linli/linli.js
 * [task_local]
 * 0 10 * * * https://raw.githubusercontent.com/MaYIHEI/paperclip/refs/heads/main/miniprogram/linli/linli.js, tag=林里签到兑换, img-url=https://raw.githubusercontent.com/MaYIHEI/pin/refs/heads/main/app/linli.png, enabled=true
 *
 * ===== Stash =====
 * cron:
 *   script:
 *     - name: 林里签到兑换
 *       cron: '0 10 * * *'
 *       timeout: 60
 * http:
 *   mitm:
 *     - "webapi.qmai.cn"
 *   script:
 *     - match: ^https:\/\/webapi\.qmai\.cn\/web\/(cmk-center\/sign\/(activityInfo|userSignStatistics|userSignRecordCalendar)|catering\/common\/common-info|mall-apiserver\/integral\/(home\/index|item\/goods(\/detail)?))
 *       name: 林里 Cookie
 *       type: request
 *       require-body: true
 * script-providers:
 *   林里签到兑换:
 *     url: https://raw.githubusercontent.com/MaYIHEI/paperclip/refs/heads/main/miniprogram/linli/linli.js
 *     interval: 86400
 */

const $ = new Env("林里");

const SCRIPT_VERSION = "2026-08-04.stable-r11.0"; // token 临期/失效自动刷新:脚本自触发抓包规则换 token,无需再手动打开小程序
$.log(`[INFO] 脚本版本 ${SCRIPT_VERSION}`);

const CK_KEY = "linli_data";
const CK_CLEAR = "linli_clear";
const CK_DEBUG = "linli_debug";
const CK_REFRESH = "linli_refresh_token"; // R11 自动刷新开关(默认开,BoxJS 可关)
const TASK_COUPON = "linli_task_exchange_coupon";
const TASK_TOY = "linli_task_exchange_toy";
const SIGN_BASE = "https://webapi.qmai.cn/web/cmk-center/sign";
const MALL_BASE = "https://webapi.qmai.cn/web/mall-apiserver/integral";
const COMMON_INFO = "https://webapi.qmai.cn/web/catering/common/common-info";
const DROP_HEADERS = ["content-length", "host", "connection", "accept-encoding"];
const REFRESH_AGE = 20 * 3600 * 1000; // 凭据保存满 20 小时即视为临期,先刷新再签到
const REFRESH_ROUNDS = 2;             // 失效后最多自动刷新轮数(每轮 4 个探测接口)
const EXCHANGE_TARGETS = [
    { key: TASK_COUPON, name: "单杯免单券", keywords: ["单杯免单券", "免单券", "单杯免单", "饮品免单"] },
    { key: TASK_TOY, name: "林里鸭游乐园周边", keywords: ["林里鸭游乐园周边", "鸭游乐园", "林里鸭", "游乐园周边"] },
];

$.is_debug = ($.isNode() ? process.env.IS_DEBUG : $.getdata(CK_DEBUG)) || "false";
$.messages = [];

function captureCookie() {
    try {
        const hitKey = "linli_capture_hit";
        const hitCount = Number($.getdata(hitKey) || 0) + 1;
        $.setdata(String(hitCount), hitKey);
        const reqUrl = ($request && $request.url) || "";
        $.log(`[capture-hit] #${hitCount} request ${reqUrl}`);
        const incoming = cleanHeaders(($request && $request.headers) || {});
        const old = parseJSON($.getdata(CK_KEY), {});
        // 不同接口分别携带 token、storeId、activityId，必须逐次合并，不能丢弃半成品。
        const headers = Object.assign({}, old.headers || {}, incoming);
        const lower = lowerKeys(headers);
        const body = parseBody($request.body);
        const query = parseQuery($request.url || "");
        const flat = {}; // R6 仅处理请求，不访问 Loon 请求环境中的空 $response
        const token = first(lower["qm-user-token"], body.qmUserToken, query.qmUserToken, flat.qmUserToken);
        if (token && !lower["qm-user-token"]) headers["qm-user-token"] = String(token);
        const activityId = first(body.activityId, query.activityId, lower["activity-id"], flat.activityId, old.activityId);
        const appid = first(body.appid, query.appid, lower.appid, flat.appid, old.appid, "wx26c7aaacfa017719");
        const storeId = first(lower["store-id"], body.storeId, query.storeId, flat.storeId, old.storeId);
        const oldToken = lowerKeys(old.headers || {})["qm-user-token"] || "";
        const wasComplete = !!(oldToken && old.activityId && old.storeId && old.appid);
        const data = { headers, activityId: String(activityId || ""), storeId: String(storeId || ""), appid: String(appid), capturedAt: Date.now() };

        const saved = $.setdata(JSON.stringify(data), CK_KEY);
        if (!saved) throw new Error("凭据写入失败");
        const complete = !!(token && activityId && storeId && appid);
        const oldAge = old.capturedAt ? Math.round((Date.now() - Number(old.capturedAt)) / 360000) / 10 : "?";
        $.log(`[capture-fixed] token=${token ? "有" : "无"} activityId=${activityId || "无"} storeId=${storeId || "无"} 已保存=${saved ? "是" : "否"}`);

        if (complete && !wasComplete) {
            $.msg($.name, "✅ 林里凭据获取成功", "已合并 token、门店及签到活动信息");
        } else if (complete && oldToken && oldToken !== token) {
            $.msg($.name, "♻️ 林里凭据已自动更新", `旧 token 已用约 ${oldAge} 小时,新的 qm-user-token 已保存`);
        } else if (!complete) {
            $.log("[capture-fixed] 已保存部分凭据；请继续打开小程序首页、选择门店并进入签到页");
        }
        // R11: 探测脚本自触发抓包规则刷 token 的挂起请求,凭据落盘后立即放行
        if (complete) resumeRefresh();
    } catch (e) {
        $.log(`[ERROR] Cookie 抓取异常: ${e.message || e}`);
    }
}

function maybeClear() {
    if (($.getdata(CK_CLEAR) || "false") !== "true") return false;
    $.setdata("", CK_KEY);
    $.setdata("false", CK_CLEAR);
    $.msg($.name, "🗑 已清除 Cookie", "重新进入林里小程序签到页抓取");
    return true;
}

function loadAuth() {
    const raw = $.isNode() ? process.env.LINLI_DATA : $.getdata(CK_KEY);
    const hitCount = Number($.getdata("linli_capture_hit") || 0);
    const auth = parseJSON(raw, {}) || {};
    const token = lowerKeys(auth.headers || {})["qm-user-token"] || "";
    const missing = [];
    if (!token) missing.push("qm-user-token");
    if (!auth.storeId) missing.push("storeId");
    if (!auth.activityId) missing.push("activityId");
    if (!auth.appid) missing.push("appid");
    if (missing.length) {
        if (!hitCount) throw new Error("抓取规则命中次数为 0：Loon 未拦截到 Qmai 请求。请确认已安装 R4 插件，而不是单独运行 JS");
        throw new Error(`已命中抓取 ${hitCount} 次，但凭据仍缺少: ${missing.join(", ")}。请查看 [capture-hit] URL`);
    }
    return auth;
}

// ================= R11: token 自动刷新 =================
// 原理:Loon 的 http-request 抓包规则按 URL 匹配,不区分请求来自小程序还是脚本。
// 脚本用旧凭据请求抓包规则覆盖的接口(common-info、商城首页/详情、签到统计),
// Loon 会重新拉起本脚本的 captureCookie:此时丘麦网关若已给请求换上新 token,
// 新凭据即被合并保存——无需再手动打开小程序。

function rawPost(url, headers, body) {
    return new Promise((resolve) => {
        $.post({ url, headers, body: JSON.stringify(body) }, (err, resp, data) => {
            resolve({ err, resp, data });
        });
    });
}

function resumeRefresh() {
    if (typeof $request === "undefined") return;
    const url = ($request && $request.url) || "";
    if (!/linli-refresh=1/.test(url)) return;
    $.log("[refresh] 探测请求已携带新凭据落盘,放行该请求");
    $.done({ response: { status: 200, headers: { "Content-Type": "application/json" }, body: '{"code":0,"status":true,"data":null,"message":"linli refresh ok"}' } });
}

function isAuthFail(res) {
    if (!res) return false;
    const message = String(res.message || "");
    return [9001, 10008, 41000, 100005].includes(Number(res.code)) || /token|登录|鉴权|未授权|失效|过期/i.test(message);
}

function refreshOn(key) {
    if (typeof $argument !== "undefined" && $argument && Object.prototype.hasOwnProperty.call($argument, key)) {
        const arg = $argument[key];
        return !(arg === false || arg === 0 || arg === "false" || arg === "0"); // 默认开
    }
    const value = $.isNode() ? process.env[key.toUpperCase()] : $.getdata(key);
    if (value === undefined || value === null || value === "") return true; // 默认开
    return !(value === false || value === 0 || value === "false" || value === "0");
}

async function refreshToken(auth, reason) {
    if (!refreshOn(CK_REFRESH)) {
        $.log("[refresh] 自动刷新已被 BoxJS/Argument 关闭,跳过");
        return false;
    }
    if (!$.isLoon() && !$.isSurge() && !$.isStash() && !$.isQuanX() && !$.isShadowrocket()) return false;
    const headers = cleanHeaders(auth.headers);
    const probes = [
        { url: COMMON_INFO, body: { appid: auth.appid } },
        { url: MALL_BASE + "/home/index", body: { appid: auth.appid, storeId: auth.storeId } },
        { url: MALL_BASE + "/item/goods/detail", body: { appid: auth.appid, goodsId: "0" } },
        { url: SIGN_BASE + "/userSignStatistics", body: { appid: auth.appid, activityId: auth.activityId } },
    ];
    for (let round = 1; round <= REFRESH_ROUNDS; round++) {
        $.log(`[refresh] 第 ${round}/${REFRESH_ROUNDS} 轮自动刷新(${reason}):自触发抓包规则换取新 token`);
        for (const probe of probes) {
            const sep = probe.url.includes("?") ? "&" : "?";
            await rawPost(`${probe.url}${sep}linli-refresh=1`, headers, probe.body);
            const fresh = parseJSON($.isNode() ? process.env.LINLI_DATA : $.getdata(CK_KEY), {});
            const freshToken = lowerKeys(fresh.headers || {})["qm-user-token"] || "";
            const oldToken = lowerKeys(auth.headers || {})["qm-user-token"] || "";
            if (freshToken && freshToken !== oldToken && fresh.activityId && fresh.storeId) {
                const age = auth.capturedAt ? Math.round((Date.now() - Number(auth.capturedAt)) / 360000) / 10 : "?";
                $.log(`[refresh] ✅ 已捕获新 token(旧 token 存活约 ${age} 小时),继续执行`);
                $.msg($.name, "♻️ 已自动续期", `旧 token 存活约 ${age} 小时,新 token 已落盘`);
                return true;
            }
        }
        await $.wait(800);
    }
    $.log("[refresh] ❌ 自动刷新未成功:网关未在请求中下发新 token,仍需手动打开一次小程序");
    return false;
}
// ================= R11 end =================

async function checkin(auth) {
    $.messages.push("", "========== 📅 每日签到 ==========");
    const common = { activityId: auth.activityId, appid: auth.appid };
    let before = await api(SIGN_BASE + "/userSignStatistics", cleanHeaders(auth.headers), common);
    signLog(before, "userSignStatistics(before)");

    // R11: token 失效 → 自触发抓包规则换新 token,重读凭据后重试一次
    if (isAuthFail(before) && (await refreshToken(auth, "签到前校验失效"))) {
        auth = loadAuth();
        before = await api(SIGN_BASE + "/userSignStatistics", cleanHeaders(auth.headers), common);
        signLog(before, "userSignStatistics(retry)");
    }
    assertAuth(before);

    if (!before || before.status !== true) {
        throw new Error(`签到状态查询失败: ${(before && before.message) || short(before)}`);
    }
    if (isSigned(before)) {
        $.messages.push(formatSignedStatus(before));
        return;
    }

    let sign = await api(SIGN_BASE + "/takePartInSign", cleanHeaders(auth.headers), {
        activityId: auth.activityId,
        storeId: auth.storeId,
        appid: auth.appid,
    });
    signLog(sign, "takePartInSign");

    // R11: 签到请求途中 token 才过期(如 10 点整高并发被挤下线),再刷新重试一次
    if (isAuthFail(sign) && (await refreshToken(auth, "签到请求失效"))) {
        auth = loadAuth();
        sign = await api(SIGN_BASE + "/takePartInSign", cleanHeaders(auth.headers), {
            activityId: auth.activityId,
            storeId: auth.storeId,
            appid: auth.appid,
        });
        signLog(sign, "takePartInSign(retry)");
    }
    assertAuth(sign);

    if (sign && sign.status === true) {
        const rewards = rewardText(sign.data && sign.data.rewardDetailList);
        const after = await api(SIGN_BASE + "/userSignStatistics", cleanHeaders(auth.headers), common);
        signLog(after, "userSignStatistics(after)");
        $.messages.push(formatStatus(`✅ 签到成功${rewards ? `: ${rewards}` : ""}`, after));
        return;
    }

    const message = String((sign && sign.message) || "");
    if (/已签到|重复签到/.test(message)) {
        $.messages.push("✨ 今日已签到");
        return;
    }
    throw new Error(`签到失败: ${message || short(sign)}`);
}

async function exchange(auth) {
    $.messages.push("========== 🎁 10点兑换 ==========");
    const headers = cleanHeaders(auth.headers);
    const enabled = EXCHANGE_TARGETS.filter((target) => taskOn(target.key));
    EXCHANGE_TARGETS.filter((target) => !taskOn(target.key)).forEach((target) => $.messages.push(`${target.name}：未开启`));
    if (!enabled.length) {
        $.log(`[exchange] 兑换均未开启;凭据已保存 ${auth.capturedAt ? Math.round((Date.now() - Number(auth.capturedAt)) / 360000) / 10 : "?"} 小时`);
        return;
    }

    // 每次运行都从商城实时发现商品，不再依赖可能过期的固定 goodsId。
    const catalog = await loadMallCatalog(headers, auth.appid, auth.storeId);
    const candidates = collectGoods(catalog);
    $.log(`[exchange] 商城动态发现 ${candidates.length} 个带ID商品`);

    for (const target of enabled) {
        const found = matchGoods(candidates, target.keywords);
        if (!found) {
            $.messages.push(`❌ ${target.name}: 商城未找到当前商品（未使用旧ID）`);
            continue;
        }
        $.log(`[exchange] ${target.name} 动态匹配: ${found.name} goodsId=${found.id}`);
        const detail = await api(MALL_BASE + "/item/goods/detail", headers, {
            goodsId: found.id,
            appid: auth.appid,
        });
        debug(detail, `exchange detail: ${target.name}`);
        assertAuth(detail);
        if (!detail || detail.status !== true || !detail.data) {
            $.messages.push(`❌ ${target.name}: 动态ID ${found.id} 商品详情为空`);
            continue;
        }

        const goods = detail.data;
        const period = goods.timeCycleExtraVo || {};
        if (period.saleIng === false) {
            $.messages.push(`⏳ ${target.name}: 当前不在售卖时间`);
            continue;
        }
        if (Number(goods.userOrderLimit) > 0 && Number(goods.userOrderTimes) >= Number(goods.userOrderLimit)) {
            $.messages.push(`✨ ${target.name}: 已兑换`);
            continue;
        }
        if (Number(goods.remainStocks) <= 0) {
            $.messages.push(`⛔ ${target.name}: 已售罄`);
            continue;
        }
        if (Number(goods.userPoints) < Number(goods.pointsPrice)) {
            $.messages.push(`❌ ${target.name}: 鸭币不足（${goods.userPoints || 0}/${goods.pointsPrice || 0}）`);
            continue;
        }

        const order = await api(MALL_BASE + "/order/create", headers, {
            goodsId: found.id,
            appid: auth.appid,
        });
        debug(order, `exchange order: ${target.name}`);
        assertAuth(order);
        if (order && order.status === true && order.data) {
            $.messages.push(`✅ ${target.name}: 兑换成功`);
            continue;
        }
        const message = String((order && order.message) || "未知错误");
        if (/已兑换|已购买|超过.*限制|限购/.test(message)) $.messages.push(`✨ ${target.name}: 已兑换`);
        else if (/售罄|库存|抢光/.test(message)) $.messages.push(`⛔ ${target.name}: 已售罄`);
        else $.messages.push(`❌ ${target.name}: ${message}`);
    }
}

async function loadMallCatalog(headers, appid, storeId) {
    const payloads = [
        { appid, storeId },
        { appid },
        { appid, storeId, pageNo: 1, pageSize: 100 },
        { appid, storeId, page: 1, size: 100 },
    ];
    let best = null;
    for (const body of payloads) {
        const res = await api(MALL_BASE + "/home/index", headers, body);
        debug(res, "exchange catalog: home/index");
        assertAuth(res);
        if (res && res.status === true && res.data) {
            best = res;
            if (collectGoods(res).length) break;
        }
    }
    return best;
}

function collectGoods(root) {
    const out = [], seen = {};
    const idKeys = ["goodsId", "itemId", "id", "entityId"];
    const nameKeys = ["goodsName", "itemName", "name", "title", "productName", "showName"];
    function walk(value, depth) {
        if (!value || depth > 12 || typeof value !== "object") return;
        if (!Array.isArray(value)) {
            const id = first.apply(null, idKeys.map((key) => value[key]));
            const name = first.apply(null, nameKeys.map((key) => value[key]));
            if (id && name && /^\d{6,}$/.test(String(id))) {
                const key = String(id);
                if (!seen[key]) { seen[key] = true; out.push({ id: key, name: String(name), raw: value }); }
            }
        }
        Object.keys(value).forEach((key) => walk(value[key], depth + 1));
    }
    walk(root, 0);
    return out;
}

function matchGoods(goods, keywords) {
    let best = null, score = 0;
    for (const item of goods) {
        const name = String(item.name || "").replace(/\s+/g, "");
        for (let i = 0; i < keywords.length; i++) {
            const key = String(keywords[i]).replace(/\s+/g, "");
            const current = name === key ? 1000 - i : (name.includes(key) ? 500 - i : 0);
            if (current > score) { best = item; score = current; }
        }
    }
    return best;
}

function api(url, headers, body) {
    return new Promise((resolve) => {
        const path = url.replace("https://webapi.qmai.cn/web", "");
        const opts = { url, headers, body: JSON.stringify(body) };
        $.post(opts, (err, resp, data) => {
            if (err) {
                $.log(`[ERROR] POST ${path}: ${short(err)}`);
                resolve(null);
                return;
            }
            const result = parseJSON(data, null);
            if (!result) $.log(`[ERROR] ${path} 响应解析失败: ${String(data || "").slice(0, 300)}`);
            resolve(result);
        });
    });
}

function taskOn(key) {
    // Loon 插件 [Argument] 开关优先；兼容旧的持久化/Node 环境变量配置。
    if (typeof $argument !== "undefined" && $argument && Object.prototype.hasOwnProperty.call($argument, key)) {
        const arg = $argument[key];
        return arg === true || arg === 1 || arg === "true" || arg === "1";
    }
    const value = $.isNode() ? process.env[key.toUpperCase()] : $.getdata(key);
    return value === true || value === 1 || value === "true" || value === "1";
}

function assertAuth(res) {
    if (!res) throw new Error("网络无响应,请稍后重试");
    const message = String(res.message || "");
    if (Number(res.code) === 9009 || /未知的请求来源/.test(message)) {
        throw new Error("请求来源校验失败：请安装 R10.1，并重新进入签到有礼页面覆盖来源请求头");
    }
    if ([9001, 10008, 41000, 100005].includes(Number(res.code)) || /token|登录|鉴权|未授权|失效|过期/i.test(message)) {
        throw new Error(`Cookie 已失效且自动刷新未成功,请打开一次林里小程序首页(无需进签到页): ${message || `code=${res.code}`}`);
    }
}

function isSigned(res) {
    return !!(res && res.status === true && res.data && Number(res.data.signStatus) === 1);
}

function formatStatus(prefix, res) {
    const data = (res && res.data) || {};
    const continuous = firstNumber(data.continuousSignDays, data.continueSignDays, data.signDays);
    const total = firstNumber(data.totalSignDays, data.accumulativeSignDays, data.cumulativeSignDays);
    const parts = [prefix];
    if (continuous > 0) parts.push(`连续 ${continuous} 天`);
    if (total > 0 && total !== continuous) parts.push(`累计 ${total} 天`);
    return parts.join(" · ");
}

function formatSignedStatus(res) {
    const data = (res && res.data) || {};
    const points = firstNumber(data.basicPoints, data.todayPoints, data.signPoints);
    const experience = firstNumber(data.basicExperience, data.todayExperience);
    const rewards = [];
    if (points > 0) rewards.push(`今日 +${points} 鸭币`);
    if (experience > 0) rewards.push(`+${experience} 成长值`);
    return formatStatus(`✨ 今日已签到${rewards.length ? `（${rewards.join("、")}）` : ""}`, res);
}

function firstNumber() {
    for (let i = 0; i < arguments.length; i++) {
        const n = Number(arguments[i]);
        if (Number.isFinite(n) && n > 0) return n;
    }
    return 0;
}

function rewardText(list) {
    if (!Array.isArray(list)) return "";
    return list.map((item) => item && item.rewardName ? `+${item.sendNum || 1} ${item.rewardName}` : "").filter(Boolean).join("、");
}

function cleanHeaders(raw) {
    const out = {};
    Object.keys(raw || {}).forEach((key) => {
        if (key.startsWith(":")) return;
        if (DROP_HEADERS.includes(key.toLowerCase())) return;
        out[key] = raw[key];
    });
    if (!lowerKeys(out)["content-type"]) out["content-type"] = "application/json";
    return out;
}

function lowerKeys(obj) {
    const out = {};
    Object.keys(obj || {}).forEach((key) => { out[key.toLowerCase()] = obj[key]; });
    return out;
}

function parseJSON(value, fallback) {
    if (value && typeof value === "object") return value;
    try { return JSON.parse(value); } catch (_) { return fallback; }
}

function parseBody(value) {
    const json = parseJSON(value, null);
    if (json && typeof json === "object") return json;
    const out = {};
    String(value || "").split("&").forEach((part) => {
        const pos = part.indexOf("=");
        if (pos < 0) return;
        try { out[decodeURIComponent(part.slice(0, pos))] = decodeURIComponent(part.slice(pos + 1).replace(/\+/g, " ")); } catch (_) {}
    });
    return out;
}

function parseQuery(url) {
    const out = {};
    const query = String(url || "").split("?")[1] || "";
    query.split("&").forEach((part) => {
        const pos = part.indexOf("=");
        if (pos < 0) return;
        try { out[decodeURIComponent(part.slice(0, pos))] = decodeURIComponent(part.slice(pos + 1)); } catch (_) {}
    });
    return out;
}

function first() {
    for (let i = 0; i < arguments.length; i++) if (arguments[i] !== undefined && arguments[i] !== null && String(arguments[i]) !== "") return arguments[i];
    return "";
}

function findAuthFields(root) {
    const found = {};
    const aliases = {
        activityid: "activityId", activity_id: "activityId", signactivityid: "activityId",
        storeid: "storeId", store_id: "storeId", shopid: "storeId",
        appid: "appid", app_id: "appid", qmusertoken: "qmUserToken", "qm-user-token": "qmUserToken"
    };
    function walk(value, depth) {
        if (!value || depth > 8 || typeof value !== "object") return;
        Object.keys(value).forEach((key) => {
            const v = value[key];
            const normalized = key.toLowerCase().replace(/[^a-z0-9_-]/g, "");
            const target = aliases[normalized];
            if (target && !found[target] && (typeof v === "string" || typeof v === "number")) found[target] = v;
            if (typeof v === "object") walk(v, depth + 1);
        });
    }
    walk(root, 0);
    return found;
}

function short(value) {
    return (typeof value === "string" ? value : JSON.stringify(value || {})).slice(0, 300);
}

function signLog(content, title) {
    $.log(`\n----- ${title} -----`);
    $.log(short(content));
    $.log("----- end -----\n");
}

function debug(content, title) {
    if ($.is_debug !== "true") return;
    signLog(content, title);
}

if (typeof $request !== "undefined") {
    captureCookie();
    // Loon 脚本必须返回受支持的对象，避免“返回结果的类型不受支持”。
    $.done({});
} else {
    (async () => {
        if (maybeClear()) return;
        let auth = loadAuth();
        // R11: 凭据保存满 20 小时即临期,先自动换新再签到,避开 10 点整的失效高峰
        const age = Date.now() - Number(auth.capturedAt || 0);
        if (age > REFRESH_AGE) {
            $.log(`[refresh] 凭据已保存 ${Math.round(age / 360000) / 10} 小时(>${REFRESH_AGE / 3600000} 小时),签到前预刷新`);
            if (await refreshToken(auth, "凭据临期")) auth = loadAuth();
        }
        try {
            await exchange(auth);
        } catch (e) {
            $.messages.push(`❌ 兑换异常: ${e.message || e}`);
            $.logErr(e);
        }
        await checkin(auth);
    })().catch((e) => {
        $.messages.push(`❌ ${e.message || e}`);
        $.logErr(e);
    }).finally(() => {
        if ($.messages.length) $.msg($.name, "", $.messages.join("\n"));
        $.done();
    });
}

// prettier-ignore
function Env(t,e){class s{constructor(t){this.env=t}send(t,e="GET"){t="string"==typeof t?{url:t}:t;let s=this.get;return"POST"===e&&(s=this.post),new Promise((e,a)=>{s.call(this,t,(t,s,r)=>{t?a(t):e(s)})})}get(t){return this.send.call(this.env,t)}post(t){return this.send.call(this.env,t,"POST")}}return new class{constructor(t,e){this.name=t,this.http=new s(this),this.data=null,this.dataFile="box.dat",this.logs=[],this.isMute=!1,this.isNeedRewrite=!1,this.logSeparator="\n",this.encoding="utf-8",this.startTime=(new Date).getTime(),Object.assign(this,e),this.log("",`🔔${this.name}, 开始!`)}getEnv(){return"undefined"!=typeof $environment&&$environment["surge-version"]?"Surge":"undefined"!=typeof $environment&&$environment["stash-version"]?"Stash":"undefined"!=typeof module&&module.exports?"Node.js":"undefined"!=typeof $task?"Quantumult X":"undefined"!=typeof $loon?"Loon":"undefined"!=typeof $rocket?"Shadowrocket":void 0}isNode(){return"Node.js"===this.getEnv()}isQuanX(){return"Quantumult X"===this.getEnv()}isSurge(){return"Surge"===this.getEnv()}isLoon(){return"Loon"===this.getEnv()}isShadowrocket(){return"Shadowrocket"===this.getEnv()}isStash(){return"Stash"===this.getEnv()}toObj(t,e=null){try{return JSON.parse(t)}catch{return e}}toStr(t,e=null){try{return JSON.stringify(t)}catch{return e}}getjson(t,e){let s=e;const a=this.getdata(t);if(a)try{s=JSON.parse(this.getdata(t))}catch{}return s}setjson(t,e){try{return this.setdata(JSON.stringify(t),e)}catch{return!1}}getScript(t){return new Promise(e=>{this.get({url:t},(t,s,a)=>e(a))})}loaddata(){if(!this.isNode())return{};{this.fs=this.fs?this.fs:require("fs"),this.path=this.path?this.path:require("path");const t=this.path.resolve(this.dataFile),e=this.path.resolve(process.cwd(),this.dataFile),s=this.fs.existsSync(t),a=!s&&this.fs.existsSync(e);if(!s&&!a)return{};{const a=s?t:e;try{return JSON.parse(this.fs.readFileSync(a))}catch(t){return{}}}}}writedata(){if(this.isNode()){this.fs=this.fs?this.fs:require("fs"),this.path=this.path?this.path:require("path");const t=this.path.resolve(this.dataFile),e=this.path.resolve(process.cwd(),this.dataFile),s=this.fs.existsSync(t),a=!s&&this.fs.existsSync(e),r=JSON.stringify(this.data);s?this.fs.writeFileSync(t,r):a?this.fs.writeFileSync(e,r):this.fs.writeFileSync(t,r)}}getdata(t){return this.getval(t)}setdata(t,e){return this.setval(t,e)}getval(t){switch(this.getEnv()){case"Surge":case"Loon":case"Stash":case"Shadowrocket":return $persistentStore.read(t);case"Quantumult X":return $prefs.valueForKey(t);case"Node.js":return this.data=this.loaddata(),this.data[t];default:return this.data&&this.data[t]||null}}setval(t,e){switch(this.getEnv()){case"Surge":case"Loon":case"Stash":case"Shadowrocket":return $persistentStore.write(t,e);case"Quantumult X":return $prefs.setValueForKey(t,e);case"Node.js":return this.data=this.loaddata(),this.data[e]=t,this.writedata(),!0;default:return this.data&&this.data[e]||null}}initGotEnv(t){this.got=this.got?this.got:require("got"),this.cktough=this.cktough?this.cktough:require("tough-cookie"),this.ckjar=this.ckjar?this.ckjar:new this.cktough.CookieJar,t&&(t.headers=t.headers?t.headers:{},void 0===t.headers.Cookie&&void 0===t.cookieJar&&(t.cookieJar=this.ckjar))}get(t,e=(()=>{})){switch(t.headers&&(delete t.headers["Content-Type"],delete t.headers["Content-Length"],delete t.headers["content-type"],delete t.headers["content-length"]),t.params&&(t.url+="?"+this.queryStr(t.params)),this.getEnv()){case"Surge":case"Loon":case"Stash":case"Shadowrocket":default:this.isSurge()&&this.isNeedRewrite&&(t.headers=t.headers||{},Object.assign(t.headers,{"X-Surge-Skip-Scripting":!1})),$httpClient.get(t,(t,s,a)=>{!t&&s&&(s.body=a,s.statusCode=s.status?s.status:s.statusCode,s.status=s.statusCode),e(t,s,a)});break;case"Quantumult X":this.isNeedRewrite&&(t.opts=t.opts||{},Object.assign(t.opts,{hints:!1})),$task.fetch(t).then(t=>{const{statusCode:s,statusCode:a,headers:r,body:i,bodyBytes:o}=t;e(null,{status:s,statusCode:a,headers:r,body:i,bodyBytes:o},i,o)},t=>e(t&&t.error||"UndefinedError"));break;case"Node.js":let s=require("iconv-lite");this.initGotEnv(t),this.got(t).on("redirect",(t,e)=>{try{if(t.headers["set-cookie"]){const s=t.headers["set-cookie"].map(this.cktough.Cookie.parse).toString();s&&this.ckjar.setCookieSync(s,null),e.cookieJar=this.ckjar}}catch(t){this.logErr(t)}}).then(t=>{const{statusCode:a,statusCode:r,headers:i,rawBody:o}=t,n=s.decode(o,this.encoding);e(null,{status:a,statusCode:r,headers:i,rawBody:o,body:n},n)},t=>{const{message:a,response:r}=t;e(a,r,r&&s.decode(r.rawBody,this.encoding))})}}post(t,e=(()=>{})){const s=t.method?t.method.toLocaleLowerCase():"post";switch(t.body&&t.headers&&!t.headers["Content-Type"]&&!t.headers["content-type"]&&(t.headers["content-type"]="application/x-www-form-urlencoded"),t.headers&&(delete t.headers["Content-Length"],delete t.headers["content-length"]),this.getEnv()){case"Surge":case"Loon":case"Stash":case"Shadowrocket":default:this.isSurge()&&this.isNeedRewrite&&(t.headers=t.headers||{},Object.assign(t.headers,{"X-Surge-Skip-Scripting":!1})),$httpClient[s](t,(t,s,a)=>{!t&&s&&(s.body=a,s.statusCode=s.status?s.status:s.statusCode,s.status=s.statusCode),e(t,s,a)});break;case"Quantumult X":t.method=s,this.isNeedRewrite&&(t.opts=t.opts||{},Object.assign(t.opts,{hints:!1})),$task.fetch(t).then(t=>{const{statusCode:s,statusCode:a,headers:r,body:i,bodyBytes:o}=t;e(null,{status:s,statusCode:a,headers:r,body:i,bodyBytes:o},i,o)},t=>e(t&&t.error||"UndefinedError"));break;case"Node.js":let a=require("iconv-lite");this.initGotEnv(t);const{url:r,...i}=t;this.got[s](r,i).then(t=>{const{statusCode:s,statusCode:r,headers:i,rawBody:o}=t,n=a.decode(o,this.encoding);e(null,{status:s,statusCode:r,headers:i,rawBody:o,body:n},n)},t=>{const{message:s,response:r}=t;e(s,r,r&&a.decode(r.rawBody,this.encoding))})}}time(t,e=null){const s=e?new Date(e):new Date;let a={"M+":s.getMonth()+1,"d+":s.getDate(),"H+":s.getHours(),"m+":s.getMinutes(),"s+":s.getSeconds(),"q+":Math.floor((s.getMonth()+3)/3),S:s.getMilliseconds()};/(y+)/.test(t)&&(t=t.replace(RegExp.$1,(s.getFullYear()+"").substr(4-RegExp.$1.length)));for(let e in a)new RegExp("("+e+")").test(t)&&(t=t.replace(RegExp.$1,1==RegExp.$1.length?a[e]:("00"+a[e]).substr((""+a[e]).length)));return t}queryStr(t){let e="";for(const s in t){let a=t[s];null!=a&&""!==a&&("object"==typeof a&&(a=JSON.stringify(a)),e+=`${s}=${a}&`)}return e=e.substring(0,e.length-1),e}msg(e=t,s="",a="",r){const i=t=>{switch(typeof t){case void 0:return t;case"string":switch(this.getEnv()){case"Surge":case"Stash":default:return{url:t};case"Loon":case"Shadowrocket":return t;case"Quantumult X":return{"open-url":t};case"Node.js":return}case"object":switch(this.getEnv()){case"Surge":case"Stash":case"Shadowrocket":default:{let e=t.url||t.openUrl||t["open-url"];return{url:e}}case"Loon":{let e=t.openUrl||t.url||t["open-url"],s=t.mediaUrl||t["media-url"];return{openUrl:e,mediaUrl:s}}case"Quantumult X":{let e=t["open-url"]||t.url||t.openUrl,s=t["media-url"]||t.mediaUrl,a=t["update-pasteboard"]||t.updatePasteboard;return{"open-url":e,"media-url":s,"update-pasteboard":a}}case"Node.js":return}default:return}};if(!this.isMute)switch(this.getEnv()){case"Surge":case"Loon":case"Stash":case"Shadowrocket":default:$notification.post(e,s,a,i(r));break;case"Quantumult X":$notify(e,s,a,i(r));break;case"Node.js":}if(!this.isMuteLog){let t=["","==============📣系统通知📣=============="];t.push(e),s&&t.push(s),a&&t.push(a),console.log(t.join("\n")),this.logs=this.logs.concat(t)}}log(...t){t.length>0&&(this.logs=[...this.logs,...t]),console.log(t.join(this.logSeparator))}logErr(t,e){switch(this.getEnv()){case"Surge":case"Loon":case"Stash":case"Shadowrocket":case"Quantumult X":default:this.log("",`❗️${this.name}, 错误!`,t);break;case"Node.js":this.log("",`❗️${this.name}, 错误!`,t.stack)}}wait(t){return new Promise(e=>setTimeout(e,t))}done(t={}){const e=(new Date).getTime(),s=(e-this.startTime)/1e3;switch(this.log("",`🔔${this.name}, 结束! 🕛 ${s} 秒`),this.log(),this.getEnv()){case"Surge":case"Loon":case"Stash":case"Shadowrocket":case"Quantumult X":default:$done(t);break;case"Node.js":process.exit(1)}}}(t,e)}