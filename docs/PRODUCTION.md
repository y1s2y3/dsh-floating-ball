# 生产状态与回滚（v1.0.0）

## 一、当前生产配置

- 插件版本：**1.0.1**（原版名字 `dsh-floating-ball` 已让给新版；旧版备份改名 `dsh-session-ball-plugin-original`）（`package.json`）
- 引擎：**v2**（`lib/floating-ball-v2.js` + `resources/ball-v2.ps1`，球/面板均为自研新版）
- 入口：`lib/session-ball.js` 的 `resolveEngine()` —— **默认返回 v2**，不再依赖 profile 里写 `engine`。
- Profile 配置：`~/.dsh/profiles/desktop/cordis.patch.yml` 的 `- id: session-ball` 块（只保留一份）。

## 二、原版备份

| 内容 | 位置 |
|---|---|
| 原版宿主 | `legacy/original-plugin/session-ball.js`（= `lib/session-ball-upstream.js`） |
| 原版球脚本 | `legacy/original-plugin/ball.ps1`（= `resources/ball.ps1`） |
| 备份说明 | `legacy/original-plugin/README.md` |
| Git 标签 | `legacy-original-plugin`（备份提交）、`v1.0.0`（生产版本） |

## 三、回滚

### 快速回滚（只换引擎，不换文件）

`cordis.patch.yml`：

```yaml
- id: session-ball
  name: dsh-floating-ball
  config:
    engine: upstream
    enabled: true
    ballSize: 48
```

完全退出并重启 DSH Desktop。日志里出现 `engine=upstream` 即旧版在跑。

### 完全回滚（连入口一起还原）

把 `legacy/original-plugin/session-ball.js` 与 `ball.ps1` 分别复制回
`lib/session-ball.js`、`resources/ball.ps1`，然后 `node deploy.mjs` 并重启。

## 四、生产验收命令

```powershell
cd dsh-floating-ball
node test/host-v2.mjs        # 宿主假 ctx 测试
node test/dispatch.mjs       # 入口默认引擎 = v2，legacy 仍可加载
node tools/check-brand.mjs   # 品牌/图标一致性
node deploy.mjs              # 部署到 profile（需 danger-full-access 之外无特殊权限）
```

部署后在日志 `%APPDATA%\DSH Desktop\logs\host\dsh-<日期>.log` 里应看到
`engine=v2`；运行目录 `%LOCALAPPDATA%\dsh-session-ball\default\ball.log` 里应为
`host started (ball-v2)`。

## 五、2026-11-20 命名记录

- **新版**：包名 `dsh-floating-ball`（v1.0.1），延续原版的名字；Profile 安装目录同步为
  `~/.dsh/profiles/desktop/node_modules/dsh-floating-ball`。
- **旧版备份**：保留原名加后缀 `dsh-session-ball-plugin-original`，位于
  `legacy/dsh-session-ball-plugin-original/`，git 标签 `legacy-original-plugin` 不变。
- GitHub 仓库地址仍然是 `github.com/y1s2y3/dsh-floating-ball`（仓库名未改）。

### 更名过程（最终态）

1. v1.0.0：`dsh-floating-ball` → 转生产；
2. v1.0.1：短暂改为 `dsh-session-ball-plugin`（沿用原版名），原版备份改名 `dsh-session-ball-plugin-original`；
3. **v1.0.2（当前）**：包名最终定为 **`dsh-floating-ball`**，与 GitHub 仓库同名；原版备份名保持
   `dsh-session-ball-plugin-original` 不变。
