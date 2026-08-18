-- 이 파일은 CLI가 제안한 다음 질문을 일반 업무 활동과 구분해 저장한다.

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
