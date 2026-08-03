-- 이 파일은 기존 Slack 스레드에 실제 대화 연결과 재시작 후 응답 복구 상태를 추가한다.

ALTER TABLE slack_threads
DROP CONSTRAINT IF EXISTS slack_threads_conversation_unique;

ALTER TABLE slack_threads
ADD COLUMN IF NOT EXISTS status_message_ts text;

ALTER TABLE slack_threads
ADD COLUMN IF NOT EXISTS delivery_completed_at timestamptz;

CREATE INDEX IF NOT EXISTS slack_threads_pending_delivery_idx
ON slack_threads (updated_at)
WHERE last_turn_id IS NOT NULL
  AND status_message_ts IS NOT NULL
  AND delivery_completed_at IS NULL;
