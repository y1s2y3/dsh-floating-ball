# 合规自检报告（v0.11.1）

> 检查对象：<https://github.com/y1s2y3/dsh-floating-ball>（本地仓库与远端 `main` 一致）
> 检查日期：2026-11-20

## 一、结论

| 类别 | 结果 | 说明 |
|---|---|---|
| 商标 / 版权（DeepSeek） | ✅ 通过 | 图标、桌面球、封面均为**原创鲸鱼轮廓**，不含 DeepSeek 商标图形；「非官方」标注三处齐全 |
| 上游代码许可（MIT） | ✅ 通过 | 保留原 `LICENSE`（Copyright (c) 2026 EvilOfRed）；README 新增「来源与许可」段，说明基于上游改名修改 |
| 包元数据 | ✅ 已补 | 补 `repository` / `homepage` / `bugs` / `author` / `contributors`；版本 0.11.1 |
| 敏感信息 / 隐私 | ✅ 已修 | 仓库无 token / 密钥 / 真实项目数据；工具脚本里的本机绝对路径改为脚本相对路径，README-DEV 里的本机用户目录已改为 `%USERPROFILE%` |
| 第三方素材 | ✅ 通过 | 图标为自绘路径；封面/预览图改用 SIL OFL 1.1 的 Noto Sans SC 子集（随仓库分发 + 版权声明）；未打包他人图片 |
| 依赖安全 | ✅ 通过 | 无 runtime `dependencies`；仅 peer `@deepseek-ai/cordis` 与 devDependencies（构建/测试用），均为官方或常见包 |
| 安装与权限说明 | ✅ 通过 | README 写明 Windows 专用、需要桌面窗口权限、安装方式；无夸大「官方」「安全」等表述 |
| 发布信息 | ✅ 通过 | Release / README / package.json 均标注非官方；安装命令为 `github:` 形式（npm 尚未发布） |

## 二、检查项与证据

### 1. 商标与图形

① 在 `assets/icon.svg`、`resources/ball.ps1`、`tools/render-icon.ps1` 三处比对鲸鱼路径：**逐字符一致**，且不含 DeepSeek 鲸鱼的路径特征串（旧版路径 `M23.748 4.651…` 已删除）。
② `node tools/check-brand.mjs` 输出 `[PASS]`，路径指纹 `947598534486d9ee`。
③ 全仓库检索 `simple-icons` / `DeepSeek 鲸鱼`：仅 `README-DEV.md` 与 `docs/LOCAL-CHANGES.md` 作为历史记录提及，**不包含图形数据**。
④ 命名：`dsh-session-ball-plugin` 是功能性描述 + 社区命名习惯，未使用 DeepSeek 官方名称作为产品名。

### 2. 上游 MIT 许可

① `LICENSE` 保留原文：`MIT License / Copyright (c) 2026 EvilOfRed`（上游 `dsh-session-ball-plugin` 作者）。
② README「来源与许可」段写明：本仓库是**改名 + 本地修改**版本，并指向 npm 上游包。
③ 修改了哪些地方，`docs/LOCAL-CHANGES.md` 按 ①–⑧ 编号记录（视觉、面板筛选、拖动修复、改名等），可追溯。

### 3. 元数据

`package.json` 补：
```json
"version": "0.11.1",
"author": "EvilOfRed (original dsh-session-ball-plugin author)",
"contributors": ["y1s2y3"],
"repository": { "type": "git", "url": "git+https://github.com/y1s2y3/dsh-floating-ball.git" },
"homepage": "https://github.com/y1s2y3/dsh-floating-ball#readme",
"bugs": { "url": "https://github.com/y1s2y3/dsh-floating-ball/issues" }
```

### 4. 敏感信息

① 检索模式：`gho_` / `ghp_` / `github_pat_` / `sk-` / `AKIA` / 邮箱 / 内网 IP / 本机用户目录 —— 仓库内**无命中**（`assets/manifest.txt` 只有文件哈希）。
② `tools/make-cover.py` 与 `tools/render-icon.ps1` 原来的本机绝对路径改为**脚本相对路径**，clone 到任何机器都能跑。
③ `README-DEV.md` 里的本机用户目录统一改成 `%USERPROFILE%`。
④ `.gitignore` 排除 `backups/`、`*.log`、`.publish-files.txt`、`*.bak-*`，本机备份和发布清单不会进仓库。

### 5. 第三方素材

① 图标为自绘 SVG 路径（`tools/render-icon.ps1` 可复现），不是从图标库复制的图形。
② 封面用 Pillow + 系统字体（Microsoft YaHei / Segoe UI）渲染成交付用 PNG，仓库不包含字体文件。
③ 无外部图片、无第三方音频/视频。

### 6. 依赖与构建

① runtime 依赖为空（纯 host 插件，`lib/session-ball.js` 已构建）。
② peerDependency 只有官方 `@deepseek-ai/cordis`；devDependencies 为 `tsdown`、`typescript`、官方 schemastery/cordis，用于构建与测试。
③ `npm test` 的五个测试不接触桌面（`test/*.mjs` 在 CI/本地均可跑）。

### 7. 用户告知义务

① README 首屏三处非官方声明（标题、blockquote、来源与许可段）。
② Release 说明首行即「非官方 · 社区自制」。
③ 已知限制写明：Windows 专用、球会出现在桌面自动化截图里、输入框聚焦时短暂抢占键盘（配置项可关）。
④ 安装命令明确是 `github:` 形式，并说明 npm 尚未发布。

## 三、仍待处理的「非合规但需留意」项

① **npm 发布未做**：要 `dsh plugin add dsh-session-ball-plugin` 这种短命令，需要把包发到 npm；发布前请确认包名 `dsh-session-ball-plugin` 未被占用，且 npm 账号有 2FA/scope 设置。
② **公众号推文**：推文里的截图如使用真实会话内容，发布前需遮挡项目名/人名（本篇目前只有示意图与图标，无真实截图，风险低）。
③ **商标复审**：目前是「原创鲸鱼 + 悬浮球」，与 DeepSeek 官方鲸鱼图形有明显差异；若后续有人提出异议，保留 `docs/BRAND.md` 里的设计说明与路径指纹可作为原创证据。
④ **字体授权（已解决）**：封面与预览图已改用 **SIL OFL 1.1 的 Noto Sans SC 子集**，字体文件与 OFL 全文随仓库分发（`assets/fonts/`），修改版已按 OFL 要求改名；桌面球 UI 字体来自 Windows 系统（运行时不随包分发）。
