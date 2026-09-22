# ScriptHubs

Loon / Quantumult X / Surge 签到与定时脚本合集。

## 脚本

- [linlee](linlee/) — 林里柠檬茶每日签到 + 10点鸭币兑换。R11 免维护版，token 临期自动续期。
- [bingcn](bingcn/) — 必应中国多源唯一搜索 V6，Loon/Quantumult X 定时脚本 + 插件。
- [lottery-query](lottery-query/) — 多彩票开奖查询。
- [gemini-web2api](gemini-web2api/) — Gemini 网页端反代 OpenAI API 的小鸡部署套件。R1.8.1，gw.sh 菜单式一键管理（主控/出口/代理池/体检），含健康巡检插件。
- [qq-group-guard](qq-group-guard/) — QQ 群名片守卫。R1.0.4，OneBot v11 定时巡检群名片，宽容模式（观察期 + @提醒 + 多轮确认 + 比例熔断）分级踢人，含 Loon 插件与一键安装脚本。
- [9nb-checkin](9nb-checkin/) — 9NB.DE 多账号自动登录签到。默认每天 08:00，账号去重、账号间随机等待 0～5 分钟，显示签到奖励和积分余额。
- [agentrouter](agentrouter/) — AgentRouter 多账号每日签到，保留原登录、余额和签到确认逻辑，新增账号间随机等待 0～5 分钟。
- [workbuddy2api-manager](workbuddy2api-manager/) — workbuddy2api 网关 + 管理面板部署套件。R1.0.2，`workbuddy2api.sh` 一键部署/更新/自检（旧名 `deploy.sh` 保留为兼容外壳），`NET_MODE=host` 应对 LXC 里 Docker bridge 出网不通，含端口链/登录链路/容器出网三重自检与面板密码重置；已修正网关容器因镜像写死探针端口而永远 `unhealthy` 的问题。
- [9router](9router/) — 9Router（40+ 家上游收敛成 OpenAI 兼容端点）部署套件。R1.0.0，`9router.sh` 一键部署/更新/自检，端口只绑回环 + 默认开启 `REQUIRE_API_KEY`，并在首次启动就写死随机 `INITIAL_PASSWORD`（规避反代场景下 `isLocalRequest` 恒假导致的登录 403），含端口链/登录链路/容器出网/暴露面四项自检与密码重置。
- [sub-store-deploy](sub-store-deploy/) — 自建 Sub-Store 部署套件。R1.0.0，`sub-store.sh` 一键部署/更新，默认写好前后端同源路径与 CORS 白名单（治「网页端 403 CORS origin not allowed / 列表空白」），含端口链、前端路径、CORS 实测自检。

## 使用

每个脚本目录内含独立 README，安装配置请看对应说明。

仅供学习交流。
