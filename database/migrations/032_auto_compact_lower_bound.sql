-- 자동 압축 기준 하한을 Codex가 실제로 유지하는 맥락 크기까지 낮춘다.
-- Claude 창은 100만 토큰이라 50%(50만)로는 Codex 최대(약 27만)에 맞출 수 없다.

ALTER TABLE characters
DROP CONSTRAINT IF EXISTS characters_auto_compact_percent_check;

ALTER TABLE characters
ADD CONSTRAINT characters_auto_compact_percent_check
CHECK (auto_compact_percent BETWEEN 20 AND 95);

UPDATE characters
SET auto_compact_percent = 25, updated_at = now()
WHERE backend = 'claude' AND auto_compact_percent = 50;
