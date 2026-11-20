# 发布到 GitHub

> 仓库：<https://github.com/y1s2y3/dsh-floating-ball>

## 一、为什么要走 API，不是 `git push`

本机 DSH 沙箱里 `git` 的 schannel TLS 是坏的（`SEC_E_NO_CREDENTIALS`），`github.com:443`
也不稳定，所以 `git push` 会失败。能稳定访问的是 `api.github.com`，于是发布走
**GitHub Git Data API**：把整棵文件树做成 blobs → tree → commit → 移动 `main`。

## 二、发布步骤

```bash
# 1. 确保有 repo + workflow 权限的登录态（token 存在 Windows 凭据/keyring）
gh auth login --hostname github.com --git-protocol https --web --scopes repo,workflow

# 2. 生成文件清单（Node 里不能 spawn git，所以这一步在终端做）
git ls-files > .publish-files.txt

# 3. 推送 main、tag、release
node tools/publish-github.mjs
```

脚本是幂等的：重复跑会覆盖 `main`、更新同 tag 的 release，不会重复建 tag。

## 三、发了什么

| 动作 | 说明 |
|---|---|
| `main` 分支 | 全部文件（代码 / 资源 / 文档 / 工具），逐文件 sha256 不变的 base64 blob |
| `v1.0.1` | annotated tag（tag object → commit） |
| Release `v1.0.1 · 生产版（新宿主/新面板）` | 说明里含功能亮点、安装命令、非官方声明 |
| 仓库描述 / topics | 非官方声明 + `dsh` `dsh-plugin` `deepseek-harness` `floating-ball` `windows` `wpf` `overlay` `desktop` |

## 四、校验

脚本最后会自己核对：

① 远端文件树与本地 `git ls-files` 逐文件比对（missing / extra 都应为 0）；
② 远端 `main` 的 head 等于刚推的 commit；
③ release 通过 `GET /releases/tags/v0.11.0` 能读到。

手动复核：

```bash
gh api repos/y1s2y3/dsh-floating-ball --jq '.default_branch, .description'
gh api repos/y1s2y3/dsh-floating-ball/git/trees/main?recursive=1 --jq '.tree | map(select(.type=="blob")) | length'
gh api repos/y1s2y3/dsh-floating-ball/releases/latest --jq '.tag_name, .html_url'
```

## 五、注意

① **npm 还没发**：`dsh plugin add dsh-floating-ball` 要等 npm 上架后才好用；现在装 GitHub 版用 `github:y1s2y3/dsh-floating-ball`。
② 每次发新版：改 `package.json` 的 `version`、把脚本顶部 `VERSION` 一起改掉，再跑一次发布。
③ API 发布的 commit 与本地 git 的 commit sha **不同**（本地是另一条历史）；本地只作为源，`main` 以远端为准。以后如果要让本地和远端同源，正常终端里 `git push --force` 即可（内容一致）。
