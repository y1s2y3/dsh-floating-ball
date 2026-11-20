/**
 * Tests for the dispatcher (lib/session-ball.js):
 * - v2 (production) is the default; only `engine: 'upstream'` selects the legacy engine;
 * - engine = v2 really runs the new host (state document v9 appears);
 * - the old host module still exports a usable apply function.
 *
 *   node test/dispatch.mjs
 */
import assert from 'node:assert/strict'
import { mkdirSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const RUNTIME = join(ROOT, '_work', 'dispatch-test')
rmSync(RUNTIME, { recursive: true, force: true })
mkdirSync(RUNTIME, { recursive: true })
process.env.DSH_BALL_DIR = RUNTIME
process.env.DSH_BALL_NO_SPAWN = '1'

const { name, resolveEngine, apply } = await import('../lib/session-ball.js')

assert.equal(name, 'session-ball')
assert.equal(resolveEngine(undefined), 'v2')
assert.equal(resolveEngine({}), 'v2')
assert.equal(resolveEngine({ engine: 'upstream' }), 'upstream')
assert.equal(resolveEngine({ engine: 'v2' }), 'v2')
assert.equal(resolveEngine({ engine: 'something-else' }), 'v2')

// The legacy module needs @deepseek-ai/schemastery, which is only present in the installed profile,
// so verify it statically instead of importing it here.
const legacySource = readFileSync(join(ROOT, 'lib', 'session-ball-upstream.js'), 'utf8')
assert.ok(legacySource.length > 1000, 'legacy engine file is present')
assert.ok(/(export\s+(async\s+)?function\s+apply)|(export\s*\{[^}]*\bapply\b)/.test(legacySource), 'legacy engine still exports apply()')

const ctx = (() => {
  const handlers = new Map()
  const cleanups = []
  return {
    logger: { info() {}, warn() {}, error() {} },
    get: () => undefined,
    on: (event, handler) => {
      const list = handlers.get(event) ?? []
      list.push(handler)
      handlers.set(event, list)
    },
    effect: (fn) => {
      cleanups.push(fn())
    },
    emit: (event, ...args) => {
      for (const handler of handlers.get(event) ?? []) handler(...args)
    },
    dispose: () => {
      for (const cleanup of cleanups) cleanup?.()
    }
  }
})()

await apply(ctx, { engine: 'v2', enabled: true })
ctx.emit('api-session/added', { sessionId: 'dispatch-1', cwd: 'C:\\work', projections: { values: { title: { text: 'A/B 测试会话' } } } })
ctx.emit('api-session/status', 'dispatch-1', true)

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
let state
for (let attempt = 0; attempt < 40; attempt++) {
  const files = readdirSync(RUNTIME).filter((entry) => /^state-\d+\.json$/.test(entry))
  if (files.length > 0) {
    files.sort((left, right) => Number(left.match(/\d+/)[0]) - Number(right.match(/\d+/)[0]))
    state = JSON.parse(readFileSync(join(RUNTIME, files[files.length - 1]), 'utf8'))
    if (state.entries.length > 0) break
  }
  await sleep(50)
}
assert.ok(state, 'v2 engine wrote a state document')
assert.equal(state.v, 9)
assert.equal(state.status.key, 'working')
assert.equal(state.metrics.ballSize, 48)
assert.equal(state.metrics.panelWidth, 320)
assert.equal(state.metrics.panelHeight, 460)

ctx.dispose()
console.log('PASS dispatch A/B test')
console.log(`  engine default: ${resolveEngine({})} / explicit upstream: ${resolveEngine({ engine: 'upstream' })}`)
console.log(`  v2 state: v${state.v} status=${state.status.key} entries=${state.entries.length}`)
