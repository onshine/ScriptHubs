# ScriptHubs 更新铁律

**每次 push 前，先读一遍本文件。**

## 铁律（禁止违反）

### 1. 所有文档/脚本一律不准删除
- 只能新增、修改、移动；**禁止 `git rm`、禁止清空文件代替删除**、禁止在 rebase/merge 时用"以本地为准"抹掉远端已有文件
- push 前必查：`git status` 里**不允许出现非本次任务的 deletions**；发现 `D xxx` 且不是你这次要处理的文件，立即停下恢复
- 历史默认保留，弃用请改名加 `_deprecated` 后缀而不是删

### 2. 版本号必须内外一致
- 脚本**头部注释**里的版本号，必须与代码里 `SCRIPT_VERSION` 常量、README 里的版本**完全一致**
- 改任何逻辑都要同时改：① `SCRIPT_VERSION` ② 头部"版本/更新"行 ③ 目录 README 版本记录
- 禁止出现"内部已升 R12.3，头部还写 R12.0"这种脱节

### 3. 新增脚本后必须同步根目录 README
- 加新脚本目录后，立即在根 `README.md` 的脚本列表加一行
- 不允许"仓库有了新脚本但 README 没提"的状态
- 删脚本（如果将来真有此情况）也必须同步删 README 行——默认禁止删

### 4. 每个脚本目录必须包含以下 4 类文件
```
<script>/
  ├── <name>.js / <name>-vN.js       # 脚本本体
  ├── <Name>.plugin                  # Loon 插件（带 argument/cron 参数）
  └── README.md                      # 使用说明（安装/配置/FAQ）
```
缺任何一个都不算完整提交。

## Push 前自查清单

- [ ] `git status` 无意外删除（deletions 只能是本次主动处理的文件）
- [ ] 改动脚本的头部注释版本号 = `SCRIPT_VERSION` = README 版本
- [ ] 若新增脚本目录，根 README 已加对应行
- [ ] 每个脚本目录齐 js/plugin/README 三件套
- [ ] `node --check <脚本>` 通过
- [ ] push 后 `git ls-tree -r origin/main --name-only` 与预期一致
