// Codex notify를 정식 rollout 턴과 대조해 터미널 대화만 받아들인다.

import { createReadStream } from "node:fs";
import { opendir, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
import { createInterface } from "node:readline";

const THREAD_ID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const DEFAULT_RETRY_COUNT = 7;
const DEFAULT_RETRY_DELAY_MS = 500;
const rolloutPathCache = new Map();

function cleanID(value) {
  const candidate = String(value ?? "").trim();
  return THREAD_ID.test(candidate) ? candidate : null;
}

function dateParts(value) {
  const date = new Date(value);
  return [
    String(date.getFullYear()),
    String(date.getMonth() + 1).padStart(2, "0"),
    String(date.getDate()).padStart(2, "0"),
  ];
}

async function findInDirectory(directory, suffix, recursive) {
  let entries;
  try {
    entries = await opendir(directory);
  } catch {
    return null;
  }
  for await (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isFile() && entry.name.endsWith(suffix)) {
      return path;
    }
    if (recursive && entry.isDirectory()) {
      const nested = await findInDirectory(path, suffix, true);
      if (nested) return nested;
    }
  }
  return null;
}

export async function findCodexRolloutPath(
  threadID,
  {
    sessionsRoot = join(homedir(), ".codex", "sessions"),
    now = Date.now(),
    cache = rolloutPathCache,
  } = {},
) {
  const id = cleanID(threadID);
  if (!id) return null;
  const cacheKey = `${resolve(sessionsRoot)}:${id}`;
  const cached = cache.get(cacheKey);
  if (cached) return cached;

  const suffix = `-${id}.jsonl`;
  for (const offset of [0, -24 * 60 * 60 * 1_000]) {
    const directory = join(sessionsRoot, ...dateParts(now + offset));
    const candidate = await findInDirectory(directory, suffix, false);
    if (candidate) {
      cache.set(cacheKey, candidate);
      return candidate;
    }
  }
  const candidate = await findInDirectory(sessionsRoot, suffix, true);
  if (candidate) cache.set(cacheKey, candidate);
  return candidate;
}

function textContent(content) {
  const values = [];
  for (const item of Array.isArray(content) ? content : []) {
    const type = String(item?.type ?? "").toLowerCase();
    if (["text", "input_text", "output_text"].includes(type)) {
      const text = String(item?.text ?? "").trim();
      if (text) values.push(text);
    } else if (type === "local_image") {
      const path = String(item?.path ?? "").trim();
      if (path) values.push(`[첨부: ${path}]`);
    }
  }
  return values;
}

function itemType(item) {
  return String(item?.type ?? "").replace(/[_-]/g, "").toLowerCase();
}

export async function readCodexRolloutTurn(path, turnID) {
  const wantedTurnID = String(turnID ?? "").trim();
  if (!path || !wantedTurnID) return null;
  let source = null;
  let cwd = null;
  let startedAt = null;
  let completedAt = null;
  let taskComplete = null;
  const eventPrompts = [];
  const eventFinalAnswers = [];
  const responseItemPrompts = [];
  const responseItemFinalAnswers = [];

  let stream;
  try {
    stream = createReadStream(path, { encoding: "utf8" });
    const lines = createInterface({ input: stream, crlfDelay: Infinity });
    for await (const line of lines) {
      if (!line || (!line.includes(wantedTurnID) && source !== null)) {
        continue;
      }
      let record;
      try {
        record = JSON.parse(line);
      } catch {
        continue;
      }
      const payload = record?.payload ?? {};
      if (record?.type === "session_meta" && source === null) {
        source = String(payload.source ?? "");
        continue;
      }
      if (record?.type === "turn_context" && payload.turn_id === wantedTurnID) {
        cwd = String(payload.cwd ?? "").trim() || null;
        continue;
      }
      if (record?.type === "response_item" && payload.type === "message") {
        const metadataTurnID = String(
          payload.internal_chat_message_metadata_passthrough?.turn_id ?? "",
        ).trim();
        if (metadataTurnID !== wantedTurnID) continue;
        const role = String(payload.role ?? "").toLowerCase();
        if (role === "user") {
          responseItemPrompts.push(...textContent(payload.content));
        } else if (
          role === "assistant" &&
          String(payload.phase ?? "").toLowerCase() === "final_answer"
        ) {
          responseItemFinalAnswers.push(...textContent(payload.content));
        }
        continue;
      }
      if (record?.type !== "event_msg" || payload.turn_id !== wantedTurnID) {
        continue;
      }
      if (payload.type === "task_started") {
        startedAt = Number(payload.started_at) || startedAt;
        continue;
      }
      if (payload.type === "task_complete") {
        taskComplete = payload;
        startedAt = Number(payload.started_at) || startedAt;
        completedAt = Number(payload.completed_at) || completedAt;
        continue;
      }
      if (payload.type !== "item_completed") continue;
      const item = payload.item ?? {};
      const type = itemType(item);
      if (type === "usermessage") {
        eventPrompts.push(...textContent(item.content));
      } else if (
        type === "agentmessage" &&
        String(item.phase ?? "").toLowerCase() === "final_answer"
      ) {
        eventFinalAnswers.push(...textContent(item.content));
      }
    }
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  } finally {
    stream?.destroy();
  }

  if (!taskComplete) return null;
  const prompts = responseItemPrompts.length > 0
    ? responseItemPrompts
    : eventPrompts;
  const finalAnswers = responseItemFinalAnswers.length > 0
    ? responseItemFinalAnswers
    : eventFinalAnswers;
  return {
    rolloutPath: path,
    source,
    turnID: wantedTurnID,
    cwd,
    prompt: prompts.join("\n").trim(),
    response:
      String(taskComplete.last_agent_message ?? "").trim() ||
      finalAnswers.join("\n").trim(),
    startedAt,
    completedAt,
  };
}

async function canonicalPath(value) {
  const path = resolve(String(value ?? ""));
  try {
    return await realpath(path);
  } catch {
    return path;
  }
}

function notifyPrompt(payload) {
  const messages = (Array.isArray(payload?.["input-messages"])
    ? payload["input-messages"]
    : [])
    .map((value) => String(value ?? "").trim())
    .filter(Boolean);
  // resume 세션의 notify는 현재 입력뿐 아니라 과거 사용자 입력 전체를
  // input-messages에 실어 줄 수 있다. rollout 원문을 읽지 못한 최후의
  // 대체 경로에서는 마지막 입력만 현재 턴으로 취급한다.
  return messages.at(-1) ?? "";
}

export class CodexTerminalTurnGate {
  constructor({
    cwd,
    externalSessionID = null,
    sessionsRoot,
    retryCount = DEFAULT_RETRY_COUNT,
    retryDelayMs = DEFAULT_RETRY_DELAY_MS,
    sleep = (milliseconds) => new Promise((resolveSleep) =>
      setTimeout(resolveSleep, milliseconds)
    ),
    now = () => Date.now(),
    cache = new Map(),
  }) {
    this.cwd = cwd;
    this.externalSessionID = cleanID(externalSessionID);
    this.sessionsRoot = sessionsRoot;
    this.retryCount = retryCount;
    this.retryDelayMs = retryDelayMs;
    this.sleep = sleep;
    this.now = now;
    this.cache = cache;
    this.seen = new Set();
    this.rolloutPath = null;
  }

  async accept(payload) {
    if (payload?.type !== "agent-turn-complete") {
      return { accepted: false, reason: "unsupported-event" };
    }
    const threadID = cleanID(payload?.["thread-id"]);
    const turnID = cleanID(payload?.["turn-id"]);
    if (!threadID || !turnID) {
      return { accepted: false, reason: "invalid-identifiers" };
    }
    if (this.externalSessionID && threadID !== this.externalSessionID) {
      return { accepted: false, reason: "thread-mismatch" };
    }
    const dedupeKey = `${threadID}:${turnID}`;
    if (this.seen.has(dedupeKey)) {
      return { accepted: false, reason: "duplicate" };
    }

    let turn = null;
    let path = this.rolloutPath;
    for (let attempt = 0; attempt < this.retryCount; attempt += 1) {
      path = path ?? await findCodexRolloutPath(threadID, {
        sessionsRoot: this.sessionsRoot,
        now: this.now(),
        cache: this.cache,
      });
      turn = await readCodexRolloutTurn(path, turnID);
      if (turn) break;
      if (attempt + 1 < this.retryCount) {
        await this.sleep(this.retryDelayMs);
      }
    }
    if (!turn) {
      return { accepted: false, reason: "rollout-turn-not-found" };
    }
    if (
      await canonicalPath(turn.cwd) !== await canonicalPath(this.cwd)
    ) {
      return { accepted: false, reason: "cwd-mismatch" };
    }
    const isNewSession = !this.externalSessionID;
    if (isNewSession && turn.source !== "cli") {
      return { accepted: false, reason: "new-session-not-cli" };
    }

    if (isNewSession) this.externalSessionID = threadID;
    this.rolloutPath = path;
    this.seen.add(dedupeKey);
    return {
      accepted: true,
      boundExternalSessionID: isNewSession ? threadID : null,
      turn: {
        ...turn,
        threadID,
        prompt: turn.prompt || notifyPrompt(payload),
        response:
          turn.response ||
          String(payload?.["last-assistant-message"] ?? "").trim(),
      },
    };
  }
}

export function codexRolloutFilenameMatches(path, threadID) {
  const id = cleanID(threadID);
  return Boolean(id && basename(String(path ?? "")).endsWith(`-${id}.jsonl`));
}
