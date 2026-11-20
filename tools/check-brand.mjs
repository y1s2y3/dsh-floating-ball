/**
 * 封版校验：图标、封面、桌面球必须是同一只鲸鱼，且已去掉嘴/腹线。
 *
 * 三处鲸鱼路径必须逐字符一致（忽略多余空白）：
 *   1. assets/icon.svg          —— 图标源文件
 *   2. resources/ball.ps1       —— 桌面球（BallMark 里白色路径 + 阴影路径两份）
 *   3. tools/render-icon.ps1    —— 生成 PNG 的渲染脚本（$whaleBody）
 *
 * 另外校验 icon-1024…icon-16 都存在、尺寸正确，且封面存在。
 *
 * 用法：node tools/check-brand.mjs
 */
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { fileURLToPath } from 'node:url'

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const failures = []
const notes = []

const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8')
const squash = (s) => s.replace(/\s+/g, ' ').trim()

const bodyFromSvg = (() => {
  const svg = read('assets/icon.svg')
  const match = svg.match(/<path d="(M 4 50[^"]*)" fill="url\(#whale\)"/)
  if (!match) throw new Error('assets/icon.svg 里找不到鲸鱼身体路径')
  return squash(match[1])
})()

const ball = read('resources/ball.ps1')
const ballBodies = [...ball.matchAll(/Data="(M 4 50[^"]*)"/g)].map((m) => squash(m[1]))
if (ballBodies.length < 2) failures.push(`ball.ps1 里鲸鱼身体路径应为 2 份（白鲸 + 阴影），实际 ${ballBodies.length}`)
for (const body of ballBodies) {
  if (body !== bodyFromSvg) failures.push('ball.ps1 的鲸鱼路径与 assets/icon.svg 不一致')
}

const renderer = read('tools/render-icon.ps1')
const rendererBody = (() => {
  const match = renderer.match(/\$whaleBody = '([^']+)'/)
  if (!match) throw new Error('tools/render-icon.ps1 里找不到 $whaleBody')
  return squash(match[1])
})()
if (rendererBody !== bodyFromSvg) failures.push('tools/render-icon.ps1 的鲸鱼路径与 assets/icon.svg 不一致')

// 封版后不允许再把嘴 / 腹线加回来
const MOUTH = 'M 7 56'
const BELLY = 'M 30 66'
for (const [rel, text] of [
  ['resources/ball.ps1', ball],
  ['tools/render-icon.ps1', renderer],
  ['assets/icon.svg', read('assets/icon.svg')]
]) {
  // 文档/注释里提到历史值不算，只看绘制路径本身
  if (text.includes(`Data="${MOUTH}`) || text.includes(`d="${MOUTH}`) || text.includes('To-Global 7 56')) {
    failures.push(`${rel} 仍然带着微笑嘴路径`)
  }
  if (text.includes(`Data="${BELLY}`) || text.includes(`d="${BELLY}`) || text.includes('To-Global 30 66')) {
    failures.push(`${rel} 仍然带着腹线路径`)
  }
}

// PNG 尺寸
const pngSize = (rel) => {
  const buf = fs.readFileSync(path.join(ROOT, rel))
  if (buf.length < 24 || buf.toString('ascii', 1, 4) !== 'PNG') throw new Error(`${rel} 不是 PNG`)
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) }
}
for (const size of [1024, 512, 256, 128, 64, 48, 32, 16]) {
  const rel = `assets/icon-${size}.png`
  if (!fs.existsSync(path.join(ROOT, rel))) { failures.push(`缺少 ${rel}`); continue }
  const actual = pngSize(rel)
  if (actual.width !== size || actual.height !== size) failures.push(`${rel} 尺寸应为 ${size}×${size}，实际 ${actual.width}×${actual.height}`)
}
if (!fs.existsSync(path.join(ROOT, 'assets/cover-wechat-900x383.png'))) failures.push('缺少公众号封面 assets/cover-wechat-900x383.png')

// 记录（不是失败）：球上鲸鱼的缩放比例
const factor = (ball.match(/\$script:BallMarkScaleFactor = ([0-9.]+)/) || [])[1]
notes.push(`球上鲸鱼占球径：${factor ?? '?'}（BallMarkScaleFactor）`)
notes.push(`封版鲸鱼路径：${bodyFromSvg.slice(0, 60)}…（三处一致）`)

const manifest = crypto.createHash('sha256').update(bodyFromSvg).digest('hex').slice(0, 16)
notes.push(`鲸鱼路径指纹：${manifest}`)

for (const note of notes) console.log('  ' + note)
if (failures.length > 0) {
  console.error('\n[FAIL]')
  for (const failure of failures) console.error('  - ' + failure)
  process.exit(1)
}
console.log('\n[PASS] 图标 / 封面 / 桌面球 已封版为同一只鲸鱼（无嘴、无腹线）')
