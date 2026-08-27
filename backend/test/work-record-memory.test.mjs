// 이 파일은 완료 턴 작업 기록과 파생 RAG 색인을 검증한다.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  completedTurnRecordBody,
  persistCompletedTurnWorkRecord,
  reconcileTerminalWorkRecordReviews,
  syncWorkRecordRAGDocuments,
  transitionTurnWorkRecordReview,
  workRecordSearchTSQuery,
  workRecordTitle,
} from "../src/work-record-memory.mjs";

test("완료 턴 제목과 본문은 사용자 요청과 최종 결과만 보존한다", () => {
  assert.equal(
    workRecordTitle("  세션 유지 상태를 확인해줘  \n추가 설명"),
    "세션 유지 상태를 확인해줘",
  );
  assert.equal(
    completedTurnRecordBody("세션을 확인해줘.", "문제없습니다."),
    "요청\n세션을 확인해줘.\n\n결과\n문제없습니다.",
  );
});

test("RAG 검색어는 일반 지시어를 빼고 의미 토큰을 OR 접두 검색으로 만든다", () => {
  assert.equal(
    workRecordSearchTSQuery("계속 진행해 세션 유지 작업 기록을 다시 확인해"),
    "세션:* | 유지:* | 작업:* | 기록을:*",
  );
  assert.equal(workRecordSearchTSQuery(""), "");
  assert.equal(workRecordSearchTSQuery("! ? _"), "");
  assert.equal(workRecordSearchTSQuery("계속 진행해 다시 확인해"), "");
});

test("RAG 전문검색 폴백도 같은 OR 접두 검색을 쓴다", () => {
  const searchSource = readFileSync(
    new URL("../src/rag-search.mjs", import.meta.url),
    "utf8",
  );

  assert.match(
    searchSource,
    /const tsQuery = workRecordSearchTSQuery\(query\)/,
  );
  assert.match(
    searchSource,
    /if \(!tsQuery\) \{[\s\S]*return \[\];/,
  );
  assert.match(searchSource, /to_tsquery\('simple', \$1\)/);
  assert.doesNotMatch(searchSource, /websearch_to_tsquery/);
  assert.match(searchSource, /\[tsQuery, limit\]/);
});

test("완료 턴 저장은 source turn 고유키와 검토 상태를 한 번에 기록한다", async () => {
  const queries = [];
  const client = {
    query: async (text, values) => {
      queries.push({ text, values });
      return {
        rowCount: 1,
        rows: [{ workRecordId: "record-1" }],
      };
    },
  };

  const result = await persistCompletedTurnWorkRecord(client, {
    repositoryRoot: "/repo",
    turnID: "11111111-1111-1111-1111-111111111111",
    workspaceID: "22222222-2222-2222-2222-222222222222",
    characterID: "boss",
    prompt: "작업 기록 전환",
    response: "완료했습니다.",
    backend: "codex",
    model: "gpt-5.6-sol",
    reviewStatus: "awaiting_approval",
    reviewTree: "tree-1",
    changedFiles: [{ path: "backend/src/server.mjs", status: "M" }],
    recordedAt: "2026-08-01 11:34:14.123456+00",
  });

  assert.equal(result.workRecordId, "record-1");
  assert.match(queries[0].text, /ON CONFLICT \(source_turn_id, record_type\)/);
  assert.match(queries[0].text, /INSERT INTO work_record_events/);
  const metadata = JSON.parse(queries[0].values[7]);
  assert.equal(metadata.source, "completed_turn");
  assert.equal(metadata.review.status, "awaiting_approval");
  assert.equal(metadata.review.reviewTree, "tree-1");
  assert.equal(
    queries[0].values[8],
    "2026-08-01 11:34:14.123456+00",
  );
  assert.match(queries[0].text, /COALESCE\(\$9::timestamptz, now\(\)\)/);
});

test("RAG 동기화는 부적격 문서를 지운 뒤 승인된 기록만 멱등 upsert한다", async () => {
  const queries = [];
  const client = {
    query: async (text, values) => {
      queries.push({ text, values });
      if (/DELETE FROM rag_documents/.test(text)) {
        return { rowCount: 1, rows: [] };
      }
      return {
        rowCount: 1,
        rows: [{ ragDocumentId: "rag-1", workRecordId: "record-1" }],
      };
    },
  };

  const result = await syncWorkRecordRAGDocuments(client, {
    repositoryRoot: "/repo",
  });

  assert.deepEqual(result, {
    changed: 1,
    deleted: 1,
    documents: [{ ragDocumentId: "rag-1", workRecordId: "record-1" }],
  });
  assert.equal(queries.length, 2);
  assert.match(queries[0].text, /NOT EXISTS \(/);
  assert.match(queries[0].text, /FROM searchable_work_record_ids/);
  assert.match(queries[1].text, /JOIN searchable_work_record_ids/);
  assert.match(queries[1].text, /ON CONFLICT \(work_record_id\)/);
  assert.match(queries[1].text, /embedding_model = NULL/);
});

test("검토 승인 상태 전환은 잠금과 이벤트만 저장하고 RAG를 직접 갱신하지 않는다", async () => {
  const queries = [];
  const client = {
    query: async (text, values) => {
      queries.push({ text, values });
      if (/WITH updated_record AS/.test(text)) {
        return { rowCount: 1, rows: [{ workRecordId: "record-1" }] };
      }
      return { rowCount: 0, rows: [] };
    },
  };

  const workRecordID = await transitionTurnWorkRecordReview(client, {
    turnID: "11111111-1111-1111-1111-111111111111",
    status: "merged",
    taskCommit: "task-commit",
    mergedCommit: "merge-commit",
  });

  assert.equal(workRecordID, "record-1");
  assert.equal(queries.length, 2);
  assert.match(queries[0].text, /pg_advisory_xact_lock/);
  assert.deepEqual(queries[0].values, [
    "officestra:work-record:11111111-1111-1111-1111-111111111111",
  ]);
  assert.match(queries[1].text, /INSERT INTO work_record_events/);
  assert.equal(queries[1].values[1], "merged");
  assert.equal(
    queries.some(({ text }) => /rag_documents/.test(text)),
    false,
  );
});

test("기동 재조정은 terminal workspace와 어긋난 작업 기록을 복구한다", async () => {
  const queries = [];
  const client = {
    query: async (text, values) => {
      queries.push({ text, values });
      if (/FROM work_records AS record/.test(text)) {
        return {
          rowCount: 1,
          rows: [{
            turnID: "11111111-1111-1111-1111-111111111111",
            status: "merged",
            taskCommit: "task-commit",
            mergedCommit: "merged-commit",
            reviewTree: "review-tree",
            headCommit: "head-commit",
            changedFiles: [{ status: "M", path: "README.md" }],
          }],
        };
      }
      if (/WITH updated_record AS/.test(text)) {
        return {
          rowCount: 1,
          rows: [{ workRecordId: "record-1" }],
        };
      }
      return { rowCount: 1, rows: [] };
    },
  };

  const workRecordIDs = await reconcileTerminalWorkRecordReviews(client, {
    repositoryRoot: "/repo",
  });

  assert.deepEqual(workRecordIDs, ["record-1"]);
  assert.equal(queries.length, 3);
  assert.deepEqual(queries[0].values, ["/repo"]);
  assert.match(
    queries[0].text,
    /workspace\.review_turn_id = record\.source_turn_id/,
  );
  assert.match(queries[0].text, /workspace\.status = 'closed'/);
  assert.match(queries[0].text, /turn\.status = 'completed'/);
  assert.match(queries[0].text, /'not_required' AS status/);
  assert.match(queries[1].text, /pg_advisory_xact_lock/);
  assert.equal(queries[2].values[1], "merged");
});
