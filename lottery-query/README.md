# 五种彩票近15期查询

分段查询 **双色球、大乐透、福彩3D、排列三、七乐彩** 的最近 15 期开奖号码与今日开奖号码，支持 Loon / Quantumult X / Surge 定时脚本。

## 文件

| 文件 | 说明 | Raw 地址 |
|---|---|---|
| `lottery-query.js` | 彩票查询主脚本 | https://raw.githubusercontent.com/onshine/ScriptHubs/main/lottery-query/lottery-query.js |
| `Lottery_Query.plugin` | Loon 插件配置 | https://raw.githubusercontent.com/onshine/ScriptHubs/main/lottery-query/Lottery_Query.plugin |
| `README.md` | 使用说明 | https://github.com/onshine/ScriptHubs/tree/main/lottery-query |

## 输出格式

脚本按彩种分段输出 5 段独立通知：

1. 双色球
2. 大乐透
3. 福彩3D
4. 排列三
5. 七乐彩

每段包含：

- 最近 15 期：期号、日期、开奖号码、和值（3D/排列三）
- 今日开奖号码：若接口未更新会显示“今日未开奖（或开奖数据暂未更新）”

> 15 期正文较长，不同代理工具可能有通知折叠或截断；完整内容始终会写入脚本日志。

## Loon 插件安装

Loon → 配置 → 插件 → 右上角 `+`，添加：

```text
https://raw.githubusercontent.com/onshine/ScriptHubs/main/lottery-query/Lottery_Query.plugin
```

默认每天 **21:30** 执行。

## Loon 手写配置

```ini
cron "30 21 * * *" script-path=https://raw.githubusercontent.com/onshine/ScriptHubs/main/lottery-query/lottery-query.js, timeout=300, tag=彩票查询
```

## Quantumult X

```ini
[task_local]
30 21 * * * https://raw.githubusercontent.com/onshine/ScriptHubs/main/lottery-query/lottery-query.js, tag=彩票查询, enabled=true
```

## Surge

```ini
[Script]
彩票查询 = type=cron, cronexp="30 21 * * *", script-path=https://raw.githubusercontent.com/onshine/ScriptHubs/main/lottery-query/lottery-query.js, timeout=300
```

## 数据源

- 中国福彩网：双色球、福彩3D、七乐彩
- 中国体彩网：大乐透、排列三

福彩接口包含新版 HTTPS 入口、HTTP 入口及旧版兼容入口，遇到风控或接口改版时会自动切换。体彩接口使用官方历史开奖分页接口。

## 注意

- 奖号数据以官方彩票官网最终公告为准。
- 定时脚本执行时如果接口暂时未返回数据，脚本仅记录失败，不影响其他彩种查询。
- 仅供学习交流。