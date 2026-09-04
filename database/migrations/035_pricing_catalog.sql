-- 공식 가격표를 하루 두 번만 갱신하고 마지막 정상 카탈로그를 보존한다.

CREATE TABLE IF NOT EXISTS pricing_catalogs (
    provider text PRIMARY KEY,
    source_url text NOT NULL,
    catalog jsonb,
    fetched_at timestamptz,
    last_attempted_at timestamptz,
    last_error text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pricing_catalogs_provider_check
        CHECK (provider IN ('codex', 'antigravity')),
    CONSTRAINT pricing_catalogs_catalog_check
        CHECK (catalog IS NULL OR jsonb_typeof(catalog) = 'object')
);
