import { fileURLToPath } from "node:url";

import { pool } from "./db.mjs";
import { LocalEmbeddingService } from "./local-embedding.mjs";
import { searchRAGDocuments } from "./rag-search.mjs";

export const RAG_COMPARISON_QUERIES = Object.freeze([
  "만화 콘티",
  "웹툰 그림 순서",
  "ComfyUI",
  "그림 만드는 프로그램",
  "임베딩",
  "검색이 잘 안 되는 문제",
  "RAM 95%",
  "메모리 부족으로 중단",
  "터널",
  "원격 접속 끊김",
]);

function compact(documents) {
  return documents.map((document) => ({
    ragDocumentId: document.ragDocumentId ?? document.id,
    workRecordId: document.workRecordId ?? null,
    title: document.title,
    score: Number(document.score),
  }));
}

export async function benchmarkRAGSearch({
  databasePool = pool,
  embeddingService = new LocalEmbeddingService(),
  limit = 3,
} = {}) {
  const results = [];
  try {
    for (const query of RAG_COMPARISON_QUERIES) {
      const lexical = await searchRAGDocuments(databasePool, {
        query,
        limit,
      });
      const automatic = await searchRAGDocuments(databasePool, {
        query,
        limit,
        embeddingService,
      });
      results.push({
        query,
        lexical: compact(lexical.documents),
        automaticMode: automatic.mode,
        automatic: compact(automatic.documents),
      });
    }
    return { results, metrics: embeddingService.metrics() };
  } finally {
    embeddingService.close();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  benchmarkRAGSearch()
    .then((result) => console.log(JSON.stringify(result, null, 2)))
    .catch((error) => {
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
    })
    .finally(() => pool.end());
}
