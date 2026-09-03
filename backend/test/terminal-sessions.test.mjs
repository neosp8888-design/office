import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

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

test("turn origin migration은 gui 기본값과 terminal 제약을 둔다", () => {
  const sql = readFileSync(new URL("../../database/migrations/034_turn_origin.sql", import.meta.url), "utf8");
  assert.match(sql, /origin text NOT NULL DEFAULT 'gui'/);
  assert.match(sql, /origin IN \('gui', 'terminal'\)/);
  assert.match(sql, /turns_origin_check/);
});

function fakeRuntime() {
  return {
    begun: [],
    completed: [],
    bound: [],
    registry: null,
    async prepareTerminalLaunch(characterID) {
      return {
        character: { ...baseCharacter, id: characterID, backend: "claude" },
        sessionID: "db-session",
        conversationID: "conversation",
        externalSessionID: null,
        workdir: "/tmp/office",
      };
    },
    async bindTerminalExternalSession(entry) { this.bound.push(entry); },
    async beginTerminalTurn(entry) {
      const turn = { ...entry, turnID: `turn-${this.begun.length + 1}` };
      this.begun.push(turn);
      return turn;
    },
    async completeTerminalTurn(entry) { this.completed.push(entry); },
    async interruptTerminalTurn() { return true; },
  };
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
