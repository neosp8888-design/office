import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migrationURL = new URL(
  "../../database/migrations/027_local_rag_embeddings.sql",
  import.meta.url,
);

test("로컬 임베딩 마이그레이션은 1024차원과 모델 추적·HNSW를 복원한다", async () => {
  const sql = await readFile(migrationURL, "utf8");
  assert.match(sql, /vector\(1024\)/);
  assert.match(sql, /ADD COLUMN IF NOT EXISTS embedding_model text/);
  assert.match(sql, /ADD COLUMN IF NOT EXISTS embedding_updated_at timestamptz/);
  assert.match(sql, /DROP VIEW IF EXISTS searchable_rag_documents/);
  assert.match(sql, /CREATE OR REPLACE VIEW searchable_rag_documents/);
  assert.match(sql, /USING hnsw \(embedding vector_cosine_ops\)/);
});
