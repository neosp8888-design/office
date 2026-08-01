// 이 파일은 작업 기록 색인 CLI가 명시적 적용과 저장소 범위를 강제하는지 검증한다.

import assert from "node:assert/strict";
import test from "node:test";

import {
  indexWorkRecords,
  parseIndexWorkRecordArguments,
} from "../src/index-work-records.mjs";

test("색인 CLI는 apply와 절대 저장소 경로를 모두 요구한다", () => {
  const invalidCases = [
    { argumentsList: [], pattern: /--apply/ },
    {
      argumentsList: ["--repository-root", "/repo"],
      pattern: /--apply/,
    },
    { argumentsList: ["--apply"], pattern: /색인 범위/ },
    {
      argumentsList: ["--apply", "--repository-root"],
      pattern: /절대경로를 입력/,
    },
    {
      argumentsList: ["--apply", "--repository-root", "   "],
      pattern: /색인 범위/,
    },
    {
      argumentsList: ["--apply", "--repository-root", "relative/repo"],
      pattern: /절대경로여야/,
    },
    {
      argumentsList: ["--apply", "--apply", "--repository-root", "/repo"],
      pattern: /중복 지정/,
    },
    {
      argumentsList: [
        "--apply",
        "--repository-root",
        "/repo",
        "--repository-root",
        "/other",
      ],
      pattern: /중복 지정/,
    },
    {
      argumentsList: ["--apply", "--repository-root", "/repo", "--unknown"],
      pattern: /알 수 없는 옵션/,
    },
    {
      argumentsList: ["--help", "--apply"],
      pattern: /도움말은 다른 옵션과 함께/,
    },
  ];

  for (const { argumentsList, pattern } of invalidCases) {
    assert.throws(
      () => parseIndexWorkRecordArguments(argumentsList),
      pattern,
      JSON.stringify(argumentsList),
    );
  }
});

test("색인 CLI는 명시한 절대 저장소 경로만 반환한다", () => {
  assert.deepEqual(
    parseIndexWorkRecordArguments([
      "--apply",
      "--repository-root",
      "/repo",
    ]),
    { help: false, apply: true, repositoryRoot: "/repo" },
  );
  assert.deepEqual(
    parseIndexWorkRecordArguments(["--help"]),
    { help: true, apply: false, repositoryRoot: null },
  );
  assert.deepEqual(
    parseIndexWorkRecordArguments(["-h"]),
    { help: true, apply: false, repositoryRoot: null },
  );
});

test("색인 API는 범위가 없거나 상대경로면 쿼리 전에 거절한다", async () => {
  let queryCount = 0;
  const client = {
    query: async () => {
      queryCount += 1;
      return { rowCount: 0, rows: [] };
    },
  };

  await assert.rejects(indexWorkRecords(client), /저장소 절대경로가 필요/);
  await assert.rejects(
    indexWorkRecords(client, { repositoryRoot: "relative/repo" }),
    /절대경로로 지정/,
  );
  assert.equal(queryCount, 0);
});

test("색인 API는 모든 파생 RAG 쿼리를 지정한 저장소로 제한한다", async () => {
  const queries = [];
  const client = {
    query: async (text, values) => {
      queries.push({ text, values });
      if (/DELETE FROM rag_documents/.test(text)) {
        return { rowCount: 2, rows: [] };
      }
      return {
        rowCount: 1,
        rows: [{ ragDocumentId: "rag-1", workRecordId: "record-1" }],
      };
    },
  };

  const result = await indexWorkRecords(client, {
    repositoryRoot: "  /repo  ",
  });

  assert.deepEqual(result, {
    changed: 1,
    deleted: 2,
    documents: [{ ragDocumentId: "rag-1", workRecordId: "record-1" }],
  });
  assert.equal(queries.length, 2);
  assert.deepEqual(queries.map(({ values }) => values), [
    ["/repo", null],
    ["/repo", null],
  ]);
});
