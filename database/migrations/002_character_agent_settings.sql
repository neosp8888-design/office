-- 이 파일은 캐릭터별 CLI 모델과 추론 및 권한 설정을 PostgreSQL에 추가한다.

ALTER TABLE characters
ADD COLUMN IF NOT EXISTS model text;

ALTER TABLE characters
ADD COLUMN IF NOT EXISTS effort text NOT NULL DEFAULT 'high';

ALTER TABLE characters
ADD COLUMN IF NOT EXISTS permission text;

UPDATE characters
SET
    model = CASE backend
        WHEN 'codex' THEN 'gpt-5.6-sol'
        ELSE 'claude-opus-5'
    END,
    effort = 'high',
    permission = CASE backend
        WHEN 'codex' THEN 'workspace-write'
        ELSE 'acceptEdits'
    END
WHERE model IS NULL OR permission IS NULL;

ALTER TABLE characters
ALTER COLUMN permission SET NOT NULL;
