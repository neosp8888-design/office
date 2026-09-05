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

function responseItemRolloutLines() {
  const metadata = {
    turn_id: turnID,
    create_time: 1_788_347_511,
  };
  return [
    { type: "session_meta", payload: { id: threadID, source: "exec", cwd: "/old" } },
    { type: "event_msg", payload: { type: "task_started", turn_id: turnID, started_at: 1_788_347_510 } },
    { type: "response_item", payload: { type: "message", role: "developer", content: [{ type: "input_text", text: "내부 지침" }], internal_chat_message_metadata_passthrough: metadata } },
    { type: "turn_context", payload: { turn_id: turnID, cwd } },
    { type: "response_item", payload: { type: "message", role: "user", content: [{ type: "input_text", text: "오 이제 보이네" }], internal_chat_message_metadata_passthrough: metadata } },
    { type: "response_item", payload: { type: "message", role: "assistant", phase: "final_answer", content: [{ type: "output_text", text: "확인했습니다." }], internal_chat_message_metadata_passthrough: metadata } },
    { type: "event_msg", payload: { type: "task_complete", turn_id: turnID, last_agent_message: "확인했습니다.", started_at: 1_788_347_510, completed_at: 1_788_347_513 } },
  ];
}

async function fixture(options = {}) {
  const root = await mkdtemp(join(tmpdir(), "codex-rollout-turns-"));
  const day = join(root, "2026", "09", "02");
  await mkdir(day, { recursive: true });
  await mkdir(cwd, { recursive: true });
  const path = join(day, `rollout-measure-${threadID}.jsonl`);
  const lines = options.lines ?? rolloutLines(options);
  await writeFile(path, lines.map(JSON.stringify).join("\n") + "\n");
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

test("현재 Codex response_item 형식에서 해당 턴 사용자 입력만 읽는다", async () => {
  const { root, path } = await fixture({ lines: responseItemRolloutLines() });
  const turn = await readCodexRolloutTurn(path, turnID);
  assert.equal(turn.prompt, "오 이제 보이네");
  assert.equal(turn.response, "확인했습니다.");

  const gate = new CodexTerminalTurnGate({
    cwd,
    externalSessionID: threadID,
    sessionsRoot: root,
    retryCount: 1,
  });
  const accepted = await gate.accept({
    ...realNotify,
    "input-messages": ["과거 질문 1", "링크드인 과거 질문", "오 이제 보이네"],
  });
  assert.equal(accepted.accepted, true);
  assert.equal(accepted.turn.prompt, "오 이제 보이네");
});

test("rollout에 사용자 본문이 없으면 notify의 마지막 입력만 쓴다", async () => {
  const lines = rolloutLines().filter((record) =>
    record?.payload?.type !== "item_completed"
  );
  const { root } = await fixture({ lines });
  const gate = new CodexTerminalTurnGate({
    cwd,
    externalSessionID: threadID,
    sessionsRoot: root,
    retryCount: 1,
  });
  const accepted = await gate.accept({
    ...realNotify,
    "input-messages": ["과거 질문", "현재 질문"],
  });
  assert.equal(accepted.accepted, true);
  assert.equal(accepted.turn.prompt, "현재 질문");
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

test("턴 ID 없는 활동은 현재 턴 경계 안에서만 수집하고 최종 답변은 보존한다", async () => {
  const lines = responseItemRolloutLines();
  const activity = (text) => ({ type: "response_item", payload: { type: "message", role: "assistant", phase: "commentary", content: [{ type: "output_text", text }] } });
  lines.splice(4, 0,
    activity("파일을 확인합니다"),
    { type: "response_item", payload: { type: "reasoning", summary: [{ type: "summary_text", text: "공개 요약" }], encrypted_content: "private" } },
    { type: "response_item", payload: { type: "custom_tool_call", call_id: "c1", name: "exec", input: "비공개 도구 원문" } },
    { type: "response_item", payload: { type: "custom_tool_call_output", call_id: "c1", output: "도구 출력 전문" } },
    { type: "response_item", payload: { ...activity("다른 턴").payload, internal_chat_message_metadata_passthrough: { turn_id: titleTurnID } } },
  );
  lines.push(activity("끝난 뒤 메시지"), { type: "turn_context", payload: { turn_id: titleTurnID, cwd } }, activity("다음 턴 메시지"));
  const { path } = await fixture({ lines });
  const turn = await readCodexRolloutTurn(path, turnID);
  assert.equal(turn.prompt, "오 이제 보이네");
  assert.equal(turn.response, "확인했습니다.");
  assert.deepEqual(turn.activities.map(({ kind, text }) => ({ kind, text })), [
    { kind: "message", text: "파일을 확인합니다" },
    { kind: "thinking", text: "공개 요약" },
    { kind: "tool", text: "도구 · exec" },
  ]);
});
