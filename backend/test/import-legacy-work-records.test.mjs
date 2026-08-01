// 이 파일은 v1.0.0 작업 기록의 파싱과 dry-run 및 멱등 경로를 검증한다.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  LEGACY_EXPECTED_COUNTS,
  LEGACY_SOURCE_COMMIT,
  LegacyWorkRecordImportError,
  applyLegacyImport,
  legacyStoredContent,
  loadLegacyImportPlan,
  pairLegacySections,
  parseBlamePorcelain,
  parseImportMode,
  parseLegacySections,
} from "../src/import-legacy-work-records.mjs";

const importerPath = fileURLToPath(
  new URL("../src/import-legacy-work-records.mjs", import.meta.url),
);
const actualPlanPromise = loadLegacyImportPlan();

function completedImportClient(plan, mutateStoredContent = null) {
  const stored = structuredClone(legacyStoredContent(plan));
  mutateStoredContent?.(stored);
  const queries = [];
  const result = (rows) => ({ rowCount: rows.length, rows });
  return {
    queries,
    client: {
      async query(sql, parameters = []) {
        const compact = sql.replace(/\s+/g, " ").trim();
        queries.push({ sql: compact, parameters });
        if (compact.startsWith("SELECT to_regclass")) {
          return result([{
            table_0: "projects",
            table_1: "work_record_imports",
            table_2: "work_records",
            table_3: "work_record_items",
            table_4: "work_record_links",
            table_5: "work_record_events",
          }]);
        }
        if (compact.startsWith("SELECT id FROM characters")) {
          return result(parameters[0].map((id) => ({ id })));
        }
        if (compact.startsWith("INSERT INTO projects")) {
          return result([]);
        }
        if (compact.startsWith("SELECT id FROM projects")) {
          return result([{ id: "project-id" }]);
        }
        if (compact.startsWith("INSERT INTO work_record_imports")) {
          return result([]);
        }
        if (compact.startsWith(
          "SELECT id, status, parser_version, source_counts",
        )) {
          return result([{
            id: "import-id",
            status: "completed",
            parser_version: plan.parserVersion,
            source_counts: {
              ...plan.counts,
              contentDigest: plan.contentDigest,
            },
          }]);
        }
        if (compact.startsWith("SELECT status, parser_version AS")) {
          return result([{
            status: "completed",
            parserVersion: plan.parserVersion,
            sourceCounts: {
              ...plan.counts,
              contentDigest: plan.contentDigest,
            },
          }]);
        }
        if (compact.includes("FROM work_record_items AS item")) {
          return result(stored.items);
        }
        if (compact.includes("FROM work_record_links AS link")) {
          return result(stored.links);
        }
        if (compact.includes("FROM work_record_events AS event")) {
          return result(stored.events);
        }
        if (
          compact.includes("FROM work_records") &&
          compact.includes("WHERE import_id = $1")
        ) {
          return result(stored.records);
        }
        throw new Error(`예상하지 않은 SQL ${compact}`);
      },
    },
  };
}

test("CLI는 dry-run과 apply 중 하나를 명시해야 한다", () => {
  assert.equal(parseImportMode(["--dry-run"]), "dry-run");
  assert.equal(parseImportMode(["--apply"]), "apply");
  for (const argumentsList of [
    [],
    ["--dry-run", "--apply"],
    ["--apply", "--apply"],
    ["--unknown"],
  ]) {
    assert.throws(
      () => parseImportMode(argumentsList),
      LegacyWorkRecordImportError,
    );
  }
});

test("Git blame은 작성자와 커밋 시각 및 시간대를 분리해 읽는다", () => {
  const blame = parseBlamePorcelain([
    `${"a".repeat(40)} 3 7 1`,
    "author OFFICESTRA",
    "author-mail <officestra@local>",
    "author-time 1700000000",
    "author-tz +0900",
    "committer-time 1700000010",
    "committer-tz +0900",
    "summary OFFICESTRA: 코대리 업무 deadbeef",
    "\t## 제목",
    "",
  ].join("\n"));

  assert.deepEqual(blame.get(7), {
    commit: "a".repeat(40),
    finalLine: 7,
    author: "OFFICESTRA",
    authorMail: "<officestra@local>",
    authorTime: 1_700_000_000,
    authorTimezone: "+0900",
    committerTime: 1_700_000_010,
    committerTimezone: "+0900",
    summary: "OFFICESTRA: 코대리 업무 deadbeef",
  });
});

test("섹션 파서는 행 범위와 항목 상태 및 엄격한 직원 귀속을 보존한다", () => {
  const text = [
    "# 테스트",
    "",
    "## 7단계 같은 제목",
    "",
    "- [x] 완료",
    "  - [ ] 대기",
    "",
    "## 추가 작업  Cafe\u0301   기록",
    "",
    "- 일반 근거",
    "",
  ].join("\n");
  const blameByLine = new Map([
    [
      3,
      {
        commit: "a".repeat(40),
        author: "OFFICESTRA",
        authorMail: "<officestra@local>",
        authorTime: 1_700_000_000,
        authorTimezone: "+0900",
        committerTime: 1_700_000_010,
        committerTimezone: "+0900",
        summary: "OFFICESTRA: 코대리 업무 deadbeef",
      },
    ],
    [
      8,
      {
        commit: "b".repeat(40),
        author: "OFFICESTRA",
        authorMail: "<officestra@local>",
        authorTime: 1_700_000_100,
        authorTimezone: "+0900",
        committerTime: 1_700_000_110,
        committerTimezone: "+0900",
        summary: "OFFICESTRA: 코대리 업무 deadbee",
      },
    ],
  ]);

  const records = parseLegacySections({
    sourcePath: "checklist.md",
    recordType: "task",
    text,
    blameByLine,
  });

  assert.equal(records.length, 2);
  assert.deepEqual(
    {
      start: records[0].sourceLineStart,
      end: records[0].sourceLineEnd,
      stage: records[0].legacyStageNumber,
      normalizedTitle: records[0].normalizedTitle,
      characterID: records[0].characterID,
      attribution: records[0].attribution,
    },
    {
      start: 3,
      end: 7,
      stage: 7,
      normalizedTitle: "같은 제목",
      characterID: "right-woman",
      attribution: "character",
    },
  );
  assert.deepEqual(
    records[0].items.map((item) => [item.item_text, item.is_checked]),
    [["완료", true], ["대기", false]],
  );
  assert.equal(records[0].items[1].metadata.indentation, 2);
  assert.equal(records[0].recordedAt, "2023-11-14T22:13:30.000Z");
  assert.equal(records[0].body.startsWith("\n"), false);
  assert.equal(records[0].body.endsWith("\n"), false);
  assert.equal(records[1].sourceLineStart, 8);
  assert.equal(records[1].sourceLineEnd, 10);
  assert.equal(records[1].normalizedTitle, "Café 기록");
  assert.equal(records[1].characterID, null);
  assert.equal(records[1].attribution, "unknown");
  assert.equal(records[1].items[0].is_checked, null);
  assert.match(records[0].sourceSectionSha256, /^[0-9a-f]{64}$/);
});

test("연결은 정규화 제목이 정확히 같은 섹션만 한 방향으로 만든다", () => {
  const checklist = [
    { key: "checklist.md:0", normalizedTitle: "세션 유지" },
    { key: "checklist.md:1", normalizedTitle: "다른 작업" },
  ];
  const contextNotes = [
    { key: "context-notes.md:0", normalizedTitle: "세션 유지" },
    { key: "context-notes.md:1", normalizedTitle: "별도 근거" },
  ];

  assert.deepEqual(pairLegacySections(checklist, contextNotes), {
    links: [
      {
        sourceKey: "checklist.md:0",
        targetKey: "context-notes.md:0",
        relation: "paired_with",
        normalizedTitle: "세션 유지",
      },
    ],
    unmatchedChecklistSections: 1,
    unmatchedContextNoteSections: 1,
  });
  assert.deepEqual(
    pairLegacySections(
      [...checklist, { key: "checklist.md:2", normalizedTitle: "세션 유지" }],
      contextNotes,
    ),
    {
      links: [],
      unmatchedChecklistSections: 3,
      unmatchedContextNoteSections: 2,
    },
  );
});

test("고정 v1.0.0 Git 원본은 231개 기록과 검증 경계를 만든다", async () => {
  const plan = await actualPlanPromise;

  assert.equal(plan.sourceCommit, LEGACY_SOURCE_COMMIT);
  assert.deepEqual(plan.counts, LEGACY_EXPECTED_COUNTS);
  assert.match(plan.contentDigest, /^[0-9a-f]{64}$/);
  assert.deepEqual(
    plan.sources.map((source) => [source.sourcePath, source.sha256]),
    [
      [
        "checklist.md",
        "ab262339307d7ad1435a0851497fb44ce78ffd027879a385c250a802921ecf6c",
      ],
      [
        "context-notes.md",
        "bfc45e248dd13ec3244739f1cf557b57b76c0bc296f971ac188548110f382228",
      ],
    ],
  );

  const checklistFirst = plan.records[0];
  const checklistLast = plan.records[154];
  const contextFirst = plan.records[155];
  const contextLast = plan.records[230];
  assert.deepEqual(
    [
      checklistFirst.sourceLineStart,
      checklistFirst.sourceLineEnd,
      checklistFirst.legacyStageNumber,
      checklistFirst.items.length,
    ],
    [3, 8, 0, 3],
  );
  assert.deepEqual(
    [
      checklistLast.sourceLineStart,
      checklistLast.sourceLineEnd,
      checklistLast.legacyStageNumber,
      checklistLast.items.length,
    ],
    [1_503, 1_508, 130, 4],
  );
  assert.deepEqual(
    [
      contextFirst.sourceLineStart,
      contextFirst.sourceLineEnd,
      contextFirst.items.length,
    ],
    [3, 7, 2],
  );
  assert.deepEqual(
    [
      contextLast.sourceLineStart,
      contextLast.sourceLineEnd,
      contextLast.items.length,
    ],
    [1_238, 1_243, 4],
  );

  const attributionCounts = {};
  for (const record of plan.records) {
    if (record.characterID) {
      attributionCounts[record.characterID] =
        (attributionCounts[record.characterID] ?? 0) + 1;
    }
  }
  assert.deepEqual(attributionCounts, {
    "right-woman": 10,
    boss: 6,
    "left-woman": 2,
    "right-man": 6,
  });
});

test("실제 CLI dry-run은 DB 없이 고정 Git 출처와 개수만 출력한다", () => {
  const output = execFileSync(
    process.execPath,
    [importerPath, "--dry-run"],
    { encoding: "utf8" },
  );
  const result = JSON.parse(output);

  assert.equal(result.status, "dry-run");
  assert.equal(result.sourceCommit, LEGACY_SOURCE_COMMIT);
  assert.deepEqual(result.counts, LEGACY_EXPECTED_COUNTS);
  assert.deepEqual(
    result.sources.map((source) => source.kind),
    ["file", "file"],
  );
  assert.equal("importId" in result, false);
});

test("완료된 동일 import는 전체 내용을 검증하고 기록을 다시 넣지 않는다", async () => {
  const plan = await actualPlanPromise;
  const { client, queries } = completedImportClient(plan);

  const result = await applyLegacyImport(client, plan);

  assert.deepEqual(result, {
    status: "already-imported",
    projectId: "project-id",
    importId: "import-id",
  });
  assert.equal(
    queries.some(({ sql }) => sql.startsWith("INSERT INTO work_records")),
    false,
  );
});

test("완료된 import의 본문이 같은 개수로 변조돼도 재실행을 거절한다", async () => {
  const plan = await actualPlanPromise;
  const { client } = completedImportClient(plan, (stored) => {
    stored.records[0].body = "변조된 본문";
  });

  await assert.rejects(
    applyLegacyImport(client, plan),
    /저장된 records 내용이 현재 이관 계획과 다릅니다/,
  );
});
