// 이 파일은 CLI 원문에서 공개 가능한 실시간 이벤트만 추출되는지 검증한다.

import assert from "node:assert/strict";
import test from "node:test";

import {
  decodeAgentResponse,
  parseAgentEvent,
} from "../src/agent-event-parser.mjs";

test("Codex 생각 요약을 공개 활동으로 변환한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "item.completed",
      item: {
        type: "reasoning",
        text: "레이아웃 구조를 확인했습니다.",
      },
    }),
    "codex",
  );

  assert.deepEqual(event.activity, {
    kind: "thinking",
    text: "레이아웃 구조를 확인했습니다.",
  });
});

test("Codex 명령 인수는 진행 이벤트에 포함하지 않는다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "item.started",
      item: {
        type: "command_execution",
        command: "deploy --token secret-value",
      },
    }),
    "codex",
  );

  assert.equal(event.activity.text, "터미널 출동 🧰");
  assert.equal(event.activity.text.includes("secret-value"), false);
});

test("Claude 공개 응답 조각을 실시간으로 추출한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "stream_event",
      event: {
        type: "content_block_delta",
        delta: {
          type: "text_delta",
          text: "현재 파일을 확인",
        },
      },
    }),
    "claude",
  );

  assert.equal(event.responseDelta, "현재 파일을 확인");
});

test("Claude 내부 생각 원문은 노출하지 않는다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "stream_event",
      event: {
        type: "content_block_start",
        content_block: {
          type: "thinking",
          thinking: "private chain of thought",
        },
      },
    }),
    "claude",
  );

  assert.equal(event.activity.text, "각 잡고 분석 중 🧠");
  assert.equal(event.activity.text.includes("private"), false);
});

test("사용자 확인 표식을 질문 상태로 분리한다", () => {
  assert.deepEqual(
    decodeAgentResponse("[NEED_INPUT]\n어느 색으로 할까요?"),
    {
      text: "어느 색으로 할까요?",
      needsInput: true,
    },
  );
});
