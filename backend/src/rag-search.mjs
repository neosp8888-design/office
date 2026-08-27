import { LOCAL_EMBEDDING_MODEL_ID } from "./local-embedding-config.mjs";
import { workRecordSearchTSQuery } from "./work-record-memory.mjs";

export const DEFAULT_RAG_VECTOR_MIN_SCORE = 0.45;
export const STRONG_LEXICAL_SCORE = 0.2;

export function ragVectorMinimumScore(environment = process.env) {
  const configured = Number(environment.OFFICE_RAG_VECTOR_MIN_SCORE);
  return Number.isFinite(configured)
    ? Math.max(-1, Math.min(configured, 1))
    : DEFAULT_RAG_VECTOR_MIN_SCORE;
}

export function filterRAGDocumentsByScore(documents, minimumScore) {
  return documents.filter(
    (document) => Number(document.score) >= minimumScore,
  );
}

async function explicitVectorSearch(pool, embedding, limit) {
  const literal = `[${embedding.join(",")}]`;
  const result = await pool.query(
    `
      SELECT
        id,
        id AS "ragDocumentId",
        source,
        title,
        content,
        metadata,
        work_record_id AS "workRecordId",
        1 - (embedding <=> $1::vector) AS score
      FROM searchable_rag_documents
      WHERE embedding IS NOT NULL
      ORDER BY embedding <=> $1::vector
      LIMIT $2
    `,
    [literal, limit],
  );
  return result.rows ?? [];
}

async function localVectorSearch(pool, embedding, limit, minimumScore) {
  const literal = `[${embedding.join(",")}]`;
  const result = await pool.query(
    `
      SELECT
        id,
        id AS "ragDocumentId",
        source,
        title,
        content,
        metadata,
        work_record_id AS "workRecordId",
        1 - (embedding <=> $1::vector) AS score
      FROM searchable_rag_documents
      WHERE embedding IS NOT NULL
        AND embedding_model = $3
        AND COALESCE(title, '') ~ '[[:alnum:]]'
        AND (
          char_length(COALESCE(title, '')) >= 4
          OR char_length(content) >= 80
        )
      ORDER BY embedding <=> $1::vector
      LIMIT $2
    `,
    [literal, limit, LOCAL_EMBEDDING_MODEL_ID],
  );
  return filterRAGDocumentsByScore(result.rows ?? [], minimumScore);
}

async function lexicalSearch(pool, query, limit) {
  const tsQuery = workRecordSearchTSQuery(query);
  if (!tsQuery) {
    return [];
  }
  const result = await pool.query(
    `
      SELECT
        id,
        id AS "ragDocumentId",
        source,
        title,
        content,
        metadata,
        work_record_id AS "workRecordId",
        ts_rank(
          search_document,
          to_tsquery('simple', $1)
        ) AS score
      FROM searchable_rag_documents
      WHERE search_document @@ to_tsquery('simple', $1)
        AND COALESCE(title, '') ~ '[[:alnum:]]'
      ORDER BY score DESC
      LIMIT $2
    `,
    [tsQuery, limit],
  );
  return result.rows ?? [];
}

export async function searchRAGDocuments(pool, {
  query = "",
  embedding = null,
  limit = 5,
  embeddingService = null,
  minimumScore = ragVectorMinimumScore(),
} = {}) {
  const boundedLimit = Math.max(1, Math.min(Number(limit) || 5, 20));
  if (Array.isArray(embedding)) {
    return {
      documents: await explicitVectorSearch(pool, embedding, boundedLimit),
      mode: "explicit_vector",
      fallbackError: null,
    };
  }
  const normalizedQuery = String(query ?? "").trim();
  if (!normalizedQuery) {
    return { documents: [], mode: "empty", fallbackError: null };
  }
  if (embeddingService) {
    try {
      const [queryEmbedding] = await embeddingService.embed([normalizedQuery]);
      const vectorDocuments = await localVectorSearch(
        pool,
        queryEmbedding,
        boundedLimit,
        minimumScore,
      );
      const lexicalDocuments = await lexicalSearch(
        pool,
        normalizedQuery,
        boundedLimit,
      );
      if (Number(lexicalDocuments[0]?.score) >= STRONG_LEXICAL_SCORE) {
        return {
          documents: lexicalDocuments,
          mode: "strong_lexical",
          fallbackError: null,
        };
      }
      return {
        documents: vectorDocuments,
        mode: "local_vector",
        fallbackError: null,
      };
    } catch (error) {
      return {
        documents: await lexicalSearch(pool, normalizedQuery, boundedLimit),
        mode: "lexical_fallback",
        fallbackError: error instanceof Error ? error.message : String(error),
      };
    }
  }
  return {
    documents: await lexicalSearch(pool, normalizedQuery, boundedLimit),
    mode: "lexical",
    fallbackError: null,
  };
}
