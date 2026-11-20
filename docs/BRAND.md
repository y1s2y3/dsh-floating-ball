# 视觉封版说明（v0.11.0）

> 从这一版起，**桌面球、插件图标、公众号封面**是同一只鲸鱼，不再各改各的。
> 任何一处要改，三处一起改，改完跑 `node tools/check-brand.mjs` 必须 PASS。

## 一、定稿形象

**一只蓝渐变悬浮球 + 白色原创鲸鱼 + 三颗上浮小气泡。**

① **鲸鱼是原创轮廓**，不是 DeepSeek 商标图形：身体/胸鳍/背鳍三块填充 + 一只蓝色眼睛；
**没有微笑嘴、没有腹线**（这两条在白身体上会读成「第二张嘴」，2026-11-20 定稿时去掉）。
② **尾鳍上扬**：尾鳍尖端在本地坐标 y=10 / y=57，鲸鱼有往上浮的动势。
③ **球体**：径向渐变 `#B0CAFF → #749AFD → #4A7AE8 → #345CC8`，左上高光、底部内阴影、细边。
④ **气泡**：右上三颗白色小圆点（桌面球上是三层 alpha 的组合）。

## 二、三处各自用哪份文件

| 用途 | 文件 | 说明 |
|---|---|---|
| 插件图标（市场/README/封面素材） | `assets/icon.svg` + `assets/icon-1024…16.png` | `tools/render-icon.ps1` 渲染；改鲸鱼路径后重跑脚本 |
| 桌面球上的鲸鱼 | `resources/ball.ps1` 里的 `BallMark`（Viewbox + 3 块 Path + 眼睛 + 气泡 + 阴影） | 参数在 `ball.ps1` 顶部五个常量 |
| 公众号封面 | `assets/cover-wechat-900x383.png` | `tools/make-cover.py` 读图标生成；右上角固定「非官方 · 社区插件」 |

## 三、球上鲸鱼的五个常量

`resources/ball.ps1` 顶部：

```powershell
$script:BallMarkScaleFactor = 0.68   # 鲸鱼占球径的比例
$script:BallMarkFlip = 1             # -1 = 水平镜像
$script:BallMarkAngle = 0            # 旋转角度（负值 = 尾巴上抬）
$script:BallMarkShadow = 1           # 软阴影
$script:BallMarkBubbles = 1          # 三颗上浮气泡
```

改完任一项，`node deploy.mjs` 部署、球几秒内重启；**不要只改球不改图标**，反之亦然。

## 四、非官方标注（三处，不随封版删）

① 图标本体保持干净：**不放任何「非官方」小字**（48px 下不可读）。
② 名称与描述：`package.json` 的 `description` / `meta.title` / `meta.description`、README 首屏，都写「非官方 · 社区自制，与 DeepSeek / DeepSeek Harness 官方无关」。
③ 公众号封面右上角「非官方 · 社区插件」小标签；推文图注写「非官方社区插件」。

## 五、封版检查

```bash
node tools/check-brand.mjs
```

校验内容：

① 鲸鱼路径在 `assets/icon.svg`、`resources/ball.ps1`（白鲸 + 阴影两份）、`tools/render-icon.ps1` 三处逐字符一致；
② 嘴（`M 7 56`）和腹线（`M 30 66`）没有在绘制代码里复活；
③ `icon-1024…16.png` 都存在且尺寸正确，封面存在；
④ 打印鲸鱼路径指纹（sha256 前 16 位），方便和 release note 对照。

## 六、重新生成素材

```bash
# 图标 PNG（读 assets/icon.svg 同源的路径）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\render-icon.ps1

# 公众号封面 + 多尺寸预览图
python tools\make-cover.py
```

## 七、字体与授权

封面图（`assets/cover-wechat-900x383.png`）与尺寸预览图（`assets/preview-sizes.png`）里的文字，
用的是仓库自带的 **Noto Sans SC 子集**（SIL Open Font License 1.1）：

- `assets/fonts/NotoSansSC-Regular-subset.ttf` / `NotoSansSC-Bold-subset.ttf`：由系统 Noto Sans SC 可变字体
  实例化到 400/700 字重，并只保留封面用到的 147 个字形；子集字体改名为 “Noto Sans SC Media Subset”（OFL 对修改版不使用 Reserved Font Name 的要求）。
- `assets/fonts/OFL.txt`：许可证全文 + 源字体版权声明（© 2014-2021 Adobe，Reserved Font Name “Source”）。
- 重新生成：`python tools/build-font-subset.py`（改文案后要同步脚本里的 CHARSET），再 `python tools/make-cover.py`。

桌面球/面板的 UI 字体随包分发：`assets/fonts/DshUiSans-*.ttf`（由 DSH Desktop 自带的 Inter
拉丁子集派生的 400/500/600 静态实例，子集到界面用到的字符，改名为 “DshUiSans”），
宿主启动时把它物化到运行目录，球脚本用 `file:///...#DshUiSans` 载入；中文由 Windows 字体回退补齐（微软雅黑）。
因此球上的拉丁字形与 DSH 界面（Inter）一致，且不再依赖系统里恰好装了某个 UI 字体。
