# 车来了去广告（Loon）

去掉「车来了」iOS App 的**开屏广告**与**应用内广告**。适用于 Loon（脚本 / 复写 / MitM 均为新版语法，建议 Loon ≥ 3.5.1）。

- 插件：`CheLaiLe_Ads.plugin`
- 脚本：`chelaile-ads.js`
- 版本：**R1.0.0**

---

## 一、为什么你之前装的规则「突然不好使了」

车来了 App 在 2025 年底～2026 年做了一次接口大改版，**老的去广告规则基本全废**，原因是双重的：

**1. 接口换了。** 老规则（奶思 wool_scripts / 墨鱼 ddgksf2013 / 各处抄来抄去的那份）打的是这些地址：

```
pic1.chelaile.net.cn/adv/            ← 老开屏图
api.chelaile.net.cn/adpub/           ← 老广告位
api.chelaile.net.cn/goocity/advert/  ← 老广告接口
cdn.*.chelaileapp.cn/(api/)adpub     ← 老 CDN 广告
```

而现在 App 实际在用的是：

```
api.chelaile.net.cn/bus-side/appToggle/getStatus   ← 启动配置（开屏/插屏全部开关在这）
api.chelaile.net.cn/goocity/flowPos/home           ← 首页金刚位（含推广位）
api.chelaile.net.cn/goocity/flowPos/listByPos      ← 「我的」页面推广位
web.chelaile.net.cn/api/operative_position/infoflow/getInfo  ← 详情页信息流
cdn.web.chelaile.net.cn/info-flow/index.html       ← 信息流落地页
image3.chelaile.net.cn/hw6u6LYY.png                ← 首页固定广告位图
api.chelaile.net.cn/goocity/config/notices         ← 公告弹窗
api.chelaile.net.cn/encourage/activity/control     ← 活动弹窗
api.chelaile.net.cn/led-weather/v1/condition_brief ← LED 天气条
adx.yg84.com/sdk/ad/{get,setting,init}             ← 广告 SDK（投放任务下发）
```

老规则的路径**一个都不在上面**，所以它其实早就「空转」了 —— 规则还在跑，只是再也匹配不到东西。

**2. 思路也过时了。** 老规则是「等广告素材请求出来再拦」。现在开屏广告是**先由启动配置接口下发开关和素材 URL**，App 再照着去拉素材。只要拦不到配置这一步，广告会照常显示；反过来，**把配置里的广告字段删掉，App 压根不会去拉开屏素材**，连加载都不发生。这才是现在唯一稳的做法。

> 本插件的核心就是第 2 条：`appToggle/getStatus` 配置清洗。

---

## 二、安装

Loon → 配置 → 插件 → 右上角 `+` → 添加订阅，填入：

```
https://raw.githubusercontent.com/onshine/ScriptHubs/main/chelaile/CheLaiLe_Ads.plugin
```

装好后：

1. **打开 MitM**（插件会自动把所需域名附加进 MitM 列表，用的是 `%APPEND%`，不会覆盖你自己的列表）。
2. 确认 MitM 证书已安装且在「关于本机 → 证书信任设置」里被信任。
3. 进插件设置页，6 个开关按需勾选（默认全开）。
4. **杀掉车来了 App 重开**（老配置缓存在内存/本地，不重启可能还是旧行为）。
5. 如果开屏广告还在，去 **设置 → 通用 → iPhone 储存空间 → 车来了 → 卸载 App**（保留数据的那种「卸载」，不是「删除」）后重装 —— 社区规则普遍提示要清缓存。

---

## 三、开关说明

| 开关 | 默认 | 作用 |
|---|---|---|
| `remove_splash` | ✅ | 清洗启动配置，删掉开屏 / 插屏 / 预加载广告的开关字段。**去开屏广告的关键项** |
| `remove_home_grid` | ✅ | 首页金刚位、「我的」页面里的推广位（保留地铁、站点地图等功能入口） |
| `remove_feed` | ✅ | 详情页信息流文章推荐、城市列表推广图，并清空广告 SDK 投放任务 |
| `remove_notice` | ✅ | 公告、活动控制、LED 天气条等弹层 |
| `block_httpdns` | ✅ | 删掉 `useHttpDns` / `appBackupDomains` / `blacklistDomains`，防止 App 走 HTTPDNS 绕过分流 |
| `debug` | ❌ | 在 Loon 运行日志里输出每个接口的处理结果，排查用 |

---

## 四、实现要点（改脚本前必读）

### 1. 响应体的 `**YGKJ...YGKJ##` 外壳绝不能写死

车来了的接口响应都被包成：

```
**YGKJ{"jsonr":{"status":"00","data":{...}}}YGKJ##
```

历史上有 `YGKJ**`、`YGKJ##` 两种结尾标记都出现过。很多去广告脚本直接 `mock` 一段写死的 JSON 字符串，**一旦 App 换了结尾标记就会解析失败**，表现为首页空白 / 一直转圈。

本脚本的做法是：**用正则把外壳切出来，只替换中间那段 JSON，外壳原样接回去**（`splitWrap` / `joinWrap`）。无论 App 用 `##` 还是 `**`，都不会写坏数据。

### 2. 只删字段，不写死内容

社区部分规则会把首页金刚位 `mock` 成一段固定的两三项 JSON。App 改版加了新功能入口，这段 JSON 就错位了。

本脚本改为**按「是不是推广」判断并剔除**：指向外部 App（有 `appId`/`appPath`）或站外链接的判为推广位，其余保留。App 加新功能入口也能自动带上。

### 3. 任何异常一律放行原响应

JSON 解析失败、结构不符合预期、字段不存在 —— 全部 `$done({})`，让原始响应原样通过。**宁可这个广告拦不掉，也绝不把 App 的响应写坏。**

### 4. 老接口仍然保留拦截

`adpub` / `goocity/advert` / `pic1/adv/` 这些老路径在 `[Rewrite]` 里保留着，防止某些版本或某些机型回退到老接口。

---

## 五、可选但强烈建议：装一个「广告平台拦截器」

车来了会通过 **HTTPDNS** 解析广告域名，从而绕开 Loon 的 DNS 与规则匹配，导致去广告时灵时不灵。

- 本插件已经会删掉配置里的 `useHttpDns` 字段（`block_httpdns` 开关）。
- 但如果你的其他 App 也需要去广告，建议再装一个专门的 HTTPDNS 拦截插件（社区常叫「广告平台拦截器」，可莉/VirgilClyne 维护的那份），把所有去广告插件都变成它的下游。

---

## 六、排查

| 现象 | 处理 |
|---|---|
| 开屏广告还在 | ① 确认 `remove_splash` 打开 ② 杀 App 重开 ③ 卸载重装 ④ 开 `debug` 看日志里有没有命中 `appToggle/getStatus` |
| 首页金刚位还有推广 | 开 `debug`，看有没有命中 `flowPos/home`；没有就是新接口，把 URL 贴给我 |
| 完全没反应 | 检查 MitM 开关是否打开、证书是否被信任、插件是否启用 |
| 页面空白 / 转圈 | **立刻停用插件**并反馈 —— 这是响应被写坏的信号（本脚本理论上不会，但要有这个止损动作） |
| 想确认命中情况 | Loon → 日志，筛选 `车来了` |

---

## 七、版本记录

- **R1.0.0**（2026-10-10）首版。基于 2026-10 仍有效的接口调研（可莉 Kelee 2026-10-02 版 + chikacya 2026-10-03 版），在其基础上做了三点改进：
  1. 外壳**动态保留**（不写死 `##`/`**`），兼容两种结尾标记；
  2. 首页金刚位改为**按推广特征动态剔除**，不再写死固定 JSON；
  3. 补齐 chikacya 版独有的 **`adx.yg84.com` 广告 SDK** 处理，并新增 `block_httpdns` 防绕过开关。

---

仅供学习交流。规则基于公开社区资料与逆向观察整理，接口随时可能变更；如失效请按「排查」一节定位后反馈。
