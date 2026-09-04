-- 설치된 Codex·Antigravity CLI가 제공하는 모델과 사용자의 표시 제외 설정을 저장한다.

CREATE TABLE IF NOT EXISTS agent_model_catalogs (
    provider text PRIMARY KEY
        CHECK (provider IN ('codex', 'antigravity')),
    catalog jsonb NOT NULL DEFAULT '{"version":1,"models":[]}'::jsonb,
    excluded_models text[] NOT NULL DEFAULT ARRAY[]::text[],
    fetched_at timestamptz,
    last_attempted_at timestamptz,
    last_error text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT agent_model_catalogs_catalog_check CHECK (
        jsonb_typeof(catalog) = 'object'
        AND jsonb_typeof(catalog -> 'models') = 'array'
    )
);

-- 모델 카탈로그가 앞으로 새로운 추론 단계를 알려도 턴 저장이 막히지 않게 한다.
-- 실제 허용 여부는 선택 시점에 해당 CLI 카탈로그로 검증한다.
ALTER TABLE turns
DROP CONSTRAINT IF EXISTS turns_effort_check;

ALTER TABLE turns
ADD CONSTRAINT turns_effort_check
CHECK (
    effort IS NULL
    OR effort ~ '^[a-z][a-z0-9_-]{0,31}$'
);
