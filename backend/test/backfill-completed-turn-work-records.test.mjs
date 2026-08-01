// 이 파일은 완료 턴 백필 범위와 시간·검토 상태 복원이 안전한지 검증한다.

import assert from "node:assert/strict";
import test from "node:test";

import {
  backfillCompletedTurnWorkRecords,
  listMissingCompletedTurnWorkRecords,
  parseBackfillCompletedTurnArguments,
  restoredReviewStatus,
} from "../src/backfill-completed-turn-work-records.mjs";

const SCOPE_ARGUMENTS = [
  "--repository-root",
  "/repo",
  "--from",
  "2026-08-01T11:08:35.312702Z",
  "--before",
  "2026-08-01T13:24:20.335199Z",
  "--expected-count",
  "12",
];

function scopeArgumentsWith(index, value) {
  return SCOPE_ARGUMENTS.map((argument, currentIndex) =>
    currentIndex === index ? value : argument);
}

test("백필 CLI는 실행 모드와 고정 범위를 모두 요구한다", () => {
  assert.deepEqual(
    parseBackfillCompletedTurnArguments(["--dry-run", ...SCOPE_ARGUMENTS]),
    {
      help: false,
      mode: "dry-run",
      repositoryRoot: "/repo",
      from: "2026-08-01T11:08:35.312702Z",
      before: "2026-08-01T13:24:20.335199Z",
      expectedCount: 12,
    },
  );
  assert.deepEqual(
    parseBackfillCompletedTurnArguments(["--help"]),
    { help: true },
  );

  const invalidCases = [
    { argumentsList: SCOPE_ARGUMENTS, pattern: /--dry-run 또는 --apply/ },
    {
      argumentsList: ["--dry-run", "--apply", ...SCOPE_ARGUMENTS],
      pattern: /하나만 지정/,
    },
    {
      argumentsList: [
        "--apply",
        ...scopeArgumentsWith(1, "relative/repo"),
      ],
      pattern: /절대경로/,
    },
    {
      argumentsList: [
        "--apply",
        ...scopeArgumentsWith(5, "2026-08-01T10:00:00Z"),
      ],
      pattern: /앞선 시각/,
    },
    {
      argumentsList: [
        "--apply",
        ...scopeArgumentsWith(7, "0"),
      ],
      pattern: /1 이상의 정수/,
    },
    {
      argumentsList: ["--help", "--apply", ...SCOPE_ARGUMENTS],
      pattern: /다른 옵션과 함께/,
    },
    {
      argumentsList: ["--apply", ...SCOPE_ARGUMENTS, "--unknown", "x"],
      pattern: /알 수 없는 옵션/,
    },
  ];
  for (const { argumentsList, pattern } of invalidCases) {
    assert.throws(
      () => parseBackfillCompletedTurnArguments(argumentsList),
      pattern,
      JSON.stringify(argumentsList),
    );
  }
});

test("검토 상태는 현재 workspace가 아니라 해당 검토 턴 일치 여부로 복원한다", () => {
  assert.equal(restoredReviewStatus({ needsInput: true }), "needs_input");
  assert.equal(restoredReviewStatus({ turnID: "turn-1" }), "not_applicable");
  assert.equal(restoredReviewStatus({
    turnID: "turn-1",
    workspaceID: "workspace-1",
    workspaceStatus: "merged",
    reviewTurnID: "later-turn",
    changedFiles: [{ path: "README.md", status: "M" }],
  }), "not_required");
  assert.equal(restoredReviewStatus({
    turnID: "turn-1",
    workspaceID: "workspace-1",
    workspaceStatus: "merged",
    reviewTurnID: "turn-1",
    changedFiles: [{ path: "README.md", status: "M" }],
  }), "awaiting_approval");
  assert.equal(restoredReviewStatus({
    turnID: "turn-1",
    workspaceID: "workspace-1",
    workspaceStatus: "active",
    reviewTurnID: null,
    changedFiles: [],
  }), "not_required");
});

test("후보 조회는 완료된 최종 message와 명시된 저장소·시간 범위만 사용한다", async () => {
  const queries = [];
  const client = {
    query: async (text, values) => {
      queries.push({ text, values });
      return { rows: [{ turnID: "turn-1" }], rowCount: 1 };
    },
  };
  const candidates = await listMissingCompletedTurnWorkRecords(client, {
    repositoryRoot: "/repo",
    from: "2026-08-01T11:08:35.312702Z",
    before: "2026-08-01T13:24:20.335199Z",
  });

  assert.deepEqual(candidates, [{ turnID: "turn-1" }]);
  assert.equal(queries.length, 1);
  assert.deepEqual(queries[0].values, [
    "/repo",
    "2026-08-01T11:08:35.312702Z",
    "2026-08-01T13:24:20.335199Z",
  ]);
  assert.match(queries[0].text, /activity\.kind = 'message'/);
  assert.match(queries[0].text, /activity\.status = 'completed'/);
  assert.match(queries[0].text, /turn\.ended_at >= \$2/);
  assert.match(queries[0].text, /turn\.ended_at < \$3/);
  assert.match(queries[0].text, /NOT EXISTS \(/);
  assert.doesNotMatch(queries[0].text, /messages AS/);
});

function candidate(overrides = {}) {
  return {
    turnID: "turn-1",
    prompt: "기록을 복원해줘",
    response: "복원했습니다.",
    recordedAt: "2026-08-01 11:34:14.123456+00",
    backend: "codex",
    model: "gpt-5.6-sol",
    needsInput: false,
    responseSourceWarning: null,
    responseSourceCount: 0,
    characterID: "boss",
    workspaceID: "workspace-1",
    workspaceStatus: "merged",
    reviewTurnID: "turn-1",
    reviewTree: "tree-1",
    headCommit: "head-1",
    changedFiles: [{ path: "README.md", status: "M" }],
    taskCommit: "task-1",
    mergedCommit: "merge-1",
    mergedAt: "2026-08-01 11:35:00.000001+00",
    rejectedAt: null,
    ...overrides,
  };
}

test("백필은 기록 시각과 최종 검토 상태를 복원하고 앞선 무변경 턴은 분리한다", async () => {
  const candidates = [
    candidate(),
    candidate({
      turnID: "turn-2",
      workspaceID: "workspace-2",
      reviewTurnID: "later-turn",
      recordedAt: "2026-08-01 11:40:00.000002+00",
    }),
    candidate({
      turnID: "turn-3",
      workspaceID: "workspace-3",
      workspaceStatus: "rejected",
      reviewTurnID: "turn-3",
      mergedAt: null,
      rejectedAt: "2026-08-01 11:50:00.000003+00",
      recordedAt: "2026-08-01 11:45:00.000003+00",
      taskCommit: null,
      mergedCommit: null,
    }),
  ];
  const queries = [];
  let inserted = 0;
  const client = {
    query: async (text, values) => {
      queries.push({ text, values });
      if (/FROM turns AS turn/.test(text)) {
        return { rows: candidates, rowCount: candidates.length };
      }
      if (/WITH selected_project AS/.test(text)) {
        inserted += 1;
        return {
          rows: [{ workRecordId: `record-${inserted}` }],
          rowCount: 1,
        };
      }
      if (/WITH updated_record AS/.test(text)) {
        return { rows: [{ workRecordId: "transitioned" }], rowCount: 1 };
      }
      return { rows: [], rowCount: 0 };
    },
  };

  const result = await backfillCompletedTurnWorkRecords(client, {
    repositoryRoot: "/repo",
    from: "2026-08-01T11:08:35.312702Z",
    before: "2026-08-01T13:24:20.335199Z",
    expectedCount: 3,
  });

  assert.equal(result.backfilled, 3);
  assert.equal(result.transitioned, 2);
  assert.deepEqual(result.workRecordIDs, ["record-1", "record-2", "record-3"]);
  const recordQueries = queries.filter(({ text }) =>
    /WITH selected_project AS/.test(text));
  assert.equal(recordQueries.length, 3);
  assert.equal(recordQueries[0].values[8], candidates[0].recordedAt);
  assert.equal(recordQueries[1].values[8], candidates[1].recordedAt);
  assert.equal(
    JSON.parse(recordQueries[0].values[7]).review.status,
    "awaiting_approval",
  );
  assert.equal(
    JSON.parse(recordQueries[1].values[7]).review.status,
    "not_required",
  );
  assert.equal(
    JSON.parse(recordQueries[2].values[7]).review.status,
    "awaiting_approval",
  );
  const transitionQueries = queries.filter(({ text }) =>
    /WITH updated_record AS/.test(text));
  assert.equal(transitionQueries.length, 2);
  assert.equal(transitionQueries[0].values[1], "merged");
  assert.equal(transitionQueries[0].values[5], candidates[0].mergedAt);
  assert.equal(transitionQueries[1].values[1], "rejected");
  assert.equal(transitionQueries[1].values[5], candidates[2].rejectedAt);
});

test("백필은 후보 수나 필수 최종 메시지가 다르면 쓰기 전에 중단한다", async () => {
  const makeClient = (rows) => {
    let writeCount = 0;
    return {
      get writeCount() {
        return writeCount;
      },
      query: async (text) => {
        if (/FROM turns AS turn/.test(text)) {
          return { rows, rowCount: rows.length };
        }
        if (/WITH selected_project AS/.test(text)) {
          writeCount += 1;
        }
        return { rows: [], rowCount: 0 };
      },
    };
  };
  const scope = {
    repositoryRoot: "/repo",
    from: "2026-08-01T11:08:35.312702Z",
    before: "2026-08-01T13:24:20.335199Z",
    expectedCount: 2,
  };

  const wrongCountClient = makeClient([candidate()]);
  await assert.rejects(
    backfillCompletedTurnWorkRecords(wrongCountClient, scope),
    /예상 2개와 다릅니다/,
  );
  assert.equal(wrongCountClient.writeCount, 0);

  const invalidClient = makeClient([
    candidate(),
    candidate({ turnID: "turn-2", response: null }),
  ]);
  await assert.rejects(
    backfillCompletedTurnWorkRecords(invalidClient, scope),
    /최종 공개 메시지 값이 없습니다/,
  );
});
