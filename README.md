# ScriptHubs

Loon / Quantumult X / Surge 签到与定时脚本合集。

## 脚本

- [linlee](linlee/) — 林里柠檬茶每日签到 + 10点鸭币兑换。R11 免维护版，token 临期自动续期。
- [bingcn](bingcn/) — 必应中国多源唯一搜索 V6，Loon/Quantumult X 定时脚本 + 插件。
- [lottery-query](lottery-query/) — 多彩票开奖查询。
- [gemini-web2api](gemini-web2api/) — Gemini 网页端反代 OpenAI API 的小鸡部署套件。R1.8.1，gw.sh 菜单式一键管理（主控/出口/代理池/体检），含健康巡检插件。
- [qq-group-guard](qq-group-guard/) — QQ 群名片守卫。R1.0.4，OneBot v11 定时巡检群名片，宽容模式（观察期 + @提醒 + 多轮确认 + 比例熔断）分级踢人，含 Loon 插件与一键安装脚本。
- [9nb-checkin](9nb-checkin/) — 9NB.DE 多账号自动登录签到。默认每天 08:00，账号去重、账号间随机等待 0～5 分钟，显示签到奖励和积分余额。
- [agentrouter](agentrouter/) — AgentRouter 多账号每日签到，保留原登录、余额和签到确认逻辑，新增账号间随机等待 0～5 分钟。**两版按命名区分、二选一**：`AgentRouter_Checkin_ScriptHubs.plugin`＝本仓库本地脚本（账号填插件设置）；`AgentRouter_Checkin_Upstream.plugin`＝引用上游 `MaYIHEI/paperclip` 脚本（账号走 BoxJS）。
- [workbuddy2api-manager](workbuddy2api-manager/) — workbuddy2api 网关 + 管理面板部署套件。**R1.0.5**：修复面板容器内 `WB_UPSTREAM_DIR` 与 Docker daemon 宿主 bind mount 路径错位，避免管理端更新后重建网关时报 OCI `not a directory`；此前已修设置保存原子写权限（R1.0.4）、bridge 共享网络及上游镜像迁移。
- [9router](9router/) — 9Router（40+ 家上游收敛成 OpenAI 兼容端点）部署套件。R1.0.0，`9router.sh` 一键部署/更新/自检，端口只绑回环 + 默认开启 `REQUIRE_API_KEY`，并在首次启动就写死随机 `INITIAL_PASSWORD`（规避反代场景下 `isLocalRequest` 恒假导致的登录 403），含端口链/登录链路/容器出网/暴露面四项自检与密码重置。
- [chelaile](chelaile/) — 车来了去广告（Loon 插件）。R1.0.2，去开屏广告与应用内广告；核心是清洗启动配置 `appToggle/getStatus` 让 App 不拉开屏素材，响应体外壳 `**YGKJ...YGKJ##` 动态保留不写死，首页金刚位按推广特征动态剔除；含 `block_httpdns` 防绕过开关。
- [wetalk](wetalk/) — WeTalk 签到 + 视频奖励的 **Loon 外壳**。R1.0.0，脚本本体引用上游 `CaoXiaoMann/XiaoMan`（不内置）；补上作者没给的 Loon 配置，并把 cron 做成 Argument 可自定义。
- [pingme](pingme/) — PingMe 签到 + 视频奖励的 **Loon 外壳**。R1.0.0，脚本本体引用上游 `fmz200/wool_scripts`（不内置）；把流传版本里写死的 `cron "30 8,20 * * *"` 改成 Argument 可自定义，并补上它引用却没声明的 `PingMe` 开关。
- [sgcc](sgcc/) — 网上国网（国家电网 95598）积分签到的 **Loon 外壳**。R1.0.0，脚本本体引用上游 `MaYIHEI/paperclip`（不内置）；改用**手机号 + 密码自动登录**，**不再需要抓包和 MITM**，首次登录填一次短信验证码即可，凭证 15 天自动续期，能读到签到结果与实际错误码。⚠️ **上游为 `testing` 实验分支，2026-10-15 提交，作者自标「🧪 待验证」，随时可能变更**；需把账号密码存在本机，密码连错 5 次会锁定 30 分钟。另附协议实现实测可通记录（已排除加密/设备令牌层面的问题）。
- [chelaile-checkin](chelaile-checkin/) — 车来了每日签到（Loon 插件）。R1.0.7，`signin` 与 `config` 鉴权不同：签到**必须**带 `secret` + `s`（只带 `udid`+`accountId` 一律 `0002 非法请求`）；`signature`/`nonce`/`h5TimeStamp` 服务端并不校验。`http-request` 钩子自动抓凭证 + cron 签到，按 `signDate` 判断当日是否已签；日志与通知里的凭证一律脱敏。
- [sub-store-deploy](sub-store-deploy/) — 自建 Sub-Store 部署套件。R1.0.0，`sub-store.sh` 一键部署/更新，默认写好前后端同源路径与 CORS 白名单（治「网页端 403 CORS origin not allowed / 列表空白」），含端口链、前端路径、CORS 实测自检。
- [paperclip](paperclip/) — Paperclip 全套签到脚本的 **Loon 外壳**（签到合集 + Cookie 抓取合集）。R1.0.0，脚本本体引用上游 `MaYIHEI/paperclip`（不内置）；每个脚本的签到时间可改、汇总时间可改，修掉上游「小米抽奖」六段 cron 永不触发的问题，MITM 改 `%APPEND%` 不覆盖其它插件，并补上 6 个上游插件没收录的脚本（**特来电引用 gist 原文、一个字未改**、松山棉店、笔笔省、CASETiFY、驴充充、滔搏）。⚠️ 与作者原插件二选一。

## 使用

每个脚本目录内含独立 README，安装配置请看对应说明。

仅供学习交流。
