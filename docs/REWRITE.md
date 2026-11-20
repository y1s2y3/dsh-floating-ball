# 从零重写计划（去上游依赖）

> 目标：把 `dsh-session-ball-plugin` 的上游代码全部换成本仓库自己的实现，最后只剩我们自己的
> 代码 + 来源说明。分三期，每期都有肉眼可验收的标准。
>
> 当前状态：**第一期（球体）已完成**，生产环境仍运行旧 `resources/ball.ps1`，等第二期和
> A/B 对照通过后再切换。

## 一、三期安排

| 期 | 内容 | 验收 | 状态 |
|---|---|---|---|
| ① 球体（1 天） | 自己的 XAML + 自己的绘制逻辑：能浮、颜色对、能呼吸 | 肉眼：四种状态色正确、呼吸可见、能拖动 | ✅ 完成 |
| ② 宿主 + 面板（3–4 天） | 用自己的 `lib/` 替换上游 `session-ball.js`：状态发布、条目、输入框、审批 | 面板功能与旧版逐项对齐 | 面板渲染已完成（2a）；宿主替换待做（2b） |
| ③ 收尾（1 天） | 删掉上游文件、写来源说明、旧版/新版各跑一遍对照三项行为 | 三项行为对齐后切换 | 待开始 |

## 二、第一期：球体（`resources/ball-v2.ps1`）

**自研部分**

① **自己的 XAML**：窗口 / 球体 / 光晕 / 高光 / 状态环 / 鲸鱼 / 徽标全部自己写，不再沿用上游布局；窗口仍是 layered + topmost + noactivate（能浮在所有窗口上、不抢焦点）。
② **自己的绘制逻辑**：状态颜色直接取宿主下发的 `status.color`，画在**状态环 + 光晕 + 徽标**三处；鲸鱼用本仓库自己的路径（与图标同源）。
③ **自己的呼吸**：`Storyboard` + `DoubleAnimation` 驱动光晕透明度（0.18 ↔ 0.92，1.7s 来回，Sine 缓动），只在「有会话在输出」时启动。
④ **自己的拖动**：`GetCursorPos` 绝对坐标 + DPI 换算（这是旧版修过的坑，新版直接带上）。
⑤ **协议不变**：仍然读 `state-<n>.json`（UTF-8）、写 `act-<pid>-<seq>.json`，所以第二期可以复用同一份宿主协议。

**预览和验收**

```powershell
# 生成四种状态 + 呼吸两帧 + 48px 实尺寸图（透明底 PNG，不弹窗、不碰生产球）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\preview-ball.ps1 -OutDir <目录>
```

验收结果：

| 项 | 证据 |
|---|---|
| 能浮 | layered/topmost/noactivate 窗口；拖动按物理坐标 + DPI 换算（与旧版一致） |
| 颜色对 | `idle` 灰、`working` 蓝、`asking` 琥珀、`error` 红：状态环 + 光晕 + 徽标同步变化（见预览图） |
| 能呼吸 | 呼吸两帧像素均差 9.25（0–255 标度），肉眼可见光晕强弱变化 |
| 兼容真实状态 | 直接用运行目录里的 `state-706.json` 渲染成功，解析无报错 |

**刻意没做的（第二期）**：展开面板、条目、输入框、审批卡片、徽标计数以外的交互、z-order 看门狗、窗口位置记忆（`window.json`），都留给第二期；所以现在**不能**用它替换生产球。

## 三、第二期：宿主 + 面板

### 2a 面板渲染（已完成）

`resources/ball-v2.ps1` 现在同时画球和面板：

- 面板：圆角卡片 + 软阴影、头部（状态点 / 标题 / ＋ / −）、meta 行、条目滚动区、footer；
- 条目：状态点、标题、明细、错误原因、「×」、卡片（审批/问题 + 选项按钮）、自己的输入框 + 发送、出错时的「知道了」；
- 排序/筛选与旧版一致：待审核（approval/question）→ 异常 → 未读完成 → 进行中；空/idle 不显示；
- 高度按内容测量（先建条目再测量，避免 Collapsed 元素测出 0）；超过 panelHeight 后滚动；
- 中文文案全部来自 state 的 `labels` 字段（脚本保持纯 ASCII）；
- 动作写入：`expanded` / `pos` / `prompt` / `approval` / `question` / `ack` / `close` / `new`。

预览（三种条目 + 审批卡片 + 错误条目 + 运行中条目）：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\preview-ball.ps1 -OutDir <目录>
```

### 2b 宿主替换（待做）


要替换 `lib/session-ball.js` 的部分：

① **状态发布**：监听 `agent/assistant-stream`、`session/event`、`api-session/*`、`user-questions/request`、`approval/request`，拼出与现在同结构的 state 文档（v9）。
② **面板**：条目列表（筛选/排序规则保持现在这套：待审核 → 异常 → 未读完成 → 进行中）、每条自己的输入框与发送回执、审批/问题卡片、`+ 新建`、`×`/知道了。
③ **动作消费**：`act-*.json` 的 `pos` / `expanded` / `prompt` / `approval` / `ack` / `close`。

验收：新旧两版并排跑同一批会话，逐项对比「状态色、条目集合与顺序、输入与审批回执」。

## 四、第三期：收尾

① 删除上游 `lib/session-ball.js`、上游 `ball.ps1` 及只在旧版用到的文件；
② 写 `docs/PROVENANCE.md`：上游 MIT 来源、保留 `LICENSE`、我们重写了哪些部分；
③ 旧版/新版各跑一遍三项行为（状态色 / 条目与顺序 / 输入审批），对齐后把 `deploy` 切到新版并打 tag。
### 2a 样式定稿（2026-11-20）

面板采用 **S1 精修**（白 + 蓝 + 灰）：

- 面板纯白、会话卡浅灰 `#F5F6F8`，两者有层次；无 footer、无「几个待处理 / 几个进行中」计数。
- 每条左侧 2px 低饱和状态条；标题 13px SemiBold + 小 chip（审批/异常/输出中/未读）。
- 问句、错误原因、输入占位统一降到 11.5px 灰色（二级信息）。
- 按钮轻量化（A 档）：主按钮浅蓝底 + 蓝字，次要按钮白底细边，发送为浅蓝方块 + `↑`；输入框有占位文案。
- 分组顺序：等你处理（审批 + 异常）→ 运行中 → 已完成·未读；组标题来自 state.labels。

**尺寸与当前插件一致**：面板内容宽 320、展开窗口 352×N（四周 16px 投影边）、最大高度 460；球 48、收起窗口 98（25px 边）。这些值来自 `state.metrics`，默认值与此相同。
### 2b 宿主重写 · 里程碑 1（2026-11-20）

新增 `lib/floating-ball-v2.js`（自研宿主原型，不沿用上游代码）+ `test/host-v2.mjs`（假 Host 测试，`npm run test:host`）。

已打通：

- 事件收口：`api-session/added|status|activity|removed`、`session/event`、`agent/assistant-stream` → 自己的会话镜像；
- 状态文档 v9：状态色/标签、条目（运行中 / 异常 / 已完成未读）、labels、metrics（默认 48 / 320 / 460，与当前插件一致）、window（位置与展开态持久化到 `window.json`）；
- 球进程管理：按内容哈希物化 `resources/ball-v2.ps1`、spawn PowerShell、退出自动重启（5 分钟内超过 5 次放弃）；
- 动作消费：`expanded / pos / prompt / close / ack` 已实现；`prompt` 走 `sessionController.prompt`（或 `typertGateway.invoke`），payload 与网页端一致（`requestId/sessionId/mode/content`）；
- 测试覆盖：运行中条目（chip 输出中、锁输入）、完成后未读、出错 + 知道了、ack 清红、prompt 路由、expanded 持久化、close 移除条目、脚本物化唯一。

下一里程碑（2b-2）：`approval/request` / `user-questions/request` 的卡片与作答回传、`＋ 新会话` 工作区选择；之后作为开发行与旧版并排 A/B，通过后切生产。
### 2b 宿主重写 · 里程碑 2（2026-11-20）

审批 / 单选题卡片已接通：

- `approval/request`（`prepend` 环绕监听）：把自己的 Promise 与上游 `next()` 竞速 → 球上点「允许一次 / 拒绝」直接把 `allowed-once` / `rejected` 作为结果返回，抢在网页端之前落地；
- `user-questions/request`：**只接管单题且有选项**的提问（球上渲染成选项按钮，选中的 label 作为 `answers:[{id,selected:[label]}]` 返回）；多题/无选项/自由文本一律 `next()` 交回桌面 UI，不在球上做半套；
- 卡片挂到对应会话条目上：条目状态变 `approval` / `question`、chip 变「待审批 / 待回答」、`pendingCount` 计数、整体状态色跟着变；会话还没有条目时补一条，请求结束后卡片与条目一起收；
- 假 Host 测试新增：审批卡片渲染 + 球上作答回传 `allowed-once`、单选题卡片 + 回传 `{answers:[{id,selected}]}`（`npm run test:host` 全绿）。

仍未接：`＋ 新会话` 的工作区选择、审批理由长文本/多审批同屏的细节；之后进入 **A/B 挂载**（开发行并排旧版）再切生产。
### A/B 挂载（2026-11-20）

- 上游宿主改名 `lib/session-ball-upstream.js`；入口 `lib/session-ball.js` 变薄，按 `config.engine` 分发（默认 upstream，显式 `v2` 才走新宿主）；两个引擎都惰性 `import()`，互不拖累。
- 版本升到 0.12.0；`test/dispatch.mjs` 覆盖引擎选择与 v2 冒烟；`npm test` = host-v2 + dispatch。
- 已部署到 profile：`~/.dsh/profiles/desktop/node_modules/dsh-floating-ball`（备份 `backups/20261120-144249`），profile 配置 `engine: v2`（备份 `cordis.patch.yml.bak-20261120-1443`）。
- 重启 Desktop 后按 `docs/AB-TEST.md` 的检查清单对照；回滚 = 改回 `engine: upstream` 或恢复备份。
### 2b 里程碑 3：补掉三个缺口（v0.12.1）

- ①「＋ 新会话」：`new` 动作在面板顶部加一条 `local-new` 本地行；在它输入框发出的 `prompt(target:'new')` 走 `sessionController.create({cwd})`（最近活跃会话目录）→ 拿到 sessionId 后再 prompt，成功后本地行消失；`×` 取消。
- ② 提问：宿主不再只接「单题 + 选项」，`items`（每题 id/prompt/options）全量下发；球上每题可选项或自由文本，底部「作答」一次提交 `{kind:'answer', answers:[...]}`，没答全提示「每个问题都要选一项或填一句」。
- ③ 审批题面：优先 `displayReason`（中文），工具名变成灰色小字 `工具：<name>`。
- 预览：`tools/preview-ball.ps1` 多渲染一张只含提问卡的面板（`ball-question.png`）；`preview-panel.json` 增加本地新会话行、真实审批理由、两题提问。
- 测试：审批理由、多题作答、`new` 建会话并投递、`answer` 动作全部纳入 `npm run test:host`。
### 2b 里程碑 4：DSH 式逐题作答 + DSH 同源字体（v0.12.2）

- **多题改成一步一题**：进度 `1 / 2`，选项 + 自由文本；「上一题 / 下一题」，最后一题按钮变「提交」；提交时校验所有题，缺哪题自动跳回哪题并提示「每个问题都要选一项或填一句」。
- **字体与 DSH 一致**：DSH 界面用 Inter Variable，本机没装 Inter → 从 DSH Desktop 自带的 Inter 拉丁子集派生 400/500/600 三个静态实例、子集到界面字符、改名 **DshUiSans**（OFL 1.1，不使用保留名 Inter），随包放 `assets/fonts/`；宿主启动时物化到运行目录并通过 `DSH_BALL_FONTS` 传给球，球用 `file:///...#DshUiSans` 载入；中文由系统字体回退（微软雅黑）。
- 文档：`assets/fonts/FONT-NOTICE.txt` 增加 Inter 来源与修改说明；`assets/manifest.txt` 重新生成；`docs/BRAND.md` §七 更新。
- 预览：`ball-question.png` 为单题卡长图，可直接看进度/下一题按钮与新的拉丁字形。
### 2b 里程碑 5：兼容 DSH 的长选项 / 多选 / 题目补充信息（v0.12.3）

DSH 的提问形状是 `{ header, question, detail, multiSelect, options:[{label, description}] }`，`label` 与
`description` 都可能很长。球上按这样兼容：

- 选项从「横排小按钮」改成**整行纵向卡片**：`label` 自动换行，`description` 作为第二行灰色说明；
  行高随内容增长、不截断，卡片超过面板高度时整面板滚动（仍受 `panelHeight` 上限约束）。
- `multiSelect: true` 的题支持多选（点一次选中、再点取消），单选仍是互斥；选中态统一为浅蓝底 + 蓝字。
- `header` 显示为题目上方的小标题，`detail` 显示为题面下的灰色补充说明。
- 答案回传 `selected` 是数组（多选就是多个 label），自由文本仍可同时填写。
- 预览模板换成真实长选项（带 description）与一道多选题；假 Host 测试覆盖 `description`、`multiSelect`、多选答案。
### 2b 里程碑 6：球体照搬生产版外观，去掉空转光圈（v0.12.4）

- 悬浮球 XAML 直接照搬 `resources/ball.ps1`（原作者手调版）：半透明蓝渐变球体、左上高光、
  2.5px 状态色细环、白鲸鱼 + 软阴影 + 三个小气泡、徽标位置 -3。
- 呼吸也照搬：**环**在会话输出时呼吸（0.55..1.0），**白色光晕只在有会话运行时存在**
  （0.35..1.0 呼吸）；空闲时 `Glow.Visibility = Collapsed` —— 之前那版空闲也挂着一圈彩色光晕，
  就是「没有对话时候的光圈有点奇怪」的来源。
- 几何与生产版一致：body = ballSize、ring = ballSize+2（-1 margin）、窗口 = ballSize + 50（18 光晕 + 32 阴影边）。
- 预览：`ball-idle.png` 空闲无光晕、`ball-working.png` 有光晕、呼吸两帧差异 16.6（可测）。
### 2b 里程碑 7：窗口不出屏 + 按钮闪烁/多点才响应修复（v0.12.5）

- **窗口不出屏**：移植生产版的 `Move-IntoVirtualScreen`（虚拟桌面 = 所有显示器并集），在展开/收起、
  恢复记忆位置、拖动过程中都夹紧；窗口自带透明边（球 25px / 面板 16px），所以夹到屏幕边缘时
  视觉上仍与边缘留出这段距离 —— 就是「以前那个限制 + 留一点距离」。
- **「允许一次」悬停闪烁 / 点几次才响应**：根因是每 200ms 的状态轮询都在重新 `Apply-Shape`
  （重设窗口尺寸/位置）并重刷条目属性，悬停时布局不断被重排。修复：
  ① 只在 `ballSize / expanded / panelWidth / panelHeight` 或条目内容真的变化时才重新测高/换形；
  ② 条目 JSON 不变就跳过 `Update-EntryView`；
  ③ 位置只在真正不同时写入；
  ④ 所有面板按钮改用自绘 `FlatButton` 模板（无系统 chrome / 无视觉状态动画），悬停只改透明度；
  ⑤ 宿主与球的状态节拍从 120ms 放慢到 200ms。
### 2b 里程碑 8：字体回退到生产字体栈（v0.12.6）

「字体不好看」的根因查清了：随包的 `DshUiSans` 是 Inter 拉丁子集，**没有中文字形**，WPF 对缺失的
汉字回退到了另一个中文字体，中英混排看起来不协调（而且早先是单文件 Regular，粗体是伪粗体）。
处理：

- 默认字体**回到生产球那套**：`Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI`（拉丁 Segoe、中文雅黑）；
- 随包 Inter 子集保留但改成**可选**（`DSH_BALL_FONT_FAMILY` 环境变量），仅用于字体对比预览；
- 另外把 DshUiSans 合成 `.ttc`（400/500/600 三个真实字重），避免伪粗体，供以后想用时不再糊。
- 预览工具支持 `-FontFamily`/`-Tag`，一次生成四套字体对照图（系统 Segoe+雅黑 / 雅黑 / Noto Sans SC / Inter 子集）。
### 2b 里程碑 9：重复宿主导致的所有异常（v0.12.7）

现场日志证据：`ball.log` 里出现**两次** `[host] host started (ball-v2)`（07:14:05 / 07:34:20），
并且每 200ms 一条 `write state failed: data must be string... received undefined`，运行目录的
`state-*.json` 只剩奇数编号（两个实例各自计数、互相覆盖）。两个宿主各拉一个球、交替写状态，
球读到的是两份来回切换的文档 —— 这就是「点输入框面板自己关又开 / 高度一点点长 / 位置飘出屏幕 /
一直闪」的总根源。

修法：

1. **apply 改回同步**：v2 引擎改成静态 import，`apply()` 不再先 `await import()`。异步 apply 在
   插件重载时可能还没执行到 `ctx.effect()` 就被 dispose，清理函数没注册 → 旧实例泄漏成“第二个宿主”。
   上游引擎仍需惰性 import（依赖宿主提供的 @deepseek-ai/schemastery），只在 engine=upstream 时走。
2. **单实例锁**：宿主启动时在运行目录写 `host-<pid>.lock`，若发现另一个仍存活的宿主 pid 就直接不启动
   并在日志说明；清理时删自己的锁，过期锁会被接管。
3. **量高前 Reset-Measure**：递归 `InvalidateMeasure()` 再 Measure，避免 WPF 按约束缓存导致面板
   “一点点长高”。
4. **夹紧后回写 pos**：窗口因不出屏被夹回时，球主动发 `pos` 动作，宿主记住新位置，避免下一拍
   又用旧坐标把窗口推出去（位置来回跳）。
### 2b 里程碑 10：一次全量自查（v0.12.8）

对照上游 host 的真实事件契约，把自研宿主里“看起来能跑、真机上会错”的地方补了一遍：

| # | 问题 | 影响 | 修法 |
|---|---|---|---|
| 1 | `turn/end` 的 `reason.kind = error / aborted` 没识别 | 出错/中断后球不红 | 按 reason 判 error/aborted 并写原因 |
| 2 | `tool/result` 失败没处理 | 工具报错不红 | `ok === false` 时置 error + `code：reason` |
| 3 | `stream` 只认 start/end/error，真实是 `chunk` + `text-delta / reasoning-delta / tool-call-delta` | “输出中”状态不稳 | 按 chunk 类型维持 working |
| 4 | `user/message` 没处理 | 用户发话后错误红不消 | 清 error、置 working |
| 5 | 量高前 `$panelView.Height` 是显式值 | 内容变化后高度不再自适应（长高根因之一） | Measure 前 Height=NaN |
| 6 | 新会话用第一个会话目录 | 新会话落在最旧目录 | 改成最近活跃会话的 cwd |
| 7 | 发送模式总用 steer | 空闲会话可能发送失败 | 按目标是否在跑选 queue/steer，失败回退，controller/gateway 两条路都试 |
| 8 | 会话没有条目时审批卡标题是 session id | 标题难看 | 用会话标题/cwd |
| 9 | 球上缺 下一题/上一步/提交 标签 | 显示英文按钮 | 宿主 labels 补齐 |
| 10 | 每 200ms 都写一份相同 state | 磁盘/读取抖动 | 相同文档跳过写盘 |
| 11 | 单实例锁直接拒绝启动 | reload 时可能出现“没有球” | 改为等待旧实例退出后接管 |
| 12 | buildState 为空时 writeFileSync 抛错刷屏 | 日志噪音 | 写作前判空 |
| 13 | 宿主坐标每拍都重新应用 | 夹紧与旧坐标互相打架、位置跳 | 坐标变了才应用 + 夹紧后回写 pos |

未验证/已知限制：审批与提问的事件形状是按上游代码反推的，重启后需真机各点一次；新会话仍无工作区选择；提问卡片不支持图片/附件。
### 2b 里程碑 11：首次点击被窗口激活吃掉 / 点击延时（v0.12.9）

用户反馈：第一张审批卡「允许一次」点了三次才有反应；第二次出现点一次就行，但有点延时。

- **根因**：窗口是普通可激活窗口（`ShowActivated=False` 只是不主动抢焦点），第一次点击先被
  Windows 拿去激活窗口，按钮收不到；第二次时窗口已经是前台，所以一次就中。
- **修法**：照生产球的做法给窗口加 `WS_EX_NOACTIVATE + WS_EX_TOOLWINDOW`，点击直接进按钮；
  WPF 输框需要键盘，所以在 TextBox 获得焦点时临时去掉该样式并 `Activate()`，失焦/收起时恢复。
- **延时**：状态节拍 200ms → 150ms；点击后按钮立刻禁用（乐观反馈），不等下一轮状态。
- **另修**：宿主 Overlay 里遗留的一个定时器还在每 200ms 调 `writeState()`（无参数）→ 就是日志里
  `write state skipped: buildState returned nothing` 的来源，已删除，只保留宿主自己的 buildState 循环。
- **新增 `tools/smoke-ui.ps1`**：找到运行中的球窗口 → 写入假状态（展开面板 + 输入行 + 审批卡）→
  用真实鼠标点击面板内空白处和一个按钮 → 断言面板仍展开、尺寸不变。当前运行实例实测 **PASS**。
### 2b 里程碑 12：开/关面板后浮球回到原位（v0.12.10）

反馈：把球拖到某处 → 点开面板 → 关闭 → 球的位置变了。

原因：展开/收起只是把窗口的「左上角」原地改尺寸，收起时窗口左上角还停在面板的左上角（面板可能被屏幕
夹过、或比球宽很多），所以球看起来“挪了”。生产球的做法是记住收起时的位置，展开时先存
`CollapsedAnchor`，收起时把窗口放回那个点。

实现：

- `Apply-Shape` 展开前记录 `$script:CollapsedAnchor`（球窗口的 Left/Top）；
- 收起时先把窗口尺寸恢复成球窗口，再把 Left/Top 放回 anchor，然后做一次屏幕内夹紧，并把最终坐标
  用 `pos` 动作回写给宿主（宿主的记忆位置也跟着变成球的位置）；
- 拖动过程中不触发该回写（避免和拖动打架）。

`tools/smoke-ui.ps1` 也加了这一段回归：收起态记录位置 → 点球展开 → 点 `-` 收起 → 断言位置回到原位。
### 2b 里程碑 13：开关面板的闪烁（v0.12.11）

反馈：关闭浮窗时会闪一下。

两个原因，都照生产球的做法修了：

1. **同一形状被应用两次**：点「−」时 `Collapse-Panel` 立刻 `Apply-Shape(false)`，但形状缓存 `$script:ShapeKey`
   没有一起更新；150ms 后宿主状态回来，`Apply-State` 发现 key 不匹配又 `Apply-Shape(false)` 一次 ——
   一开一关之间窗口被连续 resize 两次，就是那一下闪。修法：`Expand-Panel`/`Collapse-Panel` 里调用
   `Sync-ShapeKey`，让状态回来时不再重复换形。
2. **展开时窗口在面板可见的情况下 resize**：面板已经可见、窗口还是旧尺寸，合成器可能抓到一个“错尺寸”的帧。
   改成生产球的写法：量高时面板可见，**真正写窗口宽高的两条语句期间面板隐藏**，写完再显示。

开/关路径都已覆盖；窗口位置仍用 CollapsedAnchor 恢复（见里程碑 12）。
### 2b 里程碑 14：首次点击根因确认 + 交互提速（v0.12.12）

用一个**隔离的球实例**（独立运行目录 + 真实鼠标点击）复现并定位了「面板启用后第一次点允许要几次」：

- 现象：全新窗口的**第一次鼠标点击会被吞掉**（先点一下面板空白处再点按钮，第一次就生效）。
- 根因：`WS_EX_NOACTIVATE` 只是 Win32 层不激活；WPF 仍把 `WM_MOUSEACTIVATE` 默认答成 `MA_ACTIVATE`，
  这次激活失败导致首个点击被丢弃。修法：在 HwndSource 上挂钩子，把 `WM_MOUSEACTIVATE` 回 `MA_NOACTIVATE(3)`。
  隔离实例实测：加钩子后**第一次点击就写出 action（93ms）**，不加钩子要点 2 次。
- 交互提速（针对「新增会话/关闭反应慢」）：宿主消费动作后**立即重写状态**（不再等下一拍），动作消费 80ms、
  状态循环 120ms；球轮询 100ms。隔离实例实测：`+` 动作 **49ms**、首次审批 **93ms** 落盘。
- 已验证/未验证：首次审批点击、`+` 新会话动作通过；关闭行/发送/多题作答的隔离用例受测试夹具限制未跑通，
  需要重启后在真实面板上手工确认。
### 2b 里程碑 15：关面板回左上角 / 拖到屏外闪烁（v0.12.13）

1. **关面板后球跑到左上角**：启动时若记住的状态是「展开」，`Apply-State` 先应用形状、后应用位置，
   于是 `Apply-Shape` 在窗口还停在默认 (0,0) 时就把 `CollapsedAnchor` 记成了 (0,0)；之后一收面板，
   球就被“恢复”到左上角。修法：`Apply-State` 改成**先应用位置、再应用形状**，锚点记录的是真实位置。
2. **往屏幕外拖时一直闪**：拖动时每一帧先把窗口写到屏外、再夹回屏内 —— `Window.Left/Top` 的 setter
   每次都直接 `SetWindowPos`，所以一次鼠标移动里实际发生了“出去→拉回”两次移动，看起来就是闪。
   修法：新增 `Get-ScreenClamped` 纯计算函数；拖动只计算一次夹紧后的目标位置并**只赋值一次**。
### 2b 里程碑 16：首次启动的默认位置（v0.12.14）

首次启动（宿主没有记住的位置）时，球停在**工作区右侧、垂直居中**：

- `Set-DefaultBallPosition`：`Left = WorkArea.Right - 窗口宽 - 12`，`Top = WorkArea.Top + (WorkArea.Height - 窗口高) / 2`；
- 工作区（WorkArea）已排除任务栏，所以视觉上是屏幕垂直居中；
- 宿主状态里带 x/y（拖动过/上次记住的位置）时以宿主为准，并清掉“首次”标记；
- 想重新看到默认位置：删掉运行目录的 `window.json` 再重启。
### 2b 里程碑 17：默认位置不写死，按当前机器实时计算（v0.12.15）

反馈：不能把位置写死，换台电脑就不对了。

- 默认位置本来就是**运行时**用 `SystemParameters.WorkArea` 算的（右缘 12、垂直居中），没有任何硬编码坐标；
- 另外加了一道校验：宿主记住的位置每次都会先和**当前机器的工作区**比对，窗口如果放不进当前屏幕
  （换分辨率/换显示器/从别的机器带来的旧坐标），直接忽略并改用算出来的默认位置，同时把新位置写回宿主；
- 运行目录的 `window.json` 是**每台机器各自**的，不会随插件包复制，所以新机器上第一次启动本来就是默认位置。
### 2b 里程碑 18：点球开面板的闪烁（v0.12.16）

点球时面板会“先闪一下再出现”，原因是面板打开分两步：

1. 点球 → `Expand-Panel` 立刻按**上一次同步的条目**（可能是空的）测量高度并开窗；
2. 约 100–200ms 后宿主状态回来，`Sync-Entries` 建出条目、`ContentDirty` 触发**第二次换形**，面板从矮变高 —— 这两次 resize 就是那一下闪。

修法：`Expand-Panel` 在测量之前先用**当前已缓存的状态**（`$script:State`）跑一次 `Sync-Entries`，条目先建好再测量；换形后把 `ContentDirty` 清零并同步 `ShapeKey`，宿主状态回来时不会再换一次。
### 2b 里程碑 19：启动位置不对 / 开关仍闪（v0.12.17）

1. **启动位置不对**：记忆位置被“夹紧后的临时坐标”污染过 —— 展开面板时窗口被屏幕夹到某个中间坐标，
   球把那个坐标当成位置写回宿主，下次启动就恢复成那个中间值。现在**只有用户真正拖动**才写 `pos`；
   默认位置的首次计算仍写一次（让每台机器自己记住）。清掉运行目录里的 `window.json` 后，下次启动
   回到实时计算的右侧居中。
2. **开关仍闪**：WPF layered 窗口在改变宽高时可能被合成器呈现中间帧。现在换形期间先把窗口 `Hidden`，
   尺寸/位置/视图都改完再 `Visible`，避免中间帧露出来。若这一版仍闪，说明是 DWM 对 layered 窗口的
   resize 本身，需要改成“窗口尺寸固定、球在内部移动”的方案（工作量大，另行评估）。
### 2b 里程碑 20：按原插件的方式重做形状/位置（v0.12.18）

一直闪的根因是我们自己在 v0.12.17 引入的“换形时把整个窗口 Hidden 再 Visible”，加上每次状态更新
都可能触发整窗换形。把原插件 `ball.ps1` 的做法搬了过来：

1. **只有开/关状态变化才整窗换形**：`expanded` 变了才 `Apply-Shape`；已展开时只用
   `Apply-PanelHeight`（只改高度且高度没变就跳过）；收起时用 `Sync-BallSize` 校正尺寸。
   不再有每次状态更新都换形的情况，也没有窗口 Hide/Show。
2. **展开时钉住右上角**：记下展开前的宽度，换形后 `Left += oldWidth - newWidth`，球贴着右边时面板
   向左长、收起后回到同一个角（原插件同款）。
3. **记忆位置的语义**：宿主记的是“收起时球的左上角”；面板展开时拖动，上报的是面板右上角
   （= 球的位置），并同步更新 `CollapsedAnchor`，收起就回到你拖到的地方。
4. **默认位置**仍是运行时按 WorkArea 计算（右侧、垂直居中），展开后再计算，尺寸准确。
5. 位置只在**用户拖动**时写回宿主；夹紧/纠偏不污染记忆。
### 2b 里程碑 21：单次闪的结论与下一步方案（v0.12.19 后）

现状（用户确认）：**常闪已消失、位置正确**，只剩打开/关闭时**一次**闪动。

结论：单窗口方案已经到极限。球和面板在同一个 WPF layered 窗口里，开/关必须改变窗口宽高，
DWM 在 layered 窗口 resize 时会合成一帧（内容/尺寸切换的瞬间），调换 Visible/Hidden 的顺序只能
决定这一帧“有内容还是空”，不能去掉它。

彻底消除需要换架构，两个候选：

1. **固定尺寸窗口（改动较小）**：窗口始终是面板大小（352×492），球画在窗口内部的固定偏移处；
   开合只是切换内部内容，完全不 resize。依赖：layered 窗口 alpha=0 的区域对鼠标穿透（原作者
   在 ball.ps1 注释里确认过），所以透明区域不会挡住桌面。需要重做球/面板在窗口内的坐标映射、
   拖动（窗口位置≠球位置）、屏幕夹紧（窗口可以部分出屏）、以及“关面板回原位”的锚点。
2. **双窗口（改动较大）**：球窗口固定 98×98、面板窗口打开时按其最终尺寸创建/显示；打开=隐藏球窗 +
   显示面板窗。没有 resize，也没有透明区域映射问题，但要改窗口创建、事件绑定、拖动、位置记忆和
   预览渲染。

两者都需要一轮专门改造；在拿到用户确认前不切换架构。
### 2b 里程碑 22：确认原插件是单窗口 + 用淡入盖住单帧（v0.12.20）

先回答「原插件是不是双窗口」：**不是**。`resources/ball.ps1` 里是一个 `<Window>`，内部 XAML 先
`<Grid Name="BallView">` 再 `<Border Name="PanelView">`，开关面板同样是**单窗口改宽高**，和我们的架构一样；
它看起来“不闪”，很大程度是因为面板是深色（`#F7151922 → #F70A0C11`），中间帧和桌面背景融在一起，
而我们的白面板让同一帧非常显眼。

既然两边都是单窗口，就不动架构了：给每次换形加 **110ms 淡入**（`Start-ShapeFade`），
把那一帧盖过去，观感上变成“打开/关闭的小动画”。若仍然突兀，再考虑固定尺寸窗口/双窗口方案。
### 2b 里程碑 23：球↔面板交叉淡入（v0.12.21）

帧采集确认“闪”是球/面板瞬间切换本身（没有坏帧）。原插件同样单窗口硬切换，所以换架构也不解决
观感。改为**交叉淡入**：

- 打开：球先保持原屏幕位置，窗口一次性放大（只有透明窗口变大），然后球 1→0、面板 0→1，130ms 同步淡变；
- 关闭：球先以 0 透明度出现在锚点位置，面板 1→0、球 0→1，结束后把窗口缩回球尺寸并归位；
- 过渡期间宿主状态 tick 不触发换形（避免动画被打断）；
- 渲染/截图模式跳过动画直接出最终形状。
### 2b 里程碑 24：拖动卡顿 —— 对齐原插件的做法（v0.12.22）

对比 `resources/ball.ps1` 的拖动实现，差异有两处：

1. **原插件拖动时不做屏幕夹紧**：`$window.Left = DragStart.Left + dx`，只写坐标；夹紧留到**松开鼠标**时再做。
   我们上一版每一帧都调 `Get-ScreenClamped`（读 4 个 SystemParameters 值）再赋值，鼠标一动就多一轮计算，
   贴着屏幕边时还会出现“推不动/发黏”的手感。
2. **原插件 120ms 轮询**，而且宿主只在状态变化时写文件；我们的球每 100ms 把整份状态重新 Apply 一遍
   （字体/画刷/文本/布局都重新赋值），拖动期间这些重活会抢 UI 线程，所以球和面板都显得卡。

改造（照原插件）：

- 拖动只做 `Left/Top = 起点 + 位移`，**松手时**再 `Move-IntoVirtualScreen` 夹紧并回写宿主；
- **拖动期间暂停状态轮询**（`$poll.Stop()`），松手恢复；
- 读状态改为**原始 JSON 缓存比较**：内容和上次一样就直接返回，不再重复 Apply-State。
### 2b 里程碑 25：鼠标移入让鲸鱼“游起来”（v0.12.23）

- 移入球：鲸鱼绕自身中心 ±6° 摇摆（620ms 往复）+ 上下轻浮动 ±1.6px（520ms 往复）+ 气泡透明度 0.45↔1 呼吸（900ms 往复）；
- 移出球 / 展开面板：全部归零，鲸鱼回到静止姿态；
- 实现：复用 XAML 里已有的 `WhaleRotate`，再补一个 `TranslateTransform` 挂到 `Whale` 的 TransformGroup；
  三个动画都是 transform/opacity（不触发布局），不会和拖动抢 UI 线程；
- 预览渲染模式跳过动画（`$Preview` 直接 return），保证截图是静止姿态。
### 2b 里程碑 26：一次全面排查（v0.12.24）

排查范围：宿主/球脚本静态检查、运行目录、宿主与球日志、资源占用、测试与品牌校验、仓库卫生。

**修掉的问题**

1. **面板展开状态下重启，位置会偏右一个面板宽**：记忆点是“收起球的左上角”，但重启时若上次是展开状态，
   代码把这个点直接当成面板 Left 用，面板就整体右移；夹紧后更明显。现在展开时按
   `Left = 球点 + 球窗宽 - 面板宽` 换算，锚点也按换算后的位置记。
2. **首次形状（启动时恢复展开状态）会看到球先出现再淡成面板**：加入 `FirstShape` 标记，第一次换形直接出最终形状。
3. **鼠标捕获丢失会导致状态轮询永久停摆**：拖动开始时 `Stop()` 轮询，只有正常 MouseUp 才 `Start()`；
   若捕获被系统抢走，状态就永远不刷新。补 `LostMouseCapture` 处理：取消拖动并恢复轮询。
4. **仓库卫生**：`_work/` 测试运行产物一直被 git 跟踪（每次测试生成新哈希脚本，仓库永久脏）；已加
   `.gitignore` 并 `git rm --cached`。删除两个死函数（`Sync-ShapeKey`、`Read-BallState` 包装）。
5. **磁盘**：部署备份 55 份/61.4MB（每次 deploy 一份）→ 清理并保留最近 8 份（13.1MB）；运行目录
   `ball.log` 3.07MB 旧日志（旧版宿主遗留）→ 清空。

**检查通过、无需改动的项**

- 单实例锁只有 1 个（`host-<pid>.lock`），运行目录只物化 1 份球脚本；`act-*.json` 0 残留（宿主与球都及时消费删除）；
- `state-*.json` 由宿主按 60 份上限自动清理（当前 36 份、36.8KB）；
- 假宿主测试 / 调度测试 / 品牌校验全部通过，仓库与已部署版本号一致；
- 宿主日志无 session-ball 相关报错（error.log 里那条是 DSH 自带 client-connection 的，与本插件无关）。
### 2b 里程碑 27：面板与对话区的轻微透明度（v0.12.25）

- 面板底：`#FFFFFFFF` → `#F0FFFFFF`（94% 白，透出一点点桌面）；
- 对话卡片底（“对话底色”）：`#FFF5F6F8` → `#E6F5F6F8`（90%）；
- 卡片里的白色控件（输入框、选项、行）`#FF → #E8`（91%），禁用输入框 `#E6`；
- 透明度只在元素 Fill 上，窗口仍是 `AllowsTransparency` 的 layered 窗口，不会影响点击穿透/角色；
- 预览合成：`_work/screenshots/ball-v2/translucent-preview.png`（深/浅两种桌面底色对比）。
### 2b 里程碑 28：头部待确认提示 + 最大高度滚动（v0.12.26）

1. **头部待确认提示**：面板头部标题右侧新增一枚小胶囊，显示「N 个待确认」（N = 宿主 `pendingCount`，
   老/外部状态文档回退为“带卡片的条目数”）；N=0 时隐藏。文案里的“个待确认”来自宿主 labels.pendingHint，
   球脚本保持纯 ASCII。
2. **最大高度 + 滚动**：面板高度继续“按内容伸缩、最高 panelHeight（默认 460）”；原来内容行是
   `Auto`，内容超高时会被裁掉且没有滚动条，现在是 `*` + `ScrollViewer`，超出即出现滚动条，
   不超出则面板自动缩到内容高度。实测：1 条内容 352×188，9 条内容 352×492（封顶）并出现滚动条。
3. 滚动条加了全局 Slim ScrollBar 样式（宽 6、透明底）。
### 2b 里程碑 29：启动位置专项修复 + 隔离实例验证（v0.12.27）

用户反馈「启动就给我看浮窗，还有一半在窗口外面」。用**隔离球实例**（独立运行目录 + 真实窗口测量 + 截屏）
复现并定位到 4 个叠加问题：

1. **宿主启动恢复 expanded=true** → 每次重启自动把面板弹出来。改为：位置照旧记忆，**展开状态不记忆，
   启动永远是球**（`loadWindow` 里 expanded 固定 false）。
2. **Apply-State 末尾遗留了一段“直接应用宿主坐标”的旧代码**：它每次状态都把 `Left/Top` 覆盖成宿主记住的
   **球点**，既不换算面板坐标也不夹紧 —— 面板开在右缘时右半屏被推到屏幕外（本次“一半在窗口外面”的根因）。
   已删除，并把位置应用统一收敛到一处：**先应用形状、再应用位置**（换算 + 夹紧 + 锚点一次完成）。
3. **位置可用性判定用错尺寸**：`Test-HostPositionUsable` 用当前窗口（面板）尺寸去判断“球点”，面板一开就把
   合法球点误判成放不下 → 改用球窗尺寸（ballSize+50）。
4. **`FirstPositionPending` 初始化行在前几次重构中丢失** → 没有记忆位置时不走“右侧居中”默认值；已补回。
   另新增 `Set-DefaultPanelPosition`：万一首帧就是展开态且无记忆位置，面板按右缘 12 / 垂直居中摆放。

验证（`_work/tmp/verify-startup.ps1`，真实窗口按 DPI 换算成 DIP 后与 1536×960 屏幕比对，全部 PASS）：

| 案例 | 形状 | 位置(DIP) | 结果 |
|---|---|---|---|
| 有记忆位置 · 收起 | 球 98×98 | 1388.8, 412.8 | PASS |
| 无记忆位置 · 收起 | 球 98×98 | 1426.4, 407.2（右侧居中） | PASS |
| 有记忆位置 · 展开 | 面板 352×492 | 1135.2, 412.8 | PASS |
| 贴边球点 · 展开 | 面板 352×492 | 1176, 468（夹回屏内） | PASS |
### 2b 里程碑 30：单击打不开面板（要点两下）修复 + 单次点击实测（v0.12.28）

现象：v0.12.27 后点球要两下才出面板；线上 `ball-v2.log` 里每次点击都留下
`mouse capture lost: drag cancelled, poll resumed`。

根因：上一版为防“拖动中鼠标捕获被抢走导致轮询停摆”，在 `LostMouseCapture` 里把 `$script:Dragging`
置回 false。但**非激活窗口上 CaptureMouse 失败/被释放时会立刻触发 LostMouseCapture**（每次点击都会），
于是 MouseDown 刚把 Dragging 置 true 就被清掉，MouseUp 走到 `if (-not Dragging) { return }`，面板不展开；
第二次点击偶然命中才打开。

修法：

1. `LostMouseCapture` **不再取消拖动**，只做“未在拖动时确保轮询在跑”；
2. 新增 1 秒一次看门狗：`-not Dragging -and poll 未启用` 就恢复轮询（替代原来的粗暴取消）；
3. MouseUp 一开始就恢复轮询，再判断拖动状态。

实测（`_work/tmp/click-test.ps1`，隔离实例 + 真实 mouse_event 单击）：窗 123×123 的球，**一次点击**
即展开为 440×235 的面板，日志无 capture-lost 噪声。`[PASS] first click opened the panel`。
### 2b 里程碑 31：点击输入框导致球进程重启（真崩溃）修复（v0.12.29）

现象：点面板里「写一句…」输入框，球消失又出现（进程重启）。宿主日志：
`ball exited (code=1)`，2 秒后自动重拉 —— 所以表现为“重启”。

用隔离实例 + 真实点击复现，stdout/stderr 抓到真凶：

```
使用“0”个参数调用“Run”时发生异常:“在此对象上找不到属性“Visibility”。”
  + [System.Windows.Threading.Dispatcher]::Run()
```

根因：PowerShell 的**延迟事件处理器**（.NET 事件回调里的 scriptblock）**看不到定义它的函数局部变量**。
`New-EntryView` 里 `$placeholder = New-Object TextBlock`，但处理器 `{ $placeholder.Visibility = 'Collapsed' }`
执行时 `$placeholder` 是 $null → `$null.Visibility` 抛异常 → `Dispatcher.Run()` 终止 → 进程退出 → 宿主重拉。
同类隐患也存在于问题卡片的选项/上一步/下一题/提交处理器（引用 `$optionState`/`$prevState`/`$nextState`/`$submitState`）。

修法：

1. 给 8 个引用函数局部变量的事件处理器加 `.GetNewClosure()`（输入框 TextChanged/GotKeyboardFocus/LostKeyboardFocus、
   选项行、上一步、下一题、提交），让它们捕获创建时的变量；
2. 加全局兜底：`$window.Dispatcher.Add_UnhandledException` 记录 `dispatcher error (handled)` 并标记 `Handled`，
   以后任何漏网的处理器异常都不会再杀掉球进程。

实测（`_work/tmp/input-crash2.ps1`，隔离实例 + 真实点击输入框）：进程 `exited=False`，stderr 空，
日志 `dispatcher error` 计数 0。
### 2b 里程碑 32：球上发的消息会话收不到（v0.12.30）

现象：在球上输入一句话点 ↑，界面显示发出，但会话端完全没收到，宿主日志里也没有任何 prompt 记录。

根因：球侧 `New-EntryView` 的视图状态里 `Target = ''` 初始化后**从未被赋值**；`Update-EntryView` 只更新了
标题/输入框/卡片，却漏了 `$View.Target = $Entry.target`。于是发送动作写成 `{kind:'prompt', target:'', ...}`，
宿主 `sendPrompt` 遇到空 target 直接 return —— 静默丢弃（没有任何日志）。

修法：

1. `Update-EntryView` 里补 `$View.Target = [string]$Entry.target`（发送/回车两条路径都读它）；
2. 宿主遇到空 target 不再静默：`prompt dropped: empty target (entry not mapped to a session)` 写日志。

验证（`_work/tmp/send-test.ps1`，隔离实例 + 真实点击 / 真实键盘输入）：

| 场景 | 结果 |
|---|---|
| 普通会话：点输入框、输入 `hi`、点 ↑ | `kind=prompt target=session-test-1 text=hi` ✅ |
| 新会话行：点输入框、输入 `hi`、点 ↑ | `kind=prompt target=new text=hi`（宿主走 createSession + prompt）✅ |
| 假宿主测试（新会话创建+发送链路） | PASS ✅ |
### 2b 里程碑 33：鼠标移入浮球显示点击手势（v0.12.31）

- `$ballView.Cursor = [System.Windows.Input.Cursors]::Hand`：指针移到球上时由箭头变成“点击手”；
  球体子元素默认继承父级 Cursor，所以不需要逐个设置；
- 验证（`_work/tmp/cursor-test.ps1`，隔离实例 + GetCursorInfo/LoadCursor）：球上光标句柄 == IDC_HAND ✅。
### 2b 里程碑 34：待审批用橙色，不跟错误共用红色（v0.12.32）

- 宿主 `STYLES.approval` 颜色 `#FFE0574B`（和 error 共用的红）→ **`#FFF08A24`（橙）**；
  球环、面板状态点、审批条目的状态条都随之变橙；error 仍是红色，两者不再混淆。
- 头部待审批胶囊文案：`个待确认` → **`个待审批`**（宿主 `LABELS.pendingHint`，预览模板同步）；
  胶囊配色也换成橙色系（`#FFFDF1E2` 底 / `#FFF3D3A2` 边 / `#FFD97706` 字），审批 chip 同步橙色。
- 渲染验证：`ball-panel.png`（胶囊“个待审批”、橙色）、`ball-approval-orange.png`（等待审批的球环为橙色）。
### 2b 里程碑 35：悬停游动其实没动过，改成直接动画（v0.12.33）

用户问“鼠标移入能游动吗”。复查发现 v0.12.23 的游动**从未真正生效**：

- `WhaleRotate` 这类 Freezable 用 `Storyboard.SetTarget()` 指向它时，动画不会报错也**不会动**
  （PowerShell 下 Storyboard 找不到该 target 的名字作用域）；
- 改成直接调用 `BeginAnimation`：
  - `$whaleRotate.BeginAnimation(RotateTransform.AngleProperty, …)`（-6°↔6°，620ms 往复）；
  - `$script:SwimTranslate.BeginAnimation(TranslateTransform.YProperty, …)`（±1.6px，520ms）；
  - `$bubbles.BeginAnimation(UIElement.OpacityProperty, …)`（0.45↔1，900ms）；
- 另补 `WhaleRotate` 的兜底查找（FindName 对 Freezable 不可靠，从 Whale 的 TransformGroup 里取）；
- 启动时若拿不到旋转 transform，写一条 `swim disabled: no whale rotate transform` 日志便于排查。

验证（`_work/tmp/swim-test.ps1`，隔离实例 + 真实鼠标移动 + 帧比对）：

| 状态 | 两帧差异（变化像素占比） |
|---|---|
| 指针在球外 | 0.00% |
| 指针在球上 | 1.71%（明显变化） → SWIM_DETECTED ✅ |