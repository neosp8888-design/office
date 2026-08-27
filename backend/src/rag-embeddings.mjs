import {
  LOCAL_EMBEDDING_DIMENSIONS,
  LOCAL_EMBEDDING_MODEL_ID,
} from "./local-embedding-config.mjs";

export const DEFAULT_RAG_EMBEDDING_BATCH_SIZE = 1;

export function ragEmbeddingText(document) {
  const title = String(document?.title ?? "").trim();
  const content = String(document?.content ?? "").trim();
  const beginning = content.slice(0, 600);
  const ending = content.length > 600 ? content.slice(-900) : "";
  return [title, title, ending, beginning].filter(Boolean).join("\n");
}

function vectorLiteral(vector) {
  if (
    !Array.isArray(vector) ||
    vector.length !== LOCAL_EMBEDDING_DIMENSIONS ||
    vector.some((value) => !Number.isFinite(value))
  ) {
    throw new Error(
      `로컬 임베딩은 ${LOCAL_EMBEDDING_DIMENSIONS}차원 유한 숫자여야 합니다.`,
    );
  }
  return `[${vector.join(",")}]`;
}

export async function listPendingRAGEmbeddingDocuments(pool, {
  repositoryRoot = null,
  documentIDs = null,
  workRecordIDs = null,
  limit = null,
} = {}) {
  const ids = Array.isArray(documentIDs) && documentIDs.length > 0
    ? documentIDs
    : null;
  const boundedLimit = Number.isFinite(Number(limit))
    ? Math.max(1, Number(limit))
    : null;
  const recordIDs = Array.isArray(workRecordIDs) && workRecordIDs.length > 0
    ? workRecordIDs
    : null;
  const result = await pool.query(
    `
      SELECT
        document.id::text AS id,
        document.title,
        document.content
      FROM rag_documents AS document
      LEFT JOIN work_records AS record ON record.id = document.work_record_id
      LEFT JOIN projects AS project ON project.id = record.project_id
      WHERE (document.embedding IS NULL
          OR document.embedding_model IS DISTINCT FROM $1)
        AND ($2::text IS NULL OR project.repository_root = $2)
        AND ($3::uuid[] IS NULL OR document.id = ANY($3::uuid[]))
        AND ($5::uuid[] IS NULL OR document.work_record_id = ANY($5::uuid[]))
      ORDER BY document.updated_at, document.id
      LIMIT COALESCE($4::integer, 2147483647)
    `,
    [
      LOCAL_EMBEDDING_MODEL_ID,
      repositoryRoot,
      ids,
      boundedLimit,
      recordIDs,
    ],
  );
  return result.rows ?? [];
}

export async function storeRAGDocumentEmbeddings(pool, documents, vectors) {
  if (documents.length !== vectors.length) {
    throw new Error("RAG 문서 수와 임베딩 수가 일치하지 않습니다.");
  }
  for (let index = 0; index < documents.length; index += 1) {
    await pool.query(
      `
        UPDATE rag_documents
        SET embedding = $2::vector,
            embedding_model = $3,
            embedding_updated_at = now(),
            embedding_error = NULL
        WHERE id = $1::uuid
      `,
      [documents[index].id, vectorLiteral(vectors[index]), LOCAL_EMBEDDING_MODEL_ID],
    );
  }
}

export async function markRAGEmbeddingFailure(pool, documents, error) {
  const ids = documents.map((document) => document.id);
  if (ids.length === 0) {
    return;
  }
  await pool.query(
    `
      UPDATE rag_documents
      SET embedding_error = $2,
          embedding_updated_at = now()
      WHERE id = ANY($1::uuid[])
    `,
    [ids, error instanceof Error ? error.message : String(error)],
  );
}

export async function embedRAGDocumentsBestEffort(pool, embeddingService, {
  repositoryRoot = null,
  documentIDs = null,
  workRecordIDs = null,
  limit = null,
} = {}) {
  const documents = await listPendingRAGEmbeddingDocuments(pool, {
    repositoryRoot,
    documentIDs,
    workRecordIDs,
    limit,
  });
  if (documents.length === 0) {
    return { embedded: 0, failed: 0, documents: [] };
  }
  try {
    const vectors = await embeddingService.embed(
      documents.map(ragEmbeddingText),
    );
    await storeRAGDocumentEmbeddings(pool, documents, vectors);
    return { embedded: documents.length, failed: 0, documents };
  } catch (error) {
    await markRAGEmbeddingFailure(pool, documents, error);
    return {
      embedded: 0,
      failed: documents.length,
      documents,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

export async function backfillRAGEmbeddings(pool, embeddingService, {
  repositoryRoot = null,
  batchSize = DEFAULT_RAG_EMBEDDING_BATCH_SIZE,
  progress = null,
} = {}) {
  const startedAt = performance.now();
  let embedded = 0;
  let failed = 0;
  for (;;) {
    const result = await embedRAGDocumentsBestEffort(pool, embeddingService, {
      repositoryRoot,
      limit: batchSize,
    });
    embedded += result.embedded;
    failed += result.failed;
    progress?.({ embedded, failed, last: result });
    if (result.error) {
      throw new Error(result.error);
    }
    if (result.documents.length < batchSize) {
      break;
    }
  }
  return {
    embedded,
    failed,
    elapsedSeconds: (performance.now() - startedAt) / 1000,
    ...embeddingService.metrics(),
  };
}
