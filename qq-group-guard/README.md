# QQ 群名片守卫 · qq-group-guard

**版本：R1.0.1**

定时巡检 QQ 群成员名片，对不符合群规格式的成员按「**宽容模式**」分级处理：观察期内只在群里 @ 提醒改名，连续多轮仍不改才踢出。

基于 OneBot v11 HTTP API，兼容 **go-cqhttp / NapCat / Lagrange / LLOneBot** 等实现。

提供三种用法，同一套参数：

| 形态 | 文件 | 适用场景 |
|---|---|---|
| Loon / QX / Surge 插件 | `qq-group-guard.js` + `QQ_Group_Guard.plugin` | 手机上跑，图形化填参数，最省事 |
| Linux 服务 | `qq-group-guard.py` + `install.sh` | VPS 上跑，systemd timer 定时，稳定 |
| 手动命令行 | `qq-group-guard.py` | 临时清理一次 |

---

## 为什么要「宽容模式」

原始的一把梭踢人脚本有三个致命问题，本项目逐一解决：

| 风险 | 本项目的解法 |
|---|---|
| 关键词写错 → 一秒清群 | **比例熔断**：不合规占比超阈值直接中止；**关键词为空拒绝运行** |
| 成员没看到通知就被踢 | **观察期**（默认 48h）+ **群内 @ 提醒** + **连续多轮确认**（默认 2 轮） |
| 名片只是格式差异（全角、空格、大小写）被误判 | **模糊匹配**：NFKC 归一化，全角转半角、去大小写、去空格与 30+ 种装饰符号 |
| 管理员/新人/元老被误伤 | 五重豁免：群主管理员 / 有专属头衔 / 新人保护期 / 白名单 / 机器人自身 |
| 一次踢太多触发腾讯风控 | **单轮上限**（默认 5 人）+ 可调间隔（默认 1.5s），超出的顺延到下轮 |
| 踢人失败被静默忽略 | 失败者保留在观察表里，下轮自动重试 |

### 三种模式

| 模式 | 行为 | 建议 |
|---|---|---|
| `report` | **只报告，绝不动手** | ⭐ 首次部署必用。先跑 2~3 天，确认名单里没有你不想踢的人 |
| `lenient` | 宽容模式（默认）：观察期 + @提醒 + 多轮确认 + 各种安全阀 | 日常长期运行用这个 |
| `strict` | 发现即踢（仍保留白名单/管理员/熔断保护） | 只在临时清理小号时用 |

### lenient 模式的完整判定流程

```
拉取成员列表
  ↓
名片模糊匹配关键词 ──合规──> 跳过，并清除其观察记录
  ↓ 不合规
五重豁免检查 ──命中──> 跳过（日志里写明豁免原因）
  ↓
比例熔断：不合规占比 > max_ratio 且人数 >= breaker_min ──> 🛑 全部中止
  ↓
查历史观察记录：轮数 +1，计算距首次发现的小时数
  ↓
轮数 >= grace_rounds 且 小时数 >= grace_hours ？
  ├─ 否 ──> 记入观察表，群内 @ 提醒改名，本轮不踢
  └─ 是 ──> 进入待踢队列
              ↓
         单轮上限 max_kick 截断，超出的顺延下轮
              ↓
         逐个踢出（间隔 interval 秒），失败者留在观察表下轮重试
```

---

## 一、Loon / Quantumult X / Surge 用法

### 安装

Loon → 插件 → 添加插件，填入：

```
https://raw.githubusercontent.com/onshine/ScriptHubs/main/qq-group-guard/QQ_Group_Guard.plugin
```

装好后点插件进入参数页填写，**必填三项**：`api_base`、`group_id`、`keywords`。

> ⚠️ Loon 必须能网络访问到你的 OneBot HTTP 地址。如果 OneBot 跑在家里内网，手机在外网时需要先连上 VPN / 内网穿透。

### 参数一览（Loon Argument）

必填项标 ⭐。

| 参数 | 默认 | 说明 |
|---|---|---|
| ⭐ `api_base` | `http://127.0.0.1:5700` | OneBot HTTP 地址，必须带 `http://` 或 `https://` |
| `token` | 空 | OneBot 的 `access_token`，没设就留空 |
| ⭐ `group_id` | 空 | 群号，多个用英文逗号分隔 |
| ⭐ `keywords` | 空 | 合规关键词，含任一即合规。逗号分隔。`re:` 前缀写正则。**留空时脚本拒绝运行** |
| `mode` | `report` | `report` / `lenient` / `strict` |
| `grace_hours` | `48` | 观察期小时数，从首次发现算起 |
| `grace_rounds` | `2` | 连续几轮不合规才踢，与观察期需同时满足 |
| `new_member_days` | `3` | 入群不足 N 天一律豁免，0 关闭 |
| `veteran_days` | `0` | 入群超过 N 天一律豁免，0 关闭 |
| `whitelist` | 空 | 永不处理的 QQ 号，逗号分隔 |
| `self_qq` | `0` | 机器人自身 QQ，防自踢 |
| `skip_admin` | `true` | 豁免群主/管理员 |
| `skip_title` | `true` | 豁免有群专属头衔的成员 |
| `max_kick` | `5` | 单轮最多踢几人，0 不限 |
| `max_ratio` | `30` | 不合规占比熔断阈值（%），0 关闭 |
| `breaker_min` | `5` | 熔断同时要求的最少不合规人数，避免小群误触发 |
| `interval` | `1.5` | 踢人间隔秒数，防风控 |
| `reject_add` | `false` | 踢出同时拉黑，禁止再次加群 |
| `warn_in_group` | `true` | 观察期在群内 @ 提醒（每轮最多 @ 10 人） |
| `warn_template` | 见下 | 提醒话术，支持 `{hours}` `{rounds}` `{keywords}` |
| `notify_ok` | `false` | 无事也推送通知 |
| `timeout` | `20` | 单次 HTTP 超时秒数 |
| `cron` | `0 */6 * * *` | 巡检周期 |

默认话术：`请在 {hours} 小时内把群名片改成含「{keywords}」的格式，否则将被移出本群。`

观察期记录存在 `$persistentStore`（QX 为 `$prefs`），key 为 `qgg_pending_<群号>`。

---

## 二、Linux 服务用法（推荐长期运行）

### 一键安装

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/onshine/ScriptHubs/main/qq-group-guard/install.sh)"
```

不带参数运行会进入**管理菜单**；也可以直接用子命令：

```bash
./install.sh install          # 安装 + 配置向导 + 装 systemd timer
./install.sh install --quiet   # 只装程序，沿用已有配置（升级/自动化场景）
./install.sh test              # ⭐ report 模式试跑一次，绝不踢人
./install.sh run               # 立即按配置的 mode 执行一次
./install.sh mode lenient      # 切换 report / lenient / strict
./install.sh timer "0 */12 * * *"  # 改定时周期
./install.sh status            # 状态总览：模式、参数、下次运行时间
./install.sh logs 100          # 看最近 100 行日志
./install.sh pending           # 查看观察期名单（谁被盯上了、第几轮、过了多久）
./install.sh pending clear     # 清空观察记录，所有人重新从第 1 轮计时
./install.sh update            # 升级脚本本体，保留配置与观察数据
./install.sh uninstall         # 卸载（默认保留配置和数据）
```

> 💡 **为什么推荐 `sh -c "$(curl ...)"` 而不是 `curl ... | sh`？**
> 管道写法下 stdin 是脚本内容而不是你的键盘，菜单里的 `read` 会立刻读到 EOF，表现为「菜单一闪而过、按数字没反应」。
> R1.0.1 起脚本已能自动处理管道场景（落盘重跑并把 stdin 接回 `/dev/tty`），所以 `curl ... | sh` 也可以正常交互了；
> 若所在环境确实没有可用终端（部分容器 / CI），脚本会给出提示，此时请用免交互子命令：
> ```bash
> curl -fsSL .../install.sh | sh -s -- status
> curl -fsSL .../install.sh | sh -s -- install --quiet
> ```

### 安装后的文件布局

| 路径 | 内容 |
|---|---|
| `/opt/qq-group-guard/qq-group-guard.py` | 脚本本体 |
| `/usr/local/bin/qq-group-guard` | 软链接，可直接命令行调用 |
| `/etc/qq-group-guard/config.json` | 配置（含 token，权限 **600**） |
| `/var/lib/qq-group-guard/pending_<群号>.json` | 观察期记录 |
| `/var/lib/qq-group-guard/last_result.json` | 最近一次执行结果 |
| `/var/log/qq-group-guard/run.log` | 运行日志 |
| `/etc/systemd/system/qq-group-guard.{service,timer}` | 定时任务 |

无 systemd 的系统（如 OpenRC / 容器）自动回退到 crontab。

systemd unit 已加最小权限：`NoNewPrivileges` / `ProtectSystem=strict` / `ProtectHome` / `MemoryMax=128M` / `CPUQuota=30%`。

### 配置文件示例

```json
{
  "api_base": "http://127.0.0.1:5700",
  "token": "your-access-token",
  "group_id": [123456789, 987654321],
  "keywords": ["深圳", "SZ"],
  "mode": "lenient",
  "grace_hours": 48,
  "grace_rounds": 2,
  "new_member_days": 3,
  "veteran_days": 0,
  "whitelist": [10001, 10002],
  "skip_admin": true,
  "skip_title": true,
  "self_qq": 20001,
  "interval": 1.5,
  "max_kick": 5,
  "max_ratio": 30,
  "breaker_min": 5,
  "reject_add": false,
  "warn_in_group": true,
  "warn_template": "请在 {hours} 小时内把群名片改成含「{keywords}」的格式，否则将被移出本群。",
  "timeout": 20,
  "state_dir": "/var/lib/qq-group-guard",
  "log_dir": "/var/log/qq-group-guard"
}
```

### 配置优先级

**命令行参数 > 配置文件 > 环境变量 `QGG_*` > 内置默认值**

配置文件搜索顺序：`$QGG_CONFIG` → `/etc/qq-group-guard/config.json` → `~/.config/qq-group-guard/config.json` → 脚本同目录 `config.json`

环境变量即参数名大写加前缀，如 `QGG_MODE=report`、`QGG_GRACE_HOURS=72`、`QGG_KEYWORDS=深圳,SZ`。

---

## 三、命令行参数

```
qq-group-guard [选项]

  --config PATH           配置文件路径
  -g, --group             群号，逗号分隔
  -k, --keywords          合规关键词，逗号分隔；re: 前缀=正则
  -m, --mode              report | lenient | strict
      --api-base          OneBot HTTP 地址
      --token             access_token
      --grace-hours       观察期小时数
      --grace-rounds      连续命中轮数
      --new-member-days   新人保护天数
      --veteran-days      老成员保护天数，0 关闭
      --whitelist         白名单 QQ 号，逗号分隔
      --self-qq           机器人自身 QQ
  -i, --interval          踢人间隔秒数
      --max-kick          单轮上限，0 不限
      --max-ratio         比例熔断阈值(%)，0 关闭
      --breaker-min       熔断最少人数
      --reject-add        踢出同时拉黑
      --no-warn           观察期不 @ 提醒
      --no-skip-admin     不豁免管理员（危险）
      --timeout           HTTP 超时秒数
      --json PATH         结果写入 JSON 文件
  -y, --yes               跳过人工确认（定时任务必加）
  -V, --version           版本号
```

常用例子：

```bash
# 只看看有哪些人不合规，什么都不做
qq-group-guard -g 123456789 -k 深圳,SZ --mode report

# 宽容模式，给 72 小时改名宽限，连续 3 轮才踢
qq-group-guard -g 123456789 -k 深圳,SZ -m lenient --grace-hours 72 --grace-rounds 3 --yes

# 正则：要求名片形如 "部门-姓名"
qq-group-guard -g 123456789 -k "re:^[^-]+-[^-]+$" --mode report

# 临时清理，一次只踢 3 个，间隔 3 秒
qq-group-guard -g 123456789 -k 深圳 -m strict --max-kick 3 -i 3 --yes
```

> 💡 定时任务里**必须加 `--yes`**。不加时在非交互环境（cron / systemd）脚本会主动拒绝执行，这是防误触的保护。

---

## 四、关键词匹配规则

匹配前会对名片和关键词做同样的归一化处理：

1. NFKC 归一化：全角字符转半角（`ＳＺ` → `SZ`）
2. 转小写（`SZ` / `sz` / `Sz` 等价）
3. 去除空白、零宽字符，以及 `- _ | / \ . , : ; ' " \` ~ ! @ # $ % ^ & * + = ? < > [ ] { } ( ) 【】〔〕《》「」『』· 、。，！？—–` 等装饰符号

所以关键词填 `深圳` 时，下列名片全部判为**合规**：

```
深圳-张三    深圳·李四    【深圳】王五    ＳＺ－赵六（关键词含 SZ 时）
深 圳 - 钱七    sz_孙八（关键词含 SZ 时）
```

判为**不合规**的：名片为空、或归一化后不含任何关键词。

**正则模式**：关键词以 `re:` 开头时，后面部分作为正则（大小写不敏感）直接匹配**原始名片**（不做归一化）。正则写错不会崩，只是该条被忽略。

---

## 五、OneBot 端准备

以 go-cqhttp 为例，`config.yml` 需启用 HTTP 服务：

```yaml
servers:
  - http:
      address: 127.0.0.1:5700
      middlewares:
        access-token: your-access-token
```

NapCat / Lagrange 在 WebUI 里开启「HTTP 服务器」并记下端口和 token 即可。

脚本用到的 API：

| API | 用途 | 权限要求 |
|---|---|---|
| `get_group_member_list` | 拉取成员列表 | 机器人在群内 |
| `send_group_msg` | 观察期 @ 提醒 | 机器人未被禁言 |
| `set_group_kick` | 踢出成员 | **机器人必须是管理员** |

---

## 六、FAQ

**Q：第一次用怎么最稳妥？**
1. `mode` 设 `report` 装上，跑 2~3 天
2. 看日志里「不合规」名单，确认没有你不想踢的人；有的话加进 `whitelist` 或调整 `keywords`
3. 切 `lenient`，`grace_hours` 给足（48~72h），`max_kick` 先设 2~3
4. 观察一周没问题再放宽

**Q：熔断触发了怎么办？**
说明不合规占比异常高，99% 是 `keywords` 配错了（比如群规是「城市-姓名」你只填了自己那个城市）。检查关键词，或用 `report` 模式确认后再调 `max_ratio` / `breaker_min`。

**Q：为什么明明够 2 轮了还不踢？**
`grace_rounds` 和 `grace_hours` 是**同时满足**才踢。如果 cron 是每 6 小时一次、`grace_hours=48`，那至少要 8 轮之后才可能到期。想快点可以调小 `grace_hours`。

**Q：观察期记录存哪？想重置怎么办？**
- Linux：`/var/lib/qq-group-guard/pending_<群号>.json`，`./install.sh pending clear` 清空
- Loon/QX：持久化存储 key `qgg_pending_<群号>`，删除插件重装即清空

**Q：改名了会自动从观察名单移除吗？**
会。每轮都是重新拉取实时成员列表判定，改名合规后就不会再进入名单，其观察记录也随之丢弃。

**Q：踢人报「权限不足」？**
机器人不是群管理员，或目标是群主/管理员。前者去群里给机器人升管理，后者本来就该被 `skip_admin` 豁免。

**Q：会不会被腾讯风控？**
批量踢人本身有风险。默认参数（单轮 5 人、间隔 1.5s、每 6 小时一次）已经比较保守。群大人多建议 `max_kick` 调到 2~3、`interval` 调到 3~5 秒、cron 放宽到 `0 */12 * * *`。

**Q：能只提醒不踢人吗？**
可以。`mode` 设 `lenient`，`grace_rounds` 设一个很大的数（如 9999），这样永远到不了踢人条件，但每轮都会 @ 提醒改名。

---

## 版本记录

### R1.0.1
- 修复 `curl ... | sh` 管道运行时**菜单无法交互**的问题（stdin 被脚本内容占用，`read` 立即拿到 EOF）：
  - 新增管道自举：检测到 `$0` 不是真实文件时，自动把脚本落盘重跑，并用 `< /dev/tty` 把标准输入接回终端
  - 新增 `readtty()` 统一交互读取，stdin 非终端时改从 `/dev/tty` 读
  - 新增 `has_tty()` 实际尝试打开 `/dev/tty` 来判断（`[ -e /dev/tty ]` 在部分环境存在但打不开，不可靠）
  - 确实没有终端时（部分容器/CI）给出清晰指引，并支持 `sh -s -- <子命令>` 免交互用法
  - 菜单读到空输入时优雅退出，不再空转
- 自举临时脚本加 `trap` 清理兜底，中断/异常退出也不残留 `/tmp` 文件
- 自举场景下提示文案不再显示 `/tmp` 临时路径，改为展示固定的一键命令
- README 安装命令改为推荐 `sh -c "$(curl -fsSL ...)"`

### R1.0.0
- 首发。基于原始 `group_kick.py` 重写：
  - 自包含，不再依赖外部的 `group_member_check.py`，检查与踢人一体
  - 新增 **宽容模式**：观察期 / 连续多轮确认 / 群内 @ 提醒 / 单轮上限 / 比例熔断 / 五重豁免
  - 新增 **模糊匹配**：NFKC 归一化 + 去大小写 + 去符号，支持 `re:` 正则
  - 新增 **report 模式**，只报告不动手
  - 新增 Loon / Quantumult X / Surge 插件版，22 项参数全部可视化配置
  - 新增一键安装脚本：配置向导、systemd timer（含 crontab 回退）、状态/日志/观察名单管理
  - 关键词为空时**拒绝运行**；非交互环境未加 `--yes` **拒绝执行**
  - 踢人失败者保留在观察表，下轮自动重试，不再静默丢失

---

⚠️ 踢人操作**不可撤销**。请务必先用 `report` 模式验证名单，并善用 `whitelist`。仅供学习交流，请遵守腾讯相关规定。
