# 引擎说明（生产 v2 / 旧宿主 upstream 仅作回滚）

> **2026-11-20 起：v2 为生产默认。** 插件版本 v1.0.0，正常安装/不写 `engine` 就跑 v2。
> 只有显式写 `engine: upstream` 才会启用旧宿主（旧球脚本 `resources/ball.ps1`）。
> 原版宿主与球脚本已逐字备份到 `legacy/original-plugin/`，回滚步骤见 `docs/PRODUCTION.md`。

## ① 切换方法

`~/.dsh/profiles/desktop/cordis.patch.yml` 里 `- id: session-ball` 的 `config`：

```yaml
- id: session-ball
  name: dsh-session-ball-plugin
  config:
    # 不写 engine = 生产 v2；只有写 engine: upstream 才回滚到旧版
    enabled: true
    ...
```

改完**完全退出并重启 DSH Desktop**（宿主代码有 ESM 缓存，热重载不会换宿主）。

## ② 重启后检查清单（v2）

① **球出现了吗**：右下/上次位置出现 48px 球；球颜色 = 聚合状态（灰空闲 / 蓝输出中 / 琥珀待处理 / 红出错）。
② **点球展开**：出现白面板 + 浅灰会话卡、2px 低饱和左色条、无 footer、无统计。
③ **分组**：`等你处理`（审批/异常）→ `运行中` → `已完成 · 未读`；chip 为「待审批 / 异常 / 输出中 / 未读」。
④ **回一句话**：在条目输入框打字回车（或点 ↑），网页端会话里应出现同一条消息；发出后条目出现「已发出」回执。
⑤ **审批**：让模型请求一次审批，球上出现「允许一次 / 拒绝」按钮，点完网页端弹窗应跟着关闭（谁先答谁生效）。
⑥ **出错**：让模型出错，球变红；条目出现「知道了」，点完红色消失、条目保留；点 × 收走条目。
⑦ **拖动与记忆**：拖动球/面板，关掉再重启，位置应记住。
⑧ **日志证据**：`%LOCALAPPDATA%\dsh-session-ball\default\ball.log` 里要有 `[host] host started (ball-v2)`；
宿主日志 `%APPDATA%\DSH Desktop\logs\host\dsh-<日期>.log` 里应有 `engine=v2`。

## ③ 回滚

- 最快：把 `engine: v2` 改成 `engine: upstream`（或删掉本行），重启 Desktop；
- 或者恢复部署前备份：`backups/<时间戳>/dsh-session-ball-plugin` 复制回
  `~/.dsh/profiles/desktop/node_modules/dsh-session-ball-plugin`，再重启；
- profile 配置备份：`~/.dsh/profiles/desktop/cordis.patch.yml.bak-20261120-1443`。

## ④ 已补上的能力（v0.12.1）

① **「＋ 新会话」可用**：点 ＋ 出现一条「新会话」本地行，输入第一句话回车即在该目录下新建会话并把话发出去；
   右上 `×` 取消。新会话落在「最近活跃会话的目录」，还没有工作区选择列表。
② **提问全在球上答**：多题 + 选项 + 自由文本都支持，每题选一项或填一句，点「作答」一次提交；
   没答全时按钮下方提示「每个问题都要选一项或填一句」。
③ **审批题面用真实理由**：优先显示 `displayReason`（中文），工具名降为一行灰色小字（`工具：desktop_step`）。
