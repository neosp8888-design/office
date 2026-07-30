-- 이 파일은 Codex 턴에 Ultra 추론 값을 저장할 수 있도록 제약조건을 확장한다.

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
);
