// 이 파일은 파일 첨부 인수와 실행 중단 상태 저장을 검증한다.

import assert from "node:assert/strict";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { Readable } from "node:stream";
import test from "node:test";

import {
  AgentBusyError,
  AgentJobNotFoundError,
  AgentRuntime,
  adoptClaudeSession,
  buildArguments,
  claudeSessionPath,
  claudeSessionResumable,
  codexUsageDelta,
  latestClaudeUsageFromSession,
  latestCodexUsageFromRollout,
  recoverInterruptedUsage,
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
    workdir: "/tmp",
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

test("Codex 재개는 바뀐 모델·추론·Fast·권한을 같은 세션에 전달한다", () => {
  const argumentsList = buildArguments({
    character: {
      ...codexCharacter,
      model: "gpt-5.6-terra",
      effort: "xhigh",
      fastMode: false,
      permission: "danger-full-access",
    },
    prompt: "같은 세션에서 계속해줘.",
    previousSessionID: "session-1",
  });

  assert.deepEqual(argumentsList.slice(0, 4), [
    "exec",
    "resume",
    "session-1",
    "--json",
  ]);
  assert.equal(argumentsList.includes('model="gpt-5.6-terra"'), true);
  assert.equal(
    argumentsList.includes('model_reasoning_effort="xhigh"'),
    true,
  );
  assert.equal(argumentsList.includes('service_tier="default"'), true);
  assert.equal(
    argumentsList.includes('sandbox_mode="danger-full-access"'),
    true,
  );
});

test("Codex 재개는 현재 역할 지침을 같은 세션에 전달한다", () => {
  const argumentsList = buildArguments({
    character: {
      ...codexCharacter,
      identityPrompt: "업데이트된 역할 지침을 따른다.",
    },
    prompt: "계속해줘.",
    previousSessionID: "session-1",
  });
  const instructions = argumentsList.find((value) =>
    value.startsWith("developer_instructions=")
  );

  assert.match(instructions, /업데이트된 역할 지침을 따른다/);
  assert.equal(argumentsList.at(-1), "계속해줘.");
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

test("Claude 재개도 현재 역할 지침과 권한을 같은 세션에 전달한다", () => {
  const argumentsList = buildArguments({
    character: {
      backend: "claude",
      model: "claude-opus-5",
      effort: "high",
      fastMode: true,
      permission: "bypassPermissions",
      name: "클대리",
      seat: "좌측 아래",
      identityPrompt: "업데이트된 역할 지침을 따른다.",
    },
    prompt: "계속해줘.",
    previousSessionID: "session-1",
  });
  const identityIndex = argumentsList.indexOf("--append-system-prompt");
  const permissionIndex = argumentsList.indexOf("--permission-mode");

  assert.notEqual(identityIndex, -1);
  assert.match(
    argumentsList[identityIndex + 1],
    /업데이트된 역할 지침을 따른다/,
  );
  assert.equal(argumentsList[permissionIndex + 1], "bypassPermissions");
  assert.equal(argumentsList.includes("--resume"), true);
});

const claudeResumeCharacter = {
  backend: "claude",
  model: "claude-sonnet-5",
  effort: "high",
  fastMode: false,
  permission: "bypassPermissions",
  name: "클대리",
  seat: "좌측 아래",
  identityPrompt: "업무 지시를 정확히 이해한다.",
};

function withClaudeSessionHome(run) {
  const home = mkdtempSync(join(tmpdir(), "office-claude-home-"));
  const workdir = mkdtempSync(join(tmpdir(), "office-claude-workdir-"));
  const originalHome = process.env.HOME;
  process.env.HOME = home;
  try {
    return run({ workdir });
  } finally {
    if (originalHome === undefined) {
      delete process.env.HOME;
    } else {
      process.env.HOME = originalHome;
    }
    rmSync(home, { recursive: true, force: true });
    rmSync(workdir, { recursive: true, force: true });
  }
}

function writeClaudeSession(workdir, sessionID) {
  const path = claudeSessionPath(workdir, sessionID);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `{"sessionId":"${sessionID}"}\n`);
  return path;
}

test("Claude 세션 경로는 실행 디렉토리를 그대로 반영한다", () => {
  withClaudeSessionHome(({ workdir }) => {
    const path = claudeSessionPath(workdir, "session-1");
    const encoded = realpathSync(workdir).replace(/[/.]/g, "-");

    assert.equal(path.endsWith(join(encoded, "session-1.jsonl")), true);
    assert.equal(claudeSessionResumable(workdir, "session-1"), false);

    writeClaudeSession(workdir, "session-1");
    assert.equal(claudeSessionResumable(workdir, "session-1"), true);
  });
});

test("Claude는 어디에도 세션이 없으면 재개하지 않는다", () => {
  withClaudeSessionHome(({ workdir }) => {
    const argumentsList = buildArguments({
      character: claudeResumeCharacter,
      prompt: "계속해줘.",
      previousSessionID: "session-1",
      workdir,
    });

    assert.equal(argumentsList.includes("--resume"), false);
  });
});

test("Claude는 병합으로 작업 공간이 바뀌어도 이전 세션을 이어받는다", () => {
  withClaudeSessionHome(({ workdir }) => {
    const previousWorkdir = mkdtempSync(join(tmpdir(), "office-claude-old-"));
    try {
      const source = writeClaudeSession(previousWorkdir, "session-1");
      assert.equal(claudeSessionResumable(workdir, "session-1"), false);

      const adopted = adoptClaudeSession(workdir, "session-1");

      assert.equal(adopted, true);
      assert.equal(claudeSessionResumable(workdir, "session-1"), true);
      assert.equal(
        readFileSync(claudeSessionPath(workdir, "session-1"), "utf8"),
        readFileSync(source, "utf8"),
      );

      const argumentsList = buildArguments({
        character: claudeResumeCharacter,
        prompt: "계속해줘.",
        previousSessionID: "session-1",
        workdir,
      });
      const resumeIndex = argumentsList.indexOf("--resume");

      assert.notEqual(resumeIndex, -1);
      assert.equal(argumentsList[resumeIndex + 1], "session-1");
    } finally {
      rmSync(previousWorkdir, { recursive: true, force: true });
    }
  });
});

test("Claude는 같은 작업 공간에 세션이 남아 있으면 재개한다", () => {
  withClaudeSessionHome(({ workdir }) => {
    writeClaudeSession(workdir, "session-1");
    const argumentsList = buildArguments({
      character: claudeResumeCharacter,
      prompt: "계속해줘.",
      previousSessionID: "session-1",
      workdir,
    });
    const resumeIndex = argumentsList.indexOf("--resume");

    assert.notEqual(resumeIndex, -1);
    assert.equal(argumentsList[resumeIndex + 1], "session-1");
  });
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
  state.workdir = workdir;
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

test("백엔드 복구는 중단된 provisioning 기록을 Git 정리한 뒤 실패로 닫는다", async () => {
  const events = [];
  const row = workspaceDatabaseRow({
    status: "provisioning",
    review_turn_id: null,
    review_tree: null,
    changed_files: [],
  });
  const query = async (text) => {
    if (
      /SELECT \*\s+FROM task_workspaces\s+WHERE status = 'provisioning'/.test(
        text,
      )
    ) {
      events.push("db:read-provisioning");
      return { rowCount: 1, rows: [row] };
    }
    if (/WHERE status IN \('provisioning', 'merging'\)/.test(text)) {
      events.push("db:mark-failed");
      return { rowCount: 1, rows: [] };
    }
    return { rowCount: 0, rows: [] };
  };
  const cleaned = [];
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async () => {},
    workdir: "/repo",
    workspaceManager: {
      cleanupProvisioning: async (workspace) => {
        events.push("git:cleanup-provisioning");
        cleaned.push(workspace);
      },
      cleanup: async () => {
        assert.fail("provisioning 복구는 일반 cleanup을 사용하면 안 됩니다.");
      },
    },
    broadcast: () => {},
  });

  await runtime.recoverInterruptedJobs();

  assert.equal(cleaned.length, 1);
  assert.equal(cleaned[0].cliSessionID, "session-1");
  assert.equal(cleaned[0].status, "provisioning");
  assert.deepEqual(events, [
    "db:read-provisioning",
    "git:cleanup-provisioning",
    "db:mark-failed",
  ]);
});

test("백엔드 복구는 유효하지 않은 active workspace만 실패 처리하고 세션은 유지한다", async () => {
  const events = [];
  const queries = [];
  const row = workspaceDatabaseRow({
    status: "active",
    review_turn_id: null,
    review_tree: null,
    changed_files: [],
  });
  const query = async (text, values) => {
    queries.push({ text, values });
    if (
      /SELECT \*\s+FROM task_workspaces\s+WHERE status = 'active'/.test(text)
    ) {
      events.push("db:read-active");
      return { rowCount: 1, rows: [row] };
    }
    if (
      /UPDATE task_workspaces/.test(text) &&
      /SET status = 'failed'/.test(text) &&
      /AND status = 'active'/.test(text)
    ) {
      events.push("db:workspace-failed");
      return { rowCount: 1, rows: [] };
    }
    if (/DELETE FROM active_cli_sessions/.test(text)) {
      events.push("db:delete-active-session");
      return { rowCount: 1, rows: [] };
    }
    if (/UPDATE cli_sessions/.test(text) && /ended_at/.test(text)) {
      events.push("db:end-cli-session");
      return { rowCount: 1, rows: [] };
    }
    return { rowCount: 0, rows: [] };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => {
      events.push("db:transaction");
      return body({ query });
    },
    workdir: "/repo",
    workspaceManager: {
      validateWorkspace: async (workspace) => {
        events.push("git:validate-active");
        assert.equal(workspace.cliSessionID, "session-1");
        assert.equal(workspace.status, "active");
        throw new Error("worktree missing");
      },
    },
    broadcast: () => {},
  });

  const count = await runtime.recoverInterruptedJobs();

  assert.equal(count, 0);
  assert.deepEqual(events, [
    "db:read-active",
    "git:validate-active",
    "db:transaction",
    "db:workspace-failed",
  ]);
  const failed = queries.find(({ text }) =>
    /SET status = 'failed'/.test(text) && /AND status = 'active'/.test(text)
  );
  assert.ok(failed);
  assert.deepEqual(failed.values, [
    "workspace-1",
    "활성 작업 공간을 복구할 수 없습니다. worktree missing",
  ]);
  assert.equal(
    queries.some(({ text, values }) =>
      /DELETE FROM active_cli_sessions/.test(text) &&
      values?.[0] === "session-1"
    ),
    false,
  );
  assert.equal(
    queries.some(({ text, values }) =>
      /UPDATE cli_sessions/.test(text) &&
      /ended_at/.test(text) &&
      values?.[0] === "session-1"
    ),
    false,
  );
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

test("Claude 세션 기록 끝에서 마지막 사용량을 읽는다", () => {
  const directory = mkdtempSync(join(tmpdir(), "office-claude-usage-"));
  try {
    const path = join(directory, "session.jsonl");
    writeFileSync(path, [
      JSON.stringify({
        type: "assistant",
        message: { usage: { input_tokens: 1, output_tokens: 2 } },
      }),
      JSON.stringify({
        type: "assistant",
        message: {
          usage: {
            input_tokens: 11,
            output_tokens: 826,
            cache_read_input_tokens: 635_024,
            cache_creation_input_tokens: 888,
            cache_creation: {
              ephemeral_5m_input_tokens: 0,
              ephemeral_1h_input_tokens: 888,
            },
            service_tier: "standard",
          },
        },
      }),
      JSON.stringify({ type: "user", message: { content: [] } }),
      "",
    ].join("\n"));

    const usage = latestClaudeUsageFromSession(path);

    assert.equal(usage.inputTokens, 11);
    assert.equal(usage.outputTokens, 826);
    assert.equal(usage.cachedInputTokens, 635_024);
    assert.equal(usage.cacheWriteInputTokens, 888);
    assert.equal(usage.cacheWrite1hInputTokens, 888);
    assert.equal(usage.serviceTier, "standard");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("중단된 Claude 턴의 사용량을 세션 기록에서 되살린다", () => {
  withClaudeSessionHome(({ workdir }) => {
    const path = writeClaudeSession(workdir, "session-1");
    writeFileSync(path, `${JSON.stringify({
      type: "assistant",
      message: { usage: { input_tokens: 5, output_tokens: 7 } },
    })}\n`);
    const state = {
      character: { backend: "claude", model: "claude-sonnet-5" },
      workdir,
      externalSessionID: "session-1",
    };

    const usage = recoverInterruptedUsage(state);

    assert.equal(usage.inputTokens, 5);
    assert.equal(state.usage.outputTokens, 7);
  });
});

test("이미 사용량이 있는 턴은 세션 기록으로 덮어쓰지 않는다", () => {
  withClaudeSessionHome(({ workdir }) => {
    const path = writeClaudeSession(workdir, "session-1");
    writeFileSync(path, `${JSON.stringify({
      type: "assistant",
      message: { usage: { input_tokens: 5, output_tokens: 7 } },
    })}\n`);
    const existing = { inputTokens: 99, outputTokens: 99 };
    const state = {
      character: { backend: "claude", model: "claude-sonnet-5" },
      workdir,
      externalSessionID: "session-1",
      usage: existing,
    };

    assert.equal(recoverInterruptedUsage(state), null);
    assert.equal(state.usage, existing);
  });
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

function workspaceDatabaseRow(overrides = {}) {
  return {
    id: "workspace-1",
    cli_session_id: "session-1",
    status: "awaiting_approval",
    repository_root: "/repo",
    source_workdir: "/repo",
    worktree_path: "/worktrees/workspace-1",
    execution_workdir: "/worktrees/workspace-1",
    branch_name: "officestra/boss/workspace-1",
    base_branch: "main",
    base_commit: "base-commit",
    review_turn_id: "turn-1",
    review_tree: "review-tree",
    head_commit: "head-commit",
    changed_files: [{ status: "M", path: "README.md" }],
    task_commit: null,
    merged_commit: null,
    error_message: null,
    created_at: new Date("2026-08-01T00:00:00Z"),
    updated_at: new Date("2026-08-01T00:00:00Z"),
    review_requested_at: new Date("2026-08-01T00:00:00Z"),
    merged_at: null,
    rejected_at: null,
    characterID: "boss",
    characterName: "보스",
    ...overrides,
  };
}

test("기존 CLI 세션도 새 Git 업무의 격리 작업 공간을 만든다", async () => {
  const queries = [];
  const provisioned = {
    repositoryRoot: "/repo",
    sourceWorkdir: "/repo/subdir",
    worktreePath: "/worktrees/workspace-1",
    executionWorkdir: "/worktrees/workspace-1/subdir",
    branchName: "officestra/boss/workspace-1",
    baseBranch: "main",
    baseCommit: "base-commit",
  };
  const workspaceManager = {
    provision: async (input) => {
      assert.deepEqual(input, {
        workspaceID: "workspace-1",
        characterID: "boss",
      });
      return provisioned;
    },
  };
  const runtime = new AgentRuntime({
    pool: {
      query: async (text, values) => {
        queries.push({ text, values });
        return {
          rowCount: 1,
          rows: [workspaceDatabaseRow({
            status: "active",
            source_workdir: provisioned.sourceWorkdir,
            execution_workdir: provisioned.executionWorkdir,
            review_turn_id: null,
            review_tree: null,
            changed_files: [],
          })],
        };
      },
    },
    withTransaction: async () => {},
    workdir: "/repo/subdir",
    workspaceManager,
    broadcast: () => {},
  });

  const workspace = await runtime.ensureWorkspace({
    turnID: "turn-1",
    sessionID: "session-1",
    workspaceID: "workspace-1",
    reusedSession: true,
    workspace: null,
    character: { id: "boss" },
  });

  assert.equal(workspace.executionWorkdir, provisioned.executionWorkdir);
  assert.match(queries[0].text, /INSERT INTO task_workspaces/);
  assert.deepEqual(queries[0].values.slice(2, -1), [
    provisioned.repositoryRoot,
    provisioned.sourceWorkdir,
    provisioned.worktreePath,
    provisioned.executionWorkdir,
    provisioned.branchName,
    provisioned.baseBranch,
    provisioned.baseCommit,
  ]);
});

test("새 Git 업무는 provisioning을 먼저 기록한 뒤 계획한 worktree를 활성화한다", async () => {
  const events = [];
  const plan = {
    repositoryRoot: "/repo",
    sourceWorkdir: "/repo/subdir",
    worktreePath: "/worktrees/workspace-1",
    executionWorkdir: "/worktrees/workspace-1/subdir",
    branchName: "officestra/boss/workspace-1",
    baseBranch: "main",
    baseCommit: "base-commit",
  };
  const activeRow = workspaceDatabaseRow({
    status: "active",
    source_workdir: plan.sourceWorkdir,
    execution_workdir: plan.executionWorkdir,
    review_turn_id: null,
    review_tree: null,
    changed_files: [],
  });
  const query = async (text, values) => {
    if (/INSERT INTO task_workspaces/.test(text)) {
      events.push("db:provisioning");
      assert.match(text, /'provisioning'/);
      assert.deepEqual(values.slice(2, -1), [
        plan.repositoryRoot,
        plan.sourceWorkdir,
        plan.worktreePath,
        plan.executionWorkdir,
        plan.branchName,
        plan.baseBranch,
        plan.baseCommit,
      ]);
      return { rowCount: 1, rows: [] };
    }
    if (
      /UPDATE task_workspaces/.test(text) &&
      /status = 'active'/.test(text)
    ) {
      events.push("db:active");
      assert.match(text, /AND status = 'provisioning'/);
      return { rowCount: 1, rows: [activeRow] };
    }
    return { rowCount: 1, rows: [] };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async () => {},
    workdir: "/repo/subdir",
    workspaceManager: {
      planProvision: async (input) => {
        events.push("git:plan");
        assert.deepEqual(input, {
          workspaceID: "workspace-1",
          characterID: "boss",
        });
        return plan;
      },
      provisionPlanned: async (receivedPlan) => {
        events.push("git:provision");
        assert.equal(receivedPlan, plan);
        return plan;
      },
      cleanup: async () => {
        assert.fail("정상 provisioning에서는 cleanup을 호출하면 안 됩니다.");
      },
    },
    broadcast: () => {},
  });

  const workspace = await runtime.ensureWorkspace({
    turnID: "turn-1",
    sessionID: "session-1",
    workspaceID: "workspace-1",
    reusedSession: false,
    isolateGitWorkdir: true,
    workspace: null,
    character: { id: "boss" },
  });

  assert.equal(workspace.status, "active");
  assert.equal(workspace.executionWorkdir, plan.executionWorkdir);
  assert.deepEqual(events, [
    "git:plan",
    "db:provisioning",
    "git:provision",
    "db:active",
  ]);
});

test("Git 저장소 확인 뒤 provisioning 계획이 사라지면 공유 폴더로 후퇴하지 않는다", async () => {
  const events = [];
  const runtime = new AgentRuntime({
    pool: { query: async () => ({ rowCount: 1, rows: [] }) },
    withTransaction: async () => {},
    workdir: "/repo",
    workspaceManager: {
      isRepository: async () => {
        events.push("git:is-repository");
        return true;
      },
      planProvision: async () => {
        events.push("git:plan");
        return null;
      },
      provisionPlanned: async () => {
        assert.fail("계획이 없으면 worktree 생성을 시도하면 안 됩니다.");
      },
    },
    broadcast: () => {},
  });
  runtime.prepareTurn = async (input) => {
    events.push("db:prepare-turn");
    assert.equal(input.isolateGitWorkdir, true);
    return {
      turnID: "turn-1",
      sessionID: "session-1",
      workspaceID: "workspace-1",
      conversationID: input.conversationID,
      externalSessionID: null,
      character: { id: "boss", backend: "codex" },
      prompt: input.prompt,
      workspace: null,
      reusedSession: false,
      isolateGitWorkdir: true,
    };
  };
  runtime.failPreparedTurn = async (_prepared, error) => {
    events.push("db:fail-prepared-turn");
    assert.equal(error.code, "invalid-state");
  };

  await assert.rejects(
    runtime.start({
      characterID: "boss",
      prompt: "업무",
      conversationID: "11111111-1111-1111-1111-111111111111",
    }),
    (error) => error?.code === "invalid-state",
  );

  assert.deepEqual(events, [
    "git:is-repository",
    "db:prepare-turn",
    "git:plan",
    "db:fail-prepared-turn",
  ]);
  assert.equal(runtime.running.size, 0);
});

test("완료된 변경 업무는 검토 tree와 파일 목록을 승인 대기로 저장한다", async () => {
  const queries = [];
  const broadcasts = [];
  const review = {
    hasChanges: true,
    reviewTree: "review-tree",
    headCommit: "head-commit",
    changedFiles: [{ status: "M", path: "README.md" }],
  };
  const query = async (text, values) => {
    queries.push({ text, values });
    return { rowCount: 1 };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/repo",
    workspaceManager: {
      prepareReview: async () => review,
    },
    broadcast: (event) => broadcasts.push(event),
  });
  const state = {
    ...makeCodexActivityState(),
    sessionID: "session-1",
    character: {
      id: "boss",
      backend: "codex",
      model: "gpt-5.6-sol",
      fastMode: true,
    },
    workspace: {
      ...workspaceDatabaseRow({ status: "active" }),
      id: "workspace-1",
      cliSessionID: "session-1",
      repositoryRoot: "/repo",
      sourceWorkdir: "/repo",
      worktreePath: "/worktrees/workspace-1",
      executionWorkdir: "/worktrees/workspace-1",
      branchName: "officestra/boss/workspace-1",
      baseBranch: "main",
      baseCommit: "base-commit",
    },
    initialGeneratedImages: new Set(),
    externalSessionID: null,
    responseText: "완료했습니다.",
    visibleAgentMessages: [{ key: "message-1", text: "완료했습니다." }],
    usage: null,
    cancelRequested: false,
  };
  runtime.running.set("boss", state);

  await runtime.complete(state, {
    text: "완료했습니다.",
    needsInput: false,
  });

  const workspaceUpdate = queries.find(({ text }) =>
    /UPDATE task_workspaces/.test(text)
  );
  assert.equal(workspaceUpdate.values[1], "awaiting_approval");
  assert.equal(workspaceUpdate.values[2], true);
  assert.equal(workspaceUpdate.values[3], "turn-1");
  assert.equal(workspaceUpdate.values[4], "review-tree");
  assert.equal(state.workspace.status, "awaiting_approval");
  assert.equal(
    broadcasts.some((event) =>
      event.type === "workspace.changed" &&
      event.status === "awaiting_approval"
    ),
    true,
  );
});

test("사용자 답이 필요한 완료 턴은 workspace 검토를 시작하지 않는다", async () => {
  let reviewCount = 0;
  const query = async () => ({ rowCount: 1 });
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/repo",
    workspaceManager: {
      prepareReview: async () => {
        reviewCount += 1;
        return { hasChanges: true };
      },
    },
    broadcast: () => {},
  });
  const state = {
    ...makeCodexActivityState(),
    sessionID: "session-1",
    character: {
      id: "boss",
      backend: "codex",
      model: "gpt-5.6-sol",
      fastMode: true,
    },
    workspace: { status: "active" },
    initialGeneratedImages: new Set(),
    externalSessionID: null,
    responseText: "선택해 주세요.",
    visibleAgentMessages: [{ key: "message-1", text: "선택해 주세요." }],
    usage: null,
    cancelRequested: false,
  };
  runtime.running.set("boss", state);

  await runtime.complete(state, {
    text: "선택해 주세요.",
    needsInput: true,
  });

  assert.equal(reviewCount, 0);
  assert.equal(state.workspace.status, "active");
});

test("provider 전환 전에 변경이 있으면 검토 대기로 바꾸고 세션 종료를 막는다", async () => {
  const queries = [];
  const broadcasts = [];
  let cleanupCount = 0;
  const row = workspaceDatabaseRow({
    status: "active",
    review_turn_id: null,
    review_tree: null,
    changed_files: [],
    reviewCandidateTurnID: "turn-1",
  });
  const query = async (text, values) => {
    queries.push({ text, values });
    if (/FROM turns AS turn/.test(text) && /turn\.status IN/.test(text)) {
      return { rowCount: 0, rows: [] };
    }
    if (
      /FROM task_workspaces AS workspace/.test(text) &&
      /reviewCandidateTurnID/.test(text)
    ) {
      return { rowCount: 1, rows: [row] };
    }
    return { rowCount: 1, rows: [] };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/repo",
    workspaceManager: {
      prepareReview: async () => ({
        hasChanges: true,
        reviewTree: "provider-review-tree",
        headCommit: "provider-head-commit",
        changedFiles: [{ status: "M", path: "README.md" }],
      }),
      cleanup: async () => {
        cleanupCount += 1;
      },
    },
    broadcast: (event) => broadcasts.push(event),
  });

  await assert.rejects(
    runtime.prepareWorkspaceForSessionEnd("boss"),
    AgentBusyError,
  );

  const reviewUpdate = queries.find(({ text, values }) =>
    /UPDATE task_workspaces/.test(text) &&
    values?.includes("provider-review-tree")
  );
  assert.ok(reviewUpdate);
  assert.match(reviewUpdate.text, /status\s*=\s*'awaiting_approval'/);
  assert.equal(
    queries.some(({ text }) => /DELETE FROM active_cli_sessions/.test(text)),
    false,
  );
  assert.equal(cleanupCount, 0);
  assert.equal(
    broadcasts.some((event) =>
      event.type === "workspace.changed" &&
      event.status === "awaiting_approval"
    ),
    true,
  );
});

test("provider 전환 전 변경이 없으면 세션과 빈 worktree를 정리한다", async () => {
  const queries = [];
  const cleaned = [];
  const row = workspaceDatabaseRow({
    status: "active",
    review_turn_id: null,
    review_tree: null,
    changed_files: [],
    reviewCandidateTurnID: "turn-1",
  });
  const query = async (text, values) => {
    queries.push({ text, values });
    if (/FROM turns AS turn/.test(text) && /turn\.status IN/.test(text)) {
      return { rowCount: 0, rows: [] };
    }
    if (
      /FROM task_workspaces AS workspace/.test(text) &&
      /reviewCandidateTurnID/.test(text)
    ) {
      return { rowCount: 1, rows: [row] };
    }
    return { rowCount: 1, rows: [] };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/repo",
    workspaceManager: {
      prepareReview: async () => ({
        hasChanges: false,
        reviewTree: "base-tree",
        headCommit: "base-commit",
        changedFiles: [],
      }),
      cleanup: async (workspace) => {
        cleaned.push(workspace);
      },
    },
    broadcast: () => {},
  });

  const result = await runtime.prepareWorkspaceForSessionEnd("boss");

  assert.deepEqual(result, { ended: true });
  assert.equal(
    queries.some(({ text }) => /DELETE FROM active_cli_sessions/.test(text)),
    true,
  );
  assert.equal(
    queries.some(({ text }) =>
      /UPDATE cli_sessions/.test(text) && /ended_at/.test(text)
    ),
    true,
  );
  assert.equal(cleaned.length, 1);
  assert.equal(cleaned[0].cliSessionID, "session-1");
});

test("provider 전환 때 활성 workspace가 없으면 종료할 세션이 없다고 알린다", async () => {
  let cleanupCount = 0;
  const query = async () => ({ rowCount: 0, rows: [] });
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/repo",
    workspaceManager: {
      cleanup: async () => {
        cleanupCount += 1;
      },
    },
    broadcast: () => {},
  });

  assert.deepEqual(
    await runtime.prepareWorkspaceForSessionEnd("boss"),
    { ended: false },
  );
  assert.equal(cleanupCount, 0);
});

test("검토 대기 변경이 base tree로 돌아오면 fetch가 active 상태를 복원한다", async () => {
  const queries = [];
  const broadcasts = [];
  const reviewedRow = workspaceDatabaseRow();
  const activeRow = workspaceDatabaseRow({
    status: "active",
    review_turn_id: null,
    review_tree: null,
    head_commit: "base-commit",
    changed_files: [],
    review_requested_at: null,
  });
  let diffWorkspace;
  const query = async (text, values) => {
    queries.push({ text, values });
    if (
      /UPDATE task_workspaces/.test(text) &&
      /status = 'active'/.test(text) &&
      /review_turn_id = NULL/.test(text)
    ) {
      return { rowCount: 1, rows: [activeRow] };
    }
    if (/FROM task_workspaces AS workspace/.test(text)) {
      return { rowCount: 1, rows: [reviewedRow] };
    }
    return { rowCount: 0, rows: [] };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/repo",
    workspaceManager: {
      prepareReview: async (workspace) => {
        assert.equal(workspace.status, "awaiting_approval");
        assert.equal(workspace.reviewTree, "review-tree");
        return {
          hasChanges: false,
          reviewTree: "base-tree",
          headCommit: "base-commit",
          changedFiles: [],
        };
      },
      diff: async (workspace) => {
        diffWorkspace = workspace;
        return { diff: "", diffTruncated: false };
      },
    },
    broadcast: (event) => broadcasts.push(event),
  });

  const result = await runtime.fetchWorkspaceReview("turn-1");

  assert.equal(result.workspace.status, "active");
  assert.equal(result.workspace.reviewTurnId, null);
  assert.equal(result.workspace.reviewTree, null);
  assert.deepEqual(result.workspace.changedFiles, []);
  assert.equal(diffWorkspace.status, "active");
  assert.equal(diffWorkspace.reviewTurnID, null);
  assert.equal(diffWorkspace.reviewTree, null);
  const released = queries.find(({ text }) =>
    /review_turn_id = NULL/.test(text) && /review_tree = NULL/.test(text)
  );
  assert.ok(released);
  assert.deepEqual(released.values, [
    "workspace-1",
    "base-commit",
    "review-tree",
  ]);
  assert.deepEqual(broadcasts, [{
    type: "workspace.changed",
    turnId: "turn-1",
    characterId: "boss",
    status: "active",
  }]);
});

test("승인은 저장소 advisory lock 뒤 병합하고 활성 세션을 유지한다", async () => {
  const queries = [];
  const calls = [];
  const row = workspaceDatabaseRow();
  const query = async (text, values) => {
    queries.push({ text, values });
    if (/FROM task_workspaces AS workspace/.test(text)) {
      return { rowCount: 1, rows: [row] };
    }
    if (/RETURNING id/.test(text)) {
      return { rowCount: 1, rows: [{ id: "workspace-1" }] };
    }
    return { rowCount: 1, rows: [] };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/repo",
    workspaceManager: {
      approve: async (workspace, options) => {
        calls.push({ kind: "approve", workspace, options });
        return {
          taskCommit: "task-commit",
          mergedCommit: "merged-commit",
        };
      },
      cleanup: async (workspace) => {
        calls.push({ kind: "cleanup", workspace });
      },
    },
    broadcast: () => {},
  });

  const result = await runtime.approveWorkspace("turn-1", "review-tree");

  assert.equal(result.workspace.status, "merged");
  assert.equal(result.workspace.mergedCommit, "merged-commit");
  assert.equal(calls[0].options.expectedReviewTree, "review-tree");
  assert.equal(calls[1].kind, "cleanup");
  assert.equal(
    queries.some(({ text, values }) =>
      /pg_advisory_xact_lock/.test(text) && values[0] === "/repo"
    ),
    true,
  );
  assert.equal(
    queries.some(({ text }) => /DELETE FROM active_cli_sessions/.test(text)),
    false,
  );
  assert.equal(
    queries.some(({ text }) =>
      /UPDATE cli_sessions/.test(text) && /ended_at/.test(text)
    ),
    false,
  );
});

test("충돌 상태는 같은 review tree로 다시 병합할 수 있다", async () => {
  const queries = [];
  const calls = [];
  const row = workspaceDatabaseRow({ status: "conflict" });
  const query = async (text, values) => {
    queries.push({ text, values });
    if (/FROM task_workspaces AS workspace/.test(text)) {
      return { rowCount: 1, rows: [row] };
    }
    if (/RETURNING id/.test(text)) {
      return { rowCount: 1, rows: [{ id: "workspace-1" }] };
    }
    return { rowCount: 1, rows: [] };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/repo",
    workspaceManager: {
      approve: async (workspace, options) => {
        calls.push({ workspace, options });
        return {
          taskCommit: "retried-task-commit",
          mergedCommit: "retried-merged-commit",
        };
      },
      cleanup: async () => {},
    },
    broadcast: () => {},
  });

  const result = await runtime.approveWorkspace("turn-1", "review-tree");

  assert.equal(result.workspace.status, "merged");
  assert.equal(result.workspace.mergedCommit, "retried-merged-commit");
  assert.equal(calls[0].options.expectedReviewTree, "review-tree");
  assert.equal(
    queries.some(({ text }) =>
      /status IN \('awaiting_approval', 'conflict'\)/.test(text)
    ),
    true,
  );
});

test("충돌 재시도의 stale tree 오류는 충돌 상태를 유지한다", async () => {
  const queries = [];
  const broadcasts = [];
  const row = workspaceDatabaseRow({ status: "conflict" });
  const query = async (text, values) => {
    queries.push({ text, values });
    if (/FROM task_workspaces AS workspace/.test(text)) {
      return { rowCount: 1, rows: [row] };
    }
    if (/RETURNING\s+session\.character_id/s.test(text)) {
      return {
        rowCount: 1,
        rows: [{ characterID: "boss", status: "conflict" }],
      };
    }
    return { rowCount: 1, rows: [] };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/repo",
    workspaceManager: {
      approve: async () => {
        assert.fail("stale review tree는 Git 병합을 시작하면 안 됩니다.");
      },
    },
    broadcast: (event) => broadcasts.push(event),
  });

  await assert.rejects(
    runtime.approveWorkspace("turn-1", "stale-review-tree"),
    AgentBusyError,
  );

  assert.equal(
    queries.some(({ text }) => /UPDATE task_workspaces AS workspace/.test(text)),
    false,
  );
  assert.deepEqual(broadcasts, []);
});

test("승인은 사용자가 실제로 확인한 review tree가 아니면 병합을 시작하지 않는다", async () => {
  const queries = [];
  let approveCount = 0;
  const query = async (text, values) => {
    queries.push({ text, values });
    if (/FROM task_workspaces AS workspace/.test(text)) {
      return { rowCount: 1, rows: [workspaceDatabaseRow()] };
    }
    return { rowCount: 1, rows: [] };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/repo",
    workspaceManager: {
      approve: async () => {
        approveCount += 1;
      },
    },
    broadcast: () => {},
  });

  await assert.rejects(
    runtime.approveWorkspace("turn-1", "stale-review-tree"),
    AgentBusyError,
  );

  assert.equal(approveCount, 0);
  assert.equal(
    queries.some(({ text }) => /status = 'merging'/.test(text)),
    false,
  );
});

test("검토 뒤 tree가 바뀌면 새 diff 메타데이터를 저장하고 재승인을 요구한다", async () => {
  const queries = [];
  const changedError = new Error("검토 뒤 변경사항이 달라졌습니다.");
  changedError.code = "changed-after-review";
  const query = async (text, values) => {
    queries.push({ text, values });
    if (/FROM task_workspaces AS workspace/.test(text)) {
      return { rowCount: 1, rows: [workspaceDatabaseRow()] };
    }
    if (/RETURNING id/.test(text)) {
      return { rowCount: 1, rows: [{ id: "workspace-1" }] };
    }
    return { rowCount: 1, rows: [] };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/repo",
    workspaceManager: {
      approve: async () => {
        throw changedError;
      },
      prepareReview: async () => ({
        hasChanges: true,
        reviewTree: "new-review-tree",
        headCommit: "new-head-commit",
        changedFiles: [{ status: "A", path: "new.txt" }],
      }),
    },
    broadcast: () => {},
  });

  await assert.rejects(
    runtime.approveWorkspace("turn-1", "review-tree"),
    (error) => error === changedError,
  );

  const refreshed = queries.find(({ text, values }) =>
    /review_tree = CASE WHEN \$7 THEN \$2 ELSE NULL END/.test(text) &&
    values?.[1] === "new-review-tree"
  );
  assert.ok(refreshed);
  assert.equal(refreshed.values[2], "new-head-commit");
  assert.equal(refreshed.values[3], JSON.stringify([
    { status: "A", path: "new.txt" },
  ]));
});

test("검토 갱신 오류는 동시에 거절된 workspace를 다시 승인 대기로 만들지 않는다", async () => {
  const changedError = new Error("검토 뒤 변경사항이 달라졌습니다.");
  changedError.code = "changed-after-review";
  let workspaceStatus = "rejected";
  const query = async (text) => {
    if (/FROM task_workspaces AS workspace/.test(text)) {
      return {
        rowCount: 1,
        rows: [workspaceDatabaseRow({ status: workspaceStatus })],
      };
    }
    if (/UPDATE task_workspaces/.test(text)) {
      const whereClause = text.split(/\bWHERE\b/i).slice(1).join(" WHERE ");
      const guardsReviewableStatus =
        /status\s+(?:=|IN\b)/.test(whereClause) &&
        /'awaiting_approval'/.test(whereClause);
      const isReviewable = [
        "awaiting_approval",
        "conflict",
      ].includes(workspaceStatus);
      if (!guardsReviewableStatus || isReviewable) {
        workspaceStatus = "awaiting_approval";
        return { rowCount: 1, rows: [] };
      }
      return { rowCount: 0, rows: [] };
    }
    return { rowCount: 1, rows: [] };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/repo",
    workspaceManager: {
      prepareReview: async () => ({
        hasChanges: true,
        reviewTree: "new-review-tree",
        headCommit: "new-head-commit",
        changedFiles: [{ status: "A", path: "new.txt" }],
      }),
    },
    broadcast: () => {},
  });

  await runtime.recordWorkspaceApprovalError("turn-1", changedError);

  assert.equal(workspaceStatus, "rejected");
});

test("충돌한 workspace를 거절해도 세션을 유지하고 worktree는 보존한다", async () => {
  const queries = [];
  const query = async (text, values) => {
    queries.push({ text, values });
    if (/FROM task_workspaces AS workspace/.test(text)) {
      return {
        rowCount: 1,
        rows: [workspaceDatabaseRow({ status: "conflict" })],
      };
    }
    if (/RETURNING id/.test(text)) {
      return { rowCount: 1, rows: [{ id: "workspace-1" }] };
    }
    return { rowCount: 1, rows: [] };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/repo",
    broadcast: () => {},
  });

  const result = await runtime.rejectWorkspace("turn-1");

  assert.equal(result.workspace.status, "rejected");
  assert.equal(
    queries.some(({ text }) => /DELETE FROM active_cli_sessions/.test(text)),
    false,
  );
  assert.equal(
    queries.some(({ text }) => /worktree remove|DELETE FROM task_workspaces/.test(text)),
    false,
  );
});

test("worktree가 없는 활성 CLI 세션은 종료하지 않고 다음 업무에 재사용한다", async () => {
  const queries = [];
  const query = async (text, values) => {
    queries.push({ text, values });
    if (/FROM characters/.test(text)) {
      return {
        rowCount: 1,
        rows: [{
          id: "boss",
          name: "보스",
          backend: "codex",
          model: "gpt-5.6-sol",
          effort: "high",
          fastMode: true,
          permission: "workspace-write",
          identityPrompt: "업무를 처리한다.",
          config: {},
        }],
      };
    }
    if (/turn\.status IN/.test(text)) {
      return { rowCount: 0, rows: [] };
    }
    if (/SELECT workspace\.review_turn_id/.test(text)) {
      return { rowCount: 0, rows: [] };
    }
    if (/FROM active_cli_sessions AS active/.test(text)) {
      return {
        rowCount: 1,
        rows: [{
          id: "session-1",
          externalSessionID: "external-1",
          conversationID: "11111111-1111-1111-1111-111111111111",
          workspaceID: null,
          workspaceStatus: null,
        }],
      };
    }
    return { rowCount: 1, rows: [] };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/repo",
    broadcast: () => {},
  });

  const prepared = await runtime.prepareTurn({
    characterID: "boss",
    prompt: "다음 업무",
    conversationID: "22222222-2222-2222-2222-222222222222",
    isolateGitWorkdir: true,
  });

  assert.equal(prepared.sessionID, "session-1");
  assert.equal(prepared.externalSessionID, "external-1");
  assert.equal(prepared.reusedSession, true);
  assert.equal(prepared.workspace, null);
  assert.equal(
    queries.some(({ text }) => /DELETE FROM active_cli_sessions/.test(text)),
    false,
  );
  assert.equal(
    queries.some(({ text }) =>
      /UPDATE cli_sessions/.test(text) && /ended_at/.test(text)
    ),
    false,
  );
});

test("검토 대기 workspace가 있으면 같은 직원의 다음 턴을 차단한다", async () => {
  const queries = [];
  const query = async (text, values) => {
    queries.push({ text, values });
    if (/FROM characters/.test(text)) {
      return {
        rowCount: 1,
        rows: [{
          id: "boss",
          name: "보스",
          backend: "codex",
          model: "gpt-5.6-sol",
          effort: "high",
          fastMode: true,
          permission: "workspace-write",
          identityPrompt: "업무를 처리한다.",
          config: {},
        }],
      };
    }
    if (/turn\.status IN/.test(text)) {
      return { rowCount: 0, rows: [] };
    }
    if (/FROM active_cli_sessions AS active/.test(text)) {
      return {
        rowCount: 1,
        rows: [{
          id: "session-1",
          externalSessionID: "external-1",
          conversationID: "11111111-1111-1111-1111-111111111111",
          workspaceStatus: "awaiting_approval",
        }],
      };
    }
    return { rowCount: 1, rows: [] };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/repo",
    broadcast: () => {},
  });

  await assert.rejects(
    runtime.prepareTurn({
      characterID: "boss",
      prompt: "다음 업무",
      conversationID: "11111111-1111-1111-1111-111111111111",
    }),
    AgentBusyError,
  );
  assert.match(queries[0].text, /pg_advisory_xact_lock/);
  assert.deepEqual(queries[0].values, ["officestra:character:boss"]);
});

test("외부 CLI 세션 ID가 없어도 직원의 검토 대기 workspace가 다음 턴을 막는다", async () => {
  const query = async (text) => {
    if (/FROM characters/.test(text)) {
      return {
        rowCount: 1,
        rows: [{
          id: "boss",
          name: "보스",
          backend: "codex",
          model: "gpt-5.6-sol",
          effort: "high",
          fastMode: true,
          permission: "workspace-write",
          identityPrompt: "업무를 처리한다.",
          config: {},
        }],
      };
    }
    if (/turn\.status IN/.test(text)) {
      return { rowCount: 0, rows: [] };
    }
    if (
      /FROM task_workspaces/.test(text) &&
      /character_id/.test(text) &&
      !/active_cli_sessions/.test(text)
    ) {
      return {
        rowCount: 1,
        rows: [{ status: "awaiting_approval" }],
      };
    }
    if (/FROM active_cli_sessions AS active/.test(text)) {
      return { rowCount: 0, rows: [] };
    }
    if (/INSERT INTO cli_sessions/.test(text)) {
      return { rowCount: 1, rows: [{ id: "unexpected-session" }] };
    }
    return { rowCount: 0, rows: [] };
  };
  const runtime = new AgentRuntime({
    pool: { query },
    withTransaction: async (body) => body({ query }),
    workdir: "/repo",
    broadcast: () => {},
  });

  await assert.rejects(
    runtime.prepareTurn({
      characterID: "boss",
      prompt: "다음 업무",
      conversationID: "11111111-1111-1111-1111-111111111111",
    }),
    AgentBusyError,
  );
});

test("실시간 피드 쿼리는 최근 제한 밖의 미해결 workspace 검토 턴도 고정한다", () => {
  const serverSource = readFileSync(
    new URL("../src/server.mjs", import.meta.url),
    "utf8",
  );
  const queryStart = serverSource.indexOf("async function queryLiveFeed");
  const queryEnd = serverSource.indexOf(
    "async function workspaceReview",
    queryStart,
  );
  assert.ok(queryStart >= 0 && queryEnd > queryStart);
  const querySource = serverSource.slice(queryStart, queryEnd);

  assert.match(querySource, /UNION[\s\S]*task_workspace\.review_turn_id/);
  assert.match(querySource, /task_workspace\.id = t\.task_workspace_id/);
  assert.doesNotMatch(
    querySource,
    /task_workspace\.cli_session_id = s\.id/,
  );
  for (const status of ["awaiting_approval", "merging", "conflict"]) {
    assert.match(querySource, new RegExp(`'${status}'`));
  }
});
