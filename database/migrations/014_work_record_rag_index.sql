-- 이 파일은 완료 턴 작업 기록과 파생 RAG 문서를 일대일로 연결한다.

ALTER TABLE rag_documents
ADD COLUMN IF NOT EXISTS work_record_id uuid;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'rag_documents'::regclass
          AND conname = 'rag_documents_work_record_id_fkey'
    ) THEN
        ALTER TABLE rag_documents
        ADD CONSTRAINT rag_documents_work_record_id_fkey
        FOREIGN KEY (work_record_id)
        REFERENCES work_records(id)
        ON DELETE CASCADE;
    END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS rag_documents_work_record_unique_idx
ON rag_documents (work_record_id)
WHERE work_record_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS work_records_turn_type_unique_idx
ON work_records (source_turn_id, record_type)
WHERE source_turn_id IS NOT NULL
  AND import_id IS NULL;

CREATE OR REPLACE VIEW searchable_work_record_ids AS
SELECT record.id
FROM work_records AS record
WHERE record.lifecycle_state = 'legacy'
   OR (
        record.lifecycle_state = 'active'
        AND record.metadata->>'needsInput' IS DISTINCT FROM 'true'
        AND CASE
            WHEN COALESCE(
                record.metadata #>> '{review,status}',
                'not_applicable'
            ) = 'merged'
            THEN EXISTS (
                SELECT 1
                FROM task_workspaces AS workspace
                WHERE workspace.id = record.source_workspace_id
                  AND workspace.status IN ('merged', 'closed')
                  AND (
                      workspace.review_turn_id = record.source_turn_id
                      OR record.source_turn_id IS NULL
                  )
            )
            WHEN COALESCE(
                record.metadata #>> '{review,status}',
                'not_applicable'
            ) IN ('not_required', 'not_applicable')
            THEN NOT EXISTS (
                SELECT 1
                FROM task_workspaces AS workspace
                WHERE workspace.id = record.source_workspace_id
                  AND workspace.review_turn_id = record.source_turn_id
                  AND workspace.status NOT IN ('merged', 'closed')
            )
            ELSE false
        END
   );

CREATE OR REPLACE VIEW searchable_rag_documents AS
SELECT document.*
FROM rag_documents AS document
WHERE document.work_record_id IS NULL
   OR EXISTS (
       SELECT 1
       FROM searchable_work_record_ids AS searchable
       WHERE searchable.id = document.work_record_id
   );
