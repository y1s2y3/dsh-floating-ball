/**
 * 把本仓库发布到 GitHub：y1s2y3/dsh-floating-ball。
 *
 * 为什么不用 git push：本机（DSH 沙箱）里 git 的 schannel TLS 是坏的
 * （SEC_E_NO_CREDENTIALS），github.com:443 也不稳定；api.github.com 可以访问，
 * 所以走 GitHub API 的 Git Data API 推送整棵树、tag 和 release。
 *
 * 前置：
 *   gh auth login           # 需要 repo + workflow 权限
 *   git ls-files > .publish-files.txt
 *
 * 用法：
 *   node tools/publish-github.mjs            # 读仓库根目录的 .publish-files.txt
 *   node tools/publish-github.mjs <文件清单>  # 指定清单
 *
 * 幂等：重复运行会覆盖 main 分支、更新同 tag 的 release，不会重复建 tag。
 */
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const OWNER = 'y1s2y3'
const NAME = 'dsh-floating-ball'
const BRANCH = 'main'
const VERSION = 'v0.11.0'
const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)))

const token = process.env.GH_TOKEN || (() => {
  try { return execFileSync('gh', ['auth', 'token'], { encoding: 'utf8' }).trim() } catch { return '' }
})()
if (!token) throw new Error('missing GH_TOKEN（先 gh auth login，或 export GH_TOKEN）')

const listFile = process.argv[2] ? path.resolve(process.argv[2]) : path.join(ROOT, '.publish-files.txt')
if (!fs.existsSync(listFile)) throw new Error(`missing file list: ${listFile}（git ls-files > .publish-files.txt）`)

const api = async (method, endpoint, body) => {
  const res = await fetch(`https://api.github.com${endpoint}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'dsh-floating-ball-publish',
      ...(body ? { 'Content-Type': 'application/json' } : {})
    },
    body: body ? JSON.stringify(body) : undefined
  })
  const text = await res.text()
  let parsed = null
  try { parsed = text ? JSON.parse(text) : null } catch { parsed = text }
  return { status: res.status, body: parsed }
}
const must = async (method, endpoint, body) => {
  const result = await api(method, endpoint, body)
  if (result.status >= 300) {
    throw new Error(`${method} ${endpoint} -> ${result.status}: ${typeof result.body === 'string' ? result.body.slice(0, 300) : JSON.stringify(result.body).slice(0, 300)}`)
  }
  return result.body
}

const files = fs.readFileSync(listFile, 'utf8').split(/\r?\n/).map((line) => line.trim()).filter(Boolean)
console.log('files to publish:', files.length)

const repo = await must('GET', `/repos/${OWNER}/${NAME}`)
const branch = repo.default_branch || BRANCH
console.log('repo:', repo.full_name, '| default branch:', branch)

// 1) 空仓库先用 Contents API 落一个初始 commit（Git Data API 对空仓库的 blob 会报 409）
const refResult = await api('GET', `/repos/${OWNER}/${NAME}/git/ref/heads/${branch}`)
let refSha
if (refResult.status === 200) {
  refSha = refResult.body.object.sha
} else {
  console.log('repo has no ref yet; seeding an initial commit through the Contents API')
  const readme = fs.readFileSync(path.join(ROOT, 'README.md'), 'utf8')
  const seeded = await must('PUT', `/repos/${OWNER}/${NAME}/contents/README.md`, {
    message: 'chore: initial commit',
    content: Buffer.from(readme, 'utf8').toString('base64'),
    branch
  })
  refSha = seeded.commit.sha
}
console.log('base commit:', refSha)

// 2) blobs
const treeItems = []
for (const file of files) {
  const buffer = fs.readFileSync(path.join(ROOT, file))
  const blob = await must('POST', `/repos/${OWNER}/${NAME}/git/blobs`, {
    content: buffer.toString('base64'),
    encoding: 'base64'
  })
  treeItems.push({ path: file, mode: '100644', type: 'blob', sha: blob.sha })
}
console.log('blobs uploaded:', treeItems.length)

// 3) tree + commit
const tree = await must('POST', `/repos/${OWNER}/${NAME}/git/trees`, { tree: treeItems })
const commit = await must('POST', `/repos/${OWNER}/${NAME}/git/commits`, {
  message: `release: ${VERSION} — 视觉封版（原创鲸鱼，图标/封面/桌面球统一）\n\n- 面板只显示待审核/异常/未读完成/进行中四类会话并按此排序\n- 拖动坐标修复（高 DPI 下不再越拖越偏）\n- 输入框缩小、统计行与拖动提示隐藏\n- 图标/封面/桌面球统一为同一只原创鲸鱼（无嘴、翘尾）`,
  tree: tree.sha,
  parents: [refSha]
})
console.log('commit:', commit.sha)

// 4) 移动分支
await must('PATCH', `/repos/${OWNER}/${NAME}/git/refs/heads/${branch}`, { sha: commit.sha, force: true })
console.log('branch', branch, '->', commit.sha)

// 5) annotated tag（已存在则复用）
const tagRef = await api('GET', `/repos/${OWNER}/${NAME}/git/ref/tags/${VERSION}`)
if (tagRef.status === 200) {
  console.log('tag already exists:', VERSION, tagRef.body.object.sha)
} else {
  const tagObject = await must('POST', `/repos/${OWNER}/${NAME}/git/tags`, {
    tag: VERSION,
    message: `dsh-floating-ball ${VERSION}：视觉封版（原创鲸鱼，图标/封面/桌面球统一）`,
    object: commit.sha,
    type: 'commit'
  })
  await must('POST', `/repos/${OWNER}/${NAME}/git/refs`, { ref: `refs/tags/${VERSION}`, sha: tagObject.sha })
  console.log('tag created:', VERSION, tagObject.sha)
}

// 6) release（存在则更新说明）
const releaseBody = [
  '**非官方 · 社区自制**（与 DeepSeek / DeepSeek Harness 官方无关）。',
  '',
  'dsh-floating-ball 是 DSH 的 Windows 置顶悬浮球：所有会话的整体状态一眼可见 —— 几个在跑、谁在等你、有没有出错；**只要有会话在输出，球就是蓝色并缓慢呼吸，安静下来就是跑完了**。展开面板后每条会话自带输入框与卡片，可以直接在球上回话、批准、答问题。',
  '',
  '### 本版亮点',
  '- 视觉封版：桌面球 / 插件图标 / 公众号封面统一为同一只原创鲸鱼（无嘴、尾鳍上扬、三颗上浮气泡）',
  '- 面板只显示需要你处理的会话：待审核 → 异常 → 有未读已完成 → 进行中，其余隐藏',
  '- 「未读完成」本地记录（unread.json），发送 / 知道了 / 关闭即视为已读',
  '- 输入框更紧凑；聚合统计行与拖动提示隐藏',
  '- 修复高 DPI（125%）下拖球越拖越偏',
  '',
  '### 安装',
  '在 DSH Desktop 内置终端里：',
  '```',
  'dsh plugin --profile desktop add github:y1s2y3/dsh-floating-ball',
  '```',
  '装完重启 DSH Desktop。Windows 专用（PowerShell + WPF），无额外进程依赖。',
  '',
  '### 说明',
  '- 图标为原创鲸鱼轮廓，不是 DeepSeek 商标图形；「非官方」标注见 README。',
  '- 本版视觉参数见 `docs/BRAND.md`，校验：`node tools/check-brand.mjs`。'
].join('\n')
const existingRelease = await api('GET', `/repos/${OWNER}/${NAME}/releases/tags/${VERSION}`)
let release
if (existingRelease.status === 200) {
  release = await must('PATCH', `/repos/${OWNER}/${NAME}/releases/${existingRelease.body.id}`, {
    name: `${VERSION} · 视觉封版`,
    body: releaseBody
  })
  console.log('release updated:', release.html_url)
} else {
  release = await must('POST', `/repos/${OWNER}/${NAME}/releases`, {
    tag_name: VERSION,
    name: `${VERSION} · 视觉封版`,
    body: releaseBody,
    draft: false,
    prerelease: false
  })
  console.log('release created:', release.html_url)
}

// 7) 仓库描述 + topics
await must('PATCH', `/repos/${OWNER}/${NAME}`, {
  description: '非官方 DSH 悬浮球（Windows 置顶）：任务跑完没有，一眼就知道。dsh-floating-ball · 非官方社区自制',
  has_issues: true,
  has_wiki: false,
  has_projects: false
})
await must('PUT', `/repos/${OWNER}/${NAME}/topics`, {
  names: ['dsh', 'dsh-plugin', 'deepseek-harness', 'floating-ball', 'windows', 'wpf', 'overlay', 'desktop']
})
console.log('repo description + topics updated')

// 8) 校验
const remoteTree = await must('GET', `/repos/${OWNER}/${NAME}/git/trees/${branch}?recursive=1`)
const remoteFiles = remoteTree.tree.filter((item) => item.type === 'blob').map((item) => item.path).sort()
const localFiles = [...files].sort()
const missing = localFiles.filter((file) => !remoteFiles.includes(file))
const extra = remoteFiles.filter((file) => !localFiles.includes(file))
console.log('remote files:', remoteFiles.length, '| local:', localFiles.length)
console.log('missing on remote:', missing.length ? missing : 'none')
console.log('extra on remote:', extra.length ? extra : 'none')
const remoteRef = await must('GET', `/repos/${OWNER}/${NAME}/git/ref/heads/${branch}`)
console.log('remote head:', remoteRef.object.sha, '| matches pushed commit:', remoteRef.object.sha === commit.sha)
