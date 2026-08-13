-- 이 파일은 021이 이미 적용된 DB를 완료 응답 제안 수집 형식으로
-- 안전하게 올린다. 마이그레이션 실행기가 매 기동 전체 SQL을 다시
-- 실행하므로 모든 단계는 반복 실행 가능해야 한다.

ALTER TABLE wiki_proposals
ADD COLUMN IF NOT EXISTS proposal_kind text;

ALTER TABLE wiki_proposals
ADD COLUMN IF NOT EXISTS ordinal integer;

ALTER TABLE turns
ADD COLUMN IF NOT EXISTS wiki_proposal_warning text;

-- 021 시기의 페이지와 제안에는 종류가 없었다. 기존 자료는 가장
-- 중립적인 decision으로 보존하고 이후 신규 자료부터 명시 종류를 쓴다.
UPDATE work_records
SET metadata = jsonb_set(
    COALESCE(metadata, '{}'::jsonb),
    '{kind}',
    '"decision"'::jsonb,
    true
)
WHERE record_type = 'synthesis'
  AND COALESCE(metadata->>'kind', '') NOT IN (
      'decision', 'constraint', 'incident'
  );

UPDATE wiki_proposals AS proposal
SET proposal_kind = COALESCE(
    (
        SELECT record.metadata->>'kind'
        FROM work_records AS record
        WHERE record.id = proposal.target_record_id
          AND record.metadata->>'kind' IN (
              'decision', 'constraint', 'incident'
          )
    ),
    'decision'
)
WHERE proposal_kind IS NULL
   OR proposal_kind NOT IN ('decision', 'constraint', 'incident');

ALTER TABLE wiki_proposals
ALTER COLUMN proposal_kind SET NOT NULL;

-- 예전 구현이 허용한 임의 키는 원문을 metadata에 보관하고 UUID 기반
-- 안정 키로 옮긴다. 새 키는 프로젝트 안에서 항상 유일하다.
UPDATE work_records
SET metadata = jsonb_set(
    jsonb_set(
        COALESCE(metadata, '{}'::jsonb),
        '{originalPageKey}',
        to_jsonb(COALESCE(metadata->>'pageKey', '')),
        true
    ),
    '{pageKey}',
    to_jsonb('legacy-' || replace(id::text, '-', '')),
    true
)
WHERE record_type = 'synthesis'
  AND COALESCE(metadata->>'pageKey', '')
      !~ '^[a-z0-9][a-z0-9-]{0,79}$';

UPDATE wiki_proposals AS proposal
SET page_key = COALESCE(
    (
        SELECT record.metadata->>'pageKey'
        FROM work_records AS record
        WHERE record.id = proposal.target_record_id
    ),
    'legacy-' || replace(proposal.id::text, '-', '')
)
WHERE proposal.page_key !~ '^[a-z0-9][a-z0-9-]{0,79}$';

ALTER TABLE work_records
DROP CONSTRAINT IF EXISTS work_records_synthesis_page_key_check;

ALTER TABLE work_records
ADD CONSTRAINT work_records_synthesis_page_key_check CHECK (
    record_type <> 'synthesis'
    OR (
        COALESCE(metadata->>'pageKey', '')
            ~ '^[a-z0-9][a-z0-9-]{0,79}$'
        AND metadata->>'kind' IN (
            'decision', 'constraint', 'incident'
        )
    )
);

ALTER TABLE wiki_proposals
DROP CONSTRAINT IF EXISTS wiki_proposals_kind_check;
ALTER TABLE wiki_proposals
ADD CONSTRAINT wiki_proposals_kind_check CHECK (
    proposal_kind IN ('decision', 'constraint', 'incident')
);

ALTER TABLE wiki_proposals
DROP CONSTRAINT IF EXISTS wiki_proposals_page_key_check;
ALTER TABLE wiki_proposals
ADD CONSTRAINT wiki_proposals_page_key_check CHECK (
    page_key ~ '^[a-z0-9][a-z0-9-]{0,79}$'
);

ALTER TABLE wiki_proposals
DROP CONSTRAINT IF EXISTS wiki_proposals_title_check;
ALTER TABLE wiki_proposals
ADD CONSTRAINT wiki_proposals_title_check CHECK (
    draft_title <> '' AND char_length(draft_title) <= 120
) NOT VALID;

ALTER TABLE wiki_proposals
DROP CONSTRAINT IF EXISTS wiki_proposals_body_check;
ALTER TABLE wiki_proposals
ADD CONSTRAINT wiki_proposals_body_check CHECK (
    char_length(draft_body) <= 12000
) NOT VALID;

ALTER TABLE wiki_proposals
DROP CONSTRAINT IF EXISTS wiki_proposals_ordinal_check;
ALTER TABLE wiki_proposals
ADD CONSTRAINT wiki_proposals_ordinal_check CHECK (
    ordinal IS NULL OR ordinal >= 0
);

-- 같은 완료 턴을 재처리해도 동일 제안을 중복 생성하지 않는다.
CREATE UNIQUE INDEX IF NOT EXISTS wiki_proposals_turn_ordinal_idx
ON wiki_proposals (author_turn_id, ordinal)
WHERE author_turn_id IS NOT NULL AND ordinal IS NOT NULL;
