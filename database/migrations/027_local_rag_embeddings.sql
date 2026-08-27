-- BGE-M3 로컬 임베딩을 위한 1,024차원 벡터와 모델 추적 필드를 추가한다.

ALTER TABLE rag_documents
ADD COLUMN IF NOT EXISTS embedding_model text;

ALTER TABLE rag_documents
ADD COLUMN IF NOT EXISTS embedding_updated_at timestamptz;

ALTER TABLE rag_documents
ADD COLUMN IF NOT EXISTS embedding_error text;

DROP INDEX IF EXISTS rag_documents_embedding_idx;

-- document.*로 정의된 두 뷰도 embedding 열 타입에 의존하므로 타입
-- 변경 동안만 제거하고 현재 정의 그대로 복원한다.
DROP VIEW IF EXISTS searchable_wiki_page_documents;
DROP VIEW IF EXISTS searchable_rag_documents;

DO $$
DECLARE
    current_embedding_type text;
BEGIN
    SELECT format_type(attribute.atttypid, attribute.atttypmod)
    INTO current_embedding_type
    FROM pg_attribute AS attribute
    WHERE attribute.attrelid = 'rag_documents'::regclass
      AND attribute.attname = 'embedding'
      AND NOT attribute.attisdropped;

    IF current_embedding_type IS NULL THEN
        RAISE EXCEPTION 'rag_documents.embedding 컬럼이 없습니다.';
    END IF;

    IF current_embedding_type <> 'vector(1024)' THEN
        -- 서로 다른 모델의 벡터 공간은 변환할 수 없으므로 기존 벡터를
        -- 잘못 재사용하지 않고 새 모델로 백필한다.
        UPDATE rag_documents
        SET embedding = NULL,
            embedding_model = NULL,
            embedding_updated_at = NULL,
            embedding_error = NULL
        WHERE embedding IS NOT NULL
           OR embedding_model IS NOT NULL
           OR embedding_updated_at IS NOT NULL
           OR embedding_error IS NOT NULL;

        ALTER TABLE rag_documents
        ALTER COLUMN embedding TYPE vector(1024)
        USING NULL::vector(1024);
    END IF;
END
$$;

CREATE OR REPLACE VIEW searchable_rag_documents AS
SELECT document.*
FROM rag_documents AS document
WHERE (
        document.work_record_id IS NULL
        OR EXISTS (
            SELECT 1
            FROM searchable_work_record_ids AS searchable
            WHERE searchable.id = document.work_record_id
        )
    )
    AND NOT EXISTS (
        SELECT 1
        FROM work_records AS record
        WHERE record.id = document.work_record_id
          AND record.record_type = 'synthesis'
    );

CREATE OR REPLACE VIEW searchable_wiki_page_documents AS
SELECT document.*
FROM rag_documents AS document
JOIN work_records AS record ON record.id = document.work_record_id
WHERE record.record_type = 'synthesis'
  AND record.lifecycle_state = 'active'
  AND EXISTS (
      SELECT 1
      FROM searchable_work_record_ids AS searchable
      WHERE searchable.id = record.id
  );

CREATE INDEX IF NOT EXISTS rag_documents_embedding_idx
ON rag_documents USING hnsw (embedding vector_cosine_ops);

CREATE INDEX IF NOT EXISTS rag_documents_embedding_model_idx
ON rag_documents (embedding_model)
WHERE embedding IS NOT NULL;
