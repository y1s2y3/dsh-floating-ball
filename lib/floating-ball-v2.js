/**
 * floating-ball host (phase 2b, prototype) - our own host, no upstream code.
 *
 * It publishes the v9 state document that resources/ball-v2.ps1 reads, spawns that script as a
 * WPF process, and consumes the act-*.json files the ball writes. It talks to the Host through
 * the same public events/services the previous host used:
 *
 *   api-session/added | status | activity | removed   -> session directory + running flag
 *   session/event                                     -> turn start/end, errors
 *   agent/assistant-stream                            -> per-step busy state
 *   user-questions/request, approval/request          -> (2b stage 2, not wired yet)
 *
 * Status/entries in this milestone: running sessions, unacknowledged errors and recently
 * finished (unread) sessions. Prompt / close / ack / expanded / pos work. Approvals, questions
 * and the "+ new session" picker are explicitly logged as not wired yet - the old host still
 * serves production until stage 2 and the A/B comparison.
 *
 * Runtime files live in %LOCALAPPDATA%\dsh-session-ball\default (or DSH_BALL_DIR):
 *   state-<n>.json   host -> ball
 *   act-<pid>-<seq>.json  ball -> host
 *   window.json      remembered position/expanded flag
 *   ball.log         both sides
 */
import { createHash, randomUUID } from 'node:crypto'
import { spawn } from 'node:child_process'
import { appendFileSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'session-ball'

const PACKAGE_ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const SCRIPT_FILE = 'ball-v2.ps1'
const ACT_TICK_MS = 80
const STATE_TICK_MS = 120

const DEFAULTS = {
  enabled: true,
  ballSize: 48,
  panelWidth: 320,
  panelHeight: 460,
  opacity: 1,
  answerQuestions: true,
  answerApprovals: true,
  expandOnPending: false,
  promptMode: 'auto',
  lockComposeWhileBusy: true,
  entryLimit: 12
}

const STYLES = {
  idle: { label: '空闲', color: '#FF7C8598' },
  working: { label: '正在输出', color: '#FF5B8DEF' },
  asking: { label: '正在等你回答', color: '#FFE0A64B' },
  approval: { label: '正在请求审批', color: '#FFF08A24' },
  error: { label: '出错了', color: '#FFE0574B' }
}

const LABELS = {
  send: '↑',
  ack: '知道了',
  close: '×',
  placeholder: '写一句…',
  sent: '已发出，等会话接手…',
  newSession: '新会话',
  newSessionChip: '新建',
  answer: '作答',
  next: '下一题',
  prev: '上一步',
  submit: '提交',
  customAnswer: '也可以直接写一句…',
  answerIncomplete: '每个问题都要选一项或填一句',
  pending: '等你处理',
  pendingHint: '个待审批',
  running: '运行中',
  unread: '已完成 · 未读',
  approval: '待审批',
  question: '待回答',
  error: '异常'
}

const CHIP = { running: '输出中', error: '异常', unread: '未读', idle: '空闲' }
const UNREAD_WINDOW_MS = 10 * 60 * 1000

const asRecord = (value) => (typeof value === 'object' && value !== null ? value : undefined)
const asString = (value) => (typeof value === 'string' ? value : '')
const asNumber = (value) => (typeof value === 'number' && Number.isFinite(value) ? value : 0)
const oneLine = (text, max = 120) => String(text ?? '').replace(/\s+/g, ' ').trim().slice(0, max)

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

/** Human text for an approval: prefer the display reason, then a plain reason. */
/** One line for a failed tool result: code/reason, no arguments or output. */
function toolFailureNote(data) {
  const error = asRecord(asRecord(data)?.error)
  if (error === undefined) return '工具调用失败'
  const parts = [asString(error.code), asString(error.reason) || asString(error.name)].filter((part) => part !== '')
  return oneLine(parts.length > 0 ? parts.join('：') : '工具调用失败', 160)
}

function approvalReason(request) {
  const record = asRecord(request) ?? {}
  const display = asRecord(record.displayReason)
  if (display !== undefined) {
    for (const key of ['zh-CN', 'zh', 'zh-Hans', 'zh-Hant', 'en']) {
      const text = asString(display[key]).trim()
      if (text !== '') return oneLine(text, 160)
    }
  }
  return oneLine(asString(record.reason), 160)
}

/** Ball answers -> the AskUserQuestionAnswer shape the Host accepts. */
function normalizeBallAnswers(raw) {
  const answers = []
  for (const entry of Array.isArray(raw) ? raw : []) {
    const record = asRecord(entry)
    const id = asString(record?.id)
    if (id === '') continue
    const selected = []
    for (const label of Array.isArray(record?.selected) ? record.selected : []) {
      const text = asString(label).trim()
      if (text !== '') selected.push(text)
    }
    const custom = asString(record?.custom).trim()
    const answer = { id }
    if (selected.length > 0) answer.selected = selected
    if (custom !== '') answer.custom = custom
    answers.push(answer)
  }
  return answers
}

class Overlay {
  constructor(options) {
    this.dir = options.dir
    this.settings = options.settings
    this.onAction = options.onAction
    this.logPath = join(this.dir, 'ball.log')
    this.child = undefined
    this.timer = undefined
    this.window = { expanded: false }
    this.stateSeq = 0
    this.actsSeen = new Set()
    this.scriptPath = ''
    this.startedAt = 0
    this.exits = []
    this.stopping = false
  }

  log(message) {
    try {
      mkdirSync(this.dir, { recursive: true })
      appendFileSync(this.logPath, `${new Date().toISOString()} [host] ${message}\n`, 'utf8')
    } catch {}
  }

  loadWindow() {
    try {
      const parsed = JSON.parse(readFileSync(join(this.dir, 'window.json'), 'utf8'))
      // Position is remembered, the open/closed state is NOT: every launch starts as the ball so a
      // restart never dumps the panel on screen (and never at a position the panel was not sized for).
      this.window = {
        ...(typeof parsed.x === 'number' ? { x: parsed.x } : {}),
        ...(typeof parsed.y === 'number' ? { y: parsed.y } : {}),
        expanded: false
      }
    } catch {
      this.window = { expanded: false }
    }
  }

  saveWindow() {
    try {
      mkdirSync(this.dir, { recursive: true })
      writeFileSync(join(this.dir, 'window.json'), JSON.stringify(this.window), 'utf8')
    } catch {}
  }

  clearGenerated() {
    try {
      for (const entry of readdirSync(this.dir)) {
        if (/^(state-\d+\.json|act-.*\.json)$/.test(entry)) rmSync(join(this.dir, entry), { force: true })
      }
    } catch {}
  }

  materializeFonts() {
    const names = ['DshUiSans.ttc', 'DshUiSans-Regular.ttf', 'DshUiSans-Medium.ttf', 'DshUiSans-SemiBold.ttf']
    const target = join(this.dir, 'fonts')
    mkdirSync(target, { recursive: true })
    for (const name of names) {
      try {
        const content = readFileSync(join(PACKAGE_ROOT, 'assets', 'fonts', name))
        writeFileSync(join(target, name), content)
      } catch (error) {
        this.log(`font ${name} not copied: ${String(error)}`)
      }
    }
    this.fontDir = target
  }

  materializeScript() {
    const source = join(PACKAGE_ROOT, 'resources', SCRIPT_FILE)
    const content = readFileSync(source)
    const hash = createHash('sha1').update(content).digest('hex').slice(0, 12)
    const target = join(this.dir, `${hash}-${SCRIPT_FILE}`)
    writeFileSync(target, content)
    for (const entry of readdirSync(this.dir)) {
      if (!entry.endsWith(`-${SCRIPT_FILE}`) || join(this.dir, entry) === target) continue
      rmSync(join(this.dir, entry), { force: true })
    }
    this.scriptPath = target
  }

  start() {
    mkdirSync(this.dir, { recursive: true })
    this.loadWindow()
    this.clearGenerated()
    this.materializeScript()
    this.materializeFonts()
    this.startedAt = Date.now()
    if (process.env.DSH_BALL_NO_SPAWN !== '1') this.spawnBall()
    // Only consume actions here. State writes belong to the host's own buildState() loop; calling
    // writeState() with no argument from this timer was the source of the endless
    // 'write state skipped: buildState returned nothing' spam (and of the old writeFileSync errors).
    this.timer = setInterval(() => {
      this.consumeActions()
    }, ACT_TICK_MS)
    this.log('host started (ball-v2)')
  }

  spawnBall() {
    this.stopping = false
    this.child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', this.scriptPath], {
      stdio: 'ignore',
      windowsHide: true,
      env: { ...process.env, DSH_BALL_RUNTIME_DIR: this.dir, ...(this.fontDir === undefined ? {} : { DSH_BALL_FONTS: this.fontDir }) }
    })
    this.child.on('exit', (code) => {
      this.child = undefined
      if (this.stopping) return
      const now = Date.now()
      this.exits = this.exits.filter((at) => now - at < 5 * 60 * 1000).concat(now)
      this.log(`ball exited (code=${String(code)})`)
      if (this.exits.length > 5) {
        this.log('ball keeps exiting; giving up (restart DSH Desktop to revive)')
        return
      }
      setTimeout(() => {
        if (!this.stopping) this.spawnBall()
      }, 2000)
    })
  }

  stop() {
    this.stopping = true
    if (this.timer !== undefined) clearInterval(this.timer)
    this.timer = undefined
    if (this.child !== undefined) {
      try {
        this.child.kill()
      } catch {}
      this.child = undefined
    }
  }

  writeState(doc) {
    if (doc === undefined || doc === null) {
      this.log('write state skipped: buildState returned nothing')
      return
    }
    const json = JSON.stringify(doc)
    if (json === this.lastStateJson) return
    this.lastStateJson = json
    this.stateSeq += 1
    const file = join(this.dir, `state-${this.stateSeq}.json`)
    try {
      mkdirSync(this.dir, { recursive: true })
      writeFileSync(file, json, 'utf8')
      for (const entry of readdirSync(this.dir)) {
        const match = /^state-(\d+)\.json$/.exec(entry)
        if (match && this.stateSeq - Number(match[1]) > 60) rmSync(join(this.dir, entry), { force: true })
      }
    } catch (error) {
      this.log(`write state failed: ${String(error)}`)
    }
  }

  consumeActions() {
    let names = []
    try {
      names = readdirSync(this.dir).filter((entry) => entry.startsWith('act-') && entry.endsWith('.json'))
    } catch {
      return
    }
    if (names.length === 0) return
    names.sort((left, right) => {
      const [leftPid = '', leftSeq = ''] = left.replace(/^act-/, '').replace(/\.json$/, '').split('-')
      const [rightPid = '', rightSeq = ''] = right.replace(/^act-/, '').replace(/\.json$/, '').split('-')
      if (leftPid !== rightPid) return leftPid.localeCompare(rightPid)
      return Number(leftSeq) - Number(rightSeq)
    })
    for (const entry of names) {
      const file = join(this.dir, entry)
      try {
        const action = JSON.parse(readFileSync(file, 'utf8'))
        this.applyWindowAction(action)
        this.onAction(action)
      } catch (error) {
        this.log(`action ${entry} failed: ${String(error)}`)
      }
      rmSync(file, { force: true })
    }
  }

  applyWindowAction(action) {
    let changed = false
    if (action.kind === 'pos' && typeof action.x === 'number' && typeof action.y === 'number') {
      this.window = { ...this.window, x: action.x, y: action.y }
      changed = true
    }
    if (action.kind === 'expanded' && typeof action.expanded === 'boolean') {
      this.window = { ...this.window, expanded: action.expanded }
      changed = true
    }
    if (changed) this.saveWindow()
  }
}

class SessionMirror {
  constructor() {
    this.rows = new Map()
  }

  ensure(id) {
    let row = this.rows.get(id)
    if (row === undefined) {
      row = {
        id,
        title: '',
        cwd: '',
        running: false,
        busy: false,
        status: 'idle',
        errorNote: '',
        errorAcked: false,
        lastActivityAt: Date.now(),
        signal: 0
      }
      this.rows.set(id, row)
    }
    return row
  }

  summary(summary) {
    const record = asRecord(summary)
    if (record === undefined) return
    const id = asString(record.sessionId)
    if (id === '') return
    const row = this.ensure(id)
    row.cwd = asString(record.cwd) || row.cwd
    row.running = record.running === true
    if (row.running) row.signal += 1
    const title = asRecord(asRecord(record.projections)?.values)?.title
    const text = asRecord(title)?.text ?? title
    if (typeof text === 'string' && text.trim() !== '') row.title = oneLine(text)
    row.lastActivityAt = Date.now()
  }

  status(id, running) {
    const row = this.ensure(id)
    if (running === true && !row.running) row.signal += 1
    row.running = running === true
    row.lastActivityAt = Date.now()
  }

  activity(id, updatedAt) {
    const row = this.ensure(id)
    row.lastActivityAt = Math.max(row.lastActivityAt, asNumber(updatedAt) || Date.now())
  }

  removed(id) {
    this.rows.delete(id)
  }

  sessionEvent(session, event) {
    const sessionId = asString(asRecord(session)?.id)
    const record = asRecord(event)
    if (sessionId === '' || record === undefined) return
    const row = this.ensure(sessionId)
    row.lastActivityAt = Date.now()
    const type = asString(record.type)
    const data = asRecord(record.data) ?? {}
    if (type === 'turn/start') {
      row.signal += 1
      row.errorAcked = false
      row.errorNote = ''
      row.status = 'working'
      row.busy = true
    } else if (type === 'turn/end') {
      const reason = asRecord(data.reason)
      const kind = asString(reason?.kind)
      row.busy = false
      if (kind === 'error' || kind === 'aborted') {
        row.status = 'error'
        row.errorNote = oneLine(asString(asRecord(reason?.error)?.message) || (kind === 'aborted' ? '本轮被中止' : '本轮出错'))
      } else {
        row.status = 'idle'
      }
    } else if (type === 'tool/call') {
      row.busy = true
      row.status = 'working'
    } else if (type === 'tool/result') {
      row.busy = true
      if (data.ok === false) {
        row.status = 'error'
        row.errorNote = toolFailureNote(data)
      } else if (row.status !== 'error') {
        row.status = 'working'
      }
    } else if (type === 'user/message') {
      row.busy = true
      row.status = 'working'
      row.errorAcked = false
      row.errorNote = ''
    } else if (type === 'session/title') {
      const title = asString(data.title) || asString(data.text)
      if (title !== '') row.title = oneLine(title)
    } else if (type === 'assistant/message') {
      row.busy = true
      if (row.status !== 'error') row.status = 'working'
    } else if (type === 'turn/error' || type === 'error') {
      row.busy = false
      row.status = 'error'
      row.errorNote = oneLine(asString(data.message) || asString(data.reason) || '出错了')
    }
  }

  stream(payload) {
    const record = asRecord(payload)
    const agent = asRecord(record?.agent)
    const frame = asRecord(record?.frame)
    if (agent === undefined || frame === undefined) return
    const sessionId = asString(agent.id)
    if (sessionId === '') return
    const row = this.ensure(sessionId)
    row.lastActivityAt = Date.now()
    const type = asString(frame.type)
    if (type === 'start') {
      row.signal += 1
      row.busy = true
      row.status = 'working'
      return
    }
    if (type !== 'chunk') return
    const chunk = asRecord(frame.chunk)
    const chunkType = asString(chunk?.type)
    if (chunkType === 'reasoning-delta' || chunkType === 'text-delta' || chunkType === 'tool-call-delta') {
      row.busy = true
      if (row.status !== 'error') row.status = 'working'
    }
  }

  ackError(id) {
    const row = this.rows.get(id)
    if (row === undefined) return
    row.errorAcked = true
  }

  statusOf() {
    const rows = [...this.rows.values()]
    const unackedError = rows.find((row) => row.status === 'error' && !row.errorAcked)
    if (unackedError !== undefined) return { key: 'error', running: rows.some((row) => row.busy) }
    const working = rows.some((row) => row.busy || row.running)
    if (working) return { key: 'working', running: true }
    return { key: 'idle', running: false }
  }

  entries(now, settings) {
    const out = []
    for (const row of [...this.rows.values()].sort((left, right) => right.lastActivityAt - left.lastActivityAt)) {
      const unacked = row.status === 'error' && !row.errorAcked
      const unread = !row.busy && !row.running && !unacked && now - row.lastActivityAt < UNREAD_WINDOW_MS
      let state = 'idle'
      if (unacked) state = 'error'
      else if (row.busy || row.running) state = 'running'
      else if (unread) state = 'unread'
      else continue
      const busy = state === 'running'
      out.push({
        key: row.id,
        target: row.id,
        title: oneLine(row.title || row.cwd || row.id),
        chip: CHIP[state],
        state: state === 'unread' ? 'idle' : state,
        unread: state === 'unread',
        color: state === 'error' ? STYLES.error.color : state === 'running' ? STYLES.working.color : STYLES.idle.color,
        hint: state === 'error' ? row.errorNote : '',
        errorNote: state === 'error' ? row.errorNote : '',
        canAck: unacked,
        showInput: settings.showInput !== false && !busy,
        lock: busy && settings.lockComposeWhileBusy === true,
        cards: []
      })
      if (out.length >= settings.entryLimit) break
    }
    return out
  }
}

function resolveSettings(config) {
  const raw = asRecord(config) ?? {}
  const settings = { ...DEFAULTS }
  for (const [key, value] of Object.entries(raw)) if (value !== undefined && value !== null) settings[key] = value
  settings.ballSize = Math.max(24, Math.min(160, asNumber(settings.ballSize) || DEFAULTS.ballSize))
  settings.panelWidth = Math.max(240, Math.min(720, asNumber(settings.panelWidth) || DEFAULTS.panelWidth))
  settings.panelHeight = Math.max(120, Math.min(900, asNumber(settings.panelHeight) || DEFAULTS.panelHeight))
  settings.entryLimit = Math.max(1, Math.min(50, asNumber(settings.entryLimit) || DEFAULTS.entryLimit))
  return settings
}

function runtimeDir() {
  if (process.env.DSH_BALL_DIR) return process.env.DSH_BALL_DIR
  const base = process.env.LOCALAPPDATA || join(homedir(), 'AppData', 'Local')
  return join(base, 'dsh-session-ball', 'default')
}

/**
 * Single-instance guard. A reload can mount the plugin again before the previous instance is
 * disposed; without this the second instance also spawns a ball and both write state-*.json into
 * the same directory (the ball then reads alternating documents: panel closes/reopens, height
 * grows, position jumps). The lock is a pid file; a stale pid is taken over.
 */
function acquireInstanceLock(dir) {
  const lockPath = join(dir, `host-${process.pid}.lock`)
  try {
    mkdirSync(dir, { recursive: true })
    for (const entry of readdirSync(dir)) {
      if (!entry.startsWith("host-") || !entry.endsWith(".lock")) continue
      const pid = Number(entry.slice(5, -5))
      if (!Number.isFinite(pid) || pid === process.pid) continue
      try {
        process.kill(pid, 0)
        return { ok: false, path: lockPath, other: pid }
      } catch {
        rmSync(join(dir, entry), { force: true })
      }
    }
    writeFileSync(lockPath, String(process.pid), "utf8")
    return { ok: true, path: lockPath }
  } catch (error) {
    return { ok: true, path: lockPath, error: String(error) }
  }
}

export function apply(ctx, config) {
  const settings = resolveSettings(config)
  if (settings.enabled !== true) {
    ctx.logger?.info?.('session-ball：已禁用（config.enabled = false）')
    return
  }
  if (process.platform !== 'win32') {
    ctx.logger?.warn?.('session-ball：只支持 Windows')
    return
  }

  const dir = runtimeDir()

  const mirror = new SessionMirror()
  const closed = new Set()
  const pendings = new Map()
  let createPending = false
  const signals = new Map()
  const overlay = new Overlay({
    dir,
    settings,
    onAction: (action) => {
      const kind = asString(action.kind)
      if (kind === 'close') {
        if (asString(action.id) === 'local-new') { createPending = false; writeStateNow(); return }
        closed.add(asString(action.id))
        mirror.ackError(asString(action.id))
        writeStateNow()
        return
      }
      if (kind === 'ack') {
        mirror.ackError(asString(action.id))
        writeStateNow()
        return
      }
      if (kind === 'prompt') {
        void sendPrompt(asString(action.target), asString(action.text), asString(action.key))
        return
      }
      if (kind === 'new') {
        createPending = true
        writeStateNow()
        return
      }
      if (kind === 'approval' || kind === 'question' || kind === 'answer') {
        const card = pendings.get(asString(action.id))
        if (card === undefined) {
          overlay.log(`answer for unknown card ${String(action.id)} ignored`)
          return
        }
        if (kind === 'answer') {
          const answers = normalizeBallAnswers(action.answers)
          if (answers.length === 0) return
          card.resolve({ answers })
          writeStateNow()
          overlay.log(`question ${card.id} answered (${answers.length} item(s))`)
          return
        }
        const value = asString(action.optionId) || asString(action.value)
        if (value === '') return
        card.resolve(value === 'rejected' ? 'rejected' : 'allowed-once')
        writeStateNow()
        overlay.log(`approval ${card.id} answered: ${value}`)
        return
      }
    }
  })

  async function createSession(text) {
    createPending = false
    const controller = ctx.get('sessionController')
    let cwd = ''
    const byRecency = [...mirror.rows.values()].sort((left, right) => right.lastActivityAt - left.lastActivityAt)
    for (const row of byRecency) {
      if (row.cwd !== '') { cwd = row.cwd; break }
    }
    const request = cwd === '' ? {} : { cwd }
    try {
      let created
      if (typeof controller?.create === 'function') created = await controller.create(request)
      else {
        const gateway = ctx.get('typertGateway')
        if (typeof gateway?.invoke !== 'function') throw new Error('no session create route')
        created = await gateway.invoke({ namespace: 'session', method: 'create', args: { request } })
      }
      const sessionId = asString(asRecord(created)?.sessionId)
      if (sessionId === '') throw new Error('create returned no sessionId')
      overlay.log(`new session created: ${sessionId}`)
      await sendPrompt(sessionId, text, sessionId)
    } catch (error) {
      overlay.log(`new session failed: ${String(error)}`)
    }
  }

  async function sendPrompt(target, text, key) {
    if (target === 'new') { await createSession(text); return }
    const value = oneLine(text, 4000)
    if (value === '') return
    if (target === '') { overlay.log('prompt dropped: empty target (entry not mapped to a session)'); return }
    const sessionId = target.startsWith('new:') ? '' : target
    if (sessionId === '') {
      overlay.log('prompt target is a new-session row; not wired yet')
      return
    }
    const row = mirror.rows.get(sessionId)
    const running = row !== undefined && (row.busy || row.running)
    const preferred = settings.promptMode === 'auto' || settings.promptMode === undefined
      ? (running ? 'steer' : 'queue')
      : settings.promptMode
    const modes = preferred === 'steer' ? ['steer', 'queue'] : ['queue']
    const controller = ctx.get('sessionController')
    const gateway = ctx.get('typertGateway')
    const routes = []
    if (typeof controller?.prompt === 'function') routes.push((request) => controller.prompt(request))
    if (typeof gateway?.invoke === 'function') {
      routes.push((request) => gateway.invoke({ namespace: 'session', method: 'prompt', args: { request } }))
    }
    if (routes.length === 0) {
      overlay.log(`prompt failed (${key || sessionId}): no prompt route`)
      return
    }
    let sent = false
    let lastError = ''
    for (const mode of modes) {
      for (const route of routes) {
        const request = {
          requestId: randomUUID(),
          sessionId,
          mode,
          content: [{ type: 'text', text: value }]
        }
        try {
          await route(request)
          overlay.log(`prompt sent (${key || sessionId}, ${mode}): ${value}`)
          sent = true
          break
        } catch (error) {
          lastError = String(error)
        }
      }
      if (sent) break
    }
    if (!sent) overlay.log(`prompt failed (${key || sessionId}): ${lastError}`)
  }

  function buildState() {
    const now = Date.now()
    const pendingCards = [...pendings.values()]
    let status = mirror.statusOf()
    if (pendingCards.some((card) => card.kind === 'approval')) status = { key: 'approval', running: status.running }
    else if (pendingCards.some((card) => card.kind === 'question')) status = { key: 'asking', running: status.running }
    const entries = []
    for (const entry of mirror.entries(now, settings)) {
      const row = mirror.rows.get(entry.key)
      const signal = row === undefined ? 0 : row.signal
      const lastSignal = signals.get(entry.key)
      if (closed.has(entry.key)) {
        if (lastSignal === undefined || lastSignal === signal) continue
        closed.delete(entry.key)
      }
      signals.set(entry.key, signal)
      entries.push(entry)
    }
    // Cards (approval / question) hang off their session entry; sessions without an entry yet get one.
    const byKey = new Map(entries.map((entry) => [entry.key, entry]))
    for (const card of pendingCards) {
      const key = card.sessionId !== '' ? card.sessionId : 'card:' + card.id
      let entry = byKey.get(key)
      if (entry === undefined) {
        entry = {
          key,
          target: card.sessionId,
          title: oneLine(mirror.rows.get(card.sessionId)?.title || mirror.rows.get(card.sessionId)?.cwd || card.title),
          chip: '',
          state: card.kind,
          color: card.kind === 'approval' ? STYLES.approval.color : STYLES.asking.color,
          hint: '',
          canAck: false,
          showInput: false,
          lock: false,
          cards: []
        }
        entries.push(entry)
        byKey.set(key, entry)
      }
      entry.state = card.kind
      entry.chip = card.kind === 'approval' ? LABELS.approval : LABELS.question
      entry.color = card.kind === 'approval' ? STYLES.approval.color : STYLES.asking.color
      entry.cards = (entry.cards ?? []).concat([{
        id: card.id,
        kind: card.kind,
        title: card.title,
        hint: card.hint ?? '',
        options: card.options ?? [],
        items: card.items ?? []
      }])
      entry.showInput = false
      entry.lock = false
      entry.canAck = false
    }
    if (createPending) {
      entries.unshift({
        key: 'local-new',
        target: 'new',
        title: LABELS.newSession,
        chip: LABELS.newSessionChip,
        state: 'local',
        color: STYLES.working.color,
        hint: '',
        canAck: false,
        showInput: true,
        lock: false,
        cards: []
      })
    }
    const unacked = [...mirror.rows.values()].filter((row) => row.status === 'error' && !row.errorAcked).length
    const style = STYLES[status.key] ?? STYLES.idle
    return {
      v: 9,
      status: { key: status.key, label: status.label, color: style.color },
      running: status.running,
      pendingCount: pendingCards.length,
      labels: LABELS,
      entries,
      metrics: {
        ballSize: settings.ballSize,
        panelWidth: settings.panelWidth,
        panelHeight: settings.panelHeight
      },
      window: {
        visible: true,
        expanded: overlay.window.expanded === true,
        opacity: asNumber(settings.opacity) || 1,
        ...(typeof overlay.window.x === 'number' ? { x: overlay.window.x } : {}),
        ...(typeof overlay.window.y === 'number' ? { y: overlay.window.y } : {})
      }
    }
  }

  const events = ctx
  events.on('api-session/added', (summary) => mirror.summary(summary))
  events.on('api-session/status', (sessionId, running) => mirror.status(asString(sessionId), running === true))
  events.on('api-session/activity', (sessionId, updatedAt) => mirror.activity(asString(sessionId), updatedAt))
  events.on('api-session/removed', (sessionId) => mirror.removed(asString(sessionId)))
  events.on('session/event', (session, event) => mirror.sessionEvent(session, event))
  events.on('agent/assistant-stream', (payload) => mirror.stream(payload))

  events.on('approval/request', async (request, next) => {
    if (settings.answerApprovals !== true) return next()
    const record = asRecord(request) ?? {}
    const sessionId = asString(asRecord(record.agent)?.id)
    const toolName = asString(record.toolName)
    const id = 'a-' + (asString(record.callId) || randomUUID())
    const options = [
      { id: 'allowed-once', label: '允许一次' },
      { id: 'rejected', label: '拒绝' }
    ]
    const reason = approvalReason(record)
    const title = reason !== '' ? reason : toolName === '' ? '模型在等你批准这次操作' : `允许执行 ${toolName} 吗？`
    const hint = toolName === '' ? '' : `工具：${toolName}`
    const upstream = Promise.resolve().then(() => next())
    upstream.catch(() => undefined)
    let resolveOutcome
    const ballOutcome = new Promise((resolve) => { resolveOutcome = resolve })
    pendings.set(id, { id, kind: 'approval', sessionId, title, hint, options, resolve: resolveOutcome })
    try {
      return await Promise.race([ballOutcome, upstream])
    } finally {
      pendings.delete(id)
    }
  })

  events.on('user-questions/request', async (request, next) => {
    if (settings.answerQuestions !== true) return next()
    const record = asRecord(request) ?? {}
    const rawItems = Array.isArray(record.questions) ? record.questions : []
    const items = []
    for (const rawItem of rawItems) {
      const item = asRecord(rawItem)
      const id = asString(item?.id)
      if (id === '') continue
      const options = []
      for (const rawOption of Array.isArray(item?.options) ? item.options : []) {
        const option = asRecord(rawOption)
        const label = asString(option?.label)
        if (label === '') continue
        options.push({ id: label, label, description: asString(option?.description) })
      }
      items.push({
        id,
        header: asString(item?.header),
        prompt: asString(item?.question) || asString(item?.header) || '',
        detail: asString(item?.detail),
        multiSelect: item?.multiSelect === true,
        options
      })
    }
    if (items.length === 0) return next()
    const sessionId = asString(asRecord(record.agent)?.id)
    const callId = asString(asRecord(record.wait)?.callId)
    const id = 'q-' + (callId || randomUUID())
    const title = items.length === 1 ? items[0].prompt || '模型在等你回答' : '模型在等你回答几个问题'
    const upstream = Promise.resolve().then(() => next())
    upstream.catch(() => undefined)
    let resolveAnswer
    const ballOutcome = new Promise((resolve) => { resolveAnswer = resolve })
    pendings.set(id, { id, kind: 'question', sessionId, title, items, resolve: resolveAnswer })
    try {
      return await Promise.race([ballOutcome, upstream])
    } finally {
      pendings.delete(id)
    }
  })

  let stateTimer
  let retryTimer
  let lock

  const writeStateNow = () => {
    if (stateTimer === undefined) return
    try {
      overlay.writeState(buildState())
    } catch (error) {
      overlay.log(`state build failed: ${String(error)}`)
    }
  }

  const startLoop = () => {
    if (stateTimer !== undefined) return true
    const acquired = acquireInstanceLock(dir)
    if (!acquired.ok) return false
    lock = acquired
    overlay.start()
    stateTimer = setInterval(() => {
      try {
        overlay.writeState(buildState())
      } catch (error) {
        overlay.log(`state build failed: ${String(error)}`)
      }
    }, STATE_TICK_MS)
    ctx.logger?.info?.(`session-ball：悬浮球已启用（host v2 原型，运行目录 ${overlay.dir}）`)
    return true
  }

  ctx.effect?.(() => {
    if (!startLoop()) {
      // A reload can mount this instance before the previous one is disposed. Its cleanup removes
      // the lock within a moment, so wait instead of giving up (giving up would leave no ball).
      ctx.logger?.warn?.('session-ball：另一个宿主实例仍在运行，等待它退出后接管')
      retryTimer = setInterval(() => {
        if (!startLoop()) return
        clearInterval(retryTimer)
        retryTimer = undefined
      }, 400)
    }
    return () => {
      if (retryTimer !== undefined) clearInterval(retryTimer)
      if (stateTimer !== undefined) clearInterval(stateTimer)
      overlay.stop()
      try {
        if (lock !== undefined && readFileSync(lock.path, 'utf8').trim() === String(process.pid)) rmSync(lock.path, { force: true })
      } catch {}
    }
  })
}

export default { name, apply }
