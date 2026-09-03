// 앱이 소유한 PTY의 실행 명세, 직원 잠금, CLI 턴 기록을 관리한다.

import { randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import {
  closeSync,
  existsSync,
  openSync,
  readSync,
  readdirSync,
  statSync,
  watch,
} from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  AgentBusyError,
  AgentDrainingError,
  CharacterNotFoundError,
  executionEnvironment,
  locateExecutable,
} from "./agent-runtime.mjs";
import {
  nestedFields,
  parseAntigravityStepMetadata,
  protobufFields,
  utf8Field,
} from "./antigravity-local-state.mjs";
import {
  CodexTerminalTurnGate,
  codexRolloutUserPrompt,
  findCodexRolloutPath,
} from "./codex-rollout-turns.mjs";
import {
  generatedImageRoot,
  listGeneratedImages,
} from "./local-artifacts.mjs";
import {
  consumeStructuredTurnResult,
  discardStructuredTurnResult,
  prepareStructuredTurnResult,
} from "./structured-turn-result.mjs";

const require = createRequire(import.meta.url);
const SESSION_ID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const terminalHookPath = join(dirname(fileURLToPath(import.meta.url)),
  "officestra-terminal-hook");

function quotedConfig(value) {
  return JSON.stringify(String(value ?? ""));
}

function terminalHookSettings(character) {
  const hook = { hooks: [{ type: "command", command: "officestra-terminal-hook" }] };
  return JSON.stringify({
    fastMode: character.fastMode === true,
    hooks: {
      UserPromptSubmit: [hook],
      Stop: [hook],
    },
  });
}

function antigravityPermissionArguments(permission) {
  switch (permission) {
    case "plan":
      return ["--mode", "plan"];
    case "accept-edits":
      return [
        "--mode", "accept-edits", "--sandbox",
        "--dangerously-skip-permissions",
      ];
    case "dangerously-skip-permissions":
      return ["--mode", "accept-edits", "--dangerously-skip-permissions"];
    default:
      throw new Error(`지원하지 않는 Antigravity 권한입니다: ${permission}`);
  }
}

export function terminalArguments({
  character,
  previousSessionID = null,
  workdir,
  hookPath = terminalHookPath,
  nodePath = process.execPath,
}) {
  switch (character.backend) {
    case "claude": { // print 모드 플래그 없이 원래 대화형 CLI를 실행한다.
      if (character.fastMode && character.model !== "claude-opus-5") {
        throw new Error("Claude Code Fast 모드는 Opus 5에서만 사용할 수 있습니다.");
      }
      const args = [
        "--effort", character.effort,
        "--permission-mode", character.permission,
        "--settings", terminalHookSettings(character),
      ];
      if (character.model) args.push("--model", character.model);
      args.push("--append-system-prompt", String(character.identityPrompt ?? ""));
      if (previousSessionID) args.push("--resume", previousSessionID);
      return args;
    }
    case "codex": {
      const args = previousSessionID ? ["resume", previousSessionID] : [];
      if (character.model) args.push("-c", `model=${quotedConfig(character.model)}`);
      args.push(
        "-c", `model_reasoning_effort=${quotedConfig(character.effort)}`,
        "-c", "features.fast_mode=true",
        "-c", `service_tier=${quotedConfig(character.fastMode ? "fast" : "default")}`,
        "-c", 'model_reasoning_summary="detailed"',
        "-c", "show_raw_agent_reasoning=true",
        "-c", `developer_instructions=${quotedConfig(character.identityPrompt)}`,
        "-s", character.permission,
        "-c", `notify=${JSON.stringify([nodePath, hookPath])}`,
      );
      return args;
    }
    case "antigravity": {
      const args = [
        "--model", character.model,
        "--effort", character.effort,
      ];
      if (previousSessionID) args.push("--conversation", previousSessionID);
      if (workdir) args.push("--add-dir", workdir);
      args.push(...antigravityPermissionArguments(character.permission));
      return args;
    }
    default:
      throw new Error(`지원하지 않는 직원 백엔드입니다: ${character.backend}`);
  }
}

export function terminalEnvironment(character, {
  baseEnvironment = process.env,
  workdir,
  characterID,
  port = 4317,
} = {}) {
  const environment = {
    ...executionEnvironment(character, baseEnvironment, { workdir }),
    TERM: "xterm-256color",
    COLORTERM: "truecolor",
    LANG: baseEnvironment.LANG || "en_US.UTF-8",
    OFFICESTRA_TERMINAL_EVENTS_URL:
      `http://127.0.0.1:${port}/api/terminal-sessions/` +
      `${encodeURIComponent(characterID)}/events`,
    OFFICESTRA_TERMINAL_CHARACTER_ID: characterID,
  };
  environment.PATH = [
    dirname(terminalHookPath),
    dirname(process.execPath),
    ...String(environment.PATH ?? "").split(delimiter),
  ].filter(Boolean).filter((value, index, values) =>
    values.indexOf(value) === index
  ).join(delimiter);
  return Object.fromEntries(
    Object.entries(environment)
      .filter(([, value]) => value !== undefined && value !== null)
      .map(([key, value]) => [key, String(value)]),
  );
}

export function parseAntigravityTerminalStep(row) {
  try {
    if (Number(row?.status) !== 3) return null;
    const fields = protobufFields(row.step_payload);
    const stepType = Number(row.step_type);
    if (stepType === 14) {
      const text = utf8Field(nestedFields(fields, 19), 2);
      return text ? { kind: "user", text } : null;
    }
    if (stepType === 15) {
      const text = utf8Field(nestedFields(fields, 20), 1);
      return text
        ? {
          kind: "assistant",
          text,
          metadata: parseAntigravityStepMetadata(row.metadata),
        }
        : null;
    }
    return null;
  } catch {
    return null;
  }
}

function dateFromEpoch(value, fallback = new Date()) {
  const seconds = Number(value);
  return Number.isFinite(seconds) && seconds > 0
    ? new Date(seconds * 1_000)
    : fallback;
}

function resetTerminalArtifacts(state) {
  state.initialGeneratedImages = new Set(listGeneratedImages(
    state.externalSessionID,
    generatedImageRoot(state.backend),
  ));
  state.structuredResultPath = prepareStructuredTurnResult({
    workdir: state.workdir,
    characterID: state.characterID,
  });
}

function lastClaudeAssistantMessage(path) {
  if (!path || !existsSync(path)) return "";
  let descriptor;
  try {
    const size = statSync(path).size;
    const length = Math.min(size, 4 * 1024 * 1024);
    const buffer = Buffer.alloc(length);
    descriptor = openSync(path, "r");
    const count = readSync(descriptor, buffer, 0, length, size - length);
    const lines = buffer.subarray(0, count).toString("utf8").split("\n");
    if (size > length) lines.shift();
    for (let index = lines.length - 1; index >= 0; index -= 1) {
      let value;
      try {
        value = JSON.parse(lines[index]);
      } catch {
        continue;
      }
      if (value?.type !== "assistant") continue;
      const content = value?.message?.content ?? value?.content;
      const text = (Array.isArray(content) ? content : [])
        .filter((item) => item?.type === "text")
        .map((item) => String(item.text ?? "").trim())
        .filter(Boolean)
        .join("\n");
      if (text) return text;
    }
  } catch {
    return "";
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
  return "";
}

class AntigravityTerminalWatcher {
  constructor({
    state,
    runtime,
    root,
    pollIntervalMs = 1_000,
    debounceMs = 500,
  }) {
    this.state = state;
    this.runtime = runtime;
    this.root = root;
    this.conversationsRoot = join(root, "conversations");
    this.summaryPath = join(root, "conversation_summaries.db");
    this.path = state.externalSessionID
      ? join(this.conversationsRoot, `${state.externalSessionID}.db`)
      : null;
    this.lastIndex = this.path ? this.maximumIndex(this.path) : -1;
    this.pendingIndexes = new Set();
    this.baseline = new Map(this.databaseFiles().map((entry) => [entry.path, entry.mtimeMs]));
    this.watchers = [];
    this.timer = null;
    this.pollTimer = null;
    this.pollIntervalMs = pollIntervalMs;
    this.debounceMs = debounceMs;
    this.sweepPromise = Promise.resolve();
  }

  databaseFiles() {
    try {
      return readdirSync(this.conversationsRoot)
        .filter((name) => name.endsWith(".db"))
        .map((name) => {
          const path = join(this.conversationsRoot, name);
          return { path, mtimeMs: statSync(path).mtimeMs };
        });
    } catch {
      return [];
    }
  }

  maximumIndex(path) {
    let database;
    try {
      const { DatabaseSync } = require("node:sqlite");
      database = new DatabaseSync(path, { readOnly: true });
      return Number(database.prepare("SELECT COALESCE(max(idx), -1) AS idx FROM steps").get()?.idx ?? -1);
    } catch {
      return -1;
    } finally {
      try { database?.close(); } catch {}
    }
  }

  start() {
    const schedule = () => this.schedule();
    try { this.watchers.push(watch(this.conversationsRoot, schedule)); } catch {}
    try { this.watchers.push(watch(this.summaryPath, schedule)); } catch {}
    // SQLite가 WAL에만 기록하면 macOS의 fs.watch가 마지막 변경을 놓칠 수
    // 있다. 주기 확인은 debounce를 거치지 않아 지속적인 WAL 알림에도
    // 굶지 않고 반드시 실행된다.
    this.pollTimer = setInterval(
      () => this.enqueueSweep(),
      this.pollIntervalMs,
    );
    this.pollTimer.unref?.();
    this.enqueueSweep();
  }

  schedule() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = null;
      this.enqueueSweep();
    }, this.debounceMs);
  }

  enqueueSweep() {
    this.sweepPromise = this.sweepPromise
      .then(() => this.sweep())
      .catch((error) => console.warn(
        "Antigravity 터미널 기록 해독 실패:",
        error instanceof Error ? error.message : String(error),
      ));
    return this.sweepPromise;
  }

  async adoptConversationIfNeeded() {
    if (this.path) return true;
    const candidates = this.databaseFiles()
      .filter((entry) =>
        !this.baseline.has(entry.path) ||
        entry.mtimeMs > Math.max(this.baseline.get(entry.path) ?? 0, this.state.startedAt)
      )
      .sort((left, right) => right.mtimeMs - left.mtimeMs);
    const candidate = candidates[0];
    if (!candidate) return false;
    const id = basename(candidate.path, ".db");
    if (!SESSION_ID.test(id)) return false;
    await this.runtime.bindTerminalExternalSession({
      characterID: this.state.characterID,
      sessionID: this.state.sessionID,
      externalSessionID: id,
    });
    this.state.externalSessionID = id;
    this.path = candidate.path;
    this.lastIndex = -1;
    return true;
  }

  rows() {
    let database;
    try {
      const { DatabaseSync } = require("node:sqlite");
      database = new DatabaseSync(this.path, { readOnly: true });
      const rows = database.prepare(
        `
          SELECT idx, step_type, status, metadata, step_payload
          FROM steps
          WHERE idx > ?
          ORDER BY idx
        `,
      ).all(this.lastIndex);
      const pending = [...this.pendingIndexes];
      if (pending.length > 0) {
        const placeholders = pending.map(() => "?").join(", ");
        rows.push(...database.prepare(
          `
            SELECT idx, step_type, status, metadata, step_payload
            FROM steps
            WHERE idx IN (${placeholders})
          `,
        ).all(...pending));
      }
      return [...new Map(rows.map((row) => [Number(row.idx), row])).values()]
        .sort((left, right) => Number(left.idx) - Number(right.idx));
    } finally {
      try { database?.close(); } catch {}
    }
  }

  async sweep() {
    if (this.state.closed || !await this.adoptConversationIfNeeded()) return;
    for (const row of this.rows()) {
      const index = Number(row.idx);
      this.lastIndex = Math.max(this.lastIndex, index);
      // Antigravity는 한 idx의 행을 먼저 미완료 상태로 INSERT한 뒤 UPDATE한다.
      // 커서만 넘기면 완료된 같은 행을 다시 볼 수 없으므로 따로 재조회한다.
      if (Number(row.status) !== 3) {
        this.pendingIndexes.add(index);
        continue;
      }
      const event = parseAntigravityTerminalStep(row);
      if (!event) {
        this.pendingIndexes.delete(index);
        continue;
      }
      if (event.kind === "user") {
        if (this.state.runningTurnID) {
          this.pendingIndexes.add(index);
          continue;
        }
        this.pendingIndexes.add(index);
        const turn = await this.runtime.beginTerminalTurn({
          characterID: this.state.characterID,
          sessionID: this.state.sessionID,
          prompt: event.text,
          execution: this.state.character,
        });
        this.state.runningTurnID = turn.turnID;
        this.pendingIndexes.delete(index);
        continue;
      }
      if (!this.state.runningTurnID) {
        this.pendingIndexes.add(index);
        continue;
      }
      const turnID = this.state.runningTurnID;
      const usage = event.metadata?.usage
        ? {
          ...event.metadata.usage,
          cacheWriteInputTokens: null,
          cacheWrite5mInputTokens: null,
          cacheWrite1hInputTokens: null,
        }
        : null;
      const structured = consumeStructuredTurnResult(
        this.state.structuredResultPath,
      );
      this.state.structuredResultPath = null;
      // 완료 저장이 실패해도 턴을 running으로 두면 안 된다. 이미 읽은
      // 단계는 다시 오지 않으므로 세션이 그 턴에 영영 묶인다.
      this.pendingIndexes.add(index);
      try {
        await this.runtime.completeTerminalTurn({
          characterID: this.state.characterID,
          turnID,
          response: event.text,
          endedAt: event.metadata?.at
            ? new Date(event.metadata.at)
            : new Date(),
          usage,
          initialGeneratedImages: this.state.initialGeneratedImages,
          structured,
        });
        this.state.runningTurnID = null;
        this.pendingIndexes.delete(index);
        resetTerminalArtifacts(this.state);
      } catch (error) {
        await this.runtime.interruptTerminalTurn(
          this.state.characterID,
          turnID,
        );
        this.state.runningTurnID = null;
        this.pendingIndexes.delete(index);
        resetTerminalArtifacts(this.state);
        throw error;
      }
    }
  }

  async stop({ finalSweep = true } = {}) {
    clearTimeout(this.timer);
    clearInterval(this.pollTimer);
    this.pollTimer = null;
    for (const watcher of this.watchers) watcher.close();
    this.watchers = [];
    if (finalSweep) {
      await this.sweepPromise;
      await this.sweep();
    }
  }
}

// Codex 터미널은 notify가 완료 때만 와서 running 구간이 화면에 잡히지 않는다.
// GUI가 하듯 rollout을 파일 끝부터 증분으로 읽어, task_started 뒤 사용자
// 메시지가 붙는 순간 질문과 함께 running 턴을 먼저 만든다. 완료와 답변
// 추출은 검증된 notify 경로가 그대로 맡는다. 터미널이 열려 있는 동안 그
// 직원의 GUI 턴은 막히므로, 이때 붙는 턴은 모두 터미널 턴이다.
class CodexTerminalWatcher {
  constructor({ state, runtime, broadcast, sessionsRoot, intervalMs = 400 }) {
    this.state = state;
    this.runtime = runtime;
    this.broadcast = broadcast;
    this.sessionsRoot = sessionsRoot;
    this.intervalMs = intervalMs;
    this.path = null;
    this.offset = 0;
    this.remainder = "";
    this.pendingStarts = new Map();
    this.seen = new Set();
    this.timer = null;
    this.sweepPromise = Promise.resolve();
  }

  start() {
    this.timer = setInterval(() => this.schedule(), this.intervalMs);
    this.timer.unref?.();
  }

  schedule() {
    this.sweepPromise = this.sweepPromise
      .then(() => this.sweep())
      .catch((error) => console.warn(
        "Codex 터미널 기록을 읽지 못했습니다.",
        error instanceof Error ? error.message : String(error),
      ));
    return this.sweepPromise;
  }

  // notify 경로가 기록한 턴은 늦게 읽혀도 다시 만들지 않는다.
  markCompleted(turnID) {
    const id = String(turnID ?? "").trim();
    if (!id) return;
    this.pendingStarts.delete(id);
    this.seen.add(id);
  }

  // 세션이 묶이는 시점의 파일 끝에서 시작해 지난 기록을 되풀이하지 않는다.
  async adoptRolloutIfNeeded() {
    if (this.path) return true;
    if (!this.state.externalSessionID) return false;
    const path = await findCodexRolloutPath(this.state.externalSessionID, {
      sessionsRoot: this.sessionsRoot,
    });
    if (!path) return false;
    this.path = path;
    this.offset = statSync(path).size;
    this.remainder = "";
    return true;
  }

  readNewLines() {
    const size = statSync(this.path).size;
    if (size < this.offset) {
      this.offset = 0;
      this.remainder = "";
    }
    if (size === this.offset) return [];
    const length = size - this.offset;
    const buffer = Buffer.alloc(length);
    let descriptor;
    try {
      descriptor = openSync(this.path, "r");
      readSync(descriptor, buffer, 0, length, this.offset);
    } finally {
      if (descriptor !== undefined) closeSync(descriptor);
    }
    this.offset = size;
    const lines = (this.remainder + buffer.toString("utf8")).split("\n");
    this.remainder = lines.pop() ?? "";
    return lines;
  }

  async sweep() {
    if (this.state.closed || !await this.adoptRolloutIfNeeded()) return;
    for (const line of this.readNewLines()) {
      if (!line) continue;
      let record;
      try {
        record = JSON.parse(line);
      } catch {
        continue;
      }
      const payload = record?.payload ?? {};
      if (record?.type === "event_msg" && payload.type === "task_started") {
        const turnID = String(payload.turn_id ?? "").trim();
        if (turnID && !this.seen.has(turnID)) {
          this.pendingStarts.set(turnID, payload.started_at);
        }
        continue;
      }
      if (record?.type === "event_msg" && payload.type === "task_complete") {
        // 질문을 보기 전에 끝난 턴은 notify 경로가 처음부터 기록한다.
        this.pendingStarts.delete(String(payload.turn_id ?? "").trim());
        continue;
      }
      if (record?.type === "event_msg" && payload.type === "turn_aborted") {
        const abortedTurnID = String(payload.turn_id ?? "").trim();
        this.pendingStarts.delete(abortedTurnID);
        this.seen.add(abortedTurnID);
        if (
          abortedTurnID &&
          this.state.codexTurnID === abortedTurnID &&
          this.state.runningTurnID
        ) {
          const runningTurnID = this.state.runningTurnID;
          await this.runtime.interruptTerminalTurn(
            this.state.characterID,
            runningTurnID,
          );
          this.state.runningTurnID = null;
          this.state.codexTurnID = null;
          resetTerminalArtifacts(this.state);
          this.broadcast({
            type: "terminal.changed",
            characterId: this.state.characterID,
          });
        }
        continue;
      }
      const prompt = codexRolloutUserPrompt(record);
      if (!prompt || !this.pendingStarts.has(prompt.turnID)) continue;
      const startedAt = this.pendingStarts.get(prompt.turnID);
      this.pendingStarts.delete(prompt.turnID);
      this.seen.add(prompt.turnID);
      if (this.state.runningTurnID) continue;
      // 한 턴을 못 만들어도 같은 묶음의 뒷줄은 계속 읽는다. 이미 읽은
      // 바이트는 다시 오지 않는다.
      try {
        const turn = await this.runtime.beginTerminalTurn({
          characterID: this.state.characterID,
          sessionID: this.state.sessionID,
          prompt: prompt.text,
          startedAt: dateFromEpoch(startedAt),
          execution: this.state.character,
        });
        this.state.runningTurnID = turn.turnID;
        this.state.codexTurnID = prompt.turnID;
        this.broadcast({
          type: "terminal.changed",
          characterId: this.state.characterID,
        });
      } catch (error) {
        console.warn(
          `Codex 터미널 running 턴을 만들지 못했습니다(${this.state.characterID}):`,
          error instanceof Error ? error.message : String(error),
        );
      }
    }
  }

  // 완료는 notify가 맡으므로 마지막 sweep은 하지 않는다. 닫히는 중에 턴을
  // 새로 만들었다가 곧바로 중단하는 낭비를 피한다.
  async stop() {
    clearInterval(this.timer);
    this.timer = null;
    await this.sweepPromise;
  }
}

export class TerminalSessionManager {
  constructor({
    runtime,
    broadcast,
    port = 4317,
    antigravityRoot = join(homedir(), ".gemini", "antigravity-cli"),
    codexSessionsRoot = join(homedir(), ".codex", "sessions"),
    baseEnvironment = process.env,
    antigravityPollIntervalMs = 1_000,
    antigravityDebounceMs = 500,
  }) {
    this.runtime = runtime;
    this.broadcast = broadcast;
    this.port = port;
    this.antigravityRoot = antigravityRoot;
    this.codexSessionsRoot = codexSessionsRoot;
    this.baseEnvironment = baseEnvironment;
    this.antigravityPollIntervalMs = antigravityPollIntervalMs;
    this.antigravityDebounceMs = antigravityDebounceMs;
    this.sessions = new Map();
    this.opening = new Set();
  }

  get size() { return this.sessions.size + this.opening.size; }
  has(characterID) {
    const id = String(characterID ?? "");
    return this.sessions.has(id) || this.opening.has(id);
  }

  list() {
    return [...this.sessions.values()].map((state) => ({
      terminalSessionId: state.terminalSessionID,
      characterId: state.characterID,
      backend: state.backend,
      externalSessionId: state.externalSessionID,
      conversationId: state.conversationID,
      runningTurnId: state.runningTurnID,
      startedAt: new Date(state.startedAt).toISOString(),
    }));
  }

  async open(characterID) {
    const id = String(characterID ?? "").trim();
    if (!id) throw new CharacterNotFoundError("캐릭터를 찾을 수 없습니다.");
    if (this.has(id)) throw new AgentBusyError("터미널 모드에서 사용 중입니다.");
    this.opening.add(id);
    let state = null;
    try {
      const launch = await this.runtime.prepareTerminalLaunch(id);
      const character = launch.character;
      const terminalSessionID = randomUUID();
      state = {
        terminalSessionID,
        characterID: id,
        character,
        backend: character.backend,
        sessionID: launch.sessionID,
        conversationID: launch.conversationID,
        externalSessionID: launch.externalSessionID,
        workdir: launch.workdir,
        startedAt: Date.now(),
        runningTurnID: null,
        initialGeneratedImages: new Set(listGeneratedImages(
          launch.externalSessionID,
          generatedImageRoot(character.backend),
        )),
        closed: false,
        watcher: null,
        codexTurnID: null,
        codexGate: character.backend === "codex"
          ? new CodexTerminalTurnGate({
            cwd: launch.workdir,
            externalSessionID: launch.externalSessionID,
            sessionsRoot: this.codexSessionsRoot,
          })
          : null,
        structuredResultPath: prepareStructuredTurnResult({
          workdir: launch.workdir,
          characterID: id,
        }),
      };
      this.sessions.set(id, state);
      if (character.backend === "antigravity") {
        state.watcher = new AntigravityTerminalWatcher({
          state,
          runtime: this.runtime,
          root: this.antigravityRoot,
          pollIntervalMs: this.antigravityPollIntervalMs,
          debounceMs: this.antigravityDebounceMs,
        });
        state.watcher.start();
      } else if (character.backend === "codex") {
        state.watcher = new CodexTerminalWatcher({
          state,
          runtime: this.runtime,
          broadcast: (event) => this.broadcast(event),
          sessionsRoot: this.codexSessionsRoot,
        });
        state.watcher.start();
      }
      const env = terminalEnvironment(character, {
        baseEnvironment: this.baseEnvironment,
        workdir: launch.workdir,
        characterID: id,
        port: this.port,
      });
      const spec = {
        terminalSessionId: terminalSessionID,
        executable: locateExecutable(character),
        args: terminalArguments({
          character,
          previousSessionID: launch.externalSessionID,
          workdir: launch.workdir,
        }),
        cwd: launch.workdir,
        env,
        externalSessionId: launch.externalSessionID,
        conversationId: launch.conversationID,
        backend: character.backend,
      };
      this.broadcast({ type: "terminal.changed", characterId: id });
      return spec;
    } catch (error) {
      if (state) {
        state.closed = true;
        try { await state.watcher?.stop({ finalSweep: false }); } catch {}
        discardStructuredTurnResult(state.structuredResultPath);
      }
      this.sessions.delete(id);
      if (error instanceof AgentDrainingError) throw error;
      throw error;
    } finally {
      this.opening.delete(id);
    }
  }

  async bindIfNeeded(state, externalSessionID) {
    const id = String(externalSessionID ?? "").trim();
    if (!id || state.externalSessionID === id) return;
    await this.runtime.bindTerminalExternalSession({
      characterID: state.characterID,
      sessionID: state.sessionID,
      externalSessionID: id,
    });
    state.externalSessionID = id;
  }

  resetTurnArtifacts(state) {
    resetTerminalArtifacts(state);
  }

  async handleEvent(characterID, body) {
    const state = this.sessions.get(String(characterID ?? ""));
    if (!state || state.closed) {
      throw new Error("열린 터미널 세션을 찾을 수 없습니다.");
    }
    const source = String(body?.source ?? "");
    if (source === "claude" && state.backend === "claude") {
      return await this.handleClaudeEvent(state, body.payload ?? {});
    }
    if (source === "codex" && state.backend === "codex") {
      return await this.handleCodexEvent(state, body.payload ?? {});
    }
    throw new Error("터미널 CLI와 이벤트 종류가 일치하지 않습니다.");
  }

  async handleClaudeEvent(state, payload) {
    const event = String(payload.hook_event_name ?? "");
    await this.bindIfNeeded(state, payload.session_id);
    if (event === "UserPromptSubmit") {
      if (state.runningTurnID) return { accepted: false, reason: "turn-running" };
      const turn = await this.runtime.beginTerminalTurn({
        characterID: state.characterID,
        sessionID: state.sessionID,
        prompt: payload.prompt,
        execution: state.character,
      });
      state.runningTurnID = turn.turnID;
      this.broadcast({ type: "terminal.changed", characterId: state.characterID });
      return { accepted: true, turnId: turn.turnID };
    }
    if (event !== "Stop" || !state.runningTurnID) {
      return { accepted: false, reason: "ignored-hook" };
    }
    const turnID = state.runningTurnID;
    const response = String(payload.last_assistant_message ?? "").trim() ||
      lastClaudeAssistantMessage(payload.transcript_path);
    const structured = consumeStructuredTurnResult(
      state.structuredResultPath,
    );
    state.structuredResultPath = null;
    // 완료 저장이 실패해도 턴을 running으로 두면 안 된다. 세션이 그 턴에
    // 묶여 다음 질문까지 전부 turn-running으로 거절된다.
    try {
      await this.runtime.completeTerminalTurn({
        characterID: state.characterID,
        turnID,
        response,
        structured,
        initialGeneratedImages: state.initialGeneratedImages,
      });
      state.runningTurnID = null;
      this.resetTurnArtifacts(state);
    } catch (error) {
      await this.runtime.interruptTerminalTurn(state.characterID, turnID);
      state.runningTurnID = null;
      throw error;
    } finally {
      this.broadcast({
        type: "terminal.changed",
        characterId: state.characterID,
      });
    }
    return { accepted: true, turnId: turnID };
  }

  async handleCodexEvent(state, payload) {
    const result = await state.codexGate.accept(payload);
    if (!result.accepted) {
      console.info(
        `Codex 터미널 notify 폐기(${state.characterID}): ${result.reason}`,
      );
      return result;
    }
    if (result.boundExternalSessionID) {
      await this.bindIfNeeded(state, result.boundExternalSessionID);
    }
    const turn = result.turn;
    state.watcher?.markCompleted(turn.turnID);
    // 워처가 이미 이 턴을 running으로 만들었으면 그 턴을 완료한다. 다른 턴이
    // running으로 남아 있으면(그 notify가 버려진 경우) 세션이 묶이지 않게
    // 먼저 중단하고 이 notify 기준으로 처음부터 기록한다.
    let turnID;
    if (state.runningTurnID && state.codexTurnID === turn.turnID) {
      turnID = state.runningTurnID;
    } else {
      if (state.runningTurnID) {
        await this.runtime.interruptTerminalTurn(
          state.characterID,
          state.runningTurnID,
        );
        state.runningTurnID = null;
      }
      const started = await this.runtime.beginTerminalTurn({
        characterID: state.characterID,
        sessionID: state.sessionID,
        prompt: turn.prompt,
        startedAt: dateFromEpoch(turn.startedAt),
        execution: state.character,
      });
      turnID = started.turnID;
      state.runningTurnID = turnID;
    }
    state.codexTurnID = null;
    try {
      const structured = consumeStructuredTurnResult(
        state.structuredResultPath,
      );
      state.structuredResultPath = null;
      await this.runtime.completeTerminalTurn({
        characterID: state.characterID,
        turnID,
        response: turn.response,
        structured,
        endedAt: dateFromEpoch(turn.completedAt),
        initialGeneratedImages: state.initialGeneratedImages,
      });
      state.runningTurnID = null;
      this.resetTurnArtifacts(state);
    } catch (error) {
      await this.runtime.interruptTerminalTurn(state.characterID, turnID);
      state.runningTurnID = null;
      throw error;
    } finally {
      this.broadcast({ type: "terminal.changed", characterId: state.characterID });
    }
    return { accepted: true, turnId: turnID };
  }

  async close(characterID) {
    const id = String(characterID ?? "");
    const state = this.sessions.get(id);
    if (!state) return false;
    if (state.watcher) await state.watcher.stop({ finalSweep: true });
    state.closed = true;
    discardStructuredTurnResult(state.structuredResultPath);
    if (state.runningTurnID) {
      await this.runtime.interruptTerminalTurn(id, state.runningTurnID);
      state.runningTurnID = null;
    }
    this.sessions.delete(id);
    this.broadcast({ type: "terminal.changed", characterId: id });
    return true;
  }

  async shutdown() {
    for (const id of [...this.sessions.keys()]) await this.close(id);
  }
}
