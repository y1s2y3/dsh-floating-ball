# dsh-floating-ball · 工作区开发副本

这是桌面端「会话悬浮球 + 会话面板」插件的**源码工作目录**（不是 npm 包的上游仓库，上游只发布编译产物）。

原来它的全部实体只存在于 DSH Desktop 的 profile 里：

```
C:\Users\13065\.dsh\profiles\desktop\node_modules\dsh-floating-ball
```

那一份会被插件更新 / `pnpm install` 覆盖，且没有版本管理。现在以本目录为准：
**改这里 → 跑一次 `deploy.cmd` → 球原地换成新外观**。

---

## 一、它现在从哪来

| 事实 | 说明 |
|---|---|
| 上游包 | `dsh-floating-ball@0.10.0`（npm，2026-11-03 发布；本机 2026-11-18 从 0.9.0 升上来） |
| 导入方式 | npm tarball 解包导入（0.9.0 与 0.10.0 都是），7 个文件与包内 sha256 逐一相同，提交见 `git log` |
| 本机改动 | 两轮**只在 `resources/ball.ps1`** 的视觉改动（2026-11-03 精致化、2026-11-05 DeepSeek 鲸鱼图标）；升 0.10.0 时已重套，明细见 [docs/LOCAL-CHANGES.md](docs/LOCAL-CHANGES.md) |
| 不能做的事 | 上游没有 `src/*.ts` 与 `test/`，所以**不能 `npm run build`**，也没有它 README 里写的那些测试；`lib/session-ball.js` 是打包后的可读 JS，直接改它即可 |

---

## 二、目录里有什么

| 路径 | 用途 |
|---|---|
| `lib/session-ball.js` | **宿主侧逻辑**：状态口径、事件订阅、条目组装、球进程生命周期（109 KB） |
| `resources/ball.ps1` | **球的全部外观与交互**：WPF 窗口、球、面板、条目、卡片（纯 ASCII，必须保持） |
| `cordis.patch.yml` | 包自带的默认配置层（一般不改；个人参数在 profile 的 patch 里） |
| `package.json` / `icon.svg` / `LICENSE` / `README.md` | 上游包文件，原样保留（`README.md` 是上游的完整使用说明） |
| `docs/LOCAL-CHANGES.md` | 本机两轮改动的逐条说明，升级新版时照它重做 |
| `docs/local-patch-20261105-deepseek-icon.txt` | 当时 DeepSeek 图标改动的原始记录 |
| `deploy.mjs` / `deploy.cmd` | 同步到 profile 的脚本（见下一节） |
| `tools/restart-ball.ps1` | 结束球进程的小工具：宿主 2 秒内会用当前 `ball.ps1` 重新拉起它（deploy 自动调用） |
| `backups/` | 每次 deploy 自动备份的 profile 旧版本（不进仓库） |

---

## 三、改哪里、多久生效

| 想改的东西 | 改哪个文件 | 怎么生效 |
|---|---|---|
| 球的颜色、大小、面板圆角、按钮、字体、图标、条目排版 | `resources/ball.ps1` | 跑 `deploy.cmd`；宿主几秒内重启球进程，**不必重启 DSH Desktop** |
| 面板/球的**配色**（跟随 DSH 深/浅主题） | `resources/ball.ps1` 里的 `$script:ThemeMapDark` / `$script:ThemeMapLight` | 同上；想手动固定主题就在球的运行目录放 `theme.json`（`{"theme":"light"}` 或 `{"theme":"dark"}`），3 秒内球会自己重启换色 |
| 状态怎么算、哪些会话进面板、条目里有什么、输入框锁、出错「知道了」的口径 | `lib/session-ball.js` | 跑 `deploy.cmd` 后**必须完全退出并重启 DSH Desktop**（宿主有 ESM 缓存，热重载不换模块） |
| 球直径、不透明度、面板宽高、有提问时是否自动摊开 | profile 的 `cordis.patch.yml` 里 `session-ball` 块 | 改完等宿主热重载（或重启 Desktop） |

- `resources/ball.ps1` **必须保持纯 ASCII**：Windows PowerShell 5.1 在文件没有 BOM 时按 ANSI 解码 `.ps1`，
  中文会乱码。球上的每一句中文文案都是宿主在 `state-<n>.json` 里送进来的，不是写死在脚本里。
- 改了 `resources/ball.ps1` 之后不要用记事本另存为 ANSI/UTF-8-BOM，否则中文与换行都会出问题；
  本仓库 `.gitattributes` 已把换行统一成 LF（LF 的 `.ps1` 在 PowerShell 里可直接运行）。

---

## 四、怎么同步到 DSH（deploy）

在资源管理器里双击 `deploy.cmd`，或在终端里：

```powershell
cd C:\Users\13065\Desktop\plugin\dsh-floating-ball
node deploy.mjs --dry-run        # ① 先看要同步哪些文件（不写盘）
node deploy.mjs                  # ② 真正同步（备份 → 复制 → 校验登记 → 重启球）
node deploy.mjs --restart-only   # ③ 什么都没改、只想让球重启一遍
node deploy.mjs --no-restart     # ④ 只复制，不动球
```

它做的事：

1. 逐文件 sha256 比对，只列出真正变了的文件；
2. 把 profile 里的旧版本整份备份到 `backups/<时间戳>/dsh-floating-ball/`；
3. 复制 `package.json / cordis.patch.yml / README.md / LICENSE / icon.svg / lib / resources`；
4. 确认 profile 的 `dependencies` 与 `dsh.profile.bundles` 里有这个包（只补缺失，不改已有版本号）；
5. `resources/ball.ps1` 有变化时，用 `tools/restart-ball.ps1` 结束球进程 —— 宿主每一拍都在盯这个子进程，
   它一消失就（约 2 秒内）用**当前**的 `ball.ps1` 重新拉起，**不需要重启 DSH Desktop**；
   拉起后再核对运行目录里出现的 `<sha1-12>-ball.ps1` 名字，确认跑的就是这次部署的内容。

**部署前预检**：`deploy.mjs` 会先检查 `resources/ball.ps1` —— 必须纯 ASCII、XAML 注释里不能出现
`--`（也不能以 `-` 结尾）；不通过就直接退出、一个文件都不复制（这两个错误都曾让球启动即退出）。

**权限提醒**：它要写 `C:\Users\13065\.dsh\...`、还要结束球进程。DSH 会话里的沙箱默认是 workspace-write，
这两件事都做不了，需要危险全权限；最省事的是直接双击 `deploy.cmd`（在沙箱之外运行）。

**如果哪天从 `backups/` 恢复了 profile 里那份**，第一次 deploy 会看到 `resources/ball.ps1` 显示「修改」——
那是换行符从 CRLF 统一成 LF，内容一致。同步过一次之后就是「逐文件 sha256 一致」，再跑会提示没有需要同步的内容。

**注意**：以后再跑 `pnpm install` / 插件更新，profile 里那份会被覆盖回上游版本 —— 重跑一次 `deploy.mjs` 即可恢复。

**版本号为什么还是 0.9.0**：2026-11-18 升到 0.10.0 时，deploy 只覆盖了 profile 里的文件，没改 dependencies（也就能不动 pnpm-lock.yaml，避免插件管理器把依赖判成需要重装）。所以 profile 的 package.json 仍写着 dsh-floating-ball: 0.9.0，deploy 每次都会提示这条不一致 —— 这是有意的。真要「正式换版本」就走 GUI 的插件更新，更新完再跑一次 deploy.mjs 把本机视觉改动盖回去。

---

## 五、回滚与对照

```powershell
git log --oneline                                    # 导入 0.9.0 / 本机改动 / deploy 修复 / 升 0.10.0 两个提交
git diff be03c78..HEAD -- resources/ball.ps1         # 相对上游 0.9.0 的全部球脚本差异
git diff 5d6eedc..HEAD -- resources/ball.ps1          # 升到 0.10.0 带来的变化（只该有上游那 25 行）
git diff                                             # 今天又改了什么

# 只回滚球脚本到上游版本（再 deploy 一次让它生效）
git show be03c78:resources/ball.ps1 > resources/ball.ps1
node deploy.mjs
```

profile 侧的回滚：把 `backups/<时间戳>/dsh-floating-ball/` 整份复制回
`C:\Users\13065\.dsh\profiles\desktop\node_modules\dsh-floating-ball\`，再 `node deploy.mjs --restart-only`。

---

## 六、调试与已知边界

- 球是独立的 `powershell.exe -STA` + WPF 窗口（不是网页元素），所以能浮在所有窗口之上；只支持 Windows。
- 运行目录：`C:\Users\13065\AppData\Local\dsh-session-ball\default\`
  - `state-<n>.json`：宿主每 120 ms 落一份完整视图状态（球读取序号最大的那份）；`v` 是状态文档版本（当前 8）；
  - `ball.log`：宿主与球都往里写日志，排查「球没出来 / 颜色不对」先看它；
  - 放一个空的 `debug.flag` 进去，**下次球启动**时打开交互追踪。
- 球进程在 DSH 会话里通常看不到也杀不掉（沙箱限制）；要手动重启球，用 `node deploy.mjs --restart-only`
  （它按窗口类名找到那个 `powershell.exe` 再结束它，宿主会把球重新拉起来），或重启 DSH Desktop。
  判断球有没有重启成功：`%LOCALAPPDATA%\dsh-session-ball\default\ball.log` 末尾应出现新的
  `ball started … script=…\<sha1-12>-ball.ps1`，且这个文件名等于当前 `resources/ball.ps1` 内容的 sha1 前 12 位。
- 升级上游（如以后的 0.11）会覆盖本机的两轮视觉改动，重做步骤与 0.10.0 这次的核对方法见
  `docs/LOCAL-CHANGES.md` 的「升级到更新的版本」一节。

## 2026-11-20：改名为 dsh-floating-ball（0.11.0）

- 包名 / 仓库名 / profile 里的插件名：`dsh-session-ball-plugin` -> `dsh-floating-ball`；版本 0.10.0 -> 0.11.0。
- 三个「非官方」标注位置：① 图标保持干净（不加字）；② `package.json` 的 description / `meta.title` / `meta.description` 与 README 首屏写明「非官方 · 社区自制，与 DeepSeek 官方无关」；③ 公众号封面右下角/顶部放「非官方 · 社区插件」小标签（`assets/cover-wechat-900x383.png`）。
- 图标与素材在 `assets/`：`icon.svg`（源）、`icon-1024/512/256/128/64/48/32/16.png`、`preview-sizes.png`、`cover-wechat-900x383.png`；`tools/render-icon.ps1` 与 `tools/make-cover.py` 可原样重出。
- 图标是蓝渐变球 + **原创鲸鱼轮廓**（头身比例、尾鳍角度、水花都重新画，不是 DeepSeek 商标图形）+ 右上三颗上浮小气泡；`tools/render-icon.ps1` 从 0..100 的本地坐标渲染，`icon.svg` 同源。

**Profile 侧改名需要单独一步 + 重启 Desktop**（包名同时写在 profile 的 dependencies / bundles / loader row 里，运行中改会让宿主把新旧两个包各加载一次 = 两个球）：

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\migrate-profile.ps1 -WhatIf   # 先看要做什么
powershell -NoProfile -ExecutionPolicy Bypass -File tools\migrate-profile.ps1           # 执行，然后重启 DSH Desktop
```

迁移脚本会把 `node_modules\dsh-session-ball-plugin` 改名为 `dsh-floating-ball`、改 profile 的依赖/清单与 loader row 的 name，并把两个文件各留一份 `.bak-<时间戳>`。

**迁移分两步**：① `migrate-profile.ps1` 改文件；② 正在运行的旧插件实例还会从旧路径读球脚本，所以迁移后会留一份旧名兼容副本让球继续活着 —— **下次重启 DSH Desktop** 后宿主才会真正加载 `dsh-floating-ball`，这时再跑 `tools\finish-migration.ps1` 删掉旧名副本（先 `-WhatIf` 看要删什么）。

**屏幕上的球也换成了应用图标那只原创鲸鱼**：`resources/ball.ps1` 的 `BallMark` 不再是 DeepSeek 图标路径，而是 `assets/icon.svg` 同源的原创鲸鱼（身体/胸鳍/背鳍 + 蓝色眼睛/嘴线/腹线，Viewbox 包住，`Apply-Shape` 按 `ballSize * 0.56` 缩放），桌面球与图标、封面是同一只鲸鱼。
