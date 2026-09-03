import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { appendFile, mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { setTimeout as delay } from "node:timers/promises";

import {
  AgentBusyError,
  AgentRuntime,
} from "../src/agent-runtime.mjs";
import {
  TerminalSessionManager,
  parseAntigravityTerminalStep,
  terminalArguments,
} from "../src/terminal-sessions.mjs";

const baseCharacter = {
  id: "boss",
  model: "model-a",
  effort: "high",
  fastMode: false,
  permission: "danger-full-access",
  identityPrompt: "업무 지침",
  config: {},
};

test("세 CLI의 대화형 인자는 resume 유무와 권한을 보존한다", () => {
  for (const permission of ["read-only", "workspace-write", "danger-full-access"]) {
    const character = { ...baseCharacter, backend: "codex", permission };
    const fresh = terminalArguments({ character, workdir: "/tmp/office", hookPath: "/tmp/hook", nodePath: "/usr/bin/node" });
    const resumed = terminalArguments({ character, previousSessionID: "session", workdir: "/tmp/office", hookPath: "/tmp/hook", nodePath: "/usr/bin/node" });
    assert.equal(fresh.includes("resume"), false);
    assert.deepEqual(resumed.slice(0, 2), ["resume", "session"]);
    assert.equal(fresh[fresh.indexOf("-s") + 1], permission);
    assert.ok(fresh.some((value) => value.includes('notify=["/usr/bin/node","/tmp/hook"]')));
  }

  for (const permission of ["plan", "accept-edits", "dangerously-skip-permissions"]) {
    const character = { ...baseCharacter, backend: "antigravity", permission };
    const fresh = terminalArguments({ character, workdir: "/tmp/office" });
    const resumed = terminalArguments({ character, previousSessionID: "session", workdir: "/tmp/office" });
    assert.equal(fresh.includes("--conversation"), false);
    assert.equal(resumed[resumed.indexOf("--conversation") + 1], "session");
    assert.equal(fresh[fresh.indexOf("--add-dir") + 1], "/tmp/office");
  }

  for (const permission of ["plan", "acceptEdits", "bypassPermissions"]) {
    const character = { ...baseCharacter, backend: "claude", permission };
    const fresh = terminalArguments({ character, workdir: "/tmp/office" });
    const resumed = terminalArguments({ character, previousSessionID: "session", workdir: "/tmp/office" });
    assert.equal(fresh.includes("--resume"), false);
    assert.equal(resumed[resumed.indexOf("--resume") + 1], "session");
    assert.equal(fresh[fresh.indexOf("--permission-mode") + 1], permission);
    const settings = JSON.parse(fresh[fresh.indexOf("--settings") + 1]);
    assert.ok(settings.hooks.UserPromptSubmit);
    assert.ok(settings.hooks.Stop);
  }
});

test("열린 터미널은 같은 직원의 두 번째 터미널과 GUI 업무를 막는다", async () => {
  const events = [];
  const runtime = fakeRuntime();
  const manager = new TerminalSessionManager({
    runtime,
    broadcast: (event) => events.push(event),
    baseEnvironment: { PATH: "/usr/bin", LANG: "ko_KR.UTF-8" },
  });
  runtime.registry = manager;
  await manager.open("boss");
  await assert.rejects(() => manager.open("boss"), AgentBusyError);

  const agentRuntime = new AgentRuntime({
    pool: {},
    withTransaction: async () => {},
    workdir: "/tmp/office",
    broadcast() {},
  });
  agentRuntime.setTerminalSessionRegistry(manager);
  await assert.rejects(
    () => agentRuntime.start({ characterID: "boss", prompt: "GUI 업무" }),
    (error) => error instanceof AgentBusyError && error.message === "터미널 모드에서 사용 중입니다.",
  );
  assert.equal(manager.list()[0].characterId, "boss");
  assert.equal(events.at(-1).type, "terminal.changed");
  await manager.close("boss");
});

test("Claude UserPromptSubmit과 Stop 훅이 같은 터미널 턴을 생성·완료한다", async () => {
  const runtime = fakeRuntime();
  const manager = new TerminalSessionManager({ runtime, broadcast() {} });
  await manager.open("boss");
  const started = await manager.handleEvent("boss", {
    source: "claude",
    payload: {
      hook_event_name: "UserPromptSubmit",
      session_id: "claude-session",
      prompt: "터미널 질문",
    },
  });
  assert.equal(started.accepted, true);
  const completed = await manager.handleEvent("boss", {
    source: "claude",
    payload: {
      hook_event_name: "Stop",
      session_id: "claude-session",
      last_assistant_message: "터미널 답변",
    },
  });
  assert.equal(completed.turnId, started.turnId);
  assert.deepEqual(runtime.begun.map((turn) => turn.prompt), ["터미널 질문"]);
  assert.deepEqual(runtime.completed.map((turn) => turn.response), ["터미널 답변"]);
  assert.deepEqual(runtime.bound.map((entry) => entry.externalSessionID), ["claude-session"]);
  await manager.close("boss");
});

// 완료 저장이 실패했을 때 턴을 running으로 남기면 세션이 그 턴에 묶여
// 이후 질문이 전부 turn-running으로 거절된다.
test("Claude Stop 훅의 완료 저장이 실패하면 턴을 중단 처리하고 세션을 푼다", async () => {
  const runtime = fakeRuntime();
  const interrupted = [];
  runtime.completeTerminalTurn = async () => {
    throw new Error("터미널 최종 메시지가 없습니다.");
  };
  runtime.interruptTerminalTurn = async (characterID, turnID) => {
    interrupted.push({ characterID, turnID });
    return true;
  };
  const manager = new TerminalSessionManager({ runtime, broadcast() {} });
  await manager.open("boss");
  const started = await manager.handleEvent("boss", {
    source: "claude",
    payload: {
      hook_event_name: "UserPromptSubmit",
      session_id: "claude-session",
      prompt: "첫 질문",
    },
  });

  await assert.rejects(() =>
    manager.handleEvent("boss", {
      source: "claude",
      payload: {
        hook_event_name: "Stop",
        session_id: "claude-session",
        last_assistant_message: "답변",
      },
    })
  );

  assert.deepEqual(interrupted, [{
    characterID: "boss",
    turnID: started.turnId,
  }]);
  // 다음 질문이 turn-running으로 막히지 않아야 한다.
  const next = await manager.handleEvent("boss", {
    source: "claude",
    payload: {
      hook_event_name: "UserPromptSubmit",
      session_id: "claude-session",
      prompt: "다음 질문",
    },
  });
  assert.equal(next.accepted, true);
  assert.notEqual(next.turnId, started.turnId);
  await manager.close("boss");
});

test("Antigravity step 14/15 payload를 사용자·최종 응답으로 해독한다", () => {
  const user = parseAntigravityTerminalStep({
    step_type: 14,
    status: 3,
    step_payload: message(numberField(1, 14), bytesField(19, message(bytesField(2, Buffer.from("질문"))))),
  });
  const assistant = parseAntigravityTerminalStep({
    step_type: 15,
    status: 3,
    step_payload: message(numberField(1, 15), bytesField(20, message(bytesField(1, Buffer.from("답변"))))),
  });
  assert.deepEqual(user, { kind: "user", text: "질문" });
  assert.equal(assistant.kind, "assistant");
  assert.equal(assistant.text, "답변");
});

test("Antigravity 파일 알림을 놓쳐도 주기 확인으로 턴을 완료한다", async () => {
  const root = await mkdtemp(join(tmpdir(), "officestra-antigravity-terminal-"));
  const conversations = join(root, "conversations");
  const externalSessionID = "01a0c0de-3333-7000-8000-000000000003";
  const databasePath = join(conversations, `${externalSessionID}.db`);
  await mkdir(conversations, { recursive: true });
  const database = new DatabaseSync(databasePath);
  database.exec(`
    CREATE TABLE steps (
      idx INTEGER PRIMARY KEY,
      step_type INTEGER NOT NULL,
      status INTEGER NOT NULL,
      metadata BLOB,
      step_payload BLOB NOT NULL
    )
  `);
  const runtime = fakeRuntime({
    backend: "antigravity",
    externalSessionID,
    permission: "dangerously-skip-permissions",
  });
  const manager = new TerminalSessionManager({
    runtime,
    broadcast() {},
    antigravityRoot: root,
    antigravityPollIntervalMs: 10,
    antigravityDebounceMs: 50,
  });
  let notificationStorm = null;

  try {
    await manager.open("boss");
    const state = manager.sessions.get("boss");
    // 최초 sweep을 끝낸 뒤 파일 감시를 끊어 fs.watch 알림 누락을 재현한다.
    await delay(20);
    for (const watcher of state.watcher.watchers) watcher.close();
    state.watcher.watchers = [];
    // 실제 WAL/SHM처럼 debounce보다 잦은 알림이 와도 주기 확인은 굶으면
    // 안 된다. 기존 구현은 이 알림이 poll 타이머까지 계속 미뤘다.
    notificationStorm = setInterval(() => state.watcher.schedule(), 2);

    database.prepare(
      "INSERT INTO steps(idx, step_type, status, metadata, step_payload) VALUES (?, ?, ?, ?, ?)",
    ).run(
      1,
      14,
      3,
      null,
      message(
        numberField(1, 14),
        bytesField(19, message(bytesField(2, Buffer.from("질문")))),
      ),
    );
    await waitUntil(() => runtime.begun.length === 1);
    assert.equal(state.runningTurnID, "turn-1");

    const assistantPayload = message(
      numberField(1, 15),
      bytesField(20, message(bytesField(1, Buffer.from("답변")))),
    );
    database.prepare(
      "INSERT INTO steps(idx, step_type, status, metadata, step_payload) VALUES (?, ?, ?, ?, ?)",
    ).run(
      2,
      15,
      1,
      null,
      assistantPayload,
    );
    // 미완료 행을 한 번 읽어 커서가 지나간 뒤 같은 idx가 완료되는 실제
    // Antigravity 기록 순서를 재현한다.
    await waitUntil(() => state.watcher.lastIndex === 2);
    assert.equal(runtime.completed.length, 0);
    database.prepare(
      "UPDATE steps SET status = 3, step_payload = ? WHERE idx = 2",
    ).run(assistantPayload);
    await waitUntil(() => runtime.completed.length === 1);
    assert.equal(runtime.completed[0].response, "답변");
    assert.equal(state.runningTurnID, null);
  } finally {
    clearInterval(notificationStorm);
    database.close();
    await manager.close("boss");
  }
});

test("turn origin migration은 gui 기본값과 terminal 제약을 둔다", () => {
  const sql = readFileSync(new URL("../../database/migrations/034_turn_origin.sql", import.meta.url), "utf8");
  assert.match(sql, /origin text NOT NULL DEFAULT 'gui'/);
  assert.match(sql, /origin IN \('gui', 'terminal'\)/);
  assert.match(sql, /turns_origin_check/);
});

const codexThreadID = "01a0c0de-1111-7000-8000-000000000001";
const codexTurnID = "01a0c0de-2222-7000-8000-000000000002";

function rolloutLine(record) {
  return JSON.stringify(record) + "\n";
}

async function codexFixture() {
  const root = await mkdtemp(join(tmpdir(), "officestra-codex-terminal-"));
  const sessionsRoot = join(root, "sessions");
  const workdir = join(root, "workdir");
  const day = join(sessionsRoot, "2026", "09", "03");
  await mkdir(day, { recursive: true });
  await mkdir(workdir, { recursive: true });
  const rollout = join(
    day,
    `rollout-2026-09-03T00-00-00-${codexThreadID}.jsonl`,
  );
  // 열기 전에 이미 끝난 지난 턴. 워처가 되풀이하면 안 된다.
  await writeFile(rollout, [
    { type: "session_meta", payload: { id: codexThreadID, source: "cli", cwd: workdir } },
    { type: "event_msg", payload: { type: "task_started", turn_id: "old-turn", started_at: 1 } },
    { type: "event_msg", payload: { type: "item_completed", turn_id: "old-turn", item: { type: "UserMessage", content: [{ type: "text", text: "지난 질문" }] } } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: "old-turn", last_agent_message: "지난 답변", started_at: 1, completed_at: 2 } },
  ].map(rolloutLine).join(""));
  return { sessionsRoot, workdir, rollout };
}

function codexNotify(workdir, message) {
  return {
    source: "codex",
    payload: {
      type: "agent-turn-complete",
      "thread-id": codexThreadID,
      "turn-id": codexTurnID,
      cwd: workdir,
      "last-assistant-message": message,
    },
  };
}

// codex notify는 완료 때만 오므로, rollout에서 시작을 읽어 running을 먼저
// 보여야 하단 바의 "일하는중" 표시가 켜진다.
test("Codex 터미널은 rollout의 시작과 질문을 보면 running 턴을 먼저 만들고 notify가 그 턴을 완료한다", async () => {
  const { sessionsRoot, workdir, rollout } = await codexFixture();
  const events = [];
  const runtime = fakeRuntime({
    backend: "codex",
    externalSessionID: codexThreadID,
    workdir,
    executablePath: "/usr/bin/true",
  });
  const manager = new TerminalSessionManager({
    runtime,
    broadcast: (event) => events.push(event),
    codexSessionsRoot: sessionsRoot,
  });
  await manager.open("boss");
  const state = manager.sessions.get("boss");
  // 열기 전 기록은 되풀이하지 않는다.
  await state.watcher.sweep();
  assert.equal(runtime.begun.length, 0);

  await appendFile(rollout, [
    { type: "event_msg", payload: { type: "task_started", turn_id: codexTurnID, started_at: 1_788_347_510 } },
    { type: "event_msg", payload: { type: "item_completed", turn_id: codexTurnID, item: { type: "UserMessage", content: [{ type: "text", text: "터미널 질문" }] } } },
  ].map(rolloutLine).join(""));
  events.length = 0;
  await state.watcher.sweep();
  assert.equal(runtime.begun.length, 1);
  assert.equal(runtime.begun[0].prompt, "터미널 질문");
  assert.equal(state.runningTurnID, "turn-1");
  assert.ok(events.some((event) => event.type === "terminal.changed"));
  // 같은 줄을 다시 읽어도 두 번 만들지 않는다.
  await state.watcher.sweep();
  assert.equal(runtime.begun.length, 1);

  await appendFile(rollout, [
    { type: "turn_context", payload: { turn_id: codexTurnID, cwd: workdir } },
    { type: "event_msg", payload: { type: "item_completed", turn_id: codexTurnID, item: { type: "AgentMessage", phase: "final_answer", content: [{ type: "Text", text: "터미널 답변" }] } } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: codexTurnID, last_agent_message: "터미널 답변", started_at: 1_788_347_510, completed_at: 1_788_347_513 } },
  ].map(rolloutLine).join(""));
  const completed = await manager.handleEvent(
    "boss",
    codexNotify(workdir, "터미널 답변"),
  );
  assert.equal(completed.accepted, true);
  assert.equal(completed.turnId, "turn-1");
  assert.equal(runtime.begun.length, 1);
  assert.deepEqual(
    runtime.completed.map((entry) => [entry.turnID, entry.response]),
    [["turn-1", "터미널 답변"]],
  );
  assert.equal(state.runningTurnID, null);
  await manager.close("boss");
});

test("Codex notify가 워처보다 먼저 오면 기존 경로로 기록하고 늦은 sweep이 같은 턴을 다시 만들지 않는다", async () => {
  const { sessionsRoot, workdir, rollout } = await codexFixture();
  const runtime = fakeRuntime({
    backend: "codex",
    externalSessionID: codexThreadID,
    workdir,
    executablePath: "/usr/bin/true",
  });
  const manager = new TerminalSessionManager({
    runtime,
    broadcast() {},
    codexSessionsRoot: sessionsRoot,
  });
  await manager.open("boss");
  const state = manager.sessions.get("boss");
  await state.watcher.sweep();

  await appendFile(rollout, [
    { type: "event_msg", payload: { type: "task_started", turn_id: codexTurnID, started_at: 1_788_347_510 } },
    { type: "turn_context", payload: { turn_id: codexTurnID, cwd: workdir } },
    { type: "event_msg", payload: { type: "item_completed", turn_id: codexTurnID, item: { type: "UserMessage", content: [{ type: "text", text: "빠른 질문" }] } } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: codexTurnID, last_agent_message: "빠른 답변", started_at: 1_788_347_510, completed_at: 1_788_347_511 } },
  ].map(rolloutLine).join(""));
  const completed = await manager.handleEvent(
    "boss",
    codexNotify(workdir, "빠른 답변"),
  );
  assert.equal(completed.accepted, true);
  assert.equal(runtime.begun.length, 1);
  assert.equal(runtime.completed.length, 1);
  assert.equal(state.runningTurnID, null);

  await state.watcher.sweep();
  assert.equal(runtime.begun.length, 1);
  await manager.close("boss");
});

test("Codex turn_aborted를 보면 rollout 워처가 running 턴을 중단한다", async () => {
  const { sessionsRoot, workdir, rollout } = await codexFixture();
  const events = [];
  const runtime = fakeRuntime({
    backend: "codex",
    externalSessionID: codexThreadID,
    workdir,
    executablePath: "/usr/bin/true",
  });
  const manager = new TerminalSessionManager({
    runtime,
    broadcast: (event) => events.push(event),
    codexSessionsRoot: sessionsRoot,
  });
  await manager.open("boss");
  const state = manager.sessions.get("boss");
  await state.watcher.sweep();

  await appendFile(rollout, [
    { type: "event_msg", payload: { type: "task_started", turn_id: codexTurnID, started_at: 1_788_347_510 } },
    { type: "event_msg", payload: { type: "item_completed", turn_id: codexTurnID, item: { type: "UserMessage", content: [{ type: "text", text: "중단할 질문" }] } } },
  ].map(rolloutLine).join(""));
  await state.watcher.sweep();
  assert.equal(state.runningTurnID, "turn-1");

  events.length = 0;
  await appendFile(rollout, rolloutLine({
    type: "event_msg",
    payload: {
      type: "turn_aborted",
      turn_id: codexTurnID,
      started_at: 1_788_347_510,
      completed_at: 1_788_347_511,
    },
  }));
  await state.watcher.sweep();

  assert.deepEqual(runtime.interrupted, [{
    characterID: "boss",
    turnID: "turn-1",
  }]);
  assert.equal(state.runningTurnID, null);
  assert.equal(state.codexTurnID, null);
  assert.ok(events.some((event) => event.type === "terminal.changed"));
  await manager.close("boss");
});

function fakeRuntime({
  backend = "claude",
  externalSessionID = null,
  workdir = "/tmp/office",
  executablePath = null,
  permission = baseCharacter.permission,
} = {}) {
  return {
    begun: [],
    completed: [],
    interrupted: [],
    bound: [],
    registry: null,
    async prepareTerminalLaunch(characterID) {
      return {
        character: {
          ...baseCharacter,
          id: characterID,
          backend,
          permission,
          ...(executablePath ? { executablePath } : {}),
        },
        sessionID: "db-session",
        conversationID: "conversation",
        externalSessionID,
        workdir,
      };
    },
    async bindTerminalExternalSession(entry) { this.bound.push(entry); },
    async beginTerminalTurn(entry) {
      const turn = { ...entry, turnID: `turn-${this.begun.length + 1}` };
      this.begun.push(turn);
      return turn;
    },
    async completeTerminalTurn(entry) { this.completed.push(entry); },
    async interruptTerminalTurn(characterID, turnID) {
      this.interrupted.push({ characterID, turnID });
      return true;
    },
  };
}

async function waitUntil(predicate, timeoutMs = 1_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await delay(10);
  }
  assert.fail("조건이 제한 시간 안에 충족되지 않았습니다.");
}

function encodeVarint(input) {
  let value = BigInt(input);
  const bytes = [];
  do {
    let byte = Number(value & 0x7fn);
    value >>= 7n;
    if (value > 0n) byte |= 0x80;
    bytes.push(byte);
  } while (value > 0n);
  return Buffer.from(bytes);
}

function numberField(number, value) {
  return Buffer.concat([encodeVarint(number << 3), encodeVarint(value)]);
}

function bytesField(number, value) {
  const bytes = Buffer.from(value);
  return Buffer.concat([encodeVarint((number << 3) | 2), encodeVarint(bytes.length), bytes]);
}

function message(...fields) { return Buffer.concat(fields); }
