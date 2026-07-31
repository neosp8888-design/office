-- 이 파일은 캐릭터별 Fast 모드 설정과 턴별 실제 실행값을 저장한다.

ALTER TABLE characters
ADD COLUMN IF NOT EXISTS fast_mode boolean NOT NULL DEFAULT true;

UPDATE characters
SET fast_mode = false
WHERE backend = 'claude'
  AND model IS DISTINCT FROM 'claude-opus-5';

ALTER TABLE turns
ADD COLUMN IF NOT EXISTS fast_mode boolean;

UPDATE turns
SET fast_mode = false
WHERE fast_mode IS NULL;
