import assert from "node:assert/strict";
import test from "node:test";

import {
  embedRAGDocumentsBestEffort,
  ragEmbeddingText,
} from "../src/rag-embeddings.mjs";
import { LOCAL_EMBEDDING_MODEL_ID } from "../src/local-embedding-config.mjs";

function vector() {
  return Array.from({ length: 1024 }, (_, index) => index / 1024);
}

test("RAG 문서는 제목과 최종 결과를 우선해 제한된 입력을 만든다", () => {
  const text = ragEmbeddingText({
    title: "메모리 부족",
    content: `시작-${"가".repeat(1000)}-최종 결과`,
  });
  assert.ok(text.startsWith("메모리 부족\n메모리 부족\n"));
  assert.match(text, /최종 결과/);
  assert.ok(text.length < 1700);
});

test("새 RAG 문서 임베딩을 모델 식별자와 함께 저장한다", async () => {
  const queries = [];
  const pool = {
    async query(sql, values) {
      queries.push({ sql, values });
      if (/SELECT[\s\S]+FROM rag_documents/.test(sql)) {
        return {
          rows: [{ id: "11111111-1111-1111-1111-111111111111", title: "제목", content: "내용" }],
        };
      }
      return { rows: [], rowCount: 1 };
    },
  };
  const service = { embed: async () => [vector()] };

  const result = await embedRAGDocumentsBestEffort(pool, service, {
    workRecordIDs: ["22222222-2222-2222-2222-222222222222"],
  });

  assert.equal(result.embedded, 1);
  const update = queries.find(({ sql }) => /SET embedding =/.test(sql));
  assert.ok(update);
  assert.equal(update.values[2], LOCAL_EMBEDDING_MODEL_ID);
  assert.match(update.values[1], /^\[/);
  assert.match(queries[0].sql, /document\.work_record_id = ANY\(\$5::uuid\[\]\)/);
});

test("임베딩 실패는 문서 오류만 남기고 예외로 기록 저장을 막지 않는다", async () => {
  const queries = [];
  const pool = {
    async query(sql, values) {
      queries.push({ sql, values });
      if (/SELECT[\s\S]+FROM rag_documents/.test(sql)) {
        return {
          rows: [{ id: "11111111-1111-1111-1111-111111111111", title: "제목", content: "내용" }],
        };
      }
      return { rows: [], rowCount: 1 };
    },
  };
  const service = { embed: async () => { throw new Error("모델 로드 실패"); } };

  const result = await embedRAGDocumentsBestEffort(pool, service);

  assert.equal(result.embedded, 0);
  assert.equal(result.failed, 1);
  assert.equal(result.error, "모델 로드 실패");
  const failure = queries.find(({ sql }) => /SET embedding_error/.test(sql));
  assert.ok(failure);
  assert.equal(failure.values[1], "모델 로드 실패");
});
