import { fileURLToPath } from "node:url";

import { pool } from "./db.mjs";
import { LocalEmbeddingService } from "./local-embedding.mjs";
import { migrate } from "./migrate.mjs";
import { backfillRAGEmbeddings } from "./rag-embeddings.mjs";

export const BACKFILL_RAG_EMBEDDINGS_USAGE = [
  "사용법",
  "node src/backfill-rag-embeddings.mjs --apply --repository-root <절대경로>",
].join("\n");

export function parseBackfillRAGEmbeddingArguments(argumentsList) {
  let apply = false;
  let repositoryRoot = null;
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === "--apply") {
      apply = true;
      continue;
    }
    if (argument === "--repository-root") {
      repositoryRoot = argumentsList[index + 1] ?? null;
      index += 1;
      continue;
    }
    throw new Error(`알 수 없는 옵션입니다. ${argument}`);
  }
  if (!apply) {
    throw new Error("실제 백필에는 --apply 확인이 필요합니다.");
  }
  const root = String(repositoryRoot ?? "").trim();
  if (!root.startsWith("/")) {
    throw new Error("--repository-root는 절대경로여야 합니다.");
  }
  return { repositoryRoot: root };
}

async function runCLI() {
  const options = parseBackfillRAGEmbeddingArguments(process.argv.slice(2));
  const service = new LocalEmbeddingService();
  try {
    const migration = await migrate({ pool });
    const result = await backfillRAGEmbeddings(pool, service, {
      repositoryRoot: options.repositoryRoot,
      progress({ embedded }) {
        if (embedded > 0 && embedded % 100 === 0) {
          console.error(`RAG 임베딩 백필 ${embedded}건 완료`);
        }
      },
    });
    service.close();
    console.log(JSON.stringify({ migration, ...result }, null, 2));
  } finally {
    service.close();
    await pool.end();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  runCLI().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    console.error(BACKFILL_RAG_EMBEDDINGS_USAGE);
    process.exitCode = 1;
  });
}
