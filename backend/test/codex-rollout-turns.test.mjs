import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  CodexTerminalTurnGate,
  findCodexRolloutPath,
  readCodexRolloutTurn,
} from "../src/codex-rollout-turns.mjs";

const threadID = "01a043c6-c6f2-7882-b4d7-a3e118bd103f";
const turnID = "01a061d3-17cc-7023-8623-42e1572aeac4";
const titleThreadID = "01a061d3-1b81-7a93-aaa9-af4aa826e297";
const titleTurnID = "01a061d3-1c3c-74c1-8842-4744d9e37945";
const cwd = "/tmp/officestra-terminal-codex";

function rolloutLines({ source = "exec", actualCwd = cwd } = {}) {
  return [
    { type: "session_meta", payload: { id: threadID, source, cwd: "/old" } },
    { type: "turn_context", payload: { turn_id: turnID, cwd: actualCwd } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turnID, started_at: 1_788_347_510 } },
    { type: "event_msg", payload: { type: "item_completed", turn_id: turnID, item: { type: "UserMessage", content: [{ type: "text", text: "정식 질문" }, { type: "local_image", path: "/tmp/a.png" }] } } },
    { type: "event_msg", payload: { type: "item_completed", turn_id: turnID, item: { type: "AgentMessage", phase: "final_answer", content: [{ type: "Text", text: "정식 답변" }] } } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turnID, last_agent_message: "정식 답변", started_at: 1_788_347_510, completed_at: 1_788_347_513, duration_ms: 3_000 } },
  ];
}

async function fixture(options = {}) {
  const root = await mkdtemp(join(tmpdir(), "codex-rollout-turns-"));
  const day = join(root, "2026", "09", "02");
  await mkdir(day, { recursive: true });
  await mkdir(cwd, { recursive: true });
  const path = join(day, `rollout-measure-${threadID}.jsonl`);
  await writeFile(path, rolloutLines(options).map(JSON.stringify).join("\n") + "\n");
  return { root, path };
}

const realNotify = {
  type: "agent-turn-complete",
  "thread-id": threadID,
  "turn-id": turnID,
  cwd,
  "input-messages": ["정식 질문"],
  "last-assistant-message": "정식 답변",
};
const titleNotify = {
  type: "agent-turn-complete",
  "thread-id": titleThreadID,
  "turn-id": titleTurnID,
  "input-messages": ["Generate a concise task title"],
  "last-assistant-message": "{\"title\":\"측정\"}",
};

test("rollout의 정식 turn_context와 task_complete를 읽는다", async () => {
  const { root, path } = await fixture();
  assert.equal(await findCodexRolloutPath(threadID, { sessionsRoot: root }), path);
  const turn = await readCodexRolloutTurn(path, turnID);
  assert.equal(turn.cwd, cwd);
  assert.equal(turn.prompt, "정식 질문\n[첨부: /tmp/a.png]");
  assert.equal(turn.response, "정식 답변");
  assert.equal(turn.startedAt, 1_788_347_510);
  assert.equal(turn.completedAt, 1_788_347_513);
});

test("정식 notify만 받고 rollout 없는 제목 생성 notify는 버린다", async () => {
  const { root } = await fixture();
  const gate = new CodexTerminalTurnGate({
    cwd,
    externalSessionID: threadID,
    sessionsRoot: root,
    retryCount: 1,
  });
  assert.equal((await gate.accept(realNotify)).accepted, true);
  assert.equal((await gate.accept(titleNotify)).reason, "thread-mismatch");
});

test("cwd 불일치와 재개 세션 thread-id 불일치를 버린다", async () => {
  const { root } = await fixture({ actualCwd: "/tmp/wrong" });
  const cwdGate = new CodexTerminalTurnGate({ cwd, externalSessionID: threadID, sessionsRoot: root, retryCount: 1 });
  assert.equal((await cwdGate.accept(realNotify)).reason, "cwd-mismatch");

  const threadGate = new CodexTerminalTurnGate({ cwd, externalSessionID: "01a00000-0000-7000-8000-000000000000", sessionsRoot: root, retryCount: 1 });
  assert.equal((await threadGate.accept(realNotify)).reason, "thread-mismatch");
});

test("신규 cli 세션 첫 정식 이벤트를 바인딩하고 turn-id 중복을 버린다", async () => {
  const { root } = await fixture({ source: "cli" });
  const gate = new CodexTerminalTurnGate({ cwd, sessionsRoot: root, retryCount: 1 });
  const accepted = await gate.accept(realNotify);
  assert.equal(accepted.accepted, true);
  assert.equal(accepted.boundExternalSessionID, threadID);
  assert.equal(gate.externalSessionID, threadID);
  assert.equal((await gate.accept(realNotify)).reason, "duplicate");
});

test("신규 세션은 rollout source cli만 허용한다", async () => {
  const { root } = await fixture({ source: "exec" });
  const gate = new CodexTerminalTurnGate({ cwd, sessionsRoot: root, retryCount: 1 });
  assert.equal((await gate.accept(realNotify)).reason, "new-session-not-cli");
});
