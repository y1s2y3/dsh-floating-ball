/**
 * 合规自检：跑一遍就能看出仓库是否满足「非官方声明 / MIT 归属 / 元数据 / 字体许可 / 无泄漏」。
 *
 *   node tools/check-compliance.mjs
 *
 * 只做静态检查（不联网、不启动球），任何一条 FAIL 都会以非 0 退出，适合放进发版前检查。
 */
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const results = []
const pass = (name, detail = '') => results.push({ ok: true, name, detail })
const fail = (name, detail = '') => results.push({ ok: false, name, detail })

const read = (rel) => readFileSync(join(ROOT, rel), 'utf8')
const exists = (rel) => {
  try {
    return statSync(join(ROOT, rel)).isFile()
  } catch {
    return false
  }
}

// 1) package.json 元数据
let pkg = {}
try {
  pkg = JSON.parse(read('package.json'))
  pass('package.json 可解析')
} catch (error) {
  fail('package.json 可解析', String(error))
}
if (pkg.name === 'dsh-floating-ball') pass('包名 = dsh-floating-ball', pkg.name)
else fail('包名 = dsh-floating-ball', String(pkg.name))
if (pkg.license === 'MIT') pass('license = MIT')
else fail('license = MIT', String(pkg.license))
if (/EvilOfRed/.test(String(pkg.author ?? '')) && /y1s2y3/.test(String(pkg.author ?? '') + (pkg.contributors ?? []).join(','))) {
  pass('作者归属（上游 + 衍生）')
} else fail('作者归属（上游 + 衍生）', String(pkg.author))
if (String(pkg.repository?.url ?? '').includes('github.com/y1s2y3/dsh-floating-ball')) pass('repository 指向 GitHub 仓库')
else fail('repository 指向 GitHub 仓库', String(pkg.repository?.url))
if (Object.keys(pkg.dependencies ?? {}).length === 0) pass('无 runtime 依赖')
else fail('无 runtime 依赖', JSON.stringify(pkg.dependencies))
const files = (pkg.files ?? []).join(',')
for (const required of ['README.md', 'LICENSE', 'assets', 'lib', 'resources', 'cordis.patch.yml']) {
  if (files.includes(required)) pass(`files 白名单包含 ${required}`)
  else fail(`files 白名单包含 ${required}`)
}

// 2) LICENSE / 上游 MIT 归属
const license = exists('LICENSE') ? read('LICENSE') : ''
if (/MIT License/.test(license)) pass('LICENSE 为 MIT')
else fail('LICENSE 为 MIT')
if (/Copyright \(c\) 2026 EvilOfRed/.test(license)) pass('LICENSE 保留上游版权（EvilOfRed）')
else fail('LICENSE 保留上游版权（EvilOfRed）')
if (/Copyright \(c\) 2026 y1s2y3/.test(license)) pass('LICENSE 有衍生版权（y1s2y3）')
else fail('LICENSE 有衍生版权（y1s2y3）')

// 3) README 非官方声明 / 来源 / 安装命令
const readme = exists('README.md') ? read('README.md') : ''
const disclaimerCount = (readme.match(/非官方/g) ?? []).length
if (disclaimerCount >= 3) pass('README 非官方声明（≥3 处）', `${disclaimerCount} 处`)
else fail('README 非官方声明（≥3 处）', `${disclaimerCount} 处`)
if (/来源与许可/.test(readme)) pass('README 来源与许可段')
else fail('README 来源与许可段')
if (/EvilOfRed/.test(readme)) pass('README 标注上游作者')
else fail('README 标注上游作者')
if (/dsh plugin --profile desktop add github:y1s2y3\/dsh-floating-ball/.test(readme)) pass('README 安装命令与仓库一致')
else fail('README 安装命令与仓库一致')
if (/## 隐私与数据/.test(readme)) pass('README 隐私与数据段')
else fail('README 隐私与数据段')

// 4) 字体许可（DshUiSans = Inter 衍生，Noto 子集）
for (const rel of ['assets/fonts/OFL.txt', 'assets/fonts/FONT-NOTICE.txt']) {
  if (exists(rel)) pass(`字体许可文件存在：${rel}`)
  else fail(`字体许可文件存在：${rel}`)
}
if (exists('assets/fonts/FONT-NOTICE.txt')) {
  const notice = read('assets/fonts/FONT-NOTICE.txt')
  if (/Inter/.test(notice) && /DshUiSans/.test(notice) && /OFL|SIL/.test(notice)) pass('FONT-NOTICE 覆盖 Inter 衍生 + OFL')
  else fail('FONT-NOTICE 覆盖 Inter 衍生 + OFL')
}
for (const font of ['DshUiSans-Regular.ttf', 'DshUiSans-Medium.ttf', 'DshUiSans-SemiBold.ttf', 'NotoSansSC-Regular-subset.ttf', 'NotoSansSC-Bold-subset.ttf']) {
  if (exists(join('assets', 'fonts', font))) pass(`字体随包分发：${font}`)
  else fail(`字体随包分发：${font}`)
}

// 5) loader 行名与包名一致
if (exists('cordis.patch.yml')) {
  const patch = read('cordis.patch.yml')
  if (patch.includes(`name: ${pkg.name}`)) pass('cordis.patch.yml 行名 = 包名')
  else fail('cordis.patch.yml 行名 = 包名', pkg.name)
}

// 6) 版本号一致性（COMPLIANCE 报告 + publish 脚本）
const compliance = exists('docs/COMPLIANCE.md') ? read('docs/COMPLIANCE.md') : ''
if (compliance.includes(pkg.version)) pass('COMPLIANCE.md 版本与 package.json 一致', pkg.version)
else fail('COMPLIANCE.md 版本与 package.json 一致', `${pkg.version} not in COMPLIANCE.md`)
const publish = exists('tools/publish-github.mjs') ? read('tools/publish-github.mjs') : ''
if (publish.includes(`v${pkg.version}`)) pass('发布脚本版本 = 包版本', `v${pkg.version}`)
else fail('发布脚本版本 = 包版本', `v${pkg.version}`)

// 7) 泄漏扫描：密钥 / 私钥 / 本机用户目录（git 跟踪文件；COMPLIANCE.md 记录扫描模式，排除）
const SECRETS = /ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----|C:\\Users\\[^\\\s]+/
// Walk the repo instead of spawning git: Node's child_process is blocked in some sandboxes.
const SKIP_DIRS = new Set(['.git', 'node_modules', 'backups', '_work', '_archive', '_tmp'])
const SKIP_FILES = [/^.*\.log$/, /^\.publish-files\.txt$/, /^.*\.bak-/, /^.*\.tgz$/]
const tracked = []
const walk = (dir) => {
  for (const entry of readdirSync(dir)) {
    const abs = join(dir, entry)
    const rel = relative(ROOT, abs).split('\\').join('/')
    const stat = statSync(abs)
    if (stat.isDirectory()) {
      if (!SKIP_DIRS.has(entry)) walk(abs)
      continue
    }
    if (SKIP_FILES.some((re) => re.test(rel)) || SKIP_FILES.some((re) => re.test(entry))) continue
    tracked.push(rel)
  }
}
walk(ROOT)
const hits = []
for (const rel of tracked) {
  if (rel === 'docs/COMPLIANCE.md') continue
  let text = ''
  try {
    text = read(rel)
  } catch {
    continue
  }
  if (SECRETS.test(text)) hits.push(rel)
}
if (hits.length === 0) pass('无密钥 / 私钥 / 本机绝对路径泄漏', `${tracked.length} 个跟踪文件`)
else fail('无密钥 / 私钥 / 本机绝对路径泄漏', hits.join(', '))

// 8) 备份目录 / 日志不进仓库
const gi = exists('.gitignore') ? read('.gitignore') : ''
for (const ignored of ['backups/', '_work/', '*.log', '.publish-files.txt', '*.bak-*']) {
  if (gi.includes(ignored)) pass(`.gitignore 忽略 ${ignored}`)
  else fail(`.gitignore 忽略 ${ignored}`)
}

// 输出
let failed = 0
for (const item of results) {
  if (!item.ok) failed++
  console.log(`${item.ok ? '[PASS]' : '[FAIL]'} ${item.name}${item.detail ? ' — ' + item.detail : ''}`)
}
console.log('')
console.log(`${results.length - failed}/${results.length} 项通过`)
if (failed > 0) {
  console.log(`${failed} 项未通过`)
  process.exit(1)
}
console.log('合规自检通过')
