# 本机相对上游的改动清单（当前基线 0.10.0）

提交历史：

| 提交 | 内容 |
|---|---|
| `be03c78` | 上游 `dsh-floating-ball@0.9.0` 原样导入（npm dist，7 个文件 sha256 与包一致） |
| `27dcee5` | 本机两轮视觉改动 + 工作区开发脚本（deploy / 文档 / .gitignore 等） |
| `5d6eedc` | deploy 改为「结束球进程」重启球（reload-trigger 实测无效） |
| `373923e` | 同步上游 0.10.0 的宿主与文档（lib / README / cordis.patch.yml / 版本号） |
| `369c83b` | 把上游 0.10.0 的球脚本改动合进本机视觉版本 |

上游只发布编译产物，`resources/ball.ps1` 是纯 ASCII 的 Windows PowerShell + WPF 脚本，
宿主侧 `lib/session-ball.js` 是 tsdown 打出来的可读 bundle。本机改动**都只在 `resources/ball.ps1`**；
`lib/` 与其余文件始终保持上游原样（可用 `git log` / `git diff` 核对）。

---

## ① 2026-11-03：面板与按钮的视觉精致化

原样用 `git diff be03c78..HEAD -- resources/ball.ps1` 查看全部差异（约 130 行）。要点：

- **字体**：`Window` 加 `FontFamily="Segoe UI, Microsoft YaHei UI"`，中文不再是默认回退字体。
- **圆角图标按钮**：`Window.Resources` 新增 `IconButton`（圆角 9、透明底、悬停 `#1FFFFFFF`、按下 `#33FFFFFF`），
  表头「＋ / −」、条目「知道了 / ×」、卡片选项与发送按钮都套这个样式；表头按钮高度 22→24。
- **细滚动条**：新增 `SlimThumb` + `ScrollBar` 模板（宽 6、透明槽），替掉 WPF 默认粗浅灰滚动条。
- **面板**：圆角 14→16、边框 `#33FFFFFF`→`#2BFFFFFF`、纯色底改成线性渐变（`#F7151922`→`#F70A0C11`）、
  内边距 12,10→14,12；状态点改成「光晕 + 小点」两层（新增 `StatusDotGlow`，不透明度 0.22，16 见方的 Grid 居中放 9 的小点）；
  统计行上方加一条 1px 分隔线（`#14FFFFFF`）。
- **条目与卡片**：圆角 10→12、内边距 10,9→12,11、外边距 8→10；条目底色 `#FF1E222B`→`#FF1D2330`、
  边框 `#FF7C8598`→`#26FFFFFF`、鼠标悬停变 `#FF252C3B`；卡片底色 `#FF1E222B`→`#FF1A1F29`。
- **输入框**：内边距 8,5→10,6、底色 `#FF12151B`→`#FF0E1117`、边框 `#2EFFFFFF`→`#33FFFFFF`；
  发送按钮内边距 12,5→13,6。
- **审批色从红改琥珀**：上游「审批」与「出错」共用红 `#FFE0574B`，这里在渲染层把审批单独染成琥珀 `#FFE0A64B`，
  共三处：XAML 里 `BallBadge.Background`、`Update-EntryView` 里 `state === 'approval'` 时覆盖 `$color`、
  `Build-OneCard` 里 `$kind === 'approval'` 时覆盖 `$accent`。**宿主侧 `lib/session-ball.js` 的颜色口径没动**，
  所以这属于纯渲染层改动，升级宿主不会冲突。

## ② 2026-11-05：DeepSeek 鲸鱼图标

原始说明见 [`local-patch-20261105-deepseek-icon.txt`](local-patch-20261105-deepseek-icon.txt)。三处：

1. 球体 `BallBody` 的径向渐变从「不透明深灰」（`#FF4C586B`→`#FF0D1015`）改成「半透明 DeepSeek 蓝」
   （`#B86E8BFF`→`#993550D8`）。
2. 收起态中间的文字 `TextBlock Name="BallGlyph" Text="DS"` 换成矢量 `Path Name="BallMark"`，
   `Data` 是 24×24 viewBox 的 DeepSeek 鲸鱼 path，`Stretch="Uniform"`、`Fill="#F2FFFFFF"`。
3. `FindName` 处补 `$ballMark`；`Apply-Shape` 里按 `$ballMark.Width = round($ballSize * 0.56)` 等比缩放，
   换任何 `ballSize` 都不变形（当前 `ballSize: 48`，窗口 66×66）。

状态环、光晕、徽标、整个面板都没动。窗口整体不透明度仍由 profile 配置的 `opacity`（当前 0.88）叠乘。

---

## ③ 2026-11-18：升级到 0.10.0（含上游的球环裁切修复）

上游 0.9.0 → 0.10.0 的 `resources/ball.ps1` 只改了 25 行（25+/9-），全部合进来了：

- **`BallRing` 加 `Margin="-1"`**（真正的视觉 bug 修复）：`Apply-Shape` 把环设成 `ballSize + 2`，
  比所在格子大 1px；WPF 会把元素裁到**布局槽**而不是元素自身尺寸、并把溢出锚在槽的左上角，
  于是环的右边和下边各丢 2px，看起来像「被切了一刀」。负 margin 把槽撑到 `ballSize + 2`，环就不再被裁。
  —— 这条与我们的鲸鱼图标/渐变完全兼容，只是多给环一个 margin。
- 抬头与条目上关于「知道了 / ×」的注释同步（0.10.0 起「×」也算确认：收掉条目的同时把它的出错确认掉，
  否则条目没了就没有地方按「知道了」，红会一直挂着）。
- `Apply-Shape` 里环尺寸那段注释同步。

其余文件直接换成 0.10.0：`lib/session-ball.js`（宿主侧新增「× 也确认红」「未确认的出错不会被
面板上限挤掉」「条目回来是重新长出来的一条」）、`README.md`、`cordis.patch.yml`、`package.json`。

**核对方式**（两个方向都对上了才叫合干净）：

```powershell
# 与 0.10.0 上游相比：只应剩下本机视觉改动（约 127+/35-）
git diff 373923e..HEAD -- resources/ball.ps1
# 与升级前（0.9.0 + 本机改动）相比：只应是上游那 25 行（25+/9-）
git diff 5d6eedc..HEAD -- resources/ball.ps1
```

---

## ④ 2026-11-19：面板宽度 / 球大小的自愈（本机修复，不属于上游）

**症状**：面板右侧一截被裁掉 —— 表头「＋ 新会话 / －」不见了、条目上的「知道了 / ×」与「发送」
不见了、条目卡片右边像被切了一刀。实测当时窗口只有 450×280 物理像素（360×224 DIP），而内容按
480 DIP 排版：内容比窗口宽 120 DIP，右边的东西全在窗口外面点不到，连「－」收起按钮都够不着。

**原因**：面板的**宽度**只在 `Apply-Shape`（面板打开的那一瞬间）写到窗口上；打开之后每份状态文档
只走 `Apply-PanelHeight`，它只改高度。于是只要「打开那一刻读到的 `metrics.panelWidth`」和「之后
文档里的值」不一致，面板就会一直开在一个错误的宽度里。实测那一刻读到的是插件默认值 360
（`lib/session-ball.js` 的 `DEFAULTS.panelWidth = 360`），之后文档里是 Profile 配的 480 —— 这种
时序在宿主/插件重挂载后的头几份文档里出现过（同一批文档里 `ballSize` 也一度可能是默认的 64）。

**修复**（`resources/ball.ps1`）：

- `Apply-PanelHeight` 开头比对窗口宽度与当前 `metrics.panelWidth`，不一致就 `Apply-Shape $true`
  重新塑形（重新量高度、右边缘保持不动），并往 `ball.log` 写一行
  `panel width under the open panel: 360 -> 480, re-shaping`；
- 收起态同理：新增 `Sync-BallSize`，折叠球窗口尺寸与当前 `metrics.ballSize + 18` 不一致时重新塑形
  （日志 `ball size under the collapsed ball: ... re-shaping`），治同一类「挂载早期读到默认值」；
- `deploy.mjs` 的重启核对也改成读 `ball.log` 新增的 `ball started … script=<sha1-12>-ball.ps1` 行
  （内容不变时物化文件名不变，原来比对 mtime 会误报「宿主还没拉起」）。

**为什么不是视觉补丁的问题**：本地视觉改动只改了颜色/圆角/内边距，没有动任何尺寸计算；上游 0.10.0
的球脚本也只多了环的 `Margin="-1"`。这个窗口宽度与内容宽度脱节的窗口期本来就存在，只是这次撞上了。

---

## ⑤ 2026-11-19：面板改用 DSH 的设计 token（跟随深/浅主题）

原来面板和球用的是一套自己的蓝灰色（`#1D2330` / `#5B8DEF` 之类），和 DSH 界面放一起像两个产品。
现在整套颜色都来自 DSH 的设计令牌（`dsh-client-ui-theme` 的 `--dsw-alias-*`）：

| 语义 | 深色（body[data-ds-dark-theme]） | 浅色（默认 body） |
|---|---|---|
| 面板/球底色 | `#232324` → `#1B1B1C` 渐变 | `#FFFFFF` → `#F7F8FA` |
| 条目 / 卡片 | `#232324` / `#2C2C2E` | `#FFFFFF` / `#F1F3F5` |
| 输入框 | `#151517` | `#F1F3F5` |
| 描边 | `#ffffff1f`（12% 白） | `#0000001a`（10% 黑） |
| 主文字 / 次级 / 三级 / 说明 | `#F9FAFB` / `#CFD3D6` / `#ADB2B8` / `#81858C` | `#0F1115` / `#61666B` / `#81858C` / `#81858C` |
| 强调（在跑/蓝） | `#7AAAFF`（deepseek-400） | `#4176E6`（deepseek-500） |
| 提问/审批（琥珀） | `#F59E0B`（amber-500） | `#D98629`（amber-600） |
| 出错（红） | `#F25A5A`（red-400） | `#EC1313`（red-600） |
| 空闲灰 | `#81858C` | `#ADB2B8` |
| 滚动条 | `#3C3C3D` / `#545557` | `#E5E5E5` / `#D4D4D4` |

**实现方式（只加了两道翻译，没有把 40 多个色值散落到代码里）**：

1. `resources/ball.ps1` 里每个颜色**仍然写成原来那个字面量**，两张映射表 `$script:ThemeMapDark` /
   `$script:ThemeMapLight` 负责「旧字面量 → DSH token」；
2. **XAML 在解析前**用一次正则整体替换（一次 pass，避免映射值被二次替换：`#2BFFFFFF → #1FFFFFFF`
   而 `#1FFFFFFF` 本身又是 key），所以 `IconButton` / 滚动条这些模板也跟着主题走；
3. **`ConvertTo-ColorBrush` 是运行时唯一的刷子入口**，映射就在这里做 —— 宿主发来的状态色
   （`#FF5B8DEF` / `#FF7C8598` / `#FFE0A64B` / `#FFE0574B`）也顺带换成 DSH 的状态色；
   分隔线与滚动条滑块这两个与普通按钮共用字面量的元素，在替换前先抽成占位符，避免被误映射。

**主题从哪来（顺序）**：

1. 球运行目录下的 `theme.json`：`{"theme":"light"}` 或 `{"theme":"dark"}`（手动固定，最优先）；
2. Profile 的 `ui-theme` 里 `preference` 明确写了 `light` / `dark`；
3. 否则跟 Windows 的应用主题（`SystemUsesLightTheme`）。

当前本机判定 **light**（用户确认 DSH 是浅色），球脚本启动时会往 `ball.log` 写一行 `theme: light`。
DSH 里切主题后，球在 500ms 时钟里每 3 秒检查一次，发现变了就自己退出、让宿主用新主题重启它
（日志 `theme changed (light -> dark); restarting the ball`）——WPF 模板颜色不能在活着的窗口里换。

---

## ⑥ 2026-11-19：高级感打磨 + 不透明度

**不透明度**：profile 的 `session-ball` 配置里 `opacity: 0.88` → **`1.0`**（用户要求 0.96～1.0）。
改这个值会触发宿主配置热重载 → 插件重新挂载 → 球自动重启，不需要重启 Desktop。

**面板**：
- 圆角 16→20；窗口四周留 **16px 透明边**（`$script:PanelPad`），给 `DropShadowEffect` 落脚
  （WPF 的 Effect 会被窗口裁掉，不留边就没有投影）：模糊 32、偏移 6，浅色不透明度 0.18 / 深色 0.5；
- 内边距 14,12→18,16；面板底色浅色改纯白（`#FFFFFF→#F9FAFB`）、深色压到 `#1B1B1D→#151517`，
  条目层用 `#F7F8FA` / `#232324`，层次比之前清楚。

**条目 / 卡片**：圆角 12→14、内边距 14,12；边框从「状态色实线」改成**状态色 50% 透明度**的细线
（`Get-SoftBrush`），不再是整圈警示框；标题 12.5→13、详情/提示 10.5→11。

**输入框**：新增 `SlimBox` 模板（圆角 10、内容内边距用 TemplateBinding），条目输入框与卡片作答框同款。

**球**：窗口 66→**98 DIP**（球 48 + 光环 18 + 透明边 32）；新增 `BallSheen` 玻璃高光；状态环 3→2.5；
`BallGlow` 加 `BlurEffect Radius=7`——呼吸从「第二个圈」变成「发光」；徽标圆角 10；字体首选
Segoe UI Variable Text（Win11）。

**布局修复**：`Get-PanelHeight` 测完高度后，若内容没到上限就让 body 行**保持 Auto**（原来总是恢复成
Star，Star 会把窗口多出来的高度全吞掉，表现为最后一条条目下方一大片空白）。

**启动尺寸（2026-11-19 补充）**：每次球刚启动时先以 `Get-BallSize` 的回退值 64 出现、约 100ms 后
第一份状态文档到达才缩回 Profile 的 48，看起来就是「刚启动会很大」。现在启动时窗口只创建、定位，
**保持 `opacity = 0`**；第一份状态文档在同一 dispatcher turn 里同时写入尺寸与不透明度，首个可见帧
就是正确大小（时钟里留了 2.5s 兜底：宿主一直没消息时用回退形状显示，而不是留一个看不见的窗口）。

**玻璃感与「会话底色」分开（2026-11-19 再调整）**：窗口级 `opacity` 会把面板和每一条会话条目一起
稀释，所以「面板想要一点透视、会话条目又不该发灰」这两个要求互相打架。现在的做法是：**窗口
`opacity` 回到 `1.0`**，玻璃感只做在**面板自身的背景色**上（浅色 `#EEFFFFFF → #EEF9FAFB`、深色
`#EE1B1B1D → #EE151517`，即 93% 不透明，仍透出约 7% 的背后内容）；**会话条目 / 卡片 / 输入框一律
用不透明色**，所以会话底色是实的、只有面板边缘与空白处带一点透视。想调：改 `$script:ThemeMapLight/
Dark` 里 `#F7151922` / `#F70A0C11` 的 alpha（`EE`≈93%、`F2`≈95%、`F7`≈97%）。
**两个坑（都已加防护）**：
1. **XAML 注释不能出现 `--`，也不能以 `-` 结尾**（XML 规范）。这次两回写了 `--`，`[xml]$xaml` 直接抛
   异常 → 球启动即退出；宿主在 5 分钟内重试 5 次后**放弃重启**（日志
   `悬浮球在 5 分钟内反复退出，已放弃重启`）。恢复办法：改一次 profile 配置（例如 opacity 微调）
   触发插件重载即可把球拉回来。
2. `deploy.mjs` 现在**部署前预检** `resources/ball.ps1`：必须纯 ASCII、XAML 注释合法；不通过就
   直接退出、一个文件都不复制，profile 保持原样。

---

## ⑦ 2026-11-20：面板只留「要你处理的事」+ 更紧凑

**只显示四类会话**（`Get-EntryRank`，在 `Sync-Entries` 里过滤+排序）：

| 类别 | 判定 | 顺序 |
|---|---|---|
| 待审核 | `state` 是 `approval` 或 `question`（卡片在等你） | ① |
| 异常 | `state` 是 `error`（未确认的出错） | ② |
| 有未读已完成 | 上一份文档还是 running/approval/question/error，这一份变成 `idle` | ③ |
| 进行中 | `state` 是 `running` | ④ |

其余条目（纯空闲、已经点过「知道了」的出错、本地已读的完成）**不再占面板**；本机「＋新建」行固定排最前。
组内保持宿主给的顺序（新的在前）。被隐藏的行不是删掉数据：`EntryData` 每份文档重建，`EntryPrevState`/
`UnreadDone` 在独立映射里，所以一个空闲会话下次又有动静时能立刻回到面板。

**「未读完成」怎么来的**：宿主的状态文档里没有 unread 字段，所以由球自己记 —— 会话从 active 变 `idle`
就标记未读；**在条目里发送、点「知道了」、或点「×」都算已读**；集合写到运行目录的 `unread.json`
（`%LOCALAPPDATA%\dsh-session-ball\default\unread.json`），**球重启不丢**；会话从目录里消失时自动清掉。

**输入框更小**：字号 12、内边距 8,4；发送按钮 10,4；占位字号 11.5（条目整体矮了约 8px，320 宽下更省地方）。

**页脚提示去掉**：与 `labels.footerIdle` 完全相同的「拖动面板可移动 · 点右上角「-」收起」整行隐藏；
真通知（例如「已在球上允许一次」）照常显示。

**聚合统计行隐藏**：`MetaLabel` 所在整行（含上面那条分隔线）`Visibility="Collapsed"` —— 面板是待办清单，
不是仪表盘（用户 2026-11-20 要求）。宿主仍会送「输出 X tokens」文本，只是不再显示。

**验证方式**：写一份伪造状态文档，构造 待审核 / 异常 / 未读完成 / 进行中 / 已读完成（应隐藏）五条，
面板只出现四条且顺序为「待审核 → 异常 → 未读完成 → 进行中」，页脚与统计行都不显示；
截图见 `_work/screenshots/panel-filter-test.png`（验证后已把伪造状态与 `unread.json` 清掉）。

---

## ⑧ 2026-11-20：拖动坐标修复（高 DPI 下越拖越偏）

用户实测：按住球拖动时，指针和球越拖偏离越远。原因有两层，都修了：

**① 物理像素 / DIP 混用（主因）**：`Window.PointToScreen()` 返回的是**设备像素**，而
`Window.Left / Top` 是 **DIP**。本机 125% 缩放，拖 125 物理像素只该移动 100 DIP；原代码直接
拿物理增量当 DIP 用，球比指针少走 1/5，而且差距随拖动距离累积 —— 这就是「越拖越远」。
修法：拖拽开始时取 `VisualTreeHelper.GetDpi($window)` 的 `DpiScaleX/Y`，位移除以它；球和面板的
两个拖拽入口都要取（它们共用同一个 `MouseMove`）。

**② 采样点在窗口移动时抖动**：原来用 `PointToScreen(e.GetPosition($window))` 推屏幕坐标，窗口
自己在移动，这两个调用看到的是**不同时刻的窗口原点**，结果点会跳几十像素，拖动落点就不准。
修法：新增 `GetCursorPos` P/Invoke（`DshBall.Native.GetCursorPos` + 嵌套 `NativePoint`），
用绝对屏幕坐标算位移，再按 DPI 换成 DIP —— 完全不受窗口自身移动影响，
`Get-DragPoint` 函数在 `resources/ball.ps1` 里。

**验证**（自动注入鼠标事件，物理坐标量窗口位移）：

| 拖动距离（物理） | 窗口实测位移 | 结果 |
|---|---|---|
| -160, -80 | -160, -80 | 完全一致 |
| -320, -160 | -320, -160 | 完全一致 |
| -320, +160 | -320, +160 | 完全一致 |

拖完再拖回原位，窗口回到原来的坐标（1797,841），没有累积误差。

**顺带**：`deploy.mjs` 支持 `DSH_INSTALL_NAME` 环境变量 —— profile 还没迁移到新包名时，
可以用 `$env:DSH_INSTALL_NAME='dsh-session-ball-plugin'; node deploy.mjs` 把修复部署到旧名目录。

---

## 升级到更新的版本（如 0.11）时怎么办

两轮视觉改动都落在 `resources/ball.ps1`，新版只要动这个文件就要手工合。0.10.0 这次的经验：

1. 拉下新版 tarball 解开，用 `git diff --no-index` 把「上游旧版 → 上游新版」的 `ball.ps1` 差异拿出来
   （先 `Get-Content -Raw` 归一化换行，或用 `git -c core.autocrlf=false diff`）；
2. 本仓库的 `resources/ball.ps1` = 本机视觉版本：把上面那份**上游差异**手动合进来（通常只有几十行），
   比「把视觉补丁合进新版」冲突更少；
3. 合完核对两个方向：与新版上游相比只剩本机视觉改动、与升级前相比只剩上游改动；再跑
   `[Parser]::ParseFile` 确认语法、确认文件仍是纯 ASCII；
4. 部署：改完 `node deploy.mjs`，球脚本会重启；`lib/` 变了则要重启 DSH Desktop 才装载新宿主逻辑。

**屏幕上的球（2026-11-20 同日补）**：`resources/ball.ps1` 的 `BallMark` 之前仍是 DeepSeek 鲸鱼路径，
只换了 market/README/封面图标，所以「看图标的和看桌面球的」是两只不同的鲸鱼。现在 `BallMark` 换成
`assets/icon.svg` 同源的原创鲸鱼：身体 / 胸鳍 / 背鳍三块白色填充 + 蓝色眼睛 + 嘴线和腹线，
外面包一层 `Viewbox`（`Apply-Shape` 仍按 `ballSize * 0.56` 统一缩放）。注意 WPF `Shape` 没有
`StrokeOpacity` 属性（写了会 `XamlParseException`），半透明描边要用带 alpha 的颜色。
**最终定稿（同日再调）**：用户反馈「微笑的嘴很突兀」「尾巴翘一些」，所以鲸鱼改成**无嘴、无腹线**
（只有一只蓝眼睛的纯剪影，腹线在白身体上也会被读成第二张嘴），**尾鳍整体上扬**（尾鳍尖端从
y=19/61 抬到 y=10/57，尾鳍像在往上甩），球上的鲸鱼占球径 0.68、带软阴影和三颗上浮气泡。
图标、封面、README 首屏同步成同一只「无嘴 + 翘尾」的鲸鱼（`tools/render-icon.ps1` 与
`assets/icon.svg` 同源）。