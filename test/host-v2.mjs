/**
 * Fake-Host test for lib/floating-ball-v2.js (phase 2b prototype).
 *
 * No real DSH Host is involved: a fake ctx records event handlers and provides stub services,
 * then the test drives the same events the Host would emit and asserts the state documents and
 * the actions the host sends back.
 *
 *   node test/host-v2.mjs
 */
import assert from 'node:assert/strict'
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const RUNTIME = join(ROOT, '_work', 'host-v2-test')
rmSync(RUNTIME, { recursive: true, force: true })
mkdirSync(RUNTIME, { recursive: true })
process.env.DSH_BALL_DIR = RUNTIME
process.env.DSH_BALL_NO_SPAWN = '1'

const { apply } = await import('../lib/floating-ball-v2.js')

const prompts = []
const creates = []
const ctx = (() => {
  const handlers = new Map()
  const cleanups = []
  const services = {
    sessionController: {
      prompt: async (request) => {
        prompts.push(request)
      },
      create: async (request) => {
        creates.push(request)
        return { sessionId: 'session-new' }
      }
    }
  }
  const fake = {
    logger: { info() {}, warn() {}, error() {} },
    get: (name) => services[name],
    on: (name, handler) => {
      const list = handlers.get(name) ?? []
      list.push(handler)
      handlers.set(name, list)
    },
    effect: (fn) => {
      cleanups.push(fn())
    },
    emit: (name, ...args) => {
      for (const handler of handlers.get(name) ?? []) handler(...args)
    },
    invoke: (name, ...args) => Promise.all((handlers.get(name) ?? []).map((handler) => Promise.resolve(handler(...args)))),
    dispose: () => {
      for (const cleanup of cleanups) cleanup?.()
    }
  }
  return fake
})()

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const latestState = () => {
  const files = readdirSync(RUNTIME).filter((entry) => /^state-\d+\.json$/.test(entry))
  if (files.length === 0) return undefined
  files.sort((left, right) => Number(left.match(/\d+/)[0]) - Number(right.match(/\d+/)[0]))
  return JSON.parse(readFileSync(join(RUNTIME, files[files.length - 1]), 'utf8'))
}
const waitState = async (predicate, label) => {
  for (let attempt = 0; attempt < 40; attempt++) {
    const state = latestState()
    if (state !== undefined && predicate(state)) return state
    await sleep(50)
  }
  throw new Error(`timed out waiting for state: ${label}`)
}

apply(ctx, { enabled: true, ballSize: 48, panelWidth: 320, panelHeight: 460, promptMode: 'queue' })

// two sessions in the directory
ctx.emit('api-session/added', { sessionId: 'session-a', cwd: 'C:\\work\\a', projections: { values: { title: { text: '周报整理' } } } })
ctx.emit('api-session/added', { sessionId: 'session-b', cwd: 'C:\\work\\b', projections: { values: { title: { text: '素材整理' } } } })
// a is running
ctx.emit('api-session/status', 'session-a', true)
ctx.emit('session/event', { id: 'session-a' }, { type: 'turn/start', data: {} })

const running = await waitState((state) => state.status.key === 'working' && state.entries.length >= 1, 'running entry')
assert.equal(running.metrics.ballSize, 48)
assert.equal(running.metrics.panelWidth, 320)
assert.equal(running.metrics.panelHeight, 460)
const runningEntry = running.entries.find((entry) => entry.key === 'session-a')
assert.ok(runningEntry, 'running session has an entry')
assert.equal(runningEntry.chip, '输出中')
assert.equal(runningEntry.lock, true)
assert.equal(runningEntry.showInput, false)
assert.equal(running.window.expanded, false)
assert.equal(running.labels.send, '↑')

// it finishes -> completed-unread entry
ctx.emit('api-session/status', 'session-a', false)
ctx.emit('session/event', { id: 'session-a' }, { type: 'turn/end', data: {} })
const unread = await waitState((state) => state.entries.some((entry) => entry.key === 'session-a' && entry.unread === true), 'unread entry')
assert.equal(unread.status.key, 'idle')
const unreadEntry = unread.entries.find((entry) => entry.key === 'session-a')
assert.equal(unreadEntry.chip, '未读')
assert.equal(unreadEntry.showInput, true)

// b errors -> aggregate error + ack flag
ctx.emit('session/event', { id: 'session-b' }, { type: 'turn/error', data: { message: '工具调用超时' } })
const errored = await waitState((state) => state.status.key === 'error', 'error status')
const errorEntry = errored.entries.find((entry) => entry.key === 'session-b')
assert.ok(errorEntry, 'error session has an entry')
assert.equal(errorEntry.canAck, true)
assert.equal(errorEntry.chip, '异常')
assert.equal(errorEntry.hint, '工具调用超时')

// "got it" clears the error
writeFileSync(join(RUNTIME, 'act-1-1.json'), JSON.stringify({ kind: 'ack', id: 'session-b', seq: 1 }), 'utf8')
const acked = await waitState((state) => state.status.key !== 'error', 'ack clears error')
assert.equal(acked.status.key, 'idle')

// prompt goes through sessionController.prompt with the standard payload
writeFileSync(join(RUNTIME, 'act-1-2.json'), JSON.stringify({ kind: 'prompt', target: 'session-a', key: 'session-a', text: '继续把周报整理完', seq: 2 }), 'utf8')
for (let attempt = 0; attempt < 40 && prompts.length === 0; attempt++) await sleep(50)
assert.equal(prompts.length, 1, 'prompt was routed')
assert.equal(prompts[0].sessionId, 'session-a')
assert.equal(prompts[0].content[0].type, 'text')
assert.equal(prompts[0].content[0].text, '继续把周报整理完')
assert.equal(prompts[0].mode, 'queue')

// expand is remembered in window.json and in the next state
writeFileSync(join(RUNTIME, 'act-1-3.json'), JSON.stringify({ kind: 'expanded', expanded: true, seq: 3 }), 'utf8')
const expanded = await waitState((state) => state.window.expanded === true, 'expanded window')
const savedWindow = JSON.parse(readFileSync(join(RUNTIME, 'window.json'), 'utf8'))
assert.equal(savedWindow.expanded, true)

// close hides the entry
writeFileSync(join(RUNTIME, 'act-1-4.json'), JSON.stringify({ kind: 'close', id: 'session-a', seq: 4 }), 'utf8')
const closed = await waitState((state) => !state.entries.some((entry) => entry.key === 'session-a'), 'closed entry')

// materialized ball script exists and matches the package resource
const scripts = readdirSync(RUNTIME).filter((entry) => entry.endsWith('-ball-v2.ps1'))
assert.equal(scripts.length, 1, 'exactly one materialized ball script')

// approval card: the ball answers 'allowed-once' and the listener must return that outcome
const pendingUpstream = () => new Promise(() => undefined)
const approvalPromise = ctx.invoke('approval/request',
  { agent: { id: 'session-b' }, toolName: 'desktop_step', callId: 'call-42', displayReason: { 'zh-CN': '允许把这个文件写进项目目录吗？' } },
  pendingUpstream
)
const cardState = await waitState((state) => state.status.key === 'approval' && state.entries.some((entry) => Array.isArray(entry.cards) && entry.cards.length > 0), 'approval card')
assert.equal(cardState.pendingCount, 1)
const cardEntry = cardState.entries.find((entry) => Array.isArray(entry.cards) && entry.cards.length > 0)
assert.equal(cardEntry.chip, '待审批')
const card = cardEntry.cards[0]
assert.equal(card.kind, 'approval')
assert.equal(card.title, '允许把这个文件写进项目目录吗？')
assert.equal(card.hint, '工具：desktop_step')
assert.deepEqual(card.options.map((option) => option.id), ['allowed-once', 'rejected'])
writeFileSync(join(RUNTIME, 'act-2-1.json'), JSON.stringify({ kind: 'approval', id: card.id, optionId: 'allowed-once', seq: 1 }), 'utf8')
const outcome = (await approvalPromise)[0]
assert.equal(outcome, 'allowed-once')
await waitState((state) => !state.entries.some((entry) => Array.isArray(entry.cards) && entry.cards.length > 0), 'approval card cleared')

// multi-question: options + free text, answered in one shot
const questionPromise = ctx.invoke('user-questions/request',
  { agent: { id: 'session-b' }, questions: [
    { id: 'q1', question: '要发布到哪个环境？', options: [{ label: '预发' }, { label: '生产' }] },
    { id: 'q2', header: '通知', question: '发布完成后要通知哪些人？', detail: '可以多选。', multiSelect: true, options: [{ label: '项目负责人 · 张三', description: '钉钉 + 短信' }, { label: '测试同学 · 李四' }] }
  ], wait: { callId: 'call-7' } },
  pendingUpstream
)
const questionState = await waitState((state) => state.entries.some((entry) => Array.isArray(entry.cards) && entry.cards.length > 0 && entry.cards[0].kind === 'question'), 'question card')
const questionEntry = questionState.entries.find((entry) => Array.isArray(entry.cards) && entry.cards.length > 0 && entry.cards[0].kind === 'question')
assert.equal(questionEntry.chip, '待回答')
const questionCard = questionEntry.cards[0]
assert.equal(questionCard.items.length, 2)
assert.equal(questionCard.items[0].options.length, 2)
assert.equal(questionCard.items[1].multiSelect, true)
assert.equal(questionCard.items[1].options[0].description, '钉钉 + 短信')
writeFileSync(join(RUNTIME, 'act-2-2.json'), JSON.stringify({ kind: 'answer', id: questionCard.id, answers: [{ id: 'q1', selected: ['生产'] }, { id: 'q2', selected: ['项目负责人 · 张三', '测试同学 · 李四'] }], seq: 2 }), 'utf8')
const answer = (await questionPromise)[0]
assert.deepEqual(answer, { answers: [{ id: 'q1', selected: ['生产'] }, { id: 'q2', selected: ['项目负责人 · 张三', '测试同学 · 李四'] }] })

// new-session row: + adds a local row, typing in it creates the session and prompts it
writeFileSync(join(RUNTIME, 'act-3-1.json'), JSON.stringify({ kind: 'new', seq: 1 }), 'utf8')
const localState = await waitState((state) => state.entries.some((entry) => entry.key === 'local-new' && entry.state === 'local'), 'new-session row')
const localEntry = localState.entries.find((entry) => entry.key === 'local-new')
assert.equal(localEntry.target, 'new')
assert.equal(localEntry.showInput, true)
writeFileSync(join(RUNTIME, 'act-3-2.json'), JSON.stringify({ kind: 'prompt', target: 'new', key: 'local-new', text: '帮我整理这周的周报', seq: 2 }), 'utf8')
for (let attempt = 0; attempt < 40 && creates.length === 0; attempt++) await sleep(50)
assert.equal(creates.length, 1, 'session create was invoked')
assert.ok(typeof creates[0].cwd === 'string' && creates[0].cwd !== '', 'create uses a session cwd')
for (let attempt = 0; attempt < 40 && prompts.length < 2; attempt++) await sleep(50)
const createdPrompt = prompts.find((request) => request.sessionId === 'session-new')
assert.ok(createdPrompt, 'prompt was sent to the created session')
assert.equal(createdPrompt.content[0].text, '帮我整理这周的周报')
await waitState((state) => !state.entries.some((entry) => entry.key === 'local-new'), 'new-session row cleared')

ctx.dispose()
console.log('PASS host-v2 fake-host test')
console.log('  state files:', readdirSync(RUNTIME).filter((entry) => /^state-\d+\.json$/.test(entry)).length)
console.log('  final expanded:', savedWindow.expanded, '| entries after close:', closed.entries.length)
