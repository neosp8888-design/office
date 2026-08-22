-- 이 파일은 Codex 하위 에이전트 협업 요청과 결과를 구조화해 저장한다.

ALTER TABLE turn_activities
DROP CONSTRAINT IF EXISTS turn_activities_kind_check;

ALTER TABLE turn_activities
ADD CONSTRAINT turn_activities_kind_check
CHECK (
    kind IN (
        'thinking',
        'command',
        'tool',
        'message',
        'collaboration',
        'suggestion'
    )
);

ALTER TABLE turn_activities
ADD COLUMN IF NOT EXISTS collaboration jsonb;
