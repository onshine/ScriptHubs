<p align="center">
  <img src="https://raw.githubusercontent.com/MaYIHEI/pin/refs/heads/main/app/paperclip-checkin.png" width="80" alt="Paperclip 签到合集" />
</p>

# Paperclip 签到 + Cookie 合体（Loon 外壳）

给 **Paperclip** 全套签到脚本用的 Loon 插件，**一个插件搞定签到和 Cookie 抓取**。脚本本体不是本仓库的，全部引用上游 [`MaYIHEI/paperclip`](https://github.com/MaYIHEI/paperclip)，作者更新这里自动跟上。

```
https://raw.githubusercontent.com/onshine/ScriptHubs/main/paperclip/Paperclip.lpx
```

需 **Loon 3.5.1(983)** 或更高。

---

## 一、规则怎么排的

**成对排布**：每个脚本「签到」一条，紧跟其下就是它自己的「Cookie 抓取」一条。

```ini
# ---- 【微博超话】签到 ----
cron ${weibotalk_cron} then script("…/weibotalk.js", {${merge}}) with tag="微博超话签到", enable=${weibotalk}
request if ${url} ~= /…api\.weibo\.cn…/i then script("…/weibotalk.cookie.js") with enable=${weibotalk_cookie}, tag="微博超话 Cookie"
```

开关也成对：

| 设置项 | 默认 | 作用 |
|---|---|---|
| `【XXX】签到` | **开** | 那个脚本的定时签到 |
| `　└ 取 Cookie` | **关** | 那个脚本的抓 Cookie 规则；要抓时才开，抓完关掉 |
| `　└ 签到时间` | 留空 | 留空＝上游默认；填写即覆盖 |

## 二、覆盖的脚本

**上游插件收录的 31 个**：微博超话、腾讯视频、米游社、一点万象、小米商城、小米抽奖、小米有品、龙湖天街 App、QQ音乐、万达电影、听听FM、WPS、扫描全能王、追觅、灵狐灵购、NodeSeek、123社区、AgentRouter、网上国网、百度网盘、徕芬、泡泡玛特、途虎养车、海底捞、惠省红包墙、名创优品、龙德广场、龙湖天街、味多美、北京华联、林里

**本外壳补充的 4 个**（上游插件没收录）：

| 脚本 | 来源 | 说明 |
|---|---|---|
| 特来电 | `gist.githubusercontent.com/onshine/9cb869dc…/raw/teld.js` | 上游仓库**没有**这个文件，直接引用你的 gist 原文，**内容一个字没改** |
| 松山棉店 | 上游 `miniprogram/songshan/` | 唯一会写 `_status` 的补充脚本，**进汇总通知** |
| 笔笔省 | 上游 `miniprogram/bibisheng/` | 领每日礼券 |
| CASETiFY | 上游 `miniprogram/casetify/` | 会员每日签到 |

> 驴充充、滔搏已从本外壳移除（原仓库不维护）。

## 三、相比作者原插件的改动

| 问题 | 上游 | 本外壳 |
|---|---|---|
| 签到时间 | 写死 | 每个脚本一个时间框，留空＝上游默认 |
| 汇总时间 | 写死 11:30 | `summary_cron` 可填 |
| 小米抽奖永不触发 | `cron "0 30 7 * * *"` 是**六段** cron（秒分时日月周），秒=0 分=30 时=7 永远到不了 | 改标准五段，默认 `30 8 * * *` |
| 缺脚本 | 只收录 31 个 | 补上表 4 个 |
| MITM 覆盖 | 无 `%APPEND%`，整段覆盖其它插件 | `hostname = %APPEND% …` 只追加 |

## 四、使用步骤

1. Loon → 配置 → 插件 → `+`，填上面的地址
2. 需要抓哪个脚本的 Cookie，就打开它下面的「└ 取 Cookie」
3. 进对应 App / 小程序页面，收到 `✅ <名称> Cookie 获取成功` 后**关掉那个开关**
4. 签到开关默认全开；没抓 Cookie / 没配账号的脚本自动跳过
5. 账号、任务开关等设置仍在 **BoxJS**（`Paperclip` 命名空间）

⚠️ **与作者原插件二选一**：先删掉他的「签到合集」和「Cookie 抓取合集」再装这个，否则每天签两次。
单独装过「网上国网」插件、或本站 [agentrouter](../agentrouter/) 插件的，也要关掉。

## 五、已知限制

- 汇总只统计会写 `_status` 的脚本：特来电、笔笔省、CASETiFY 不登记状态，任务照常跑但不进汇总
- 龙德广场与北京华联同一会员体系，两个都开会各签一次
- 「清除 Cookie」仍在 BoxJS 操作
- Loon 会缓存插件，**更新后请删除旧插件重新添加**

## 六、历史文件

`Paperclip-Checkin.lpx` / `Paperclip-Cookie.lpx` 是早期的双插件版本，已合并为 `Paperclip.lpx`，文件保留仅为兼容旧链接，**不要再用**（`_deprecated`）。
