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
        id: "reason-1",
        type: "reasoning",
        text: "레이아웃 구조를 확인했습니다.",
      },
    }),
    "codex",
  );

  assert.deepEqual(event.activity, {
    kind: "thinking",
    text: "레이아웃 구조를 확인했습니다.",
    eventKey: "reason-1",
    status: "completed",
    preserveText: false,
    messageScoped: false,
    isCodexReasoning: true,
  });
});

test("Codex reasoning에 실제 문구가 없으면 가짜 활동을 만들지 않는다", () => {
  for (const type of ["item.started", "item.updated", "item.completed"]) {
    const event = parseAgentEvent(
      JSON.stringify({
        type,
        item: {
          id: "reason-1",
          type: "reasoning",
        },
      }),
      "codex",
    );

    assert.equal(event, null);
  }
});

test("JSON 객체가 아닌 이벤트 행은 무시한다", () => {
  for (const value of ["null", "[]", '"event"', "1", "true"]) {
    assert.equal(parseAgentEvent(value, "codex"), null);
    assert.equal(parseAgentEvent(value, "claude"), null);
  }
});

test("Codex 완료 이벤트에서 토큰 사용량을 추출한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "turn.completed",
      usage: {
        input_tokens: 2_006,
        cached_input_tokens: 1_920,
        cache_write_input_tokens: 0,
        output_tokens: 300,
        reasoning_output_tokens: 17,
      },
    }),
    "codex",
  );

  assert.deepEqual(event.usage, {
    inputTokens: 2_006,
    outputTokens: 300,
    cachedInputTokens: 1_920,
    cacheWriteInputTokens: 0,
    cacheWrite5mInputTokens: null,
    cacheWrite1hInputTokens: null,
    reasoningOutputTokens: 17,
    serviceTier: null,
    speed: null,
    inferenceGeo: null,
    reportedCostUsd: null,
  });
});

test("Claude 결과에서 누적 토큰과 공급자 비용을 추출한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "result",
      subtype: "success",
      session_id: "session-1",
      result: "완료했습니다.",
      total_cost_usd: 0.00123,
      usage: {
        input_tokens: 2,
        cache_creation_input_tokens: 30,
        cache_read_input_tokens: 100,
        output_tokens: 4,
        service_tier: "standard",
        speed: "fast",
        inference_geo: "global",
        cache_creation: {
          ephemeral_5m_input_tokens: 20,
          ephemeral_1h_input_tokens: 10,
        },
      },
    }),
    "claude",
  );

  assert.equal(event.sessionID, "session-1");
  assert.equal(event.responseText, "완료했습니다.");
  assert.deepEqual(event.usage, {
    inputTokens: 2,
    outputTokens: 4,
    cachedInputTokens: 100,
    cacheWriteInputTokens: 30,
    cacheWrite5mInputTokens: 20,
    cacheWrite1hInputTokens: 10,
    reasoningOutputTokens: null,
    serviceTier: "standard",
    speed: "fast",
    inferenceGeo: "global",
    reportedCostUsd: 0.00123,
  });
});

test("Codex 공개 진행 설명은 최종 응답 후보와 분리한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "item.completed",
      item: {
        id: "message-1",
        type: "agent_message",
        text: "현재 구조를 확인하고 있습니다.",
      },
    }),
    "codex",
  );

  assert.deepEqual(event, {
    agentMessage: "현재 구조를 확인하고 있습니다.",
    agentMessageKey: "message-1",
  });
});

test("Codex 명령은 민감 인자를 숨기고 실행 대상을 표시한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "item.started",
      item: {
        id: "command-1",
        type: "command_execution",
        command: "deploy --token secret-value",
      },
    }),
    "codex",
  );

  assert.equal(
    event.activity.text,
    "deploy [민감 인자 숨김]",
  );
  assert.equal(event.activity.status, "running");
  assert.equal(event.activity.eventKey, "command-1");
  assert.equal(event.activity.text.includes("secret-value"), false);
});

test("Codex 명령 완료는 종료 코드와 안전한 명령을 표시한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "item.completed",
      item: {
        id: "command-1",
        type: "command_execution",
        command: "swift test --filter ParserTests",
        exit_code: 0,
      },
    }),
    "codex",
  );

  assert.equal(
    event.activity.text,
    "swift test --filter ParserTests",
  );
  assert.equal(event.activity.status, "completed");
  assert.equal(event.activity.eventKey, "command-1");
});

test("Codex 파일 변경은 변경 종류와 경로를 표시한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "item.completed",
      item: {
        id: "files-1",
        type: "file_change",
        changes: [
          { kind: "update", path: "Sources/OfficeGame/Feed.swift" },
          { kind: "add", path: "Tests/FeedTests.swift" },
        ],
      },
    }),
    "codex",
  );

  assert.equal(
    event.activity.text,
    [
      "파일 2개를 편집했습니다",
      "수정 Sources/OfficeGame/Feed.swift",
      "추가 Tests/FeedTests.swift",
    ].join("\n"),
  );
  assert.equal(event.activity.status, "completed");
});

test("Codex 파일 변경 시작은 실행 중 활동과 스냅샷 메타데이터를 만든다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "item.started",
      item: {
        id: "files-1",
        type: "file_change",
        changes: [{
          kind: "update",
          path: "Sources/OfficeGame/Feed.swift",
        }],
      },
    }),
    "codex",
  );

  assert.equal(event.activity.text, "파일 변경을 적용하는 중 · 1개");
  assert.equal(event.activity.status, "running");
  assert.deepEqual(event.fileChange, {
    eventKey: "files-1",
    phase: "item.started",
    changes: [{
      path: "Sources/OfficeGame/Feed.swift",
      kind: "update",
    }],
  });
});

test("Codex가 거절한 명령은 실패 활동으로 표시한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "item.completed",
      item: {
        id: "command-1",
        type: "command_execution",
        command: "rm protected.txt",
        status: "declined",
      },
    }),
    "codex",
  );

  assert.equal(event.activity.status, "failed");
});

test("Codex 항목 오류는 실패 활동으로 표시한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "item.completed",
      item: {
        id: "error-1",
        type: "error",
        message: "도구 연결이 끊겼습니다.",
      },
    }),
    "codex",
  );

  assert.equal(event.activity.text, "오류 · 도구 연결이 끊겼습니다.");
  assert.equal(event.activity.status, "failed");
});

test("Codex MCP 호출은 서버와 도구명을 표시한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "item.started",
      item: {
        id: "tool-1",
        type: "mcp_tool_call",
        server: "computer-use",
        actionName: "inspect",
      },
    }),
    "codex",
  );

  assert.equal(
    event.activity.text,
    "computer-use/inspect",
  );
  assert.equal(event.activity.status, "running");
  assert.equal(event.activity.eventKey, "tool-1");
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

test("Claude가 제공한 thinking 원문을 완료 활동으로 표시한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "assistant",
      message: {
        id: "message-1",
        content: [{
          type: "thinking",
          thinking: "상자별 참과 거짓을 대조한다.",
        }],
      },
    }),
    "claude",
  );

  assert.equal(
    event.activities[0].text,
    "상자별 참과 거짓을 대조한다.",
  );
  assert.equal(event.activities[0].status, "completed");
  assert.equal(event.activities[0].eventKey, "message-1:block:0");
});

test("Claude thinking 시작은 현재 메시지 범위의 실행 중 활동이다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "stream_event",
      event: {
        type: "content_block_start",
        index: 0,
        content_block: { type: "thinking", thinking: "" },
      },
    }),
    "claude",
  );

  assert.equal(event.activity.text, "추론 중");
  assert.equal(event.activity.status, "running");
  assert.equal(event.activity.eventKey, "block:0");
  assert.equal(event.activity.messageScoped, true);
});

test("Claude 도구는 이름과 안전한 파일 경로를 표시한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "assistant",
      message: {
        content: [
          {
            type: "tool_use",
            name: "Read",
            input: { file_path: "Sources/OfficeGame/Feed.swift" },
          },
        ],
      },
    }),
    "claude",
  );

  assert.equal(
    event.activities[0].text,
    "도구 · Read · Sources/OfficeGame/Feed.swift",
  );
  assert.equal(event.activities[0].status, "running");
});

test("Claude Bash 도구의 민감 인자는 노출하지 않는다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "assistant",
      message: {
        content: [
          {
            type: "tool_use",
            name: "Bash",
            input: { command: "curl --token secret-value example.com" },
          },
        ],
      },
    }),
    "claude",
  );

  assert.equal(
    event.activities[0].text,
    "도구 · Bash · curl [민감 인자 숨김]",
  );
  assert.equal(
    event.activities[0].text.includes("secret-value"),
    false,
  );
});

test("Claude 계획 도구는 단계 진행과 항목을 함께 보존한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "assistant",
      message: {
        content: [
          {
            type: "tool_use",
            name: "TodoWrite",
            input: {
              todos: [
                { content: "활동 형식 확인", status: "completed" },
                { content: "타임라인 구현", status: "in_progress" },
                { content: "테스트 실행", status: "pending" },
              ],
            },
          },
        ],
      },
    }),
    "claude",
  );

  assert.equal(
    event.activities[0].text,
    [
      "도구 · TodoWrite · 1/3단계",
      "[x] 활동 형식 확인",
      "[~] 타임라인 구현",
      "[ ] 테스트 실행",
    ].join("\n"),
  );
});

test("Claude 위임 도구는 담당 유형과 설명을 표시한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "assistant",
      message: {
        content: [
          {
            type: "tool_use",
            name: "Task",
            input: {
              subagent_type: "Explore",
              description: "대화창 구현 위치 조사",
            },
          },
        ],
      },
    }),
    "claude",
  );

  assert.equal(
    event.activities[0].text,
    "도구 · Task · Explore · 대화창 구현 위치 조사",
  );
});

test("Claude 노트북 편집도 안전한 경로를 표시한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "assistant",
      message: {
        content: [
          {
            type: "tool_use",
            name: "NotebookEdit",
            input: { notebook_path: "analysis/report.ipynb" },
          },
        ],
      },
    }),
    "claude",
  );

  assert.equal(
    event.activities[0].text,
    "도구 · NotebookEdit · analysis/report.ipynb",
  );
});

test("Claude 도구 결과는 같은 도구 행을 완료 상태로 갱신한다", () => {
  const event = parseAgentEvent(
    JSON.stringify({
      type: "user",
      message: {
        content: [{
          type: "tool_result",
          tool_use_id: "tool-1",
          content: "완료",
        }],
      },
    }),
    "claude",
  );

  assert.equal(event.activities[0].eventKey, "tool-1");
  assert.equal(event.activities[0].status, "completed");
  assert.equal(event.activities[0].preserveText, true);
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
