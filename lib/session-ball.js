import Schema from "@deepseek-ai/schemastery";
import { createHash, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
//#region src/mirror.ts
/** 状态 → 中文标签 + 颜色。颜色给的是 `#AARRGGBB`，直接进 WPF 画刷。 */
const STATUS_STYLES = {
	idle: {
		label: "空闲",
		color: "#FF7C8598"
	},
	working: {
		label: "正在输出",
		color: "#FF5B8DEF"
	},
	asking: {
		label: "正在向你提问",
		color: "#FFE0A64B"
	},
	approval: {
		label: "正在请求审批",
		color: "#FFE0574B"
	},
	error: {
		label: "出错了",
		color: "#FFE0574B"
	}
};
/** 提问工具的名字。 */
const ASK_TOOL = "ask_user_question";
/** 会话首条用户消息摘要的长度上限（字符）：一行就够认人。 */
const SESSION_TEXT_CHARS = 48;
/**
* 从一次 `ask_user_question` 调用的参数里取出问题编号签名。
* 参数可能是半截 JSON：那时返回 undefined，卡片退回按投影对账，不误判。
*/
function questionSignatureOf(argumentsJson) {
	const trimmed = argumentsJson.trim();
	if (trimmed === "" || trimmed[0] !== "{") return void 0;
	let parsed;
	try {
		parsed = JSON.parse(trimmed);
	} catch {
		return;
	}
	const questions = asRecord(parsed)?.questions;
	if (!Array.isArray(questions)) return void 0;
	const ids = [];
	for (const entry of questions) {
		const id = asString(asRecord(entry)?.id);
		if (id !== "") ids.push(id);
	}
	if (ids.length === 0) return void 0;
	return [...ids].sort().join("|");
}
/** 工具结果是不是"问题尚未作答，已转为可继续回答"（pending）。 */
function isPendingToolResult(data) {
	if (asString(asRecord(data.error)?.code) === "TOOL_OUTCOME_UNKNOWN") return true;
	const message = asRecord(data.message);
	for (const block of asArray(message?.content)) {
		const record = asRecord(block);
		if (record?.type !== "text") continue;
		const text = asString(record.text);
		if (text.trim() === "") continue;
		try {
			if (JSON.parse(text)?.pending === true) return true;
		} catch {}
	}
	return false;
}
/** 取值小工具：`asRecord` 与 `oneLine` 两个模块共用（`session-ball.ts` 也从这里 import）。 */
function asRecord(value) {
	return typeof value === "object" && value !== null ? value : void 0;
}
function asString(value) {
	return typeof value === "string" ? value : "";
}
function asNumber(value) {
	return typeof value === "number" && Number.isFinite(value) ? value : 0;
}
function asArray(value) {
	if (value === void 0 || value === null) return [];
	return Array.isArray(value) ? value : [value];
}
/** 有值才放进对象字面量里（`undefined` 不该成为一个真实字段）。 */
function optionalSignature(signature) {
	return signature === void 0 ? {} : { questionSignature: signature };
}
/** 一份 `title` 投影的值 → 一行标题；拿不到就是空串。两种形状都认（`string` 或 `{ title }`）。 */
function projectedTitleText(value) {
	if (typeof value === "string") return value.trim();
	const record = asRecord(value);
	return record === void 0 ? "" : asString(record.title).trim();
}
/** 单行化 + 按字符截断（球上的一行放不下多少东西）。 */
function oneLine(text, limit = 120) {
	const flat = text.replace(/\s+/g, " ").trim();
	return flat.length <= limit ? flat : `${flat.slice(0, limit)}…`;
}
/** 从内容块数组里取出所有文本块的文本（思维链块不留：球上不显示正文与思维链）。 */
function messageText(content) {
	const parts = [];
	for (const block of asArray(content)) {
		const record = asRecord(block);
		if (record === void 0 || record.type !== "text") continue;
		const text = asString(record.text);
		if (text !== "") parts.push(text);
	}
	return parts.join("");
}
/** 会话目录里一个会话的最近活动时间：目录时间与球自己看到的时间取大者。 */
function activityOf(session) {
	return Math.max(session.updatedAt, session.lastAt);
}
/**
* 一条 `user/message` 事件的 `source.kind`。
* `data` 就是那条消息，也兼容"包在 `message` 里"的形状；读不到给空串（当"不是人说的"）。
*/
function userMessageSourceKind(data) {
	return asString((asRecord(asRecord(data.message)?.source) ?? asRecord(data.source))?.kind);
}
/**
* 一次工具调用**失败**的原因，一行。
*
* 这是球上仅剩的一处"工具调用内容"，而且它不是内容而是结论：面板顶上那行 meta 用它说明
* "刚才那一步炸了、炸在哪"，参数与输出本身不再进视图（`tool/result` 只留成败）。
*/
function toolFailureNote(data) {
	const error = asRecord(data.error);
	if (error === void 0) return "调用失败";
	return oneLine([asString(error.code), asString(error.reason) || asString(error.name)].filter((part) => part !== "").join("：") || "调用失败", 160);
}
var Mirror = class {
	/** 每次视图内容真正变化时自增；落盘侧用它决定"要不要重写 state.json"。 */
	revision = 0;
	sessions = /* @__PURE__ */ new Map();
	pending = /* @__PURE__ */ new Map();
	hidden = /* @__PURE__ */ new Set();
	pingCounter = 0;
	/** 会话标题来源（`ctx.get('sessionTitle')` / `title` 投影），可选：没有就退到首条用户消息 / 目录。 */
	titleOf;
	setTitleResolver(resolver) {
		this.titleOf = resolver;
	}
	/**
	* 从外面补一个标题进来：`api-session/added` 只在会话可见/建散时来一次，标题却之后才异步
	* 落进日志，只认那次快照会让会话一直"没有标题"。标题非空才写，且不往回改。
	*
	* @returns 这次调用是否真的改动了视图（调用方据此决定要不要记日志）。
	*/
	setTitle(id, title) {
		const value = oneLine(title, 120);
		if (value === "") return false;
		const session = this.sessions.get(id);
		if (session === void 0) return false;
		if (session.title === value) return false;
		session.title = value;
		this.revision += 1;
		return true;
	}
	ensure(id) {
		let session = this.sessions.get(id);
		if (session === void 0) {
			session = {
				id,
				title: "",
				text: "",
				cwd: "",
				origin: "",
				parentId: "",
				running: false,
				lastAt: 0,
				updatedAt: 0,
				blank: true,
				turn: 0,
				step: 0,
				turnTokens: /* @__PURE__ */ new Map(),
				tokenTurn: 0,
				tools: /* @__PURE__ */ new Map(),
				activeToolId: "",
				status: "idle",
				errorNote: "",
				errorAcked: false,
				signal: 0
			};
			this.sessions.set(id, session);
		}
		return session;
	}
	/** 会话目录里的行（`api-session/added`）：目录、父子关系、运行状态、标题。 */
	onSessionSummary(summary) {
		const record = asRecord(summary);
		if (record === void 0) return;
		const id = asString(record.sessionId);
		if (id === "") return;
		const session = this.ensure(id);
		session.cwd = asString(record.cwd) || session.cwd;
		session.origin = asString(record.origin) || session.origin;
		session.parentId = asString(record.parentSessionId) || session.parentId;
		session.running = record.running === true;
		session.updatedAt = Math.max(session.updatedAt, asNumber(record.updatedAt));
		if (record.blank === true) session.blank = true;
		const title = projectedTitleText(asRecord(asRecord(record.projections)?.values)?.title);
		if (title !== "") session.title = title;
		this.revision += 1;
	}
	/**
	* 球自己新建了一个会话：先把它登记进目录，下拉列表立刻就能选它，不用等 harness 的事件。
	* @param id - 新会话 id。
	* @param cwd - 会话目录（新会话继承发起它的那个会话的目录）。
	*/
	adoptSession(id, cwd) {
		if (id === "") return;
		const session = this.ensure(id);
		if (cwd !== "") session.cwd = cwd;
		session.updatedAt = Math.max(session.updatedAt, Date.now());
		session.blank = true;
		this.revision += 1;
	}
	onSessionStatus(sessionId, running) {
		const id = asString(sessionId);
		if (id === "") return;
		const session = this.ensure(id);
		const next = running === true;
		const wasRunning = session.running;
		session.running = next;
		if (next && !wasRunning) session.signal += 1;
		this.revision += 1;
	}
	/** 一轮用户消息推进了会话活动（`api-session/activity`）：只影响下拉列表的排序。 */
	onSessionActivity(sessionId, updatedAt) {
		const id = asString(sessionId);
		if (id === "") return;
		const session = this.ensure(id);
		const next = asNumber(updatedAt);
		if (next === 0 || next <= session.updatedAt) return;
		session.updatedAt = next;
		this.revision += 1;
	}
	/** 会话离开 live 注册表（`api-session/removed`）：从下拉列表里摘掉，别让人选一个死的。 */
	onSessionRemoved(sessionId) {
		const id = asString(sessionId);
		if (id === "") return;
		if (!this.sessions.delete(id)) return;
		this.revision += 1;
	}
	/**
	* 助手流式帧（`agent/assistant-stream`）：只取"现在处于哪一步、在做什么"。
	* 增量不留；这一步的状态只用来判断这个会话在不在跑（`working` 与白晕都从这份"在不在跑"折出来），
	* 球上不按它**逐步**变色。
	*/
	onStream(payload) {
		const record = asRecord(payload);
		if (record === void 0) return;
		const agent = asRecord(record.agent);
		const frame = asRecord(record.frame);
		if (agent === void 0 || frame === void 0) return;
		const id = asString(agent.id);
		if (id === "") return;
		const session = this.ensure(id);
		session.lastAt = Date.now();
		this.applyFrame(session, frame);
	}
	/** 一帧流式内容落到会话上（`onStream` 只负责去重，真正的折叠在这里）。 */
	applyFrame(session, frame) {
		const type = asString(frame.type);
		const turn = asNumber(frame.turn);
		const step = asNumber(frame.step);
		if (type === "start") {
			if (turn !== 0 && turn !== session.turn) session.signal += 1;
			session.turn = turn;
			session.step = step;
			session.activeToolId = "";
			session.status = "thinking";
			session.errorNote = "";
			session.errorAcked = false;
			session.blank = false;
			this.revision += 1;
			return;
		}
		if (type !== "chunk") return;
		if (turn !== 0 && (turn !== session.turn || step !== session.step)) {
			session.turn = turn;
			session.step = step;
			session.activeToolId = "";
		}
		const chunk = asRecord(frame.chunk);
		if (chunk === void 0) return;
		const chunkType = asString(chunk.type);
		if (chunkType === "reasoning-delta") {
			if (session.status !== "writing" && session.status !== "tool") session.status = "thinking";
			this.revision += 1;
			return;
		}
		if (chunkType === "text-delta") {
			session.status = "writing";
			this.revision += 1;
			return;
		}
		if (chunkType === "tool-call-delta") {
			const toolId = asString(chunk.id);
			const name = asString(chunk.name);
			if (toolId !== "" && name !== "") {
				const tool = session.tools.get(toolId) ?? {
					callId: toolId,
					name,
					startedAt: Date.now()
				};
				tool.name = name;
				session.tools.set(toolId, tool);
				session.activeToolId = toolId;
				session.status = "tool";
				this.revision += 1;
			}
			return;
		}
		if (chunkType === "usage") {
			const usage = asRecord(chunk.usage);
			if (usage !== void 0) {
				this.creditTokens(session, turn, step, asNumber(usage.outputTokens));
				this.revision += 1;
			}
		}
	}
	/** 这个会话现在算不算"在跑道上的"（不看"是不是在等用户作答"）。 */
	midTurn(session) {
		return session.running || session.status === "thinking" || session.status === "writing" || session.status === "tool";
	}
	/** 提交后的会话事件（`session/event`）。 */
	onSessionEvent(session, event) {
		const sessionRecord = asRecord(session);
		const eventRecord = asRecord(event);
		if (sessionRecord === void 0 || eventRecord === void 0) return;
		const id = asString(sessionRecord.id);
		if (id === "") return;
		const runtime = this.ensure(id);
		runtime.lastAt = Date.now();
		const wasStatus = runtime.status;
		const wasErrorNote = runtime.errorNote;
		if (runtime.title === "" && this.titleOf !== void 0) try {
			runtime.title = this.titleOf(session) ?? "";
		} catch {}
		const type = asString(eventRecord.type);
		const data = asRecord(eventRecord.data) ?? {};
		switch (type) {
			case "turn/start":
				runtime.signal += 1;
				runtime.turn = asNumber(data.turn);
				runtime.step = 0;
				runtime.activeToolId = "";
				runtime.errorNote = "";
				runtime.errorAcked = false;
				runtime.status = "thinking";
				runtime.blank = false;
				break;
			case "turn/end": {
				const reason = asRecord(data.reason);
				const kind = asString(reason?.kind);
				runtime.activeToolId = "";
				if (kind === "error" || kind === "aborted") {
					runtime.status = "error";
					runtime.errorNote = asString(asRecord(reason?.error)?.message) || (kind === "aborted" ? "本轮被中止" : "本轮出错");
				} else runtime.status = "idle";
				break;
			}
			case "tool/call": {
				const callId = asString(data.callId);
				if (callId === "") break;
				const name = asString(data.name);
				const argumentsJson = asString(data.arguments);
				runtime.tools.set(callId, {
					callId,
					name,
					rawArguments: argumentsJson,
					startedAt: Date.now(),
					...name === ASK_TOOL ? optionalSignature(questionSignatureOf(argumentsJson)) : {}
				});
				runtime.activeToolId = callId;
				runtime.status = "tool";
				break;
			}
			case "tool/result": {
				const message = asRecord(data.message);
				const callId = asString(message?.toolCallId);
				if (callId === "") break;
				const tool = runtime.tools.get(callId);
				const ok = data.error === void 0 && message?.isError !== true;
				if (tool !== void 0) {
					tool.finishedAt = Date.now();
					if (tool.name === ASK_TOOL) tool.pendingResult = isPendingToolResult(data);
				}
				if (runtime.activeToolId === callId) runtime.activeToolId = "";
				runtime.status = ok ? "thinking" : "error";
				if (!ok) runtime.errorNote = toolFailureNote(data);
				break;
			}
			case "session/title": {
				const title = oneLine(asString(data.title), 120);
				if (title !== "" && title !== runtime.title) runtime.title = title;
				break;
			}
			case "assistant/message": {
				data.message;
				const usage = asRecord(data.usage);
				if (usage !== void 0) this.creditTokens(runtime, asNumber(data.turn) || runtime.turn, asNumber(data.step) || runtime.step, asNumber(usage.outputTokens));
				runtime.turn = asNumber(data.turn) || runtime.turn;
				runtime.step = asNumber(data.step) || runtime.step;
				break;
			}
			case "user/message": {
				const fromUser = userMessageSourceKind(data) === "user";
				if (runtime.text === "" && fromUser) {
					const text = messageText((asRecord(data.message) ?? data)?.content);
					if (text.trim() !== "") runtime.text = oneLine(text, SESSION_TEXT_CHARS);
				}
				if (fromUser) runtime.signal += 1;
				runtime.status = "thinking";
				runtime.errorNote = "";
				runtime.errorAcked = false;
				if (fromUser) runtime.blank = false;
				break;
			}
			default: return;
		}
		if (runtime.status === "error" && (wasStatus !== "error" || runtime.errorNote !== wasErrorNote)) {
			runtime.errorAcked = false;
			runtime.signal += 1;
		}
		this.revision += 1;
	}
	addPending(view) {
		this.pending.set(view.id, view);
		this.hidden.delete(view.id);
		this.pingCounter += 1;
		if (view.sessionId !== "") {
			const session = this.sessions.get(view.sessionId);
			if (session !== void 0) session.signal += 1;
		}
		this.revision += 1;
	}
	/**
	* 出错的红被人在球上确认了（条目上的「知道了」，或者把那一行「×」掉 —— 后者既收条目也确认，
	* 见 session-ball.ts 的 `closeEntry()`）：这条错误不再参与整体颜色（`statusOf()`）、也不再进
	* 面板第二行那行统计里的"出错"。
	*
	* **只改颜色这件事**：调用方自己决定条目留不留（「知道了」留着，`close` 收掉）。所以这个方法
	* 不碰条目的生命周期，只碰这条错误还参不参与颜色。
	*
	* @returns 这次调用是否真的改了东西（调用方据此决定要不要写提示）。
	*/
	ackError(sessionId) {
		const session = this.sessions.get(sessionId);
		if (session === void 0) return false;
		if (session.status !== "error" || session.errorAcked) return false;
		session.errorAcked = true;
		this.revision += 1;
		return true;
	}
	/** 某个会话的活动计数（面板条目的生命周期靠它，见 `SessionRuntime.signal`）。 */
	signalOf(sessionId) {
		return this.sessions.get(sessionId)?.signal ?? 0;
	}
	updatePending(id, patch) {
		const current = this.pending.get(id);
		if (current === void 0) return;
		this.pending.set(id, {
			...current,
			...patch
		});
		this.revision += 1;
	}
	removePending(id) {
		if (!this.pending.delete(id)) return;
		this.revision += 1;
	}
	/** 只在球上收起来，底层请求照旧（网页端仍然可以作答）。 */
	hidePending(id) {
		if (!this.pending.has(id)) return;
		this.hidden.add(id);
		this.revision += 1;
	}
	/**
	* 球上**看得见**的待办卡片。状态灯、底部提示、计数、焦点会话全部只认这一份：被「先收起来」
	* 收掉的卡片还在内存里（还要跟着请求的生命周期走），但它绝不该继续把状态灯钉在「正在向你提问」上。
	*/
	visiblePendings() {
		return [...this.pending.values()].filter((view) => !this.hidden.has(view.id)).sort((left, right) => left.createdAt - right.createdAt);
	}
	/**
	* 某个会话现在是否在跑（球上给它发话时，用它决定排队还是插话）。
	*/
	runningOf(sessionId) {
		return this.sessions.get(sessionId)?.running ?? false;
	}
	/**
	* 现在**正在输出**的会话 id：球上输入框据此决定锁不锁它自己（见 `MirrorSnapshot.busy`）。
	*
	* 判据两条，取并集 —— 因为两条各自都会漏：
	*
	*   1. **会话目录说它在跑**（`api-session/status` → `session.running`）。权威，而且球挂载时
	*      `api-session/added` 就带一份初值；但它是一条独立的广播，球不一定收到每一条。
	*   2. **球自己折出来的这个会话状态不在空闲/出错**（`session.status`：`turn/start`、`user/message`、
	*      流式帧与 `turn/end` 折出来的）。只要会话事件流还在（球看见的就是它），它就准；
	*      但它只覆盖球看见过事件的会话。
	*
	* **正在等你作答的会话不算"输出中"**：那一刻模型在等人，球上那个输入框正是这时候最该能用
	* （球自己的状态灯也在说"正在向你提问"）。这里认的是**全部**待办（含被「先收起来」收掉的）
	* ——"模型在等你"与卡片在不在球上无关。
	*
	* 子代理不进来：球上那个输入框永远发不到子代理（下拉与焦点都不含它们）。
	*
	* @returns 正在输出的会话 id（稳定排序，同一份视图不会因为遍历顺序而抖动）。
	*/
	busySessions() {
		const waiting = /* @__PURE__ */ new Set();
		for (const view of this.pending.values()) if (view.sessionId !== "") waiting.add(view.sessionId);
		const ids = [];
		for (const session of this.sessions.values()) {
			if (session.id === "" || session.origin === "subagent") continue;
			if (waiting.has(session.id)) continue;
			if (this.midTurn(session)) ids.push(session.id);
		}
		return ids.sort();
	}
	/** 某个会话的目录（新建会话时继承它）。 */
	cwdOf(sessionId) {
		return this.sessions.get(sessionId)?.cwd ?? "";
	}
	/**
	* 面板条目要用的会话一览：根会话（子代理不进来），按最近活动倒序。
	*
	* 为什么用球自己手里的目录、而不是去问别处：这些会话就是 harness 通过 `api-session/*` 主动告诉
	* 球的那些（与网页端侧边栏同一份摘要，带 title 投影），所以不需要新的服务、也不会在拿不到会话
	* 列表时把面板变成空的。
	*
	* `busy` 在这里算一次（`busySessions()` 的口径，"在输出、且不是在等你作答"），因为条目里那个
	* 输入框的锁只认它；`running` 是目录自己的说法，条目上那句"运行中"两个都认（并集）。
	*/
	panelSessions() {
		const busy = new Set(this.busySessions());
		const rows = [];
		for (const session of this.sessions.values()) {
			if (session.origin === "subagent") continue;
			if (session.id === "") continue;
			rows.push({
				id: session.id,
				title: session.title,
				text: session.text,
				cwd: session.cwd,
				blank: session.blank,
				running: session.running,
				busy: busy.has(session.id),
				updatedAt: activityOf(session),
				status: session.status,
				errorNote: session.errorNote,
				errorAcked: session.errorAcked,
				signal: session.signal
			});
		}
		rows.sort((left, right) => {
			if (left.updatedAt !== right.updatedAt) return right.updatedAt - left.updatedAt;
			return left.id.localeCompare(right.id);
		});
		return rows;
	}
	/**
	* 某次工具调用的原始参数：用来读 `timeout` 这类字段，球上不直接显示它。
	*/
	toolArguments(sessionId, callId) {
		return this.sessions.get(sessionId)?.tools.get(callId)?.rawArguments;
	}
	/**
	* 反过来找：这几道问题是由哪一次 `ask_user_question` 调用问的，那次调用结束了没有。
	*
	* 这是提问卡片生命周期的**自足**判据：只用球本来就在消费的那条事件流（`tool/call` 与
	* `tool/result`），不依赖任何别的服务。它顺手补上了 `wait.callId` 缺席时缺的那个 callId，
	* 这也是超时之后仍能在球上作答的前提。
	*/
	questionCallState(sessionId, questionIds) {
		const session = this.sessions.get(sessionId);
		if (session === void 0 || questionIds.length === 0) return void 0;
		const signature = [...questionIds].sort().join("|");
		let best;
		for (const tool of session.tools.values()) {
			if (tool.questionSignature !== signature) continue;
			if (best === void 0 || tool.startedAt >= best.startedAt) best = tool;
		}
		if (best === void 0) return void 0;
		return {
			callId: best.callId,
			finished: best.finishedAt !== void 0,
			pending: best.pendingResult === true
		};
	}
	/**
	* 显示状态：**整体口径**。审批压过提问（更急），两者都压过出错；没有待办时，只要有根会话
	* 出错就是"出错了"，否则只要还有会话在输出就是"正在输出"，都没有才是"空闲"。
	*
	* `working` 排在出错与两类待办**之后**是刻意的：那三种都是"要你看一眼"的事，不该被"有会话
	* 在忙"盖过去。反过来，`working` 自己就是那条"任务跑完了"的信号 —— 它没有别的内容，只是
	* 在还有会话输出时把球染成蓝色、等最后一个会话停下来时**自己消失**（球随即回到空闲灰）。
	* 所以球上不需要第二条"任务完成"的提示，也不需要在任务结束时额外播什么。
	*/
	statusOf(visible, errors, running) {
		if (visible.some((view) => view.kind === "approval")) return "approval";
		if (visible.length > 0) return "asking";
		if (errors.length > 0) return "error";
		if (running > 0) return "working";
		return "idle";
	}
	/**
	* 出错的根会话（最近有动静的排在前面）。
	*
	* **已经被「知道了」点掉的那些不算**：这句话是整个"红不再自己消失"的另一半 —— 红的出现由出错
	* 决定，红的消失由人决定（见 `ackError()`）。它们仍然留在自己的面板条目上（会话条目里写着
	* "已确认出错"），只是不再参与球的颜色与这行统计。
	*/
	errorSessions() {
		const found = [];
		for (const session of this.sessions.values()) {
			if (session.id === "" || session.origin === "subagent") continue;
			if (session.status !== "error") continue;
			if (session.errorAcked) continue;
			found.push({
				view: {
					id: session.id,
					title: session.title,
					text: session.text,
					cwd: session.cwd,
					blank: session.blank,
					note: session.errorNote
				},
				at: activityOf(session)
			});
		}
		found.sort((left, right) => right.at - left.at);
		return found.map((item) => item.view);
	}
	snapshot() {
		const pending = this.visiblePendings();
		const errors = this.errorSessions();
		const busy = this.busySessions();
		const statusKey = this.statusOf(pending, errors, busy.length);
		const style = STATUS_STYLES[statusKey];
		const children = [...this.sessions.values()].filter((item) => item.origin === "subagent" && item.running).length;
		let tokensOut = 0;
		for (const id of busy) {
			const session = this.sessions.get(id);
			if (session === void 0) continue;
			for (const value of session.turnTokens.values()) tokensOut += value;
		}
		return {
			status: {
				key: statusKey,
				label: statusKey === "working" ? `${busy.length} 个会话在跑` : style.label,
				color: style.color
			},
			running: busy.length,
			children,
			tokensOut,
			errors,
			pending,
			pendingCount: pending.length,
			pingSeq: this.pingCounter,
			busy
		};
	}
	/**
	* 把一次 usage 报告记到"本回合"的账上：按步号记账，所以同一步被流式帧与提交后的
	* `assistant/message` 各报一次也只算一份；回合一换就把上一回合的账清掉。
	*/
	creditTokens(session, turn, step, tokens) {
		if (tokens <= 0) return;
		if (turn !== session.tokenTurn) {
			session.tokenTurn = turn;
			session.turnTokens.clear();
		}
		const key = step > 0 ? step : 0;
		if (tokens > (session.turnTokens.get(key) ?? 0)) session.turnTokens.set(key, tokens);
	}
	/** 清理长期没动静、也早已空闲的会话，避免长时间运行后 Map 无限增长。 */
	prune(now, idleMs = 216e5) {
		for (const [id, session] of this.sessions) {
			if (this.pending.has(id)) continue;
			if (session.running) continue;
			if (session.lastAt === 0 || now - session.lastAt < idleMs) continue;
			this.sessions.delete(id);
		}
	}
};
//#endregion
//#region src/overlay.ts
/**
* overlay —— 悬浮球的进程与文件管道（Windows 专用）。
*
* 另起一个 Windows PowerShell + WPF 进程（`resources/ball.ps1`）画球，宿主只喂状态、收动作；
* 状态是整份文档、动作是一个文件一件事，写文件天然幂等，也不会丢事件；两边互相盯着对方进程。
*/
/** 宿主进程能接受的球最慢存活节奏（毫秒）。 */
const TICK_MS = 120;
/** 状态文件保留几份：球一次只读最新的那份，多留两份给"正在被读"的那些一拍。 */
const KEEP_STATES = 3;
/** 同一份脚本内容复用同一个 `.ps1` 文件名。 */
const SCRIPT_NAME = "ball.ps1";
function safeSegment(value) {
	const cleaned = value.replace(/[^A-Za-z0-9._-]+/g, "_").slice(0, 40);
	return cleaned === "" ? "default" : cleaned;
}
function scriptPath() {
	return fileURLToPath(new URL("../resources/ball.ps1", import.meta.url));
}
var BallOverlay = class {
	options;
	baseDir;
	windowPath;
	logPath;
	/** 脚本路径：每次启动球都重读一遍这个文件（见 `materializeScript()`）。 */
	scriptPath = scriptPath();
	/** 当前这一代脚本的内容与落盘文件名（`<sha1-12>-ball.ps1`）。 */
	scriptBody = "";
	child;
	timer;
	scriptFile = "";
	stateSeq = 0;
	stateFiles = [];
	lastWrittenRevision = -1;
	lastWrittenState = "";
	lastHealthCheck = 0;
	stopping = false;
	giveUp = false;
	restartTimes = [];
	restartScheduled = false;
	shellInUse = "";
	logReady = false;
	windowState = { expanded: false };
	windowSaveTimer;
	constructor(options) {
		this.options = options;
		const local = process.env.LOCALAPPDATA ?? join(homedir(), "AppData", "Local");
		this.baseDir = join(local, "dsh-session-ball", safeSegment(options.profile));
		this.windowPath = join(this.baseDir, "window.json");
		this.logPath = join(this.baseDir, "ball.log");
	}
	/** 供插件在日志里说明"球装在哪"，排查时不用猜路径。 */
	get directory() {
		return this.baseDir;
	}
	/** 往球的日志（`ball.log`）里写一行：Host 侧的 `ctx.logger` 用户看不到，球上也塞不下一行以上的字。 */
	note(message) {
		this.log(message);
	}
	/** 把球摊开。默认不会被调用：只在 `config.expandOnPending` 打开、且有提问/审批到达时走。 */
	expand() {
		if (this.windowState.expanded) return;
		this.windowState = {
			...this.windowState,
			expanded: true
		};
		this.saveWindowState();
		this.lastWrittenRevision = -1;
	}
	/**
	* 状态文档里的 `window` 段：位置、展开、常态不透明度（`opacity` 来自 windowSettings）、
	* `pulse`（**有会话在跑**，取快照里的 `running`：球上不跟单会话，所以白晕是整体口径，而且它
	* 在跑的时候是**呼吸**的 —— 见 `ball.ps1`）。
	* 球**不让开**：模型操作桌面时它照样停在原地、照样可以点；窗口用 WS_EX_NOACTIVATE 创建，球
	* 常态下永远不拿键盘焦点，只有用户亲手点开的输入框临时拿。
	*/
	windowSection(document) {
		const settings = this.options.windowSettings;
		const running = typeof document.running === "number" ? document.running : 0;
		return {
			visible: true,
			expanded: this.windowState.expanded,
			opacity: settings.opacity,
			pulse: running > 0,
			...this.windowState.x === void 0 ? {} : { x: this.windowState.x },
			...this.windowState.y === void 0 ? {} : { y: this.windowState.y }
		};
	}
	start() {
		mkdirSync(this.baseDir, { recursive: true });
		this.clearGenerated();
		this.loadWindowState();
		this.materializeScript();
		this.spawnBall();
		this.timer = setInterval(() => this.tick(), TICK_MS);
	}
	/**
	* 球脚本按内容哈希命名（`<sha1-12>-ball.ps1`）：每次启动球都从包里重读一遍 `resources/ball.ps1`，
	* 内容没变就复用旧文件，变了就换新文件并退休旧的 —— 所以改脚本不必重载插件，球重启一次就生效。
	*/
	materializeScript() {
		let body;
		try {
			body = readFileSync(this.scriptPath, "utf8");
		} catch (error) {
			this.log(`读取球脚本失败，沿用上一代：${String(error)}`);
			return;
		}
		if (body === this.scriptBody && this.scriptFile !== "") return;
		const digest = createHash("sha1").update(body).digest("hex").slice(0, 12);
		const materialized = join(this.baseDir, `${digest}-${SCRIPT_NAME}`);
		try {
			writeFileSync(materialized, body, "utf8");
		} catch (error) {
			this.log(`写入球脚本失败，沿用上一代：${String(error)}`);
			return;
		}
		this.scriptBody = body;
		this.scriptFile = materialized;
		this.retireScripts(materialized);
	}
	stop() {
		this.stopping = true;
		if (this.timer !== void 0) clearInterval(this.timer);
		if (this.windowSaveTimer !== void 0) clearTimeout(this.windowSaveTimer);
		const child = this.child;
		this.child = void 0;
		if (child !== void 0 && child.exitCode === null) try {
			child.kill();
		} catch {}
	}
	get environment() {
		return {
			...process.env,
			DSH_BALL_BASE: this.baseDir,
			DSH_BALL_PARENT_PID: String(process.pid)
		};
	}
	/** `powershell.exe` 有 `-STA`（WPF 必需）且一定存在；`pwsh` 当后备，它本身默认 STA。 */
	shellCandidates() {
		const tail = [
			"-NoProfile",
			"-ExecutionPolicy",
			"Bypass",
			"-WindowStyle",
			"Hidden",
			"-File",
			this.scriptFile
		];
		return [
			{
				executable: "powershell.exe",
				args: ["-STA", ...tail]
			},
			{
				executable: "pwsh.exe",
				args: tail
			},
			{
				executable: "pwsh",
				args: tail
			}
		];
	}
	spawnBall() {
		this.materializeScript();
		const candidates = this.shellCandidates();
		const ordered = this.shellInUse === "" ? candidates : [...candidates.filter((item) => item.executable === this.shellInUse), ...candidates];
		const attempt = (index) => {
			if (this.stopping || index >= ordered.length) {
				if (index >= ordered.length) this.log("找不到可用的 PowerShell（已尝试 powershell.exe / pwsh）：悬浮球没有启动");
				return;
			}
			const candidate = ordered[index];
			let child;
			try {
				child = spawn(candidate.executable, candidate.args, {
					env: this.environment,
					windowsHide: true,
					stdio: [
						"ignore",
						"pipe",
						"pipe"
					]
				});
			} catch (error) {
				this.log(`${candidate.executable} 启动失败：${String(error)}`);
				attempt(index + 1);
				return;
			}
			let spawnFailed = false;
			child.on("error", (error) => {
				spawnFailed = true;
				this.log(`${candidate.executable} 进程错误：${String(error)}`);
				if (this.child === child) this.child = void 0;
				attempt(index + 1);
			});
			child.stdout?.on("data", (chunk) => this.log(`ball stdout: ${String(chunk).trim()}`));
			child.stderr?.on("data", (chunk) => this.log(`ball stderr: ${String(chunk).trim()}`));
			child.on("exit", (code, signal) => {
				if (this.child === child) this.child = void 0;
				if (this.stopping || spawnFailed) return;
				this.log(`悬浮球进程退出（code=${String(code)} signal=${String(signal)}）`);
				this.scheduleRestart();
			});
			this.child = child;
			this.shellInUse = candidate.executable;
			this.log(`悬浮球已启动（${candidate.executable}，pid ${String(child.pid ?? "?")}，目录 ${this.baseDir}）`);
		};
		attempt(0);
	}
	scheduleRestart() {
		if (this.giveUp || this.stopping || this.restartScheduled) return;
		const now = Date.now();
		this.restartTimes = this.restartTimes.filter((stamp) => now - stamp < 3e5);
		this.restartTimes.push(now);
		if (this.restartTimes.length > 6) {
			this.giveUp = true;
			this.log("悬浮球在 5 分钟内反复退出，已放弃重启；请查看 ball.log 里的原因");
			return;
		}
		this.restartScheduled = true;
		setTimeout(() => {
			this.restartScheduled = false;
			if (this.stopping) return;
			this.spawnBall();
		}, 1500);
	}
	tick() {
		try {
			this.consumeActions();
			if (this.options.revision() !== this.lastWrittenRevision) this.writeState();
			const now = Date.now();
			if (now - this.lastHealthCheck > 2e3) {
				this.lastHealthCheck = now;
				if (!this.stopping && !this.giveUp && this.child === void 0 && !this.restartScheduled) {
					this.log("悬浮球进程不在了，重启一次");
					this.spawnBall();
				}
			}
		} catch (error) {
			this.log(`tick 出错：${String(error)}`);
		}
	}
	/**
	* 落盘：**每次写一份新文件**（`state-<序号>.json`），球按最大序号取最新的一份。
	* 这里刻意不做"写临时文件再 rename 覆盖"：Windows 上覆盖一个正被别人打开、又没有共享删除的
	* 文件会失败（EPERM），而 120ms 一次的写入会不停撞上实时防护/索引器的扫描句柄，球上就会一直
	* 显示几分钟前的内容。写新文件不覆盖任何东西，旧文件留最近几份，删不掉就下一拍再删。
	*/
	writeState() {
		let document;
		try {
			document = this.options.buildState();
		} catch (error) {
			this.log(`构建状态失败：${String(error)}`);
			return;
		}
		document = {
			...document,
			window: this.windowSection(document)
		};
		const serialized = JSON.stringify(document);
		if (serialized === this.lastWrittenState) {
			this.lastWrittenRevision = this.options.revision();
			return;
		}
		this.stateSeq += 1;
		const name = `state-${this.stateSeq}.json`;
		try {
			writeFileSync(join(this.baseDir, name), serialized, "utf8");
		} catch (error) {
			this.log(`写入状态失败：${String(error)}`);
			return;
		}
		this.lastWrittenState = serialized;
		this.lastWrittenRevision = this.options.revision();
		this.stateFiles.push(name);
		this.retireStates();
	}
	/** 只保留最近几份状态文件；被占住删不掉就留着，下一拍再试，绝不重试到卡住主流程。 */
	retireStates() {
		while (this.stateFiles.length > KEEP_STATES) {
			const victim = this.stateFiles[0];
			try {
				rmSync(join(this.baseDir, victim), { force: true });
				this.stateFiles.shift();
			} catch {
				return;
			}
		}
	}
	consumeActions() {
		let names;
		try {
			names = readdirSync(this.baseDir).filter((name) => name.startsWith("act-") && name.endsWith(".json"));
		} catch {
			return;
		}
		if (names.length === 0) return;
		const parsed = [];
		for (const name of names) try {
			const raw = readFileSync(join(this.baseDir, name), "utf8");
			const action = JSON.parse(raw);
			if (typeof action?.kind !== "string") {
				rmSync(join(this.baseDir, name), { force: true });
				continue;
			}
			parsed.push({
				name,
				seq: name.replace(/^act-/, ""),
				action
			});
		} catch {}
		parsed.sort((left, right) => {
			const [leftPid = "", leftSeq = ""] = left.seq.split("-");
			const [rightPid = "", rightSeq = ""] = right.seq.split("-");
			if (leftPid !== rightPid) return leftPid.localeCompare(rightPid);
			return Number(leftSeq) - Number(rightSeq);
		});
		for (const entry of parsed) {
			try {
				this.applyWindowAction(entry.action);
				this.options.onAction(entry.action);
			} catch (error) {
				this.log(`处理动作 ${entry.action.kind} 失败：${String(error)}`);
			}
			rmSync(join(this.baseDir, entry.name), { force: true });
		}
	}
	applyWindowAction(action) {
		let changed = false;
		if (action.kind === "pos" && typeof action.x === "number" && typeof action.y === "number") {
			this.windowState = {
				...this.windowState,
				x: action.x,
				y: action.y
			};
			changed = true;
		}
		if (action.kind === "expanded" && typeof action.expanded === "boolean") {
			this.windowState = {
				...this.windowState,
				expanded: action.expanded
			};
			changed = true;
		}
		if (changed) this.saveWindowState();
	}
	loadWindowState() {
		try {
			const raw = readFileSync(this.windowPath, "utf8");
			const parsed = JSON.parse(raw);
			this.windowState = {
				...typeof parsed.x === "number" ? { x: parsed.x } : {},
				...typeof parsed.y === "number" ? { y: parsed.y } : {},
				expanded: parsed.expanded === true
			};
		} catch {
			this.windowState = { expanded: false };
		}
	}
	saveWindowState() {
		if (this.windowSaveTimer !== void 0) clearTimeout(this.windowSaveTimer);
		this.windowSaveTimer = setTimeout(() => {
			try {
				writeFileSync(this.windowPath, JSON.stringify(this.windowState), "utf8");
			} catch (error) {
				this.log(`写入 window.json 失败：${String(error)}`);
			}
		}, 400);
	}
	/** 清掉上一代留下的生成文件：残留的动作会被当成这一次的点击，状态序号也要从 1 重新数。 */
	clearGenerated() {
		try {
			for (const name of readdirSync(this.baseDir)) {
				const action = name.startsWith("act-") && name.endsWith(".json");
				const state = name.startsWith("state-") && name.endsWith(".json") || name === "state.json";
				if (action || state) rmSync(join(this.baseDir, name), { force: true });
			}
		} catch {}
	}
	/** 上一代的 `.ps1`（内容哈希不同）没有保留价值；删不掉就留着，不影响任何行为。 */
	retireScripts(current) {
		try {
			for (const name of readdirSync(this.baseDir)) {
				if (!name.endsWith(`-${SCRIPT_NAME}`)) continue;
				const full = join(this.baseDir, name);
				if (full === current) continue;
				rmSync(full, { force: true });
			}
		} catch {}
	}
	/**
	* 往 `ball.log` 追加一行。目录在这里**按需创建**：`note()` 可能早于 `start()` 被调用，那时目录
	* 还不存在，少了这次 mkdir，最早也最该看见的那几行就会被下面的 catch 吞掉。
	*/
	log(message) {
		const line = `${(/* @__PURE__ */ new Date()).toISOString()} [host] ${message}\n`;
		try {
			if (!this.logReady) {
				mkdirSync(this.baseDir, { recursive: true });
				this.logReady = true;
			}
			appendFileSync(this.logPath, line, "utf8");
		} catch {}
	}
};
//#endregion
//#region src/session-ball.ts
/**
* session-ball —— 会话悬浮球：模型去操作桌面（`desktop_step`）时网页端会被挡在后面，所以这里
* 另起一个**原生 Windows 置顶窗口**（`overlay.ts` + `resources/ball.ps1`），让你仍能看见会话
* 在做什么、是不是在等你，并直接在球上回答、在球上给模型发话；球上只显示运行状态与提问、
* 审批卡片，不显示思维链、正文与工具调用内容。数据全部来自 Host 既有事件（不新增事件、
* 不改决策、不写日志）：`agent/assistant-stream`（步骤级状态与用量）、`session/event`
* （工具名与成败、回合状态、模型名、会话标题）、`api-session/*`（会话目录、运行状态、
* 活动时间）、`user-questions/request` 与 `approval/request`（各 `prepend` 挂一层）；
* 唯一有真实副作用的开关是 `answerApprovals`：球上作答会抢在网页端之前落地（`allowed-once`）。
*
* 展开后的面板是**会话条目**：每个"有事"的会话一条（正在输出、在向你提问/请求审批、出错），
* 条目里自带那个会话的输入框（不必再选"发送到"—— 目标和输入框是同一个东西）、自带的卡片、
* 以及右上角那个「×」。条目**不会自己消失**：会话闲下来它就灰着留在那里，直到人点「×」
* （`close`）把它收掉 —— 收掉之后，那个会话下一次"有事"（新的输出、新的卡片、新的出错）会
* 让它重新出现（这就是 mirror 里那个活动计数的用处）。
*
* 球的颜色仍然是**整体口径**（见 `mirror.ts` 的 `statusOf()`）：有审批/提问就琥珀/红、有会话
* 出错就红、还有会话在输出就是蓝（蓝**自己会消失**：颜色回到空闲灰就是"这一轮跑完了"）。
* 出错的红**不会到点自己消失**，走得掉的只有两条路：有人在那个出错条目上按「知道了」（`ack`），
* 或者那个会话自己又开始了一轮（这条错误随之不再算）。第二条原本就有，第一条是给"那个会话再也
* 不动了"这种局面准备的：按下之后球不再为这条错误染红（条目留着，写着"已确认出错"）；会话
* 再次开始输出、或者又出了一次错，颜色照旧回来。
*
* 「×」（`close`）**也包含「知道了」的意思**：条目一收走，「知道了」按钮就跟着没了，那条红就再也
* 没有地方可以确认 —— 所以收条目的同时把它名下的出错一并确认掉。这样"清掉这条红"永远有一个
* 够得着的入口（要么留着条目按「知道了」，要么连条目一起「×」掉）。
*/
const name = "session-ball";
const DEFAULTS = {
	enabled: true,
	ballSize: 64,
	panelWidth: 360,
	panelHeight: 420,
	opacity: .94,
	answerQuestions: true,
	answerApprovals: true,
	sound: true,
	expandOnPending: false,
	promptMode: "auto",
	lockComposeWhileBusy: true,
	entryLimit: 12
};
const Config = Schema.object({
	enabled: Schema.boolean().description("总开关：关掉就不启动悬浮球").default(DEFAULTS.enabled),
	ballSize: Schema.number().description("球收起时的直径（像素）").default(DEFAULTS.ballSize),
	panelWidth: Schema.number().description("展开面板宽度（像素）").default(DEFAULTS.panelWidth),
	panelHeight: Schema.number().description("展开面板的最大高度（像素）：面板按内容自己长，到这就停，卡片自己滚动").default(DEFAULTS.panelHeight),
	opacity: Schema.number().description("常态不透明度（0.15–1）").default(DEFAULTS.opacity),
	answerQuestions: Schema.boolean().description("允许直接在球上回答模型的提问").default(DEFAULTS.answerQuestions),
	answerApprovals: Schema.boolean().description("允许直接在球上批准/拒绝审批（有真实副作用）").default(DEFAULTS.answerApprovals),
	sound: Schema.boolean().description("出现提问/审批时播放提示音").default(DEFAULTS.sound),
	expandOnPending: Schema.boolean().description("出现提问/审批时自动展开面板（默认关：球的变色与徽标数字已足够，自己点开就行）").default(DEFAULTS.expandOnPending),
	promptMode: Schema.union([
		"auto",
		"queue",
		"steer"
	]).description("球上输入框怎么把话投进会话：auto = 模型在跑就插话、空闲就排队").default(DEFAULTS.promptMode),
	lockComposeWhileBusy: Schema.boolean().description("目标会话输出期间禁用球上输入框（默认开：发送后输入框变灰＝收到了；关掉就不会因为会话在输出而锁）").default(DEFAULTS.lockComposeWhileBusy),
	entryLimit: Schema.number().description("面板上最多同时留几个会话条目（挤掉的是最旧的、此刻没事的那些；有事的一条都不挤）").default(DEFAULTS.entryLimit)
});
/** 球上所有固定文案都从这里出：`ball.ps1` 保持纯 ASCII，不内嵌任何非 ASCII 字符。 */
const LABELS = {
	send: "在球上作答",
	dismiss: "先收起来",
	/** 待办卡片自己的标题（球上的卡片正文只有题面，得先说明这是要你干什么）。 */
	cardQuestion: "模型在等你回答",
	cardApproval: "模型在等你批准",
	customHint: "也可以直接在这里输入你的回答",
	/**
	* 卡片上的「在球上作答」按了却没答全时要说的那句话。
	*
	* 两边共用同一份文案：宿主在收到不完整的答案时把它当球上的提示，球脚本在**还没发出
	* 动作**时就把它写到卡片里（见 `ball.ps1` 的 send 处理器）—— 后者才是关键，因为
	* "点了没反应"是球上最难自己看懂的一种失败。
	*/
	answerIncomplete: "每个问题都要选一项或填一句，再点「在球上作答」。",
	countdown: "{n} 秒后前台等待结束；之后仍可在这里作答",
	expired: "前台等待已结束：现在作答会作为一条补充消息交给模型。",
	/**
	* 展开、且没有待办卡片时，面板底部那行提示。
	*
	* 这行**只在展开状态下可见**（它就在面板里），所以它说的是展开状态的事：面板能拖、怎么收起。
	*/
	footerIdle: "拖动面板可移动 · 点右上角「-」收起",
	/** 统计行里「是哪个会话出错」的前缀。 */
	metaError: "出错",
	footerPending: "网页端同时也在等你：两边都能答，先答的算数。",
	footerApproval: "点允许/拒绝即在球上作答；网页端同一个弹窗可以直接关掉。",
	/** 球上输入框（在球上直接和模型说话）。 */
	sendMessage: "发送",
	composeHint: "在这里输入，回车发给模型；Esc 交还键盘",
	/**
	* 输入框被锁住时，发送按钮上换的字。
	*
	* 锁住的那两件事（刚发出去、目标会话在输出）用户一眼能看见的反应有三处：输入框与按钮
	* 一起变灰、按钮上这行字、以及输入框上的水印（下面两条）。按钮上这行字是**最贴身**的：
	* 它就长在刚刚点下去的那个位置上。
	*/
	sendWaiting: "输出中",
	/** 锁住时的水印之一：这句话刚发出去，还没等到目标会话接手（球的本地锁，见 ball.ps1）。 */
	composeSending: "已发出，等会话接手…",
	/** 锁住时的水印之二：目标会话正在输出，跑完这一步就会自己解锁。 */
	composeOutputting: "会话正在输出，跑完这一步再发",
	composeNoFocus: "这一下没能拿到键盘焦点，请再点一次这个输入框。",
	composeSent: "已把这句话发进会话。",
	composeSteered: "已插话到正在跑的这一轮。",
	composeCreated: "已新建会话（{place}），并把这句话发了出去。",
	composeNoSender: "这个 Profile 里拿不到 sessionController，球上没法发言。",
	/** 球上没有选中目标、或选中的对象已经不在了：这句话根本没出去。 */
	composeNoTarget: "这一条没有可以发送的目标。",
	composeRefused: "这句话没有发出去：{reason}",
	composeFailed: "发送失败：{reason}",
	/**
	* 会话条目（展开后每一条）自己的文案。
	*
	* `entryAck` 是出错条目上那个按钮：按下去只清掉球上的红（条目留着），所以它说的是"我看到了"
	* 而不是"把它删掉"—— 删掉是右上角那个 `entryClose`。
	*/
	entryAck: "知道了",
	entryClose: "×",
	/** 「＋ 新会话」：面板右上角那个按钮，以及它弹出的工作区列表里的标题前缀。 */
	createOpen: "＋ 新会话",
	targetNew: "＋ 新建会话",
	targetNewHead: "＋ 新建会话",
	/** 一个还没有落到任何会话上的新条目（点了「＋ 新会话」之后那一条）。 */
	entryNew: "新会话",
	/** 那个空条目的标题：`{place}` 会被工作区名替换（球脚本是 ASCII 的，间隔号只能在这里写）。 */
	entryNewFor: "新会话 · {place}",
	/**
	* 「＋ 新会话」在**一个工作区都没有**时那条兜底行的说明（也是新会话落点的兜底说法）。
	*
	* 为什么必须有这一行：工作区注册表在插件挂载那一刻常常还没就绪，于是列表会是空的 —— 那时如果
	* 没有兜底行，「＋」按钮就永远是灰的（实测踩过）。
	*/
	createDefault: "Harness 默认目录",
	/** 认不出属于哪个会话的卡片（请求里没带会话）：它自己占一条，只显示卡片。 */
	entryUnknown: "未知会话",
	/** 面板上一条条目都没有时说的话。 */
	entryEmpty: "现在没有进行中的会话：点右上角「＋」新建一个。",
	/**
	* 条目第二行开头那个**状态词**：一个条目现在到底在干什么，一眼看得到。
	*
	* `entryIdle` 是"这一条留着，但它已经跑完了"（条目不会自己消失，见文件头）；
	* `entryAckedError` 说的是同一个意思，只是它上一次是以出错结束的、而那次出错已经被人确认过了。
	*/
	entryRunning: "运行中",
	entryWaiting: "等你回答",
	entryApproval: "等你批准",
	entryError: "出错",
	entryAckedError: "已确认出错",
	entryIdle: "空闲",
	/** 没有标题的会话：与网页端侧边栏同一套说法（blank → 新会话，否则 → 未命名）。 */
	targetBlank: "新会话",
	targetUntitled: "未命名",
	targetRunning: "运行中",
	/** 提问卡片里的选项按钮：选中的记号与未选中的记号（纯文本，避免依赖字体里的符号）。 */
	optionOn: "●",
	optionOff: "○"
};
/** 一个还没有落到会话上的条目（球上点了「＋ 新会话」）送给宿主的写法。 */
const TARGET_NEW = "new";
/**
* 「新建到某个工作区」的目标写法：`new:<workspaceId>`。
*
* 球上只送来一个字符串，所以"新建"这件事的两种含义（新建到哪里）都编码在这个前缀里；
* 解析与拒绝也只在宿主这一侧发生（球脚本保持纯 ASCII、不做业务判断）。
*/
const TARGET_NEW_PREFIX = `${TARGET_NEW}:`;
function clampNumber(value, fallback, minimum, maximum) {
	if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
	if (value < minimum) return minimum;
	if (value > maximum) return maximum;
	return value;
}
function resolveSettings(config) {
	const merged = {
		...DEFAULTS,
		...config ?? {}
	};
	merged.ballSize = clampNumber(merged.ballSize, DEFAULTS.ballSize, 24, 160);
	merged.panelWidth = clampNumber(merged.panelWidth, DEFAULTS.panelWidth, 280, 1200);
	merged.panelHeight = clampNumber(merged.panelHeight, DEFAULTS.panelHeight, 200, 1400);
	merged.opacity = clampNumber(merged.opacity, DEFAULTS.opacity, .15, 1);
	merged.entryLimit = clampNumber(merged.entryLimit, DEFAULTS.entryLimit, 1, 40);
	if (merged.promptMode !== "auto" && merged.promptMode !== "queue" && merged.promptMode !== "steer") merged.promptMode = DEFAULTS.promptMode;
	return merged;
}
/** 路径的最后一段，给"没有标题的会话"当标题用。 */
function baseName(path) {
	const parts = path.replace(/[\\/]+$/, "").split(/[\\/]/);
	const last = parts[parts.length - 1] ?? "";
	return last === "" ? path : last;
}
/** 太长的路径只留尾巴（前面用 … 表示省略）——球上要认的是"哪一层目录"，不是盘符。 */
function shortPath(path, limit = 34) {
	const flat = path.trim().replace(/\s+/g, " ");
	if (flat.length <= limit) return flat;
	const parts = flat.split(/[\\/]/).filter((part) => part !== "");
	const tail = [];
	for (let index = parts.length - 1; index >= 0; index -= 1) {
		if ([parts[index], ...tail].join("\\").length + 1 > limit) break;
		tail.unshift(parts[index]);
	}
	const joined = tail.join("\\");
	if (joined === "") return `${flat.slice(0, limit - 1)}…`;
	const drive = /^[A-Za-z]:/.test(flat) ? `${flat.slice(0, 2)}\\` : "";
	return joined.length + drive.length <= limit ? `${drive}…\\${joined}` : `…\\${joined}`;
}
/** 会话 id 的短尾巴（`session-06bb561d-…-df5c` → `df5c`）：唯一、稳定、能对上日志。 */
function idTail(id) {
	const flat = id.trim();
	if (flat === "") return "----";
	const parts = flat.split("-");
	return (parts[parts.length - 1] ?? flat).slice(-4);
}
/** 相对时间：下拉列表是"按最近活动"排的，所以"多久以前"本身就是一条身份线索。 */
function timeAgo(updatedAt, now) {
	if (updatedAt <= 0) return "";
	const seconds = Math.max(0, Math.round((now - updatedAt) / 1e3));
	if (seconds < 60) return "刚刚";
	const minutes = Math.round(seconds / 60);
	if (minutes < 60) return `${minutes} 分钟前`;
	const hours = Math.round(minutes / 60);
	if (hours < 24) return `${hours} 小时前`;
	return `${Math.round(hours / 24)} 天前`;
}
function sessionHeadline(row) {
	const title = row.title.trim();
	if (title !== "") return title;
	const text = row.text.trim();
	if (text !== "") return text;
	if (row.blank) return LABELS.targetBlank;
	const cwd = row.cwd.trim();
	if (cwd !== "") return baseName(cwd);
	return LABELS.targetUntitled;
}
/**
* 一行的**明细文案**（球上第二行、小字灰字）：状态词 · 多久以前 · 目录 · 会话号尾巴。
*
* 会话号尾巴永远在：主文案可能因为标题相同、或者被截断而撞在一起，而这一行是"这一行到底
* 是哪个会话"的硬证据（`ball.log` 里的发送回执用的也是同一串尾巴）。
*/
function sessionDetail(row, stateWord, now) {
	const parts = [];
	if (stateWord !== "") parts.push(stateWord);
	const ago = timeAgo(row.updatedAt, now);
	if (ago !== "") parts.push(ago);
	const cwd = row.cwd.trim();
	if (cwd !== "") parts.push(shortPath(cwd, 34));
	parts.push(`#${idTail(row.id)}`);
	return parts.join(" · ");
}
/**
* 失败的可读描述：消息 + 稳定错误码 + **完整栈**。
*
* 球上只能显示一行（`失败：xxx`），而"链路上哪一步炸的"只有栈说得清 —— 球相关的故障最该
* 被看见的地方是球自己的日志，所以栈写进 `ball.log`，报错文案留在球上。
*/
function describeFailure(error) {
	if (!(error instanceof Error)) return String(error);
	const code = error.code;
	return `${typeof code === "string" ? `[${code}] ${error.message}` : error.message}\n${error.stack ?? "(no stack)"}`;
}
/**
* 把这条请求的**投递撤销权**拿到自己手里 —— 这是"球上先作答"之后，网页端那张卡片能自己
* 收起的唯一通道。
*
* 为什么必须有它：请求是在 waterfall 里被我们**抢先答掉**的，而前台 `next()` 那条路
* （`api-remotes` → 网关 → 网页端）会一直悬在那里。网页端的卡片不是"等一个返回值"，
* 而是"等它自己那条请求结束"：只要那条请求不结束，卡片就永远挂着 —— 模型已经拿着球上的
* 答案继续干活了，网页端还在问你同一个问题。修掉它的地方只能在这里，因为只有这里同时
* 看得见"球上答了"和"那条请求还开着"。
*
* 怎么做到：`AskUserQuestionRequestEvent.signal` 的语义本来就是 "Cancellation lifetime of
* the pending request"，网关盯着它，一中止就 `cancelRemoteEvent` 并给客户端推一条
* `{type:'cancel'}`，客户端随即以 `ASK_ABORTED` 结束那张卡片（`answerQuestion` 的 finally
* 把它摘掉）。但插件手上只有一个不能中止的 `AbortSignal`，所以这里把 `request.signal`
* 换成 `AbortSignal.any([原信号, 我们自己的 controller.signal])`：原信号的语义（停止生成、
* 轮次中止）原封不动继续传播，我们只是多拿到一个能主动中止的把手。
*
* 改的是**同一个 request 对象**：waterfall 的 `next()` 不接受参数，下游 listener 拿到的
* 必然是这一份，所以就地替换 `signal` 是唯一可行的做法。拿不到撤销权（对象被冻结、没有
* signal 字段）就老实退回"只作答、不撤销"，行为与没有这一步时一致。
*
* 审批同理：客户端的审批面板也盯 `request.signal`，中止即收起；而 `dsh-user-approval`
* 在派发 waterfall 之前就把原信号存下来了，所以这一改不影响它自己"取消即 cancelled"。
*
* @param request - 这条 waterfall 请求的原件（会就地改它的 `signal` 字段）。
* @returns 中止投递的函数；拿不到撤销权时是空操作。
*/
function takeOverCancellation(request) {
	const record = asRecord(request);
	if (record === void 0) return () => void 0;
	const rawSignal = record.signal;
	if (rawSignal !== void 0 && !(rawSignal instanceof AbortSignal)) return () => void 0;
	const original = rawSignal === void 0 ? void 0 : rawSignal;
	const controller = new AbortController();
	const composite = original === void 0 ? controller.signal : AbortSignal.any([original, controller.signal]);
	try {
		Object.defineProperty(record, "signal", {
			value: composite,
			writable: true,
			enumerable: true,
			configurable: true
		});
	} catch {
		return () => void 0;
	}
	return () => {
		if (controller.signal.aborted) return;
		controller.abort(/* @__PURE__ */ new Error("session-ball: this request was answered on the floating ball"));
	};
}
/** 审批理由：优先中文展示文案，其次英文，最后退回 reason 代码。 */
function approvalReason(request) {
	const display = asRecord(request.displayReason);
	if (display !== void 0) for (const key of [
		"zh-CN",
		"zh",
		"zh-Hans",
		"zh-Hant",
		"en"
	]) {
		const text = display[key];
		if (typeof text === "string" && text.trim() !== "") return text;
	}
	return typeof request.reason === "string" ? request.reason : "";
}
/** 请求里的 questions → 球上的卡片条目。 */
function toQuestionViews(questions) {
	const views = [];
	for (const entry of Array.isArray(questions) ? questions : []) {
		const record = asRecord(entry);
		if (record === void 0) continue;
		const id = typeof record.id === "string" ? record.id : "";
		if (id === "") continue;
		const options = [];
		for (const optionEntry of Array.isArray(record.options) ? record.options : []) {
			const option = asRecord(optionEntry);
			if (option === void 0) continue;
			const label = typeof option.label === "string" ? option.label : "";
			if (label === "") continue;
			options.push({
				label,
				description: typeof option.description === "string" ? option.description : ""
			});
		}
		views.push({
			id,
			header: typeof record.header === "string" ? record.header : "",
			question: typeof record.question === "string" ? record.question : "",
			detail: typeof record.detail === "string" ? record.detail : "",
			multiSelect: record.multiSelect === true,
			options
		});
	}
	return views;
}
/** 球发回来的答案 → 服务要的 `AskUserQuestionAnswer`；形状不对就丢掉。 */
function normalizeAnswers(raw, items) {
	const byId = /* @__PURE__ */ new Map();
	for (const item of items ?? []) byId.set(item.id, item);
	const answers = [];
	for (const entry of Array.isArray(raw) ? raw : []) {
		const record = asRecord(entry);
		if (record === void 0) continue;
		const id = typeof record.id === "string" ? record.id : "";
		if (id === "" || !byId.has(id)) continue;
		const selected = [];
		for (const label of Array.isArray(record.selected) ? record.selected : []) if (typeof label === "string" && label !== "") selected.push(label);
		const custom = typeof record.custom === "string" && record.custom.trim() !== "" ? record.custom : void 0;
		answers.push({
			id,
			selected,
			...custom === void 0 ? {} : { custom }
		});
	}
	return answers;
}
/** 这条提问的每个问题都答到了吗（服务侧要求一次答全，否则 BAD_ANSWER）。 */
function isCompleteAnswer(answers, items) {
	const expected = items ?? [];
	if (expected.length === 0) return answers.length > 0;
	if (answers.length !== expected.length) return false;
	const answered = new Set(answers.map((item) => item.id));
	return expected.every((item) => answered.has(item.id));
}
function apply(ctx, config) {
	const settings = resolveSettings(config);
	if (!settings.enabled) {
		ctx.logger?.info?.("session-ball：已禁用（config.enabled = false），没有启动悬浮球");
		return;
	}
	if (process.platform !== "win32") {
		ctx.logger?.warn?.("session-ball：只支持 Windows（悬浮球是 Windows PowerShell + WPF），当前平台不启动");
		return;
	}
	const mirror = new Mirror();
	/**
	* 按名字现查一个服务。
	*
	* **为什么不能像以前那样在挂载时取一次存起来**：Harness 的 Profile 是一棵异步装配起来的树，
	* 本插件挂载的那一刻，好几个服务**还没有就绪**（实测：`sessionProjections`、`sessions`、
	* `sessionTitle`、`workspaceRegistry` 全都能在这一刻查不到，而同一台机器上稍后重启又查得到 ——
	* 取决于装配顺序）。挂载时查一次的结果就是"这个插件这辈子都用不到工作区注册表"：球上的
	* 「＋ 新会话」按钮因此永远是灰的（`state.entities` 里 `create` 是空的），而这跟用户到底有没有
	* 工作区毫无关系。
	*
	* 所以每一处使用都现查一次：查到了就立刻用上，查不到只是"这一次没有"。这也正是
	* `sessionController` 一直以来的用法（`deliveryRoutes()` 里每次发送现查），所以它从来不受影响。
	*/
	const serviceOf = (name) => {
		try {
			return ctx.get(name);
		} catch {
			return;
		}
	};
	/** 有没有"按 id 补标题"这条最省的路（只给启动那一行日志用：真正的读法见下）。 */
	const hasProjections = () => serviceOf("sessionProjections")?.stateOf !== void 0;
	mirror.setTitleResolver((session) => {
		const title = readProjectedTitle(session);
		return title === "" ? void 0 : title;
	});
	/** `title` 投影里的一行标题：读不到（服务缺席、投影还是 null、形状不对）就是空串。 */
	function readProjectedTitle(session) {
		const service = serviceOf("sessionProjections");
		if (service?.stateOf === void 0) return "";
		try {
			return oneLine(projectedTitleText(service.stateOf(session, "title")), 120);
		} catch {
			return "";
		}
	}
	/**
	* `sessionTitle.get()` 那条兜底路：**它会重放整份会话日志**，所以漂亮但昂贵
	* （见下面 `liveTitle()` 里的节流）。投影读不出东西时才会走到这里。
	*/
	function expensiveTitle(session) {
		const service = serviceOf("sessionTitle");
		if (service?.get === void 0) return "";
		let snapshot;
		try {
			snapshot = service.get(session);
		} catch {
			return "";
		}
		return oneLine(typeof snapshot?.title === "string" ? snapshot.title : typeof snapshot?.text === "string" ? snapshot.text : "", 120);
	}
	/**
	* `ctx.workspaceRegistry.list()` → 球认得的最小形状。同步、不读持久层，可以每拍都问。
	*
	* 服务是**现查**的（见 `serviceOf()`）：注册表在插件挂载时往往还没就绪，挂载时查一次就会让
	* 「＋ 新会话」永久失去工作区列表。
	*/
	function workspaceList() {
		const registry = serviceOf("workspaceRegistry");
		let raw;
		try {
			raw = registry?.list?.();
		} catch (error) {
			ctx.logger?.warn?.(`session-ball：读取工作区注册表失败：${String(error)}`);
			return [];
		}
		const items = [];
		for (const entry of Array.isArray(raw) ? raw : []) {
			const record = asRecord(entry);
			if (record === void 0) continue;
			const id = typeof record.id === "string" ? record.id : "";
			const path = typeof record.path === "string" ? record.path : "";
			if (id === "" || path === "") continue;
			items.push({
				id,
				path,
				title: typeof record.title === "string" ? record.title : ""
			});
		}
		if (items.length > 0 && !registrySeen) {
			registrySeen = true;
			overlay.note(`工作区注册表现在可见了：${items.length} 个（${items.slice(0, 3).map((item) => workspaceName(item)).join("、")}${items.length > 3 ? " 等" : ""}）`);
		}
		return items;
	}
	/** 工作区在球上的名字：注册表里的显示名，没有就用目录名。 */
	function workspaceName(workspace) {
		return workspace.title.trim() === "" ? baseName(workspace.path) : workspace.title.trim();
	}
	/** "第一次真的看见工作区"这件事只往 `ball.log` 写一行（见 `workspaceList()`）。 */
	let registrySeen = false;
	/** 注册表里唯一的那个工作区（一个都没有、或者有好几个时返回 undefined：不猜）。 */
	function soleWorkspace() {
		const workspaces = workspaceList();
		return workspaces.length === 1 ? workspaces[0] : void 0;
	}
	const pendings = /* @__PURE__ */ new Map();
	/**
	* 面板上的会话条目（宿主侧；球那一半只负责画）。见 `PanelEntry` 与 `reconcileEntries()`。
	*
	* `suppressed` 是"被收掉的那些"：值记着**收掉时那个会话的活动计数**，所以下一拍的对账不会
	* 立刻把它加回来（正在输出的会话尤其需要这一条），而它下一次有事时计数更大、条目就会回来。
	*/
	const entries = /* @__PURE__ */ new Map();
	const suppressed = /* @__PURE__ */ new Map();
	/** 条目出现顺序的序号（越大越新，球上按它倒序排）。 */
	let entrySeq = 0;
	/**
	* 会话日志里 `approval/asked` 给的那一半身份：审批请求 id → 它属于哪个会话、哪一次工具调用。
	*
	* `approval/decided` 只重复那个 id 和结果，所以"这次审批到底是哪张卡"只能在这里配。
	* 请求本身没有 id 可用（`ApprovalRequestId` 是服务在落库那一刻才生成的），而 callId
	* 从请求一到达就在球手上 —— 见 `settleApprovalCard()`。
	*/
	const approvalAsks = /* @__PURE__ */ new Map();
	/** 这张表只用来配对两张凭据，配不上的（球挂载晚了、请求不是工具发的）留着也没有用。 */
	const APPROVAL_ASK_LIMIT = 64;
	let notice = "";
	let noticeUntil = 0;
	let sendSeq = 0;
	let lastSend;
	const setNotice = (text) => {
		notice = text;
		noticeUntil = Date.now() + 15e3;
		mirror.revision += 1;
		setTimeout(() => {
			if (Date.now() < noticeUntil) return;
			notice = "";
			mirror.revision += 1;
		}, 15200);
	};
	/**
	* 球上发送一次话之后的回执（见 `SendResult`）：球靠它把**那一条**自己解锁并写上结果，以及把
	* "＋ 新会话"那一条交接到刚建出来的会话上。失败也留一份回执（球据此立刻解锁，而不是干等）。
	*
	* `note` 同时进两条出口：那一条自己的提示行（球上的 `EntryHint`）与页脚 —— 失败时它带着原因。
	*/
	const setSendResult = (ok, key, id, note) => {
		sendSeq += 1;
		lastSend = {
			seq: sendSeq,
			ok,
			key,
			id,
			note
		};
		mirror.revision += 1;
	};
	/**
	* 一张卡片从球上**下来**（内存 + 视图两处一起，少一处都会留下幽灵）。
	*
	* 谁在别处把请求结掉了，都走这里 —— 它不碰那条投递，也不写页脚。
	*/
	const dropPending = (runtime) => {
		pendings.delete(runtime.view.id);
		mirror.removePending(runtime.view.id);
	};
	/**
	* 球上作答/批准成功之后的收尾（审批、前台还在等的提问、超时后的提问三处共用）：卡片下线，
	* 页脚给出结论，并撤掉网页端那条同一请求的投递（见 `takeOverCancellation()`）。
	*/
	const finishPending = (runtime, noticeText) => {
		dropPending(runtime);
		runtime.withdraw();
		setNotice(noticeText);
	};
	/**
	* 审批在**别处**结束（网页端答了、没有应答通道、请求被中止）时，页脚那句话。
	*
	* 三种结局在球上是同一件事（卡片都不该留），但**说的话不一样**：用户唯一能看到的
	* 就是这个页脚，而"网页端已经处理了"与"根本没有应答通道"要采取的行动完全不同。
	*/
	const approvalSettledNotice = (outcome) => {
		if (outcome === "allowed-once") return "网页端已经允许这次审批，球上的卡片自动收起。";
		if (outcome === "rejected") return "网页端已经拒绝这次审批，球上的卡片自动收起。";
		if (outcome === "unavailable") return "这次审批没有可用的应答通道，球上的卡片自动收起。";
		return "这次审批已经结束了，球上的卡片自动收起。";
	};
	const overlay = new BallOverlay({
		profile: process.env.DSH_PROFILE ?? "default",
		revision: () => mirror.revision,
		onAction: (action) => void handleAction(action),
		buildState: () => buildState(),
		windowSettings: { opacity: settings.opacity }
	});
	/**
	* 那几个"可有可无"的服务，各自能看见什么 —— 只写一行进 `ball.log`。
	*
	* 标题是球上「这一行到底是哪个会话」的全部身份，工作区列表是「＋ 新会话」的全部内容，而取不到时
	* 球**不报错**，只会安静地退到别的文案/别的路。有这一行，「下次标题又不对 / 新会话按钮又是灰的」
	* 就能一眼看出是哪条路断了。
	*
	* 注意这行只是"**这一刻**查得到什么"：挂载的那一瞬间 Harness 的几个服务常常还没就绪，而下面
	* 每一处使用都是现查的（见 `serviceOf()`），所以这里写"没有"不等于球用不到它。
	*/
	overlay.note(`服务可见性（挂载这一刻，之后每处用起来都现查）：title 投影=${hasProjections() ? "有" : "没有"} · live 会话表=${serviceOf("sessions")?.get === void 0 ? "没有" : "有"} · sessionTitle 服务=${serviceOf("sessionTitle")?.get === void 0 ? "没有" : "有"} · 工作区注册表=${serviceOf("workspaceRegistry")?.list === void 0 ? "没有" : "有"} · session/title 事件=一直在听`);
	/**
	* Harness 的事件名挂在 harness 自己的模块增强里，本插件没有（也不该）import 那些包，
	* 所以这里把 ctx 收口成一个最小的事件接口：插件真正用到的事件只有下面这几个，
	* 每个都在 `cordis_inspect_query` 的 `Event` 目录里核对过签名。
	*/
	const events = ctx;
	function footer() {
		if (Date.now() < noticeUntil && notice !== "") return notice;
		const visible = mirror.visiblePendings();
		if (visible.some((item) => item.kind === "approval")) return LABELS.footerApproval;
		if (visible.length > 0) return LABELS.footerPending;
		return LABELS.footerIdle;
	}
	/**
	* 面板第二行：**整体统计**。球不再显示「在跟谁」，所以这一行说的是全部会话的事：
	* 有几个在跑（状态字已经在说的时候就不重复）、本轮输出合计、子代理、以及是哪个会话出错。
	*/
	function metaLine(snapshot) {
		const parts = [];
		if (snapshot.status.key !== "idle" && snapshot.status.key !== "working" && snapshot.running > 0) parts.push(`${snapshot.running} 个会话在跑`);
		if (snapshot.tokensOut > 0) parts.push(`输出 ${(snapshot.tokensOut / 1e3).toFixed(1)}k tokens`);
		if (snapshot.children > 0) parts.push(`子代理 ${snapshot.children} 个在跑`);
		if (snapshot.errors.length > 0) {
			const names = snapshot.errors.slice(0, 2).map((row) => sessionHeadline(row));
			const rest = snapshot.errors.length > 2 ? ` 等 ${snapshot.errors.length} 个会话` : "";
			const note = oneLine(snapshot.errors[0]?.note ?? "", 60);
			parts.push(`${LABELS.metaError}：${names.join("、")}${rest}${note === "" ? "" : `（${note}）`}`);
		}
		return parts.join(" · ");
	}
	/**
	* 面板的**会话条目**：一个"有事"的会话一条，条目里自带它的输入框与它的卡片。
	*
	* 三件事在这里定下来：
	*
	*   1. **哪些会话有条目**（`reconcileEntries`）：正在输出、有卡片在等你、或者刚出错（还没
	*      被「知道了」确认）的会话出现一条。条目一旦出现就**不会自己消失** —— 会话闲下来它只是
	*      灰着留在那里（这样还能给它发话），只有「×」能收掉它（见 `closeEntry()`）。收掉之后再想
	*      让它回来，得等这个会话**又有新动静**（新的输出、新的卡片、新的出错）。
	*   2. **一条里放什么**（`entryView`）：标题、明细（状态词 · 时间 · 目录 · 会话号尾巴）、
	*      属于它的卡片、要不要画「知道了」。
	*   3. **没有会话的卡片**（请求里没带会话）：它自己占一条，只显示卡片、没有输入框。
	*/
	function entriesSection() {
		const now = Date.now();
		const sessions = panelSessionsWithTitles();
		const byId = new Map(sessions.map((view) => [view.id, view]));
		const cardsFor = /* @__PURE__ */ new Map();
		const orphans = [];
		for (const card of mirror.visiblePendings()) {
			if (card.sessionId === "") {
				orphans.push(card);
				continue;
			}
			const list = cardsFor.get(card.sessionId) ?? [];
			list.push(card);
			cardsFor.set(card.sessionId, list);
		}
		reconcileEntries(sessions, cardsFor);
		const out = [];
		for (const entry of [...entries.values()].sort((left, right) => right.createdAt - left.createdAt)) {
			const view = byId.get(entry.key);
			if (view === void 0) {
				entries.delete(entry.key);
				suppressed.delete(entry.key);
				continue;
			}
			out.push(entryView(view, cardsFor.get(entry.key) ?? [], now));
		}
		for (const card of orphans) out.push({
			key: `card:${card.id}`,
			target: "",
			input: false,
			title: LABELS.entryUnknown,
			detail: "",
			state: card.kind === "approval" ? "approval" : "question",
			color: card.color ?? STATUS_STYLES.asking.color,
			busy: false,
			lock: false,
			errorNote: "",
			canAck: false,
			cards: [card]
		});
		return out;
	}
	/**
	* 让条目列表跟上会话目录。
	*
	* 出现条件里那句"有新动静"就是 `mirror` 里的**活动计数**：会话开始输出、来了一张卡片、又出了
	* 一次错都会把它加一。`suppressed` 记的是"上次被收掉时它已经加到几了"，所以「×」之后的会话
	* 不会在下一拍就被对账加回来 —— 但它下一次有事（计数更大）时一定会回来。
	*/
	function reconcileEntries(sessions, cardsFor) {
		for (const view of sessions) {
			if (entries.has(view.id)) continue;
			const cards = cardsFor.get(view.id) ?? [];
			const unackedError = view.status === "error" && !view.errorAcked;
			if (!view.busy && cards.length === 0 && !unackedError) continue;
			const seen = suppressed.get(view.id);
			if (seen !== void 0 && view.signal <= seen) continue;
			suppressed.delete(view.id);
			entrySeq += 1;
			entries.set(view.id, {
				key: view.id,
				createdAt: entrySeq,
				seenSignal: view.signal
			});
			overlay.note(`面板新增会话条目 ${idTail(view.id)}（信号 ${view.signal}，${view.busy ? "在输出" : cards.length > 0 ? "有待办" : "出错"}）`);
		}
		if (entries.size <= settings.entryLimit) return;
		for (const entry of [...entries.values()].sort((left, right) => left.createdAt - right.createdAt)) {
			if (entries.size <= settings.entryLimit) break;
			const view = sessions.find((item) => item.id === entry.key);
			const cards = cardsFor.get(entry.key) ?? [];
			if (view === void 0 || view.busy || cards.length > 0) continue;
			if (view.status === "error" && !view.errorAcked) continue;
			entries.delete(entry.key);
			suppressed.set(entry.key, view.signal);
			overlay.note(`面板条目超过上限 ${settings.entryLimit}，挤掉最旧的一条 ${idTail(entry.key)}`);
		}
	}
	/** 条目状态 → 整体口径里那个状态键（颜色只有一处来源：mirror 的 `STATUS_STYLES`）。 */
	const ENTRY_STATUS_KEY = {
		approval: "approval",
		question: "asking",
		error: "error",
		running: "working",
		acked: "idle",
		idle: "idle"
	};
	/** 一条会话条目要显示的全部内容（纯数据，见 `EntryView`）。 */
	function entryView(view, cards, now) {
		const approval = cards.some((card) => card.kind === "approval");
		const unackedError = view.status === "error" && !view.errorAcked;
		let state = "idle";
		if (approval) state = "approval";
		else if (cards.length > 0) state = "question";
		else if (unackedError) state = "error";
		else if (view.busy || view.running) state = "running";
		else if (view.status === "error") state = "acked";
		const word = state === "approval" ? LABELS.entryApproval : state === "question" ? LABELS.entryWaiting : state === "error" ? LABELS.entryError : state === "running" ? LABELS.entryRunning : state === "acked" ? LABELS.entryAckedError : LABELS.entryIdle;
		return {
			key: view.id,
			target: view.id,
			input: true,
			title: sessionHeadline(view),
			detail: sessionDetail(view, word, now),
			state,
			color: STATUS_STYLES[ENTRY_STATUS_KEY[state]].color,
			busy: view.busy || view.running,
			lock: settings.lockComposeWhileBusy && view.busy,
			errorNote: view.errorNote,
			canAck: unackedError,
			cards
		};
	}
	/**
	* 给还没有标题的会话补标题，读的是 `title` 投影（网页端侧边栏读的同一份）。
	*
	* 每拍都试一次的代价是一次 Map 查表（`stateOf()` 是 O(1) 的折叠结果，不是重放日志），比让用户
	* 在一排「未命名」里猜便宜得多。非 live 的会话没有 Session 对象可读，只能用 `api-session/added`
	* 的快照加上球自己看到的首条人写的消息。
	*
	* @returns 补过标题的那一份列表（就是 `mirror.panelSessions()` 的形状）。
	*/
	function panelSessionsWithTitles() {
		const rows = mirror.panelSessions();
		for (const row of rows) {
			if (row.title !== "") continue;
			const title = liveTitle(row.id);
			if (title === "") continue;
			mirror.setTitle(row.id, title);
			row.title = title;
		}
		return rows;
	}
	/**
	* 一个 live 会话当前标题：按 id 取到 Session 对象，先读 O(1) 的投影。
	*
	* 投影空着才退到 `sessionTitle.get()`（重放整份日志），而且每个会话最多每 30 秒问一次：这一节
	* 每拍都跑，不节流就等于拿一个长会话的日志做每秒若干次的重放。标题落下来时 `session/title`
	* 事件本来就会实时告诉我们。
	*/
	function liveTitle(sessionId) {
		const session = serviceOf("sessions")?.get?.(sessionId);
		if (session === void 0) return "";
		const projected = readProjectedTitle(session);
		if (projected !== "") return projected;
		const now = Date.now();
		if (now - (titleFallbackAt.get(sessionId) ?? 0) < TITLE_FALLBACK_MS) return "";
		titleFallbackAt.set(sessionId, now);
		const title = expensiveTitle(session);
		if (title !== "") overlay.note(`会话 ${idTail(sessionId)} 的标题来自 sessionTitle 兜底：${oneLine(title, 60)}`);
		return title;
	}
	/** 上一次走"重放日志"那条兜底路问标题的时刻，每个会话一条。 */
	const titleFallbackAt = /* @__PURE__ */ new Map();
	/** 兜底问标题的最小间隔（毫秒）。 */
	const TITLE_FALLBACK_MS = 3e4;
	/**
	* 「＋ 新会话」的候选：**每个工作区一条**，一条不多；注册表里一个工作区都没有时给一条
	* **"建在默认目录里"**的兜底行。
	*
	* 面板右上角那个「＋」按钮弹的就是这一份：点一条 = 在球上多出一个**空条目**（标题写着"新会话 ·
	* 工作区名"，输入框直接可用），从它发出去的话会在那个工作区里新建一个会话（见 `resolveTarget`）。
	*
	* **优先指名工作区**：`sessionController.create()` 只有带 `workspaceId` 时才会把新会话登记进
	* 工作区，否则它会一直挂在侧边栏的「未分组」。所以注册表里有工作区时，就只让用户从工作区里挑。
	*
	* **但没有工作区时不能把按钮做成死的**（实测踩过：注册表在插件挂载那一刻还没就绪，于是列表
	* 永远是空的、按钮永远是灰的，而这跟用户有没有工作区毫无关系）：那时给一条兜底行，新会话建在
	* **最近在用的那个目录**里（一个会话都没见过就交给 Harness 的默认目录）。落到「未分组」总比
	* "根本建不出来"好；这一类会话的 `id` 用的是老写法 `new`（不带工作区），见 `resolveTarget`。
	*
	* `name` 是工作区名、`entry` 是球上那个空条目要用的**整行标题**（`entryNewFor` 拼好）：
	* 球脚本是纯 ASCII 的，所以任何带间隔号之类的文案只能由宿主这边写好再送过去。
	*/
	function createTargets() {
		const items = [];
		const workspaces = workspaceList();
		const names = /* @__PURE__ */ new Map();
		for (const workspace of workspaces) {
			const name = workspaceName(workspace);
			names.set(name, (names.get(name) ?? 0) + 1);
		}
		for (const workspace of workspaces) {
			const name = workspaceName(workspace);
			const duplicated = (names.get(name) ?? 0) > 1;
			items.push({
				id: `${TARGET_NEW_PREFIX}${workspace.id}`,
				label: `${LABELS.targetNewHead}：${duplicated ? `${name}（${shortPath(workspace.path, 24)}）` : name}`,
				detail: shortPath(workspace.path, 40),
				name,
				entry: LABELS.entryNewFor.replace("{place}", name)
			});
		}
		if (items.length === 0) {
			const cwd = recentCwd();
			items.push({
				id: TARGET_NEW,
				label: LABELS.targetNew,
				detail: cwd === "" ? LABELS.createDefault : shortPath(cwd, 40),
				name: "",
				entry: LABELS.entryNew
			});
		}
		return items;
	}
	/**
	* 最近有活动的那个会话的目录（注册表里没有工作区时，新会话就建在这里）。
	*
	* 用"最近在用的那个"而不是 Harness 的进程默认目录：用户刚在球上跟某个会话说过话，新会话落到
	* 同一个目录里才符合直觉。`panelSessions()` 已经按最近活动排好序了。
	*/
	function recentCwd() {
		for (const row of mirror.panelSessions()) {
			const cwd = row.cwd.trim();
			if (cwd !== "") return cwd;
		}
		return "";
	}
	function buildState() {
		const snapshot = mirror.snapshot();
		return {
			v: 8,
			...snapshot,
			meta: metaLine(snapshot),
			busy: settings.lockComposeWhileBusy ? snapshot.busy : [],
			labels: LABELS,
			footer: footer(),
			entries: entriesSection(),
			create: createTargets(),
			sendResult: lastSend ?? null,
			soundEnabled: settings.sound,
			metrics: {
				ballSize: settings.ballSize,
				panelWidth: settings.panelWidth,
				panelHeight: settings.panelHeight
			}
		};
	}
	const onQuestion = async (request, next) => {
		if (!settings.answerQuestions) return next();
		const record = request ?? {};
		const items = toQuestionViews(record.questions);
		if (items.length === 0) return next();
		const callId = typeof record.wait?.callId === "string" ? record.wait.callId : "";
		const id = `q-${callId === "" ? randomUUID() : callId}`;
		const sessionId = typeof record.agent?.id === "string" ? record.agent.id : "";
		const deadlineAt = record.wait?.timed === true ? deadlineFromToolCall(sessionId, callId) : void 0;
		const view = {
			id,
			kind: "question",
			sessionId,
			createdAt: Date.now(),
			color: STATUS_STYLES.asking.color,
			title: LABELS.cardQuestion,
			...deadlineAt === void 0 ? {} : { deadlineAt },
			items
		};
		const withdraw = takeOverCancellation(request);
		const upstream = Promise.resolve().then(() => next());
		upstream.catch(() => void 0);
		let resolveAnswer;
		const ballAnswer = new Promise((resolve) => {
			resolveAnswer = resolve;
		});
		const runtime = {
			view,
			agent: record.agent,
			callId,
			answeredOnBall: false,
			withdraw,
			resolveAnswer
		};
		pendings.set(id, runtime);
		mirror.addPending(view);
		if (settings.expandOnPending) overlay.expand();
		try {
			const answer = await Promise.race([ballAnswer, upstream]);
			if (!runtime.answeredOnBall) setNotice("网页端已经作答了，这条卡片自动收起。");
			return answer;
		} catch (error) {
			if (!runtime.answeredOnBall && pendings.has(id)) mirror.updatePending(id, {
				deadlineAt: void 0,
				note: LABELS.expired
			});
			throw error;
		} finally {
			runtime.resolveAnswer = void 0;
		}
	};
	const onApproval = async (request, next) => {
		if (!settings.answerApprovals) return next();
		const record = request ?? {};
		const toolName = typeof record.toolName === "string" ? record.toolName : "";
		const id = `a-${randomUUID()}`;
		const view = {
			id,
			kind: "approval",
			sessionId: typeof record.agent?.id === "string" ? record.agent.id : "",
			createdAt: Date.now(),
			color: STATUS_STYLES.approval.color,
			title: LABELS.cardApproval,
			toolName,
			reason: approvalReason(record),
			options: [{
				label: "允许一次",
				value: "allowed-once"
			}, {
				label: "拒绝",
				value: "rejected"
			}]
		};
		const upstream = Promise.resolve().then(() => next());
		upstream.catch(() => void 0);
		const withdraw = takeOverCancellation(request);
		let resolveApproval;
		const ballOutcome = new Promise((resolve) => {
			resolveApproval = resolve;
		});
		const runtime = {
			view,
			agent: record.agent,
			callId: typeof record.callId === "string" ? record.callId : "",
			answeredOnBall: false,
			withdraw,
			resolveApproval
		};
		pendings.set(id, runtime);
		mirror.addPending(view);
		if (settings.expandOnPending) overlay.expand();
		try {
			const outcome = await Promise.race([ballOutcome, upstream]);
			if (!runtime.answeredOnBall) {
				dropPending(runtime);
				setNotice(approvalSettledNotice(outcome));
			}
			return outcome;
		} catch (error) {
			if (!runtime.answeredOnBall) dropPending(runtime);
			throw error;
		} finally {
			runtime.resolveApproval = void 0;
		}
	};
	/**
	* 带 `timeout` 的提问在前台等待结束后会变成 continued；倒计时的截止时刻就是
	* "请求到达 + 工具参数里的 timeout 秒"。参数拿不到就不显示倒计时（宁可不显示，
	* 也不给一个错的秒数）。
	*/
	function deadlineFromToolCall(sessionId, callId) {
		if (callId === "") return void 0;
		const raw = mirror.toolArguments(sessionId, callId);
		if (raw === void 0) return void 0;
		try {
			const parsed = JSON.parse(raw);
			const seconds = typeof parsed.timeout === "number" && Number.isFinite(parsed.timeout) ? parsed.timeout : 0;
			if (seconds <= 0) return void 0;
			return Date.now() + seconds * 1e3;
		} catch {
			return;
		}
	}
	/**
	* 条目上的「×」：把这个会话（或那条还在空中的"新会话"）从面板上收掉。
	*
	* 收掉的只是**这一条**，会话本身一点不受影响（照样在跑、照样在网页端等你作答）。代价写清楚：
	* 那条条目上如果挂着提问/审批卡片，卡片也跟着看不见了 —— 网页端那个弹窗照旧在，哪边先答都算数
	* （所以这里是 `hidePending` 而不是把请求结掉，见 `mirror.hidePending()`）。
	*
	* **「×」也包含「知道了」的意思**：那一条如果正带着一条还没确认的出错，收走它的同时把那条错误
	* 一并确认掉。不这么做的话红就没人能清了 —— 「知道了」按钮长在条目上，条目一收走，那条错误就
	* 再也没有地方可以确认（球会一直红到那个会话自己又跑起来为止）。这也是用户报的那个问题的修法。
	*
	* 收掉之后不会立刻长回来：`suppressed` 记的是这个会话**此刻**的活动计数，只有它下一次"有事"
	* （新的一轮、人又说了一句、目录说它开始跑了、新的卡片、新的出错）才会重新出现（见
	* `reconcileEntries()`）。
	*/
	function closeEntry(key) {
		if (key === "") return;
		let closed = false;
		const acked = mirror.ackError(key);
		if (acked) closed = true;
		if (key.startsWith("card:")) {
			const cardId = key.slice(5);
			if (mirror.visiblePendings().some((view) => view.id === cardId)) {
				mirror.hidePending(cardId);
				closed = true;
			}
		}
		if (entries.delete(key)) {
			closed = true;
			suppressed.set(key, mirror.signalOf(key));
		}
		for (const view of mirror.visiblePendings()) {
			if (view.sessionId !== key) continue;
			mirror.hidePending(view.id);
			closed = true;
		}
		if (!closed) {
			setNotice("这一条已经不在面板上了。");
			return;
		}
		overlay.note(`球上收起了条目 ${idTail(key)}（会话不受影响；它下一次有事会再出现）` + (acked ? "，并确认了它的出错" : ""));
		setNotice(acked ? "已从面板上收起这一条，并确认了它的出错：球不再为它染红。" : "已从面板上收起这一条；会话本身不受影响，它下一次有事会再出现。");
	}
	/**
	* 出错条目上的「知道了」：**只清掉球上的红**，条目留着。
	*
	* 这是"红不会自己消失"的另一半（见 `Config` 与文件头）：出错之后球一直红着，直到有人按这个
	* 按钮；按下之后这条错误不再参与整体颜色与那行统计，但**条目留着**（写着"已确认出错"）。
	* 会话下一次开始输出、或者又出了一次错，颜色照旧回来（`mirror.ackError()` 的语义）。
	*
	* 「×」也做同一件事（见 `closeEntry()`），区别只是它连条目一起收走 —— 所以"确认掉这条红"永远
	* 有一个够得着的入口。
	*/
	function acknowledgeError(sessionId) {
		if (sessionId === "") return;
		if (!mirror.ackError(sessionId)) {
			setNotice("这一条没有待确认的出错。");
			return;
		}
		overlay.note(`球上确认了会话 ${idTail(sessionId)} 的出错（球不再为它染红）`);
		setNotice("已确认这条出错：球不再为它染红；条目留着，点「×」可以把它收掉。");
	}
	async function handleAction(action) {
		if (action.kind === "prompt") {
			const target = typeof action.target === "string" ? action.target : "";
			await sendPrompt(typeof action.text === "string" ? action.text : "", target, typeof action.key === "string" && action.key !== "" ? action.key : target);
			return;
		}
		if (action.kind === "close") {
			closeEntry(typeof action.id === "string" ? action.id : "");
			return;
		}
		if (action.kind === "ack") {
			acknowledgeError(typeof action.id === "string" ? action.id : "");
			return;
		}
		if (typeof action.id !== "string" || action.id === "") return;
		const runtime = pendings.get(action.id);
		if (runtime === void 0) {
			setNotice("这张卡片对应的请求已经结束了，球上没有可作答的东西。");
			return;
		}
		if (action.kind === "dismiss") {
			mirror.hidePending(action.id);
			setNotice("已在球上收起；网页端仍然可以作答。");
			return;
		}
		if (action.kind === "approval") {
			const outcome = action.outcome === "rejected" ? "rejected" : "allowed-once";
			if (runtime.resolveApproval === void 0) {
				dropPending(runtime);
				setNotice("这次审批已经结束了，球上的卡片已收起；结果请到网页端看。");
				return;
			}
			runtime.answeredOnBall = true;
			runtime.resolveApproval(outcome);
			finishPending(runtime, outcome === "allowed-once" ? "已在球上允许一次。" : "已在球上拒绝。");
			return;
		}
		if (action.kind !== "answer") return;
		const answers = normalizeAnswers(action.answers, runtime.view.items);
		if (!isCompleteAnswer(answers, runtime.view.items)) {
			setNotice(LABELS.answerIncomplete);
			return;
		}
		if (runtime.resolveAnswer !== void 0) {
			runtime.answeredOnBall = true;
			runtime.resolveAnswer({ answers });
			finishPending(runtime, "已在球上作答。");
			return;
		}
		if (runtime.callId === "") {
			setNotice("这条提问已经没有可作答的通道了，请到网页端查看。");
			return;
		}
		const service = ctx.get("userQuestions");
		if (service?.answer === void 0) {
			setNotice("提问服务不可用，无法在球上作答。");
			return;
		}
		try {
			const accepted = service.answer(runtime.agent, runtime.callId, { answers });
			finishPending(runtime, accepted ? "已在球上作答：问题已超时，答案作为补充消息交给模型。" : "这个问题已经关闭了。");
		} catch (error) {
			setNotice(`球上作答失败：${error instanceof Error ? error.message : String(error)}`);
		}
	}
	/**
	* 球上那一条条目的目标 → 真正的会话 id。
	*
	* 都在这里收口，球上只送来一个字符串（`new:<工作区 id>` / `new` / 会话 id）：
	*   - `new:<workspaceId>`：在**指定的工作区**里新建一个会话，再把这句话发进去。这一条是
	*     「新建的会话落到哪个工作区」的唯一硬保证（见 `createSession()` 里的说明）；
	*   - `new`：**没有登记工作区**时那条兜底行送来的（见 `createTargets()`）。注册表里只有一个
	*     工作区就用那一个；一个都没有就把新会话建在**最近在用的那个目录**里 —— 落到「未分组」
	*     总比"根本建不出来"好。有好几个工作区时老实拒绝（那时球上会给每个工作区一行，不该走到这）；
	*   - 其它：就是那个会话 id（prompt 自己会把它 resume 起来）；空串表示那一条没有目标，同样拒绝。
	*
	* 拒绝时回一个原因，由调用方写成球上的提示与回执（回执让那个输入框立刻解锁）。
	*/
	async function resolveTarget(target) {
		const requested = target.startsWith(TARGET_NEW_PREFIX) ? target.slice(TARGET_NEW_PREFIX.length).trim() : "";
		const workspace = requested === "" ? void 0 : workspaceList().find((item) => item.id === requested);
		if (target.startsWith(TARGET_NEW_PREFIX) || target === TARGET_NEW) {
			let request;
			let cwd = "";
			let place = "";
			if (requested !== "") {
				if (workspace === void 0) {
					overlay.note(`球上新建会话失败：工作区 ${requested} 已经不在注册表里了`);
					return {
						reason: "那个工作区已经不在注册表里了",
						id: "",
						created: false,
						cwd: "",
						place: ""
					};
				}
				request = { workspaceId: workspace.id };
				cwd = workspace.path;
				place = workspaceName(workspace);
			} else {
				const only = soleWorkspace();
				if (only !== void 0) {
					request = { workspaceId: only.id };
					cwd = only.path;
					place = workspaceName(only);
				} else if (workspaceList().length === 0) {
					const recent = recentCwd();
					request = recent === "" ? {} : { cwd: recent };
					cwd = recent;
					place = recent === "" ? LABELS.createDefault : shortPath(recent, 24);
					overlay.note(`球上新建会话：没有登记工作区，落在 ${recent === "" ? "Harness 默认目录" : recent}`);
				} else {
					overlay.note("球上新建会话失败：没有指名工作区，而且注册表里不止一个工作区");
					return {
						reason: LABELS.composeNoTarget,
						id: "",
						created: false,
						cwd: "",
						place: ""
					};
				}
			}
			const id = await createSession(request);
			if (id === void 0) return {
				reason: "新建会话失败，详情见 ball.log",
				id: "",
				created: false,
				cwd: "",
				place: ""
			};
			mirror.adoptSession(id, cwd);
			return {
				reason: "",
				id,
				created: true,
				cwd,
				place
			};
		}
		if (target.trim() === "") {
			overlay.note("球上发送失败：那一条没有可以发送的目标");
			return {
				reason: LABELS.composeNoTarget,
				id: "",
				created: false,
				cwd: "",
				place: ""
			};
		}
		return {
			reason: "",
			id: target,
			created: false,
			cwd: mirror.cwdOf(target),
			place: ""
		};
	}
	/**
	* 新建一个会话（`sessionController.create`，不带 sessionId 就是"给我一个新的"）。
	*
	* **为什么要带 `workspaceId`**：`create()` 的实现是
	* `cwd = workspace?.path ?? request.cwd ?? defaultCwd`，而只有 `workspaceId` 那一路会
	* 接着调 `workspace.attachSession(sessionId)`。工作区的会话列表是"登记过的 id + 目录校验"
	* 两件事合起来算的，所以只给 cwd 建的会话即使目录正好等于某个工作区路径，也不会被算进
	* 那个分组 —— 它就挂在侧边栏的「未分组」里（这正是用户报的那个 bug）。带上 workspaceId
	* 之后，新会话立刻出现在对应分组里，和网页端"在工作区里新建会话"走的是同一条路。
	*
	* 与 `prompt` 一样走两条路（网关优先、直连兜底），失败连同完整栈写进 `ball.log`。
	*
	* @param request - `{ workspaceId }` 或 `{ cwd }`（两者互斥，也可以都不给）。
	*/
	/**
	* 同一个业务方法的两种投递方式，按"网关优先、直连兜底"排好 —— `prompt` 与 `create` 共用。
	*
	* 为什么网关优先、直连会踩什么，见 `TypertGatewayLike` 的说明；两条路是同一个业务方法，
	* 服务端按 `requestId` 去重，所以不会把同一句话发两遍。
	*
	* @param body - 业务方法的请求体；`prompt` 按 mode 现算，`create` 忽略 mode（两条路共用
	*   一个签名，所以它照旧会收到一个占位的 mode）。
	* @returns 排好序的路；一条都没有时是空数组（调用方据此报"没有可用的发送者"）。
	*/
	function deliveryRoutes(method, body) {
		const gateway = ctx.get("typertGateway");
		const direct = ctx.get("sessionController")?.[method];
		const routes = [];
		if (gateway?.invoke !== void 0) routes.push({
			how: "gateway",
			run: (mode) => gateway.invoke?.({
				namespace: "session",
				method,
				args: { request: body(mode) },
				signal: new AbortController().signal
			}) ?? Promise.resolve()
		});
		if (direct !== void 0) routes.push({
			how: "direct",
			run: (mode) => Promise.resolve(direct(body(mode)))
		});
		return routes;
	}
	async function createSession(request) {
		const where = typeof request.workspaceId === "string" ? `workspaceId=${request.workspaceId}` : `cwd=${typeof request.cwd === "string" ? request.cwd : "(默认)"}`;
		for (const route of deliveryRoutes("create", () => request)) try {
			const value = await route.run("queue");
			const record = asRecord(value);
			const id = typeof record?.sessionId === "string" ? record.sessionId : "";
			if (id !== "") {
				overlay.note(`球上新建会话成功（${route.how}，${where}）：${id}`);
				return id;
			}
			overlay.note(`球上新建会话的返回值里没有 sessionId（${route.how}）：${oneLine(JSON.stringify(value))}`);
		} catch (error) {
			overlay.note(`球上新建会话失败（${route.how}，${where}）：${describeFailure(error)}`);
		}
	}
	/**
	* 面板上那条条目里的一句话 → 会话。
	*
	* 走的是 `ctx.sessionController.prompt`，也就是**网页端输入框提交时走的同一个入口**：同一条
	* 消息来源（`kind: 'user'`）、同一套请求去重、同一套排队/插话语义、同样的模型与附件校验。
	* 所以球上发出去的话在会话记录里和网页端发出去的完全一样，没有第二套语义。
	*
	* 发给谁：就是那一行条目自己的 `target`（会话 id，或者 `new:<工作区 id>` = 在这个工作区里新建
	* 一个会话）—— 目标和输入框在球上是同一个条目，所以**不存在"发错会话"这种可能**，也就没有
	* 早先那个「发送到」下拉了。
	*
	* 怎么投递：默认 `auto`（模型在跑就插话、空闲就排队）；插话被拒时退回排队，而不是把那句话丢掉。
	* 注意条目上的输入框默认在目标会话输出期间是禁用/变灰的（`lockComposeWhileBusy`），所以走到
	* `steer` 的那条路通常只在那个开关被关掉时才出现。
	*
	* 走哪条路：优先 `ctx.typertGateway.invoke()`（网关自己的调用上下文，客户端提交走的就是这条路），
	* 失败再退到 `sessionController.prompt()` 直连。两条路的失败都会连同**完整栈**写进 `ball.log`，
	* 因为这里出错时球上只能显示一行文案，而那一行不足以定位。
	*
	* 一次发送只用一个 `requestId`：服务端按它去重，所以「第一条路其实已经把话投进去了、只是最后一步
	* 炸了」时，第二条路不会再把同一句话发一遍。
	*
	* 结果写两条出口：**球上的回执**（`sendResult` —— 哪一条要解锁、这句话落到了哪个会话、以及那句
	* 备查的话）与**页脚提示**（`setNotice` —— 成功与失败都留在眼前，失败带原因）。`key` 原样送回
	* 球上，因为"＋ 新会话"那一条用的不是会话 id（球自己编的本地 key），只有它知道那一条是谁。
	*
	* @param raw - 框里那句话。
	* @param target - 那一行条目的目标（会话 id / `new:<工作区 id>`）。
	* @param key - 那一行条目在球上的 key（只在回执里用：球靠它解锁、并把新会话那一条交出去）。
	*/
	async function sendPrompt(raw, target, key = target) {
		const text = raw.trim();
		if (text === "") return;
		const resolved = await resolveTarget(target);
		if (resolved.reason !== "") {
			const note = LABELS.composeRefused.replace("{reason}", resolved.reason);
			setNotice(note);
			setSendResult(false, key, "", note);
			return;
		}
		const sessionId = resolved.id;
		const requestId = randomUUID();
		const routes = deliveryRoutes("prompt", (mode) => ({
			requestId,
			sessionId,
			mode,
			content: [{
				type: "text",
				text
			}]
		}));
		if (routes.length === 0) {
			setNotice(LABELS.composeNoSender);
			setSendResult(false, key, sessionId, LABELS.composeNoSender);
			return;
		}
		const running = resolved.created ? false : mirror.runningOf(sessionId);
		const modes = (settings.promptMode === "auto" ? running ? "steer" : "queue" : settings.promptMode) === "steer" ? ["steer", "queue"] : ["queue"];
		let failure = "";
		for (const mode of modes) for (const route of routes) try {
			await route.run(mode);
			overlay.note(`球上发送成功（${route.how} / ${mode} / ${sessionId}${resolved.created ? ` / 新建会话 ${resolved.place}` : ""}）：${oneLine(text)}`);
			const note = resolved.created ? LABELS.composeCreated.replace("{place}", resolved.place) : mode === "steer" ? LABELS.composeSteered : LABELS.composeSent;
			setNotice(note);
			setSendResult(true, key, sessionId, note);
			return;
		} catch (error) {
			failure = error instanceof Error ? error.message : String(error);
			overlay.note(`球上发送失败（${route.how} / ${mode} / ${sessionId}）：${describeFailure(error)}`);
		}
		const note = LABELS.composeFailed.replace("{reason}", failure);
		setNotice(note);
		setSendResult(false, key, sessionId, note);
	}
	events.on("agent/assistant-stream", (payload) => {
		try {
			mirror.onStream(payload);
		} catch (error) {
			ctx.logger?.warn?.(`session-ball：处理流式帧失败：${String(error)}`);
		}
	});
	events.on("session/event", (session, event) => {
		try {
			mirror.onSessionEvent(session, event);
			const record = asRecord(event);
			const sessionId = typeof asRecord(session)?.id === "string" ? String(asRecord(session)?.id) : "";
			if (record?.type === "tool/result") {
				const data = asRecord(record.data);
				if (data !== void 0) {
					const message = asRecord(data.message);
					const callId = typeof message?.toolCallId === "string" ? message.toolCallId : "";
					if (callId !== "") settleQuestionByCallId(callId, isPendingToolResult(data));
				}
			}
			if (sessionId !== "") reconcileQuestionCards(sessionId, session);
			if (record?.type === "approval/asked") {
				const data = asRecord(record.data);
				if (data !== void 0) rememberApprovalAsk(sessionId, data);
			} else if (record?.type === "approval/decided") {
				const data = asRecord(record.data);
				if (data !== void 0) settleApprovalCard(data);
			}
		} catch (error) {
			ctx.logger?.warn?.(`session-ball：处理会话事件失败：${String(error)}`);
		}
	});
	/**
	* 记下 `approval/asked`：审批请求 id → 身份（会话 + 工具调用）。
	*
	* 它只是 `settleApprovalCard()` 的配对表，不参与任何判断；表本身按插入顺序淘汰最旧的一条，
	* 所以一个长时间运行的宿主不会因为审批多了而无限长大。
	*
	* @param sessionId - 发起这次审批的会话（`session/event` 的会话）。
	* @param data - `approval/asked` 的载荷（`id` / `toolName` / 可选的 `callId`）。
	*/
	function rememberApprovalAsk(sessionId, data) {
		const id = typeof data.id === "string" ? data.id : "";
		if (id === "") return;
		approvalAsks.set(id, {
			sessionId,
			callId: typeof data.callId === "string" ? data.callId : "",
			toolName: typeof data.toolName === "string" ? data.toolName : ""
		});
		while (approvalAsks.size > APPROVAL_ASK_LIMIT) {
			const oldest = approvalAsks.keys().next();
			if (oldest.done === true) break;
			approvalAsks.delete(oldest.value);
		}
	}
	/**
	* `approval/decided` 到了：这次审批**已经结束**，球上那张卡必须跟着走。
	*
	* 为什么不能只靠 `onApproval()` 里那条 Promise：那是"我们的前台掏得到的那条路"，而审批
	* 可能在别处结束（网页端作答、应答者缺席 → unavailable、轮次中止 → cancelled），而且
	* 每条路径都要靠链路上每一环都好好地兑现/拒绝那个 Promise。会话日志里的这张凭据是
	* **权威、耐久**的：它由 harness 自己按成对规则落库（`approval/asked` + `approval/decided`
	* 同一个 id、且必须落在同一个未结束的轮次里）。所以这里再独立判一次 —— 与提问卡片的
	* "工具结果 + 投影对账"两条判据同一个思路，任一条成立就把卡片收掉，谁也不必依赖谁。
	*
	* 认不出是哪张卡（表里没有这条 id：球是这次审批问到一半才挂载的之类）就**什么都不做**：
	* 宁可让一条极端情况下的卡片留着，也不误收一张此刻还该显示着的卡。
	*
	* @param data - `approval/decided` 的载荷（`id` + `outcome`）。
	*/
	function settleApprovalCard(data) {
		const id = typeof data.id === "string" ? data.id : "";
		if (id === "") return;
		const ask = approvalAsks.get(id);
		approvalAsks.delete(id);
		if (ask === void 0) return;
		let target;
		for (const runtime of pendings.values()) {
			if (runtime.view.kind !== "approval") continue;
			if (ask.sessionId !== "" && runtime.view.sessionId !== ask.sessionId) continue;
			if (ask.callId !== "") {
				if (runtime.callId !== ask.callId) continue;
			} else if (ask.toolName !== "" && runtime.view.toolName !== ask.toolName) continue;
			if (target === void 0 || runtime.view.createdAt < target.view.createdAt) target = runtime;
		}
		if (target === void 0) return;
		const outcome = typeof data.outcome === "string" ? data.outcome : "";
		dropPending(target);
		setNotice(approvalSettledNotice(outcome));
	}
	function settleQuestionByCallId(callId, pending) {
		for (const [id, runtime] of pendings) {
			if (runtime.view.kind !== "question" || runtime.callId !== callId) continue;
			if (runtime.resolveAnswer !== void 0) continue;
			if (pending) {
				mirror.updatePending(id, {
					deadlineAt: void 0,
					note: LABELS.expired
				});
				return;
			}
			pendings.delete(id);
			mirror.removePending(id);
			return;
		}
	}
	/**
	* 对账提问卡片：**两条独立判据**，任一成立就动作。
	*
	* 为什么需要它：请求里不一定带 `wait.callId`，所以「网页端已经答完、球上卡片却一直挂着」是最
	* 容易让人误判的状态 —— 你会以为它还在等你。
	*
	*   判据一（自足，主判据）：这次 `ask_user_question` 调用**结束了没有**。卡片的问题编号能反过来
	*   认出是哪一次调用（`mirror.questionCallState`），调用还在跑就留着；已经结束就按结果收：
	*   `pending` 表示前台等待结束、问题仍可继续作答（留着卡片并补上 callId），否则就是被作答/关闭
	*   （收起卡片）。判据只用球本来就在消费的 `tool/call` / `tool/result`，不依赖任何别的服务。
	*
	*   判据二（投影）：harness 自己判断「还开着吗」用的就是 `userQuestions` 投影，形状与 harness
	*   内部 `continued()` 读的完全一致。拿得到就以它为准，拿不到就跳过（不误删）。
	*/
	function reconcileQuestionCards(sessionId, session) {
		const mine = [...pendings.values()].filter((runtime) => runtime.view.kind === "question" && runtime.view.sessionId === sessionId);
		if (mine.length === 0) return;
		for (const runtime of mine) {
			if (runtime.resolveAnswer !== void 0) continue;
			const ids = (runtime.view.items ?? []).map((item) => item.id);
			const call = mirror.questionCallState(sessionId, ids);
			if (call === void 0) continue;
			if (runtime.callId !== call.callId) runtime.callId = call.callId;
			if (!call.finished) continue;
			if (call.pending) {
				mirror.updatePending(runtime.view.id, {
					deadlineAt: void 0,
					note: LABELS.expired
				});
				continue;
			}
			pendings.delete(runtime.view.id);
			mirror.removePending(runtime.view.id);
			setNotice("这个问题已经作答或关闭了，球上的卡片自动收起。");
		}
		const remaining = [...pendings.values()].filter((runtime) => runtime.view.kind === "question" && runtime.view.sessionId === sessionId);
		if (remaining.length === 0) return;
		const active = asRecord(asRecord(serviceOf("sessionProjections")?.stateOf?.(session, "userQuestions"))?.questions)?.active;
		if (!Array.isArray(active)) return;
		const callIdBySignature = /* @__PURE__ */ new Map();
		for (const entry of active) {
			const record = asRecord(entry);
			if (record === void 0) continue;
			const callId = typeof record.callId === "string" ? record.callId : "";
			const ids = [];
			for (const question of Array.isArray(record.questions) ? record.questions : []) {
				const item = asRecord(question);
				const id = typeof item?.id === "string" ? item.id : "";
				if (id !== "") ids.push(id);
			}
			if (callId === "" || ids.length === 0) continue;
			callIdBySignature.set([...ids].sort().join("|"), callId);
		}
		for (const runtime of remaining) {
			if (runtime.resolveAnswer !== void 0) continue;
			const signature = (runtime.view.items ?? []).map((item) => item.id).sort().join("|");
			const callId = callIdBySignature.get(signature);
			if (callId === void 0) {
				pendings.delete(runtime.view.id);
				mirror.removePending(runtime.view.id);
				setNotice("这个问题已经作答或关闭了，球上的卡片自动收起。");
				continue;
			}
			if (runtime.callId !== callId) {
				runtime.callId = callId;
				mirror.updatePending(runtime.view.id, {
					deadlineAt: void 0,
					note: LABELS.expired
				});
			}
		}
	}
	events.on("api-session/added", (summary) => mirror.onSessionSummary(summary));
	events.on("api-session/status", (sessionId, running) => mirror.onSessionStatus(sessionId, running));
	events.on("api-session/activity", (sessionId, updatedAt) => mirror.onSessionActivity(sessionId, updatedAt));
	events.on("api-session/removed", (sessionId) => mirror.onSessionRemoved(sessionId));
	events.on("user-questions/request", onQuestion, { prepend: true });
	events.on("approval/request", onApproval, { prepend: true });
	ctx.effect(() => {
		overlay.start();
		const pruner = setInterval(() => mirror.prune(Date.now()), 6e5);
		ctx.logger?.info?.(`session-ball：悬浮球已启用（运行目录 ${overlay.directory}）`);
		return () => {
			clearInterval(pruner);
			overlay.stop();
		};
	});
}
//#endregion
export { Config, apply, name };
