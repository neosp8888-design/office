import assert from "node:assert/strict";
import test from "node:test";

import {
  filterRAGDocumentsByScore,
  searchRAGDocuments,
} from "../src/rag-search.mjs";

const embedding = Array.from({ length: 1024 }, () => 0.01);

test("query만 받은 검색은 로컬 임베딩과 모델 일치 벡터를 사용한다", async () => {
  const queries = [];
  const pool = {
    async query(sql, values) {
      queries.push({ sql, values });
      if (/ts_rank/.test(sql)) {
        return { rows: [] };
      }
      return { rows: [{ id: "one", score: 0.72 }] };
    },
  };
  const embeddingService = { embed: async () => [embedding] };

  const result = await searchRAGDocuments(pool, {
    query: "메모리 부족으로 중단",
    embeddingService,
    minimumScore: 0.5,
  });

  assert.equal(result.mode, "local_vector");
  assert.deepEqual(result.documents, [{ id: "one", score: 0.72 }]);
  assert.match(queries[0].sql, /embedding_model = \$3/);
  assert.match(queries[0].sql, /char_length\(content\) >= 80/);
  assert.equal(queries[0].values[1], 5);
});

test("강한 정확 단어 일치는 벡터 오인보다 우선한다", async () => {
  const pool = {
    async query(sql) {
      if (/ts_rank/.test(sql)) {
        return { rows: [{ id: "ssh-tunnel", score: 0.26 }] };
      }
      return { rows: [{ id: "terminal", score: 0.49 }] };
    },
  };
  const result = await searchRAGDocuments(pool, {
    query: "터널",
    embeddingService: { embed: async () => [embedding] },
  });
  assert.equal(result.mode, "strong_lexical");
  assert.equal(result.documents[0].id, "ssh-tunnel");
});

test("모델 로드가 실패하면 기존 PostgreSQL 전문검색으로 폴백한다", async () => {
  const queries = [];
  const pool = {
    async query(sql, values) {
      queries.push({ sql, values });
      return { rows: [{ id: "lexical", score: 0.2 }] };
    },
  };
  const embeddingService = {
    embed: async () => { throw new Error("모델 없음"); },
  };

  const result = await searchRAGDocuments(pool, {
    query: "원격 접속 끊김",
    embeddingService,
  });

  assert.equal(result.mode, "lexical_fallback");
  assert.equal(result.fallbackError, "모델 없음");
  assert.deepEqual(result.documents, [{ id: "lexical", score: 0.2 }]);
  assert.match(queries[0].sql, /to_tsquery\('simple', \$1\)/);
});

test("기존 embedding 인자 경로는 로컬 모델을 호출하지 않는다", async () => {
  let modelCalls = 0;
  const pool = {
    async query(sql) {
      assert.doesNotMatch(sql, /embedding_model/);
      return { rows: [{ id: "external", score: 0.4 }] };
    },
  };
  const result = await searchRAGDocuments(pool, {
    embedding,
    embeddingService: { embed: async () => { modelCalls += 1; } },
  });
  assert.equal(result.mode, "explicit_vector");
  assert.equal(modelCalls, 0);
  assert.equal(result.documents[0].id, "external");
});

test("최소 점수보다 낮은 벡터 결과는 반환하지 않는다", () => {
  assert.deepEqual(
    filterRAGDocumentsByScore(
      [{ id: "good", score: 0.61 }, { id: "noise", score: 0.42 }],
      0.5,
    ),
    [{ id: "good", score: 0.61 }],
  );
});
