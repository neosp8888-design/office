-- 이 파일은 Google Antigravity CLI를 세 번째 직원 실행 백엔드로 추가한다.

ALTER TABLE characters
DROP CONSTRAINT IF EXISTS characters_backend_check;

ALTER TABLE characters
ADD CONSTRAINT characters_backend_check
CHECK (backend IN ('codex', 'claude', 'antigravity'));

ALTER TABLE turns
DROP CONSTRAINT IF EXISTS turns_backend_check;

ALTER TABLE turns
ADD CONSTRAINT turns_backend_check
CHECK (
    backend IS NULL
    OR backend IN ('codex', 'claude', 'antigravity')
);

ALTER TABLE turns
DROP CONSTRAINT IF EXISTS turns_effort_check;

ALTER TABLE turns
ADD CONSTRAINT turns_effort_check
CHECK (
    effort IS NULL
    OR (
        backend = 'codex'
        AND effort IN ('high', 'xhigh', 'max', 'ultra')
    )
    OR (
        backend = 'claude'
        AND effort IN ('high', 'xhigh', 'max')
    )
    OR (
        backend = 'antigravity'
        AND effort IN ('low', 'medium', 'high')
    )
);
