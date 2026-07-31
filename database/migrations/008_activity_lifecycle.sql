-- 이 파일은 같은 에이전트 작업의 시작과 완료를 한 활동 행으로 관리한다.

ALTER TABLE turn_activities
ADD COLUMN IF NOT EXISTS event_key text;

ALTER TABLE turn_activities
ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'completed';

ALTER TABLE turn_activities
DROP CONSTRAINT IF EXISTS turn_activities_status_check;

ALTER TABLE turn_activities
ADD CONSTRAINT turn_activities_status_check
CHECK (status IN ('running', 'completed', 'failed'));

CREATE UNIQUE INDEX IF NOT EXISTS turn_activities_event_key_idx
ON turn_activities (turn_id, event_key)
WHERE event_key IS NOT NULL;
