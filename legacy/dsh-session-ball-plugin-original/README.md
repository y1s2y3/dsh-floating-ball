# 原版插件备份（已改名：dsh-session-ball-plugin-original）

本目录是**原版插件**（旧名 `dsh-session-ball-plugin`，现改名 `dsh-session-ball-plugin-original` 以让出名字给新版）（宿主 `session-ball.js` + 球脚本 `ball.ps1`）的只读备份，
用于：

- 回滚到旧版行为（把 Profile 配置里 `engine` 设为 `upstream` 即可，无需还原文件）；
- 对比新宿主/新球的实现；
- 万一新版不可用时，按下面的“完全回滚”步骤恢复。

## 来源

- 上游包：`dsh-session-ball-plugin`（npm，作者 **EvilOfRed**，MIT，2026）
- 本仓库从该包 fork，改名为 `dsh-session-ball-plugin`，并重写了宿主（`lib/floating-ball-v2.js`）
  与球/面板（`resources/ball-v2.ps1`）。
- 备份时间：2026-11-20（新版 v1.0.0 转生产时）。

## 文件

| 文件 | 说明 |
|---|---|
| `session-ball.js` | 原版宿主（即仓库里的 `lib/session-ball-upstream.js`，逐字备份） |
| `ball.ps1` | 原版球脚本（即仓库里的 `resources/ball.ps1`，含此前本地做过的视觉改动） |

## 回滚方式

### 方式 A：只切回旧引擎（推荐，最快）

`~/.dsh/profiles/desktop/cordis.patch.yml` 里把 `session-ball` 的 `config` 改成：

```yaml
- id: session-ball
  name: dsh-session-ball-plugin
  config:
    engine: upstream
    enabled: true
    ballSize: 48
```

完全退出并重启 DSH Desktop。新宿主不会再启动，原版 `ball.ps1` 照旧工作。

### 方式 B：完全还原原版文件

把本目录的 `session-ball.js` 复制为 `lib/session-ball.js`、`ball.ps1` 复制为
`resources/ball.ps1`，然后 `node deploy.mjs` 部署并重启 Desktop。

> 注意：方式 B 会覆盖掉新入口的分发逻辑（生产默认已是 v2），只有确认要整体退回旧版时才用。
