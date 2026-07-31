// 이 파일은 파일 첨부 인수와 실행 중단 상태 저장을 검증한다.

import assert from "node:assert/strict";
import {
  appendFileSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import test from "node:test";

import {
  AgentJobNotFoundError,
  AgentRuntime,
  buildArguments,
  codexUsageDelta,
  latestCodexUsageFromRollout,
  promptWithAttachments,
  stageAttachments,
} from "../src/agent-runtime.mjs";

const codexCharacter = {
  backend: "codex",
  model: "gpt-5.6-sol",
  effort: "high",
  fastMode: true,
  permission: "workspace-write",
  name: "코과장",
  seat: "우측 아래",
  identityPrompt: "업무를 정확히 처리한다.",
};

function makeCodexActivityState() {
  return {
    turnID: "turn-1",
    character: { id: "right-man", backend: "codex" },
    externalSessionID: "session-1",
    sequence: 0,
    lastActivity: null,
    activityRecords: new Map(),
    hasSeenInitialCodexReasoning: false,
    pendingInitialCodexReasoning: null,
    pendingAgentMessage: null,
    visibleAgentMessages: [],
    streamMessageID: null,
    responseText: "",
    partialText: "",
    lastPartialPersistedAt: 0,
    warning: null,
    failure: null,
  };
}

test("Codex에는 PNG와 JPEG만 이미지 인수로 전달한다", () => {
  const argumentsList = buildArguments({
    character: codexCharacter,
    prompt: "파일을 확인해줘.",
    previousSessionID: "session-1",
    attachments: [
      {
        path: "/tmp/photo.png",
        isCodexImage: true,
      },
      {
        path: "/tmp/document.pdf",
        isCodexImage: false,
      },
      {
        path: "/tmp/photo.jpeg",
        isCodexImage: true,
      },
    ],
  });

  assert.deepEqual(
    argumentsList.filter((value) => value.startsWith("/tmp/")),
    ["/tmp/photo.png", "/tmp/photo.jpeg"],
  );
  assert.equal(argumentsList.at(-1), "파일을 확인해줘.");
  assert.equal(argumentsList.includes("show_raw_agent_reasoning=true"), true);
  assert.equal(
    argumentsList.includes('model_reasoning_summary="detailed"'),
    true,
  );
  assert.equal(argumentsList.includes("features.fast_mode=true"), true);
  assert.equal(argumentsList.includes('service_tier="fast"'), true);
});

test("Codex는 Fast 비활성화도 신규 실행과 재개에 명시한다", () => {
  for (const previousSessionID of [null, "session-1"]) {
    const argumentsList = buildArguments({
      character: { ...codexCharacter, fastMode: false },
      prompt: "상태를 확인해줘.",
      previousSessionID,
    });

    assert.equal(argumentsList.includes("features.fast_mode=true"), true);
    assert.equal(argumentsList.includes('service_tier="default"'), true);
  }
});

test("Claude는 Fast 설정을 매 실행마다 settings JSON으로 전달한다", () => {
  for (const previousSessionID of [null, "session-1"]) {
    const argumentsList = buildArguments({
      character: {
        backend: "claude",
        model: "claude-opus-5",
        effort: "high",
        fastMode: true,
        permission: "auto",
        name: "클대리",
        seat: "좌측 아래",
        identityPrompt: "업무를 정확히 처리한다.",
      },
      prompt: "상태를 확인해줘.",
      previousSessionID,
    });
    const settingsIndex = argumentsList.indexOf("--settings");

    assert.notEqual(settingsIndex, -1);
    assert.deepEqual(
      JSON.parse(argumentsList[settingsIndex + 1]),
      { fastMode: true },
    );
  }
});

test("Claude는 Fast 비활성화를 명시하고 다른 모델의 Fast를 거절한다", () => {
  const argumentsList = buildArguments({
    character: {
      backend: "claude",
      model: "claude-sonnet-5",
      effort: "high",
      fastMode: false,
      permission: "auto",
      name: "클대리",
      seat: "좌측 아래",
      identityPrompt: "업무를 정확히 처리한다.",
    },
    prompt: "상태를 확인해줘.",
    previousSessionID: null,
  });
  const settingsIndex = argumentsList.indexOf("--settings");
  assert.deepEqual(
    JSON.parse(argumentsList[settingsIndex + 1]),
    { fastMode: false },
  );

  assert.throws(
    () => buildArguments({
      character: {
        backend: "claude",
        model: "claude-sonnet-5",
        effort: "high",
        fastMode: true,
        permission: "auto",
        name: "클대리",
        seat: "좌측 아래",
        identityPrompt: "업무를 정확히 처리한다.",
      },
      prompt: "상태를 확인해줘.",
      previousSessionID: null,
    }),
    /Opus 5/,
  );
});

test("같은 이벤트 ID의 시작과 완료는 한 활동 행을 갱신한다", async () => {
  const queries = [];
  const runtime = new AgentRuntime({
    pool: {
      query: async (text, values) => {
        queries.push({ text, values });
        return { rowCount: 1 };
      },
    },
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: () => {},
  });
  const state = {
    turnID: "turn-1",
    character: { id: "right-man" },
    sequence: 0,
    lastActivity: null,
    activityRecords: new Map(),
  };

  await runtime.addActivity(state, {
    kind: "command",
    text: "swift test",
    eventKey: "command-1",
    status: "running",
  });
  await runtime.addActivity(state, {
    kind: "command",
    text: "swift test",
    eventKey: "command-1",
    status: "completed",
  });

  const activityQueries = queries.filter(({ text }) =>
    /turn_activities/.test(text)
  );
  assert.equal(activityQueries.length, 2);
  assert.match(activityQueries[0].text, /INSERT INTO turn_activities/);
  assert.match(activityQueries[1].text, /UPDATE turn_activities/);
  assert.equal(state.sequence, 1);
  assert.equal(
    state.activityRecords.get("command-1").status,
    "completed",
  );
});

test("같은 활동 상태가 반복되면 저장과 방송을 반복하지 않는다", async () => {
  const queries = [];
  const broadcasts = [];
  const runtime = new AgentRuntime({
    pool: {
      query: async (text, values) => {
        queries.push({ text, values });
        return { rowCount: 1 };
      },
    },
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: (event) => broadcasts.push(event),
  });
  const state = makeCodexActivityState();

  await runtime.addActivity(state, {
    kind: "tool",
    text: "도구 · Read · Feed.swift",
    eventKey: "tool-1",
    status: "running",
  });
  await runtime.addActivity(state, {
    kind: "tool",
    text: "도구 · Read · Feed.swift",
    eventKey: "tool-1",
    status: "running",
  });

  assert.equal(
    queries.filter(({ text }) => /turn_activities/.test(text)).length,
    1,
  );
  assert.equal(broadcasts.length, 1);
});

test("첫 실제 Codex reasoning은 다음 활동까지 같은 행의 실행 중 상태로 저장한다", async () => {
  const queries = [];
  const runtime = new AgentRuntime({
    pool: {
      query: async (text, values) => {
        queries.push({ text, values });
        return { rowCount: 1 };
      },
    },
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: () => {},
  });
  const state = makeCodexActivityState();
  const stream = Readable.from([
    `${JSON.stringify({
      type: "item.completed",
      item: {
        id: "reason-1",
        type: "reasoning",
        text: "실제 구조를 확인하고 있습니다.",
      },
    })}\n`,
    `${JSON.stringify({
      type: "item.started",
      item: {
        id: "command-1",
        type: "command_execution",
        command: "swift test",
      },
    })}\n`,
  ]);

  await runtime.consumeOutput(state, stream);

  const activityQueries = queries.filter(({ text }) =>
    /turn_activities/.test(text)
  );
  assert.equal(activityQueries.length, 3);
  assert.match(activityQueries[0].text, /INSERT INTO turn_activities/);
  assert.equal(activityQueries[0].values[3], "실제 구조를 확인하고 있습니다.");
  assert.equal(activityQueries[0].values[5], "running");
  assert.match(activityQueries[1].text, /INSERT INTO turn_activities/);
  assert.equal(activityQueries[1].values[4], "command-1");
  assert.match(activityQueries[2].text, /UPDATE turn_activities/);
  assert.equal(activityQueries[2].values[4], "completed");
  assert.doesNotMatch(activityQueries[2].text, /occurred_at\s*=/);
  assert.equal(state.activityRecords.get("reason-1").status, "completed");
});

test("첫 Codex reasoning 뒤 바로 스트림이 끝나도 실행 중 상태를 남기지 않는다", async () => {
  const queries = [];
  const runtime = new AgentRuntime({
    pool: {
      query: async (text, values) => {
        queries.push({ text, values });
        return { rowCount: 1 };
      },
    },
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: () => {},
  });
  const state = makeCodexActivityState();
  const stream = Readable.from([
    `${JSON.stringify({
      type: "item.completed",
      item: {
        id: "reason-1",
        type: "reasoning",
        text: "실제 추론 한 건입니다.",
      },
    })}\n`,
  ]);

  await runtime.consumeOutput(state, stream);

  const activityQueries = queries.filter(({ text }) =>
    /turn_activities/.test(text)
  );
  assert.equal(activityQueries.length, 2);
  assert.equal(activityQueries[0].values[5], "running");
  assert.equal(activityQueries[1].values[4], "completed");
  assert.equal(state.pendingInitialCodexReasoning, null);
});

test("두 번째 Codex reasoning은 시작 상태를 합성하지 않고 완료로 저장한다", async () => {
  const queries = [];
  const runtime = new AgentRuntime({
    pool: {
      query: async (text, values) => {
        queries.push({ text, values });
        return { rowCount: 1 };
      },
    },
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: () => {},
  });
  const state = makeCodexActivityState();
  const stream = Readable.from([
    `${JSON.stringify({
      type: "item.completed",
      item: {
        id: "reason-1",
        type: "reasoning",
        text: "첫 실제 추론입니다.",
      },
    })}\n`,
    `${JSON.stringify({
      type: "item.completed",
      item: {
        id: "reason-2",
        type: "reasoning",
        text: "두 번째 실제 추론입니다.",
      },
    })}\n`,
  ]);

  await runtime.consumeOutput(state, stream);

  const activityQueries = queries.filter(({ text }) =>
    /turn_activities/.test(text)
  );
  assert.equal(activityQueries.length, 3);
  assert.equal(activityQueries[0].values[5], "running");
  assert.equal(activityQueries[1].values[3], "두 번째 실제 추론입니다.");
  assert.equal(activityQueries[1].values[5], "completed");
  assert.equal(activityQueries[2].values[4], "completed");
});

test("공개 진행 설명은 활동에 남기고 응답 본문에도 누적 유지한다", async () => {
  const queries = [];
  const runtime = new AgentRuntime({
    pool: {
      query: async (text, values) => {
        queries.push({ text, values });
        return { rowCount: 1 };
      },
    },
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: () => {},
  });
  const state = {
    turnID: "turn-1",
    character: { id: "right-man", backend: "codex" },
    externalSessionID: "session-1",
    sequence: 0,
    lastActivity: null,
    activityRecords: new Map(),
    pendingAgentMessage: null,
    visibleAgentMessages: [],
    streamMessageID: null,
    responseText: "",
    partialText: "",
    lastPartialPersistedAt: 0,
    warning: null,
    failure: null,
  };
  const lines = [
    {
      type: "item.completed",
      item: {
        id: "message-1",
        type: "agent_message",
        text: "현재 구조를 확인했습니다.",
      },
    },
    {
      type: "item.started",
      item: {
        id: "command-1",
        type: "command_execution",
        command: "swift test",
      },
    },
    {
      type: "item.completed",
      item: {
        id: "command-1",
        type: "command_execution",
        command: "swift test",
        exit_code: 0,
      },
    },
    {
      type: "item.completed",
      item: {
        id: "message-2",
        type: "agent_message",
        text: "검증을 통과했습니다.",
      },
    },
  ];
  const stream = Readable.from(
    lines.map((line) => `${JSON.stringify(line)}\n`),
  );

  await runtime.consumeOutput(state, stream);

  assert.equal(state.sequence, 3);
  assert.equal(state.responseText, "검증을 통과했습니다.");
  assert.deepEqual(
    state.visibleAgentMessages.map((message) => message.text),
    ["현재 구조를 확인했습니다.", "검증을 통과했습니다."],
  );
  assert.equal(
    state.activityRecords.get("message:message-1").text,
    "현재 구조를 확인했습니다.",
  );
  assert.equal(
    state.activityRecords.get("message:message-2").text,
    "검증을 통과했습니다.",
    "마지막 Codex 메시지도 후속 도구 없이 즉시 활동으로 저장한다",
  );
  assert.equal(
    state.activityRecords.get("command-1").status,
    "completed",
  );
  const responseDrafts = queries
    .filter(({ text }) => /UPDATE messages/.test(text))
    .map(({ values }) => values[1]);
  assert.equal(responseDrafts.includes(""), false);
  assert.equal(
    responseDrafts.at(-1),
    "현재 구조를 확인했습니다.\n\n검증을 통과했습니다.",
  );
  assert.equal(
    runtime.completedResponseText(state, {
      text: "검증을 통과했습니다.",
      needsInput: false,
    }),
    "현재 구조를 확인했습니다.\n\n검증을 통과했습니다.",
  );
  state.responseText = "";
  state.partialText = "";
  assert.equal(
    runtime.finalResponseCandidate(state),
    "검증을 통과했습니다.",
  );
});

test("서로 다른 ID의 같은 문장은 각각 응답 순서에 남긴다", async () => {
  const runtime = new AgentRuntime({
    pool: {
      query: async () => ({ rowCount: 1 }),
    },
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: () => {},
  });
  const state = makeCodexActivityState();
  const stream = Readable.from([
    `${JSON.stringify({
      type: "item.completed",
      item: {
        id: "message-1",
        type: "agent_message",
        text: "같은 문장",
      },
    })}\n`,
    `${JSON.stringify({
      type: "item.completed",
      item: {
        id: "message-2",
        type: "agent_message",
        text: "같은 문장",
      },
    })}\n`,
  ]);

  await runtime.consumeOutput(state, stream);

  assert.deepEqual(state.visibleAgentMessages, [
    { key: "message-1", text: "같은 문장" },
    { key: "message-2", text: "같은 문장" },
  ]);
  assert.equal(
    runtime.completedResponseText(state, {
      text: "같은 문장",
      needsInput: false,
    }),
    "같은 문장\n\n같은 문장",
  );
});

test("Codex 답변 필요 표식은 최종 메시지 활동에서도 제거한다", async () => {
  const queries = [];
  const runtime = new AgentRuntime({
    pool: {
      query: async (text, values) => {
        queries.push({ text, values });
        return { rowCount: 1 };
      },
    },
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: () => {},
  });
  const state = makeCodexActivityState();
  const stream = Readable.from([
    `${JSON.stringify({
      type: "item.completed",
      item: {
        id: "message-1",
        type: "agent_message",
        text: "[NEED_INPUT]\n어느 색으로 할까요?",
      },
    })}\n`,
  ]);

  await runtime.consumeOutput(state, stream);
  await runtime.normalizeCompletedCodexMessageActivity(state, {
    text: "어느 색으로 할까요?",
    needsInput: true,
  });

  assert.equal(
    state.activityRecords.get("message:message-1").text,
    "어느 색으로 할까요?",
  );
  assert.equal(
    state.visibleAgentMessages.at(-1).text,
    "어느 색으로 할까요?",
  );
  assert.equal(state.responseText, "어느 색으로 할까요?");
  const activityUpdates = queries.filter(({ text }) =>
    /UPDATE turn_activities/.test(text)
  );
  assert.equal(activityUpdates.length, 1);
  assert.doesNotMatch(activityUpdates[0].text, /occurred_at\s*=/);
});

test("Codex 파일 변경 통계는 현재 턴 rollout의 실제 patch diff로 계산한다", async () => {
  const workdir = mkdtempSync(join(tmpdir(), "office-file-change-test-"));
  const filePath = join(workdir, "Feed.swift");
  const rolloutPath = join(workdir, "rollout.jsonl");
  writeFileSync(filePath, "old line\nkept line\n");
  writeFileSync(rolloutPath, "");
  const queries = [];
  const runtime = new AgentRuntime({
    pool: {
      query: async (text, values) => {
        queries.push({ text, values });
        return { rowCount: 1 };
      },
    },
    withTransaction: async () => {},
    workdir,
    broadcast: () => {},
  });
  const state = makeCodexActivityState();
  state.rolloutReader = {
    path: rolloutPath,
    offset: 0,
    remainder: "",
    pending: [],
  };

  async function* events() {
    yield `${JSON.stringify({
      type: "item.started",
      item: {
        id: "files-1",
        type: "file_change",
        changes: [{ kind: "update", path: "Feed.swift" }],
        status: "in_progress",
      },
    })}\n`;
    writeFileSync(filePath, "new line\nanother line\nkept line\n");
    appendFileSync(rolloutPath, `${JSON.stringify({
      type: "event_msg",
      payload: {
        type: "patch_apply_end",
        call_id: "call-1",
        status: "completed",
        success: true,
        changes: {
          [filePath]: {
            type: "update",
            move_path: null,
            unified_diff: [
              "--- a/Feed.swift",
              "+++ b/Feed.swift",
              "@@ -1,2 +1,3 @@",
              "-old line",
              "+new line",
              "+another line",
              " kept line",
            ].join("\n"),
          },
        },
      },
    })}\n`);
    yield `${JSON.stringify({
      type: "item.completed",
      item: {
        id: "files-1",
        type: "file_change",
        changes: [{ kind: "update", path: "Feed.swift" }],
        status: "completed",
      },
    })}\n`;
  }

  try {
    await runtime.consumeOutput(state, Readable.from(events()));
  } finally {
    rmSync(workdir, { recursive: true, force: true });
  }

  assert.equal(
    state.activityRecords.get("files-1").text,
    [
      "파일 1개를 편집했습니다",
      "+2 -1",
      "수정 Feed.swift",
    ].join("\n"),
  );
  assert.equal(state.activityRecords.get("files-1").status, "completed");
});

test("업무 프롬프트에 보관된 첨부 경로를 기록한다", () => {
  const prompt = promptWithAttachments("분석해줘.", [
    {
      name: "report.pdf",
      path: "/workspace/.office-attachments/01-report.pdf",
    },
  ]);

  assert.match(prompt, /첨부 파일/);
  assert.match(prompt, /report\.pdf/);
  assert.match(prompt, /\.office-attachments/);
});

test("첨부 원본을 작업 폴더에 보관한다", () => {
  const workdir = mkdtempSync(join(tmpdir(), "office-attachment-test-"));
  const source = join(workdir, "source.txt");
  writeFileSync(source, "attachment body");

  try {
    const [attachment] = stageAttachments({
      attachmentPaths: [source],
      workdir,
    });

    assert.equal(existsSync(attachment.path), true);
    assert.equal(readFileSync(attachment.path, "utf8"), "attachment body");
    assert.match(attachment.path, /\.office-attachments/);
  } finally {
    rmSync(workdir, { recursive: true, force: true });
  }
});

test("실행 중단은 턴을 interrupted로 저장하고 실행 목록에서 제거한다", async () => {
  const queries = [];
  const broadcasts = [];
  const runtime = new AgentRuntime({
    pool: {
      query: async (text, values) => {
        queries.push({ text, values });
        return { rowCount: 1 };
      },
    },
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: (event) => broadcasts.push(event),
  });
  runtime.running.set("boss", {
    turnID: "turn-1",
    process: null,
    cancelRequested: false,
  });

  const result = await runtime.cancel("boss");

  assert.deepEqual(result, {
    turnId: "turn-1",
    status: "interrupted",
  });
  assert.equal(runtime.running.has("boss"), false);
  const turnUpdate = queries.find(({ text }) =>
    /status = 'interrupted'/.test(text)
  );
  assert.deepEqual(turnUpdate.values, [
    "turn-1",
    "사용자가 업무를 중단했습니다.",
  ]);
  assert.equal(broadcasts.length, 1);
});

test("실행 중단은 남은 실행 중 활동도 실패 상태로 닫는다", async () => {
  const queries = [];
  const runtime = new AgentRuntime({
    pool: {
      query: async (text, values) => {
        queries.push({ text, values });
        return { rowCount: 1 };
      },
    },
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: () => {},
  });
  const state = {
    ...makeCodexActivityState(),
    character: { id: "boss", backend: "codex" },
    process: null,
    cancelRequested: false,
    sequence: 1,
    activityRecords: new Map([["command-1", {
      sequence: 1,
      kind: "command",
      text: "swift test",
      status: "running",
    }]]),
  };
  runtime.running.set("boss", state);

  await runtime.cancel("boss");

  const activityUpdate = queries.find(({ text }) =>
    /UPDATE turn_activities/.test(text)
  );
  assert.equal(activityUpdate.values[1], "failed");
  assert.equal(state.activityRecords.get("command-1").status, "failed");
});

test("실패한 턴은 남은 실행 중 활동도 실패 상태로 닫는다", async () => {
  const queries = [];
  const query = async (text, values) => {
    queries.push({ text, values });
    return { rowCount: 1 };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/tmp",
    broadcast: () => {},
  });
  const state = {
    ...makeCodexActivityState(),
    character: { id: "boss", backend: "codex" },
    sequence: 1,
    activityRecords: new Map([["command-1", {
      sequence: 1,
      kind: "command",
      text: "swift test",
      status: "running",
    }]]),
  };
  runtime.running.set("boss", state);

  await runtime.fail(state, new Error("실패"));

  const activityUpdate = queries.find(({ text }) =>
    /UPDATE turn_activities/.test(text)
  );
  assert.equal(activityUpdate.values[1], "failed");
  assert.equal(state.activityRecords.get("command-1").status, "failed");
});

test("이전 턴의 늦은 실패는 같은 직원의 새 턴을 제거하지 않는다", async () => {
  const queries = [];
  const query = async (text, values) => {
    queries.push({ text, values });
    return { rowCount: 1 };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/tmp",
    broadcast: () => {},
  });
  const oldState = {
    ...makeCodexActivityState(),
    turnID: "old-turn",
    character: { id: "boss", backend: "codex" },
  };
  const newState = {
    ...makeCodexActivityState(),
    turnID: "new-turn",
    character: { id: "boss", backend: "codex" },
  };
  runtime.running.set("boss", newState);

  await runtime.fail(oldState, new Error("늦은 실패"));

  assert.equal(runtime.running.get("boss"), newState);
  assert.equal(queries.length, 0);
});

test("백엔드 복구는 중단된 턴의 실행 중 활동도 닫는다", async () => {
  const queries = [];
  const runtime = new AgentRuntime({
    pool: {
      query: async (text) => {
        queries.push(text);
        return { rowCount: 2 };
      },
    },
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: () => {},
  });

  const count = await runtime.recoverInterruptedJobs();

  assert.equal(count, 2);
  assert.match(queries[0], /UPDATE turn_activities AS activity/);
  assert.match(queries[0], /activity\.status = 'running'/);
  assert.match(queries[0], /existing_terminal_turns/);
  assert.match(queries[0], /turn\.status = 'completed'/);
  assert.match(queries[0], /THEN 'completed'/);
});

test("중단 중 늦게 저장된 keyless 활동도 출력 종료 뒤 닫는다", async () => {
  const queries = [];
  const runtime = new AgentRuntime({
    pool: {
      query: async (text, values) => {
        queries.push({ text, values });
        return { rowCount: 1 };
      },
    },
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: () => {},
  });
  const state = {
    ...makeCodexActivityState(),
    character: { id: "boss", backend: "codex" },
    cancelRequested: true,
  };
  await runtime.addActivity(state, {
    kind: "command",
    text: "buffered command",
    status: "running",
  });

  const settled = await runtime.settleCancelledOutput(state);

  assert.equal(settled, true);
  const closingUpdate = queries.findLast(({ text }) =>
    /UPDATE turn_activities\s+SET status = \$2/.test(text)
  );
  assert.deepEqual(closingUpdate.values, ["turn-1", "failed"]);
});

test("실행 중인 업무가 없으면 중단 요청을 거절한다", async () => {
  const runtime = new AgentRuntime({
    pool: {},
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: () => {},
  });

  await assert.rejects(
    runtime.cancel("boss"),
    AgentJobNotFoundError,
  );
});

test("Codex rollout 끝에서 직전 누적 사용량을 찾는다", () => {
  const directory = mkdtempSync(join(tmpdir(), "office-usage-"));
  const path = join(directory, "rollout.jsonl");
  try {
    writeFileSync(path, [
      JSON.stringify({
        payload: {
          type: "token_count",
          info: {
            total_token_usage: {
              input_tokens: 124_509_396,
              cached_input_tokens: 120_069_888,
              cache_write_input_tokens: 0,
              output_tokens: 458_293,
              reasoning_output_tokens: 226_498,
            },
          },
        },
      }),
      JSON.stringify({
        payload: {
          type: "agent_message",
          message: "x".repeat(70_000),
        },
      }),
      "",
    ].join("\n"));

    assert.deepEqual(latestCodexUsageFromRollout(path), {
      inputTokens: 124_509_396,
      outputTokens: 458_293,
      cachedInputTokens: 120_069_888,
      cacheWriteInputTokens: 0,
      cacheWrite5mInputTokens: null,
      cacheWrite1hInputTokens: null,
      reasoningOutputTokens: 226_498,
      serviceTier: null,
      speed: null,
      inferenceGeo: null,
      reportedCostUsd: null,
    });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Codex 재개 세션의 누적 사용량을 현재 턴 증분으로 바꾼다", () => {
  const baseline = {
    inputTokens: 124_509_396,
    outputTokens: 458_293,
    cachedInputTokens: 120_069_888,
    cacheWriteInputTokens: 0,
    cacheWrite5mInputTokens: null,
    cacheWrite1hInputTokens: null,
    reasoningOutputTokens: 226_498,
  };
  const usage = {
    inputTokens: 124_946_225,
    outputTokens: 459_261,
    cachedInputTokens: 120_500_480,
    cacheWriteInputTokens: 0,
    cacheWrite5mInputTokens: null,
    cacheWrite1hInputTokens: null,
    reasoningOutputTokens: 226_746,
    serviceTier: null,
    speed: null,
    inferenceGeo: null,
    reportedCostUsd: null,
  };

  assert.deepEqual(codexUsageDelta(usage, baseline), {
    ...usage,
    inputTokens: 436_829,
    outputTokens: 968,
    cachedInputTokens: 430_592,
    cacheWriteInputTokens: 0,
    reasoningOutputTokens: 248,
  });
});

test("Codex가 이미 턴 사용량을 보고하면 누적값으로 차감하지 않는다", () => {
  assert.equal(codexUsageDelta(
    {
      inputTokens: 10_000,
      outputTokens: 500,
      cachedInputTokens: 9_000,
    },
    {
      inputTokens: 100_000,
      outputTokens: 5_000,
      cachedInputTokens: 90_000,
    },
  ), null);
});

test("Codex 완료 이벤트는 재개 시점 기준 증분만 상태에 남긴다", async () => {
  const runtime = new AgentRuntime({
    pool: { query: async () => ({ rowCount: 1 }) },
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: () => {},
  });
  const state = makeCodexActivityState();
  state.resumedCodexSession = true;
  state.usageBaseline = {
    inputTokens: 124_509_396,
    outputTokens: 458_293,
    cachedInputTokens: 120_069_888,
    cacheWriteInputTokens: 0,
    reasoningOutputTokens: 226_498,
  };
  state.usage = null;

  await runtime.consumeOutput(state, Readable.from([
    `${JSON.stringify({
      type: "turn.completed",
      usage: {
        input_tokens: 124_946_225,
        output_tokens: 459_261,
        cached_input_tokens: 120_500_480,
        cache_write_input_tokens: 0,
        reasoning_output_tokens: 226_746,
      },
    })}\n`,
  ]));

  assert.equal(state.usage.inputTokens, 436_829);
  assert.equal(state.usage.cachedInputTokens, 430_592);
  assert.equal(state.usage.outputTokens, 968);
  assert.equal(state.usage.reasoningOutputTokens, 248);
});

test("완료 사용량과 추정 비용을 같은 턴의 사용량 기록으로 저장한다", async () => {
  const queries = [];
  const runtime = new AgentRuntime({
    pool: {
      query: async (text, values) => {
        queries.push({ text, values });
        return { rowCount: 1 };
      },
    },
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: () => {},
  });
  const state = {
    turnID: "turn-1",
    character: {
      backend: "codex",
      model: "gpt-5.6-sol",
      fastMode: true,
    },
    usage: {
      inputTokens: 1_000,
      outputTokens: 50,
      cachedInputTokens: 200,
      reasoningOutputTokens: 10,
      cacheWriteInputTokens: 100,
      cacheWrite5mInputTokens: null,
      cacheWrite1hInputTokens: null,
    },
  };

  await runtime.persistUsageRecord(runtime.pool, state);

  assert.equal(queries.length, 1);
  assert.match(queries[0].text, /INSERT INTO usage_records/);
  assert.deepEqual(queries[0].values, [
    "turn-1",
    1_000,
    50,
    200,
    10,
    0.01145,
    100,
    null,
    null,
  ]);
});
