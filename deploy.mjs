#!/usr/bin/env node
/**
 * 把本目录的 dsh-floating-ball 同步到本机 DSH Desktop 的 desktop profile，
 * 并让「球」用上新脚本。
 *
 * 做四件事：
 *   ①  逐文件 sha256 比对，找出本目录与 profile 里那份的差异；
 *   ②  把 profile 里的旧版本整份备份到 <repo>/backups/<时间戳>/；
 *   ③  复制 package.json / cordis.patch.yml / README.md / LICENSE / icon.svg / lib / resources，
 *      并补登记 profile 的 dependencies 与 dsh.profile.bundles（只补缺失，不改已有版本号）；
 *   ④  球脚本变了就重启球：球是独立的 powershell.exe + WPF 进程，宿主每一拍都盯着它，
 *      进程一消失（约 2 秒内）就用**当前**的 resources/ball.ps1 重新拉起 —— 所以
 *      「结束球进程」就是让新外观生效的方式，不需要重启 DSH Desktop。
 *      拉起来之后脚本会核对：运行目录里出现的新脚本文件名，是否就是本次部署内容的 sha1。
 *
 * 用法：
 *   node deploy.mjs              同步（球脚本有变化时自动重启球）
 *   node deploy.mjs --dry-run    只打印将要做什么，不写任何文件
 *   node deploy.mjs --no-restart 只复制，不重启球（下次宿主重启时才生效）
 *   node deploy.mjs --restart-only  不同步，只重启一次球（球卡住/想立刻重看效果时）
 *
 * 注意：要写 ~/.dsh 与结束别的进程，DSH 会话沙箱里需要危险全权限；
 *       最省事的是在普通终端运行，或双击 deploy.cmd（沙箱之外）。
 */
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const ROOT = path.dirname(fileURLToPath(import.meta.url))
const PKG_NAME = process.env.DSH_INSTALL_NAME || 'dsh-floating-ball'
const DRY_RUN = process.argv.includes('--dry-run')
const NO_RESTART = process.argv.includes('--no-restart')
const RESTART_ONLY = process.argv.includes('--restart-only')

/** 要同步的条目：文件按原样复制，目录整棵复制。 */
const ENTRIES = ['package.json', 'cordis.patch.yml', 'README.md', 'LICENSE', 'assets', 'lib', 'resources']

const profileDir = process.env.DSH_PROFILE_DIR
  ? path.resolve(process.env.DSH_PROFILE_DIR)
  : path.join(os.homedir(), '.dsh', 'profiles', 'desktop')
const modulesDir = path.join(profileDir, 'node_modules')
const target = path.join(modulesDir, PKG_NAME)
const profilePkgPath = path.join(profileDir, 'package.json')
const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'))

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
}

function timestamp() {
  const now = new Date()
  const pad = (value) => String(value).padStart(2, '0')
  return (
    now.getFullYear() + pad(now.getMonth() + 1) + pad(now.getDate()) + '-' +
    pad(now.getHours()) + pad(now.getMinutes()) + pad(now.getSeconds())
  )
}

/** 列出某个目录下将要同步的相对路径（POSIX 风格，便于跨平台比较）。 */
function listSourceFiles() {
  const out = []
  const walk = (abs, rel) => {
    const stat = fs.statSync(abs)
    if (stat.isDirectory()) {
      for (const name of fs.readdirSync(abs).sort()) walk(path.join(abs, name), rel ? rel + '/' + name : name)
    } else {
      out.push(rel)
    }
  }
  for (const entry of ENTRIES) {
    const abs = path.join(ROOT, entry)
    if (!fs.existsSync(abs)) {
      console.error('[错误] 源文件缺失：' + abs)
      process.exit(1)
    }
    if (fs.statSync(abs).isDirectory()) walk(abs, entry)
    else out.push(entry)
  }
  return out
}

function copyTree(source, destination) {
  fs.mkdirSync(destination, { recursive: true })
  for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
    const from = path.join(source, entry.name)
    const to = path.join(destination, entry.name)
    if (entry.isDirectory()) copyTree(from, to)
    else {
      if (fs.existsSync(to)) {
        try { fs.chmodSync(to, 0o666) } catch { /* 只读文件先放开写权限，失败就交给 copyFile 报错 */ }
      }
      fs.copyFileSync(from, to)
    }
  }
}

/** 球进程的运行时目录（宿主按 profile 名分目录，本机是 default）。 */
function runtimeDirs() {
  const local = process.env.LOCALAPPDATA ?? path.join(os.homedir(), 'AppData', 'Local')
  const root = path.join(local, 'dsh-session-ball')
  if (!fs.existsSync(root)) return []
  return fs.readdirSync(root)
    .map((name) => path.join(root, name))
    .filter((candidate) => {
      try { return fs.statSync(candidate).isDirectory() } catch { return false }
    })
}

/** 宿主把球脚本按内容 sha1 的前 12 位物化成 <sha1-12>-ball.ps1。 */
function expectedScriptName() {
  const installed = path.join(target, 'resources', 'ball.ps1')
  const hash = crypto.createHash('sha1').update(fs.readFileSync(installed)).digest('hex').slice(0, 12)
  return hash + '-ball.ps1'
}

/**
 * 结束球进程，等宿主用当前 resources/ball.ps1 重新拉起，然后核对运行目录里的脚本名。
 * @returns {Promise<'restarted'|'not-running'|'failed'>}
 */
async function restartBall() {
  const script = path.join(ROOT, 'tools', 'restart-ball.ps1')
  if (!fs.existsSync(script)) {
    console.log('没找到 tools/restart-ball.ps1，跳过重启。')
    return 'failed'
  }
  const expected = expectedScriptName()
  // Remember how much each ball.log had before the kill: the restarted ball always appends a
  // new "ball started ... script=<sha1-12>-ball.ps1" line, and that line -- not the file mtime,
  // because the same content hash reuses the same file name -- is the proof that the CURRENT
  // script is the one that came up.
  const logs = []
  for (const dir of runtimeDirs()) {
    const logPath = path.join(dir, 'ball.log')
    if (!fs.existsSync(logPath)) continue
    logs.push({ dir, logPath, size: fs.statSync(logPath).size })
  }
  const result = spawnSync(
    'powershell.exe',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script],
    { stdio: 'inherit' }
  )
  if (result.status === 2) {
    console.log('没有找到球窗口（球可能没在运行，或插件未启用）。')
    return 'not-running'
  }
  if (result.status !== 0) {
    console.log('结束球进程失败（exit ' + result.status + '）。沙箱里需要危险全权限；也可以手动重启 DSH Desktop。')
    return 'failed'
  }

  // The host notices the child is gone on its next 120ms tick and usually restarts it within
  // 2~3 seconds; give it a little more before checking.
  await sleep(4500)
  let startedLine = ''
  for (const entry of logs) {
    try {
      const size = fs.statSync(entry.logPath).size
      if (size <= entry.size) continue
      const fd = fs.openSync(entry.logPath, 'r')
      const buffer = Buffer.alloc(size - entry.size)
      fs.readSync(fd, buffer, 0, buffer.length, entry.size)
      fs.closeSync(fd)
      const added = buffer.toString('utf8')
      const lines = added.split(/\r?\n/).filter((line) => line.includes('ball started'))
      const last = lines[lines.length - 1] ?? ''
      if (last !== '') startedLine = last.trim()
    } catch { /* a log we cannot read changes nothing */ }
  }
  const scriptFile = runtimeDirs()
    .map((dir) => path.join(dir, expected))
    .find((candidate) => fs.existsSync(candidate))
  if (scriptFile) console.log('球的运行脚本：' + scriptFile)
  if (startedLine !== '') {
    console.log('ball.log 新行：' + startedLine)
    if (!startedLine.includes(expected)) {
      console.log('警告：刚启动的球用的不是本次部署的脚本（期望 ' + expected + '），请检查 profile 里的文件。')
      return 'failed'
    }
    console.log('球已用当前脚本重启（新启动的 ball.log 行指向本次部署内容的 sha1）。')
    return 'restarted'
  }
  console.log('没有等到新的「ball started」行：球可能还没被拉起（稍等几秒看球有没有出现），或重启 DSH Desktop。')
  return 'failed'
}

/**
 * Preflight for resources/ball.ps1, before anything is copied:
 *
 *  * the script must be pure ASCII (Windows PowerShell 5.1 decodes a .ps1 without a BOM as the
 *    ANSI code page, so one Chinese character in it corrupts the file at runtime);
 *  * every XML comment inside the XAML here-string must obey the XML rule "no -- inside a
 *    comment, no - right before the closing -->". A stray "--" in a comment throws at
 *    [xml]$xaml; measured twice: the ball died on startup and the host gave up restarting it
 *    after five exits in five minutes.
 *
 * The XAML itself is not parsed here (deploy has no XML parser); these are the two authoring
 * mistakes that actually shipped and broke the ball, and they are cheap to catch.
 */
function validateBallScript() {
  const file = path.join(ROOT, 'resources', 'ball.ps1')
  const text = fs.readFileSync(file, 'utf8')
  const nonAscii = text.match(/[^\x00-\x7F]/)
  if (nonAscii) {
    throw new Error('resources/ball.ps1 含非 ASCII 字符 ' + JSON.stringify(nonAscii[0]) + '：球脚本必须纯 ASCII')
  }
  const open = "$xaml = @'"
  const start = text.indexOf(open)
  const end = start < 0 ? -1 : text.indexOf("'@", start)
  if (start < 0 || end < 0) throw new Error('resources/ball.ps1 里找不到 XAML here-string（$xaml = @\' … \'@）')
  const xaml = text.slice(start + open.length, end)
  for (const match of xaml.matchAll(/<!--([\s\S]*?)-->/g)) {
    const body = match[1]
    const trimmed = body.replace(/\s+$/, '')
    if (body.includes('--') || trimmed.endsWith('-')) {
      throw new Error(
        'XAML 注释里不能出现 “--” 或以 “-” 结尾（XML 规范），修复后再部署。出问题的注释：' +
        body.replace(/\s+/g, ' ').trim().slice(0, 80)
      )
    }
  }
  return { xamlChars: xaml.length }
}

if (!fs.existsSync(profilePkgPath)) {
  console.error('[错误] 找不到 DSH desktop profile：' + profilePkgPath)
  console.error('       如果 profile 不在默认位置，用环境变量指定：DSH_PROFILE_DIR=<profile 目录> node deploy.mjs')
  process.exit(1)
}

try {
  const checked = validateBallScript()
  console.log('预检 resources/ball.ps1：纯 ASCII、XAML 注释合法（XAML ' + checked.xamlChars + ' 字符）')
} catch (error) {
  console.error('[预检失败] ' + error.message)
  console.error('       没有复制任何文件，profile 保持原样。')
  process.exit(1)
}

if (RESTART_ONLY) {
  if (NO_RESTART) {
    console.error('[错误] --restart-only 与 --no-restart 相互矛盾。')
    process.exit(1)
  }
  if (DRY_RUN) {
    console.log('--dry-run：本来会结束球进程并让宿主用当前 profile 里的 ball.ps1 重新拉起它，现在不做。')
    process.exit(0)
  }
  await restartBall()
  process.exit(0)
}

const files = listSourceFiles()
const changed = []
for (const rel of files) {
  const source = path.join(ROOT, rel)
  const destination = path.join(target, rel)
  const before = fs.existsSync(destination) ? sha256(destination) : null
  const after = sha256(source)
  if (before !== after) changed.push({ rel, kind: before === null ? '新增' : '修改' })
}

const ballChanged = changed.some((item) => item.rel === 'resources/ball.ps1')
const hostChanged = changed.some((item) => item.rel.startsWith('lib/'))
const otherChanged = changed.some((item) => item.rel !== 'resources/ball.ps1' && !item.rel.startsWith('lib/'))

console.log('源目录：' + ROOT)
console.log('目标：  ' + target + (DRY_RUN ? '   （--dry-run，不会写入）' : ''))

if (changed.length === 0) {
  console.log('')
  console.log('本目录与 profile 里那份逐文件 sha256 一致，没有需要同步的内容。')
  console.log('只想让球重启一遍看效果：node deploy.mjs --restart-only')
  process.exit(0)
}

console.log('')
console.log('有变化的文件（' + changed.length + ' 个）：')
for (const item of changed) console.log('  ' + item.kind + '  ' + item.rel)

if (DRY_RUN) {
  console.log('')
  console.log('--dry-run：到此为止，没有写任何文件。')
  console.log('去掉 --dry-run 再跑一次即可真正同步。')
  process.exit(0)
}

// ① 备份 profile 里的旧版本
if (fs.existsSync(target)) {
  const backupDir = path.join(ROOT, 'backups', timestamp())
  copyTree(target, path.join(backupDir, PKG_NAME))
  console.log('')
  console.log('已备份 profile 里的旧版本 → ' + backupDir)
}

// ② 复制
fs.mkdirSync(target, { recursive: true })
for (const rel of files) {
  const destination = path.join(target, rel)
  fs.mkdirSync(path.dirname(destination), { recursive: true })
  if (fs.existsSync(destination)) {
    try { fs.chmodSync(destination, 0o666) } catch { /* ignore */ }
  }
  fs.copyFileSync(path.join(ROOT, rel), destination)
}
console.log('已复制 ' + files.length + ' 个文件 → ' + target)

// ③ 登记（只补缺失项，绝不改已有版本号）
const document = JSON.parse(fs.readFileSync(profilePkgPath, 'utf8'))
document.dependencies = document.dependencies ?? {}
document.dsh = document.dsh ?? {}
document.dsh.profile = document.dsh.profile ?? {}
const bundles = Array.isArray(document.dsh.profile.bundles) ? document.dsh.profile.bundles : []
let registryTouched = false
if (!document.dependencies[PKG_NAME]) {
  document.dependencies[PKG_NAME] = pkg.version
  registryTouched = true
  console.log('profile dependencies 里补登记 ' + PKG_NAME + '@' + pkg.version)
} else if (document.dependencies[PKG_NAME] !== pkg.version) {
  console.log(
    '提示：profile 记录的版本是 ' + document.dependencies[PKG_NAME] + '，本目录是 ' + pkg.version +
    '。deploy 只覆盖文件、不改版本号；要换版本请走插件更新流程。'
  )
}
if (!bundles.includes(PKG_NAME)) {
  bundles.push(PKG_NAME)
  document.dsh.profile.bundles = bundles
  registryTouched = true
  console.log('profile dsh.profile.bundles 里补登记 ' + PKG_NAME)
}
if (registryTouched) fs.writeFileSync(profilePkgPath, JSON.stringify(document, null, 2) + '\n', 'utf8')

// ④ 球脚本变了就重启球（宿主重读脚本 → 新外观生效，不必重启 Desktop）
console.log('')
if (ballChanged && !NO_RESTART) {
  console.log('resources/ball.ps1 有变化，重启球进程……')
  await restartBall()
} else if (ballChanged && NO_RESTART) {
  console.log('--no-restart：球脚本已更新但球没重启；下次 DSH Desktop 启动或手动重启球时才生效。')
} else {
  console.log('球脚本没有变化，不需要重启球。')
}
if (hostChanged) {
  console.log('注意：lib/session-ball.js 已更新。宿主代码有 ESM 缓存，必须完全退出并重启 DSH Desktop 才会装载新逻辑。')
  console.log('      只改 resources/ball.ps1 时不需要这一步。')
}
if (otherChanged && !ballChanged && !hostChanged) {
  console.log('改动的是配置/文档类文件：配置类在宿主下次加载时生效，文档类无运行时影响。')
}
console.log('')
console.log('回滚：把 backups/<时间戳>/' + PKG_NAME + ' 复制回 ' + target + '，再跑 node deploy.mjs --restart-only。')
