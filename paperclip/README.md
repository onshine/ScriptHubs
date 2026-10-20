<p align="center">
  <img src="https://raw.githubusercontent.com/MaYIHEI/pin/refs/heads/main/app/paperclip-checkin.png" width="80" alt="Paperclip 签到合集" />
</p>

# Paperclip 签到合集 + Cookie 抓取合集（Loon 外壳）

给 **Paperclip** 全套签到脚本用的 Loon 插件外壳。**脚本本体不是本仓库的**，全部引用上游 [`MaYIHEI/paperclip`](https://github.com/MaYIHEI/paperclip)，作者更新脚本这里自动跟上。

| 插件 | 导入地址 |
|---|---|
| 签到合集 | `https://raw.githubusercontent.com/onshine/ScriptHubs/main/paperclip/Paperclip-Checkin.lpx` |
| Cookie 抓取合集 | `https://raw.githubusercontent.com/onshine/ScriptHubs/main/paperclip/Paperclip-Cookie.lpx` |

需 **Loon 3.5.1(983)** 或更高。

---

## 一、这外壳解决什么

| 问题 | 上游原插件 | 本外壳的处理 |
|---|---|---|
| **签到时间改不了** | 每个脚本的 cron 都写死在插件里 | 每个脚本多一个「└ 时间」输入框，**留空＝上游默认**，填写即覆盖 |
| **汇总时间改不了** | 写死 11:30 | 汇总行也做成可填的 `summary_cron` |
| **小米抽奖永不触发** | `cron "0 30 7 * * *"` 是**六段** cron（秒 分 时 日 月 周）→ 秒=0、分=30、时=7 永远到不了 | 改成 `${milottery_cron}`，默认 `30 8 * * *`（与原意 8:30 一致，改成标准 5 段） |
| **缺脚本** | 上游插件只收录 31 个 | 补 6 个：**特来电**、松山棉店、笔笔省、CASETiFY、驴充充、滔搏 |
| **MITM 整段覆盖** | Cookie 插件 `hostname = ...` 无 `%APPEND%` | 改为 `hostname = %APPEND% ...`，只追加不覆盖其它插件的 MITM |
| **抓取插件没有总开关** | 29 条规则只能逐条删 | 加「抓取开关」，一键全停 |

> 特来电：上游仓库**没有**这个脚本文件，所以本外壳直接引用你的 gist 原文
> `gist.githubusercontent.com/onshine/9cb869dc.../raw/teld.js`，**脚本内容一个字没改**。

## 二、与原插件的关系

⚠️ **二选一**。本外壳和作者原插件不能同时装，否则每个脚本每天会签两次。
先删除 `Paperclip · 签到合集` / `Paperclip · Cookie 抓取合集`，再导入上面的地址。
单独装过 `网上国网` 单独版插件、或本站 [agentrouter](../agentrouter/) 插件的，也要关掉（签到合集里已含国网脚本）。

## 三、使用步骤

1. 导入「签到合集」和「Cookie 抓取合集」
2. 打开抓取合集 → 进对应 App / 小程序页面 → 收到 `✅ <名称> Cookie 获取成功` → **关掉抓取合集**
3. 签到合集里每个脚本一个开关，默认全开；没抓 Cookie / 没配账号的自动跳过
4. 「统一通知」开着时，各脚本静默，每天汇总时间发一条；关掉就各自推送
5. 账号、任务开关等设置仍在 **BoxJS**（`Paperclip` 命名空间）

## 四、插件设置

```
【统一通知】每天一条汇总   switch  开
  └ 汇总时间               input   30 11 * * *
【微博超话】签到           switch  开
  └ 时间                   input   留空＝上游默认 0 8 * * *
...
```

- 时间框留空 → 用上游默认（每个脚本的默认值都写在 `desc` 里）
- 填了 → 覆盖，支持 5 段（分 时 日 月 周）
- Cookie 合集只有一个「抓取开关」

## 五、已知限制

- 汇总只统计**会写 `_status` 状态**的脚本；特来电、笔笔省、CASETiFY、驴充充、滔搏这几个脚本本身不登记状态，任务照常执行，但不进汇总通知（松山棉店会登记）
- 龙德广场与北京华联同一会员体系，两个都开会各签一次，通常只开一个
- 「清除 Cookie」仍在 BoxJS 操作
- 上游脚本缓存在 Loon 里，**插件更新后请删除旧插件重新添加**，强制重下插件本体

## 六、维护

生成脚本在本机 `gen.py`：读取上游三个 `.lpx`，替换 cron 触发器后输出本目录两个文件。
上游新增脚本时，改 `EXTRA` 字典或重新拉取上游 `.lpx` 即可。
