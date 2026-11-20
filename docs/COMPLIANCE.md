# 合规自检报告（v1.0.3）

> 检查对象：<https://github.com/y1s2y3/dsh-floating-ball>（v1.0.3，包名 `dsh-floating-ball`）
> 检查日期：2026-11-20
> 自动化：`node tools/check-compliance.mjs`（静态检查，不联网、不启动球）

## 一、结论

| 类别 | 结果 | 说明 |
|---|---|---|
| 商标 / 版权（DeepSeek） | ✅ 通过 | 图标/桌面球/封面是**原创鲸鱼轮廓**，不含 DeepSeek 商标图形；「非官方」声明在 README 3 处、Release 首行、package description |
| 上游 MIT 许可 | ✅ 通过 | `LICENSE` 保留 `Copyright (c) 2026 EvilOfRed`，并追加 `Copyright (c) 2026 y1s2y3`；README「来源与许可」说明基于上游改名 + 修改；原版代码逐字备份在 `legacy/` 且 README 标注 MIT |
| 包元数据 | ✅ 通过 | `name=dsh-floating-ball`、`version=1.0.3`、`license=MIT`、`author`（上游 + 衍生）、`repository`/`homepage`/`bugs` 指向 GitHub；无 runtime 依赖 |
| 隐私 / 敏感信息 | ✅ 通过 | 无 token/密钥/私钥；无本机绝对路径；**日志不再记录消息正文**（只记长度）；README 新增「隐私与数据」段 |
| 第三方素材 | ✅ 通过 | 图标为自绘 SVG；字体 `DshUiSans`（Inter 衍生，按 OFL 改名）+ Noto Sans SC 子集，均随包分发 `OFL.txt` 与 `FONT-NOTICE.txt` |
| 依赖安全 | ✅ 通过 | runtime 依赖为空；仅 peer `@deepseek-ai/cordis` + 构建/测试用 devDependencies |
| 安装与权限说明 | ✅ 通过 | README 写明 Windows 专用、需要桌面窗口权限、输入框聚焦时短暂抢占键盘的取舍 |
| 发布信息 | ✅ 通过 | GitHub tag/release `v1.0.3` 与包版本一致；安装命令 `github:y1s2y3/dsh-floating-ball`；npm 尚未发布（见待办） |

## 二、检查项与证据

### 1. 商标与图形

① `node tools/check-brand.mjs` → `[PASS]`，鲸鱼路径指纹 `947598534486d9ee`；`assets/icon.svg`、`resources/ball.ps1`、`tools/render-icon.ps1` 三处路径逐字符一致。
② 仓库不包含 DeepSeek 官方鲸鱼路径；历史文档里的提及只作记录、不含图形数据。
③ 包名 / README 标题均为功能性描述，不冒充官方。

### 2. 上游 MIT 许可与归属

① `LICENSE`：

```
MIT License
Copyright (c) 2026 EvilOfRed (original dsh-session-ball-plugin)
Copyright (c) 2026 y1s2y3 (dsh-floating-ball rewrite)
```

② README「来源与许可」段指向 npm 上游包并说明改名 + 本地修改。
③ `legacy/dsh-session-ball-plugin-original/` 保留原版宿主与球脚本逐字副本，README 标注按 MIT 分发。
④ `docs/LOCAL-CHANGES.md` 记录历次本地修改，可追溯。

### 3. 元数据

`package.json` 关键字段：`name=dsh-floating-ball`、`version=1.0.3`、`license=MIT`、`author=EvilOfRed (original dsh-session-ball-plugin) / y1s2y3 (dsh-floating-ball)`、`contributors=[y1s2y3]`、`repository/homepage/bugs` 指向 `github.com/y1s2y3/dsh-floating-ball`；`dependencies` 为空，`peerDependencies` 仅 `@deepseek-ai/cordis`。

### 4. 隐私与敏感信息

① `tools/check-compliance.mjs` 扫描 70+ 个仓库文件：无 `ghp_`/`gho_`/`github_pat_`/`sk-`/`AKIA`/私钥/`C:\Users\<用户>` 命中（COMPLIANCE.md 自身因记录扫描模式而列入例外）。
② **本轮修复**：宿主日志原先会把球上发出的**消息正文**写进 `ball.log`（`prompt sent (…): <正文>`）。已改为只写字符数（`prompt sent (…): 12 chars`）并加注释说明，日志不再留用户内容。
③ `.gitignore` 排除 `backups/`、`_work/`、`*.log`、`.publish-files.txt`、`*.bak-*`、`_tmp/`。
④ README 新增「隐私与数据」段：不联网、无遥测、不上传；仅在 `%LOCALAPPDATA%` 下写临时 state（宿主保留最近 60 份）与本机日志；会话正文不进球。

### 5. 第三方素材

① 图标为自绘路径（`tools/render-icon.ps1` 可复现）。
② `assets/fonts/`：`DshUiSans-*`（Inter 衍生，按 OFL 要求改名）与 `NotoSansSC-*-subset`，附 `OFL.txt`（SIL OFL 1.1 全文）与 `FONT-NOTICE.txt`（来源、修改说明、保留字体名声明）。
③ 无外部图片/音视频素材。

### 6. 依赖与构建

runtime 依赖为空（纯 host 插件）；peer 仅官方 cordis；devDependencies 为构建/测试用（tsdown、typescript、官方 schemastery/cordis）。

### 7. 用户告知义务

① README 首屏 3 处「非官方」声明 + 来源与许可段；② Release 首行为「非官方 · 社区自制」；③ 已知限制（Windows 专用、球出现在桌面自动化截图中、输入框聚焦时短暂抢占键盘）；④ 隐私与数据段。

## 三、剩余事项（非阻塞）

① **npm 发布**：尚未发布到 npm；要支持 `dsh plugin add dsh-floating-ball` 短命令需发 npm 包（发布前确认包名可用、2FA/scope）。
② **GitHub 仓库名**：仍为 `dsh-floating-ball`，与包名一致 ✅（改名记录见 `docs/PRODUCTION.md`）。
③ **公众号推文**：如使用真实会话截图，发布前需遮挡项目名/人名；当前素材为示意图与图标，风险低。
④ **商标复审**：保留 `docs/BRAND.md`（设计说明 + 路径指纹）作为原创证据。

## 四、复跑方式

```powershell
cd dsh-floating-ball
node tools/check-compliance.mjs   # 全绿 = 退出码 0
node tools/check-brand.mjs
node test/host-v2.mjs && node test/dispatch.mjs
```
