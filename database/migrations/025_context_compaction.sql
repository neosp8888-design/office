-- 직원별 자동 컨텍스트 압축 기준을 저장한다.

ALTER TABLE characters
ADD COLUMN IF NOT EXISTS auto_compact_percent smallint NOT NULL DEFAULT 90;

ALTER TABLE characters
DROP CONSTRAINT IF EXISTS characters_auto_compact_percent_check;

ALTER TABLE characters
ADD CONSTRAINT characters_auto_compact_percent_check
CHECK (auto_compact_percent BETWEEN 50 AND 95);
