-- 이 파일은 승인형 사내 위키의 제안 테이블과 synthesis 페이지, 검색 분리 뷰를 추가한다.

ALTER TABLE work_records
DROP CONSTRAINT IF EXISTS work_records_type_check;

ALTER TABLE work_records
ADD CONSTRAINT work_records_type_check CHECK (
    record_type IN (
        'task',
        'decision',
        'constraint',
        'evidence',
        'status',
        'result',
        'note',
        'synthesis'
    )
);

-- synthesis 페이지는 metadata.pageKey를 프로젝트별로 유일하게 갖는다.
ALTER TABLE work_records
DROP CONSTRAINT IF EXISTS work_records_synthesis_page_key_check;

ALTER TABLE work_records
ADD CONSTRAINT work_records_synthesis_page_key_check CHECK (
    record_type <> 'synthesis'
    OR COALESCE(metadata->>'pageKey', '') <> ''
);

CREATE UNIQUE INDEX IF NOT EXISTS work_records_synthesis_page_key_idx
ON work_records (project_id, (metadata->>'pageKey'))
WHERE record_type = 'synthesis';

ALTER TABLE work_record_links
DROP CONSTRAINT IF EXISTS work_record_links_relation_check;

ALTER TABLE work_record_links
ADD CONSTRAINT work_record_links_relation_check CHECK (
    relation IN (
        'paired_with',
        'supersedes',
        'derived_from',
        'related',
        'conflicts_with'
    )
);

CREATE TABLE IF NOT EXISTS wiki_proposals (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
    page_key text NOT NULL,
    target_record_id uuid REFERENCES work_records(id) ON DELETE SET NULL,
    base_version integer NOT NULL DEFAULT 0,
    state text NOT NULL DEFAULT 'drafted',
    approval_grade text NOT NULL,
    draft_title text NOT NULL,
    draft_body text NOT NULL DEFAULT '',
    source_work_record_ids jsonb NOT NULL DEFAULT '[]'::jsonb,
    author_character_id text REFERENCES characters(id) ON DELETE SET NULL,
    author_turn_id uuid REFERENCES turns(id) ON DELETE SET NULL,
    verifier_character_id text REFERENCES characters(id) ON DELETE SET NULL,
    reason text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    verified_at timestamptz,
    resolved_at timestamptz,
    CONSTRAINT wiki_proposals_state_check CHECK (
        state IN (
            'candidate',
            'drafted',
            'peer_verified',
            'pending_user',
            'published',
            'rejected',
            'conflict'
        )
    ),
    CONSTRAINT wiki_proposals_grade_check CHECK (
        approval_grade IN ('auto', 'peer', 'user')
    ),
    CONSTRAINT wiki_proposals_page_key_check CHECK (page_key <> ''),
    CONSTRAINT wiki_proposals_title_check CHECK (draft_title <> ''),
    CONSTRAINT wiki_proposals_sources_check CHECK (
        jsonb_typeof(source_work_record_ids) = 'array'
    ),
    CONSTRAINT wiki_proposals_base_version_check CHECK (base_version >= 0)
);

CREATE INDEX IF NOT EXISTS wiki_proposals_state_idx
ON wiki_proposals (state, updated_at DESC);

CREATE INDEX IF NOT EXISTS wiki_proposals_page_idx
ON wiki_proposals (project_id, page_key, state);

-- 원본 검색과 위키 검색을 분리한다. 기존 검색에서 synthesis 파생
-- 문서를 제외하고, 게시된 synthesis만 담는 위키 전용 뷰를 만든다.
-- 초안은 work_records 행을 만들지 않으므로 어느 검색에도 나타나지
-- 않는다.
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
