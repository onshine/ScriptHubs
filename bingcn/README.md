# Bing CN 多榜单自动搜索（Loon）

每天后台自动从 **百度 / 头条 / 微博 / 抖音** 热榜及**天气**接口汇总关键词，跨榜单规范化去重后，严格使用 **`https://cn.bing.com`** 搜索 22 次，每次间隔随机 **20～40 秒**，用于完成 Microsoft Rewards 每日搜索积分。

## 文件

| 文件 | 说明 |
|---|---|
| `bingcn-v5.js` | 主搜索脚本（后台 cron 执行，多榜单去重） |
| `Bing_CN_V6.plugin` | 完整 Loon 插件（含 Cookie 抓取 + 定时 + 参数） |

## 功能

- 严格使用 `cn.bing.com` 搜索域名；
- 热词来自百度、头条、微博、抖音热榜及天气接口，跨榜单严格去重；
- 22 次搜索，间隔随机 20～40 秒；
- 每次生成随机 `form`、`cvid`；
- 保存当天进度，中断后可续跑；
- Cookie 失效 / 登录失效时有日志提示；
- Loon 插件参数化 AppKey 与每日执行时间。

## Loon 插件安装

在 Loon 中进入 `配置 → 插件 → +`，添加插件地址（建议先用 gist 托管版本）：

```text
https://gist.githubusercontent.com/onshine/01599ff84998e2d865d16e55484c9dcd/raw/bingcn-V6.plugin
```

或使用本仓库 raw 地址：

```text
https://raw.githubusercontent.com/onshine/ScriptHubs/master/bingcn/Bing_CN_V6.plugin
```

### 插件说明（参数）

```ini
[Argument]
appkey = input,"",tag=故梦呀 AppKey,desc=填写 api.gmya.net 的 AppKey；留空也会尝试公共接口
cron = input,"0 10 5 * * *",tag=每日执行时间,desc=cron 表达式，默认每天 05:10 自动搜索
```

- `appkey`：api.gmya.net 的 AppKey，留空走公共接口；
- `cron`：每日执行时间，可自定义，默认 `0 10 5 * * *`（05:10）。

### 首次使用（抓 Cookie）

1. 开启插件、MITM、证书信任；
2. 使用已登录微软 Rewards 的浏览器打开：

   ```text
   https://cn.bing.com/search?q=Cookie测试
   ```

3. 收到通知 `Cookie 已保存` 后即可手动运行一次 `BingCNUniqueSearch22V6`，第二天起按 cron 自动执行。

## 注意

- 积分是否入账以 Rewards 面板为准；后台搜索只是产生符合条件的搜索请求；
- 搜索词虽有热词与编号组合，但 Bing 对每日搜索积分仍有次数与账号资格等限制；
- 软件均为个人学习测试脚本，请自行承担使用风险。
