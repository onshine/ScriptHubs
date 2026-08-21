/*
 * gemini-web2api 多节点健康巡检 R1.3.6
 * 支持 Loon / Quantumult X / Surge
 * 仓库：https://github.com/onshine/ScriptHubs/tree/main/gemini-web2api
 *
 * 用途：定时探测自建 gemini-web2api-go 节点（支持 IPv6 多台），
 *      检查存活/版本/模型数/Cookie 是否失效/Pro 是否可用/限流余量，
 *      异常时推送通知。多节点部署的运维刚需。
 *
 * 版本：R1.3.6（与 SCRIPT_VERSION 及 README 保持一致）
 */

const SCRIPT_VERSION = "R1.3.6";
const NAME = "GeminiAPI巡检";

// ── 配置：从插件 argument 读取 ────────────────────────────────
// nodes 格式（多节点用英文逗号分隔）：
//   别名|http://[2001:db8::1]:8084|sk-gemini-xxx , 别名2|http://[2001:db8::2]:8084|sk-gemini-yyy
// API Key 可省略（省略则只做不鉴权的 / 健康检查）
const ARG = typeof $argument !== "undefined" && $argument ? $argument : {};
const RAW_NODES = String(ARG.nodes || "").trim();
const TIMEOUT = Math.max(5, Number(ARG.timeout || 15)) * 1000;
const NOTIFY_OK = String(ARG.notify_ok || "false") === "true"; // 全部正常时是否也推送
const PROBE_PRO = String(ARG.probe_pro || "true") === "true";  // 是否检查 Pro 模型可用性

main().catch((e) => finish(`❌ 脚本异常：${e && e.message ? e.message : e}`));

async function main() {
  const nodes = parseNodes(RAW_NODES);
  if (!nodes.length) {
    return finish("⚠️ 未配置节点\n请在插件参数 nodes 里填写：\n别名|http://[v6]:8084|sk-gemini-xxx");
  }

  console.log(`[${NAME} ${SCRIPT_VERSION}] 开始巡检 ${nodes.length} 个节点`);
  const results = [];
  for (const n of nodes) {
    results.push(await probe(n));
  }

  const bad = results.filter((r) => !r.ok);
  const lines = results.map(fmtLine);
  const body = lines.join("\n");
  console.log(`[${NAME}] 结果：\n${body}`);

  if (bad.length) {
    finish(`⚠️ ${bad.length}/${results.length} 个节点异常\n${body}`);
  } else if (NOTIFY_OK) {
    finish(`✅ ${results.length} 个节点全部正常\n${body}`);
  } else {
    // 全部正常且未开启 notify_ok：只写日志不打扰
    console.log(`[${NAME}] 全部正常，按配置不推送通知`);
    done();
  }
}

// ── 解析节点配置 ─────────────────────────────────────────────
function parseNodes(raw) {
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((seg) => {
      // 用 | 分隔，注意 URL 里的 IPv6 方括号不受影响
      const parts = seg.split("|").map((x) => x.trim());
      if (parts.length < 2) return null;
      return { name: parts[0] || "节点", base: parts[1].replace(/\/+$/, ""), key: parts[2] || "" };
    })
    .filter(Boolean);
}

// ── 探测单节点 ───────────────────────────────────────────────
async function probe(node) {
  const out = { name: node.name, base: node.base, ok: false, msg: "", ver: "", models: 0, pro: null };

  // 1) 健康检查（不鉴权）：GET /
  const h = await get(`${node.base}/`, {});
  if (!h.ok) {
    out.msg = `离线 (${h.error || "HTTP " + h.status})`;
    return out;
  }
  try {
    const j = JSON.parse(h.body);
    out.ver = j.version || "?";
    out.models = Array.isArray(j.models) ? j.models.length : 0;
  } catch (e) {
    out.msg = "响应非 JSON，可能不是本服务";
    return out;
  }

  // 2) 有 key 才能查模型列表判断 Cookie 状态
  if (!node.key) {
    out.ok = true;
    out.msg = `存活 v${out.ver} / ${out.models} 模型（未配 key，跳过深度检查）`;
    return out;
  }

  const m = await get(`${node.base}/v1/models`, { Authorization: `Bearer ${node.key}` });
  if (!m.ok) {
    if (m.status === 401 || m.status === 403) out.msg = "API Key 无效或已轮换";
    else if (m.status === 429) out.msg = `被限流 (429)，配额打满`;
    else out.msg = `模型接口异常 (${m.error || "HTTP " + m.status})`;
    return out;
  }

  let ids = [];
  try {
    const j = JSON.parse(m.body);
    ids = (j.data || []).map((x) => x && x.id).filter(Boolean);
  } catch (e) {
    out.msg = "模型列表解析失败";
    return out;
  }
  out.models = ids.length;
  // Pro 出现在列表里 = Cookie 有效（匿名时上游只暴露两个 flash）
  out.pro = ids.some((id) => String(id).indexOf("3.1-pro") >= 0);

  // 3) 可选：真发一次 Pro 请求确认没被静默降级
  if (PROBE_PRO && out.pro) {
    const c = await post(
      `${node.base}/v1/chat/completions`,
      { Authorization: `Bearer ${node.key}`, "Content-Type": "application/json" },
      JSON.stringify({ model: "gemini-3.1-pro", messages: [{ role: "user", content: "hi" }] })
    );
    if (c.ok) {
      try {
        const j = JSON.parse(c.body);
        const msg = j.choices && j.choices[0] && j.choices[0].message;
        // 有 reasoning_content = 真 Pro；没有 = Cookie 已过期被降级
        out.proReal = !!(msg && msg.reasoning_content);
      } catch (e) {
        out.proReal = null;
      }
    } else if (c.status === 429) {
      out.msg = "Pro 探测被限流";
    }
  }

  out.ok = true;
  const bits = [`v${out.ver}`, `${out.models} 模型`];
  if (out.pro) bits.push(out.proReal === false ? "Pro已降级(Cookie过期)" : "Pro可用");
  else bits.push("匿名(无Cookie)");
  out.msg = bits.join(" / ");
  return out;
}

function fmtLine(r) {
  return `${r.ok ? "✅" : "❌"} ${r.name}：${r.msg}`;
}

// ── HTTP 封装（兼容 Loon / QX / Surge）───────────────────────
function get(url, headers) {
  return request("GET", url, headers, null);
}
function post(url, headers, body) {
  return request("POST", url, headers, body);
}
function request(method, url, headers, body) {
  const req = { url, headers: headers || {}, timeout: Math.floor(TIMEOUT / 1000) };
  if (body) req.body = body;

  return new Promise((resolve) => {
    // Quantumult X
    if (typeof $task !== "undefined") {
      req.method = method;
      $task.fetch(req).then(
        (r) => resolve(wrap(null, r.statusCode, r.body)),
        (e) => resolve(wrap(e && e.error ? e.error : "请求失败", 0, ""))
      );
      return;
    }
    // Loon / Surge
    const fn = method === "POST" ? $httpClient.post : $httpClient.get;
    if (typeof $httpClient === "undefined") return resolve(wrap("无 HTTP 客户端", 0, ""));
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
