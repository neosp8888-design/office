-- 이 파일은 Slack 사용자 선택과 스레드별 OFFICESTRA 대화 연결을 저장한다.

CREATE TABLE IF NOT EXISTS slack_user_preferences (
    team_id text NOT NULL,
    user_id text NOT NULL,
    character_id text NOT NULL REFERENCES characters(id) ON DELETE RESTRICT,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (team_id, user_id)
);

CREATE TABLE IF NOT EXISTS slack_threads (
    team_id text NOT NULL,
    channel_id text NOT NULL,
    thread_ts text NOT NULL,
    user_id text NOT NULL,
    character_id text NOT NULL REFERENCES characters(id) ON DELETE RESTRICT,
    conversation_id uuid NOT NULL DEFAULT gen_random_uuid(),
    last_turn_id uuid REFERENCES turns(id) ON DELETE SET NULL,
    status_message_ts text,
    delivery_completed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (team_id, channel_id, thread_ts)
);

ALTER TABLE slack_threads
ADD COLUMN IF NOT EXISTS status_message_ts text;

ALTER TABLE slack_threads
ADD COLUMN IF NOT EXISTS delivery_completed_at timestamptz;

CREATE INDEX IF NOT EXISTS slack_threads_user_updated_idx
ON slack_threads (team_id, user_id, updated_at DESC);

CREATE INDEX IF NOT EXISTS slack_threads_pending_delivery_idx
ON slack_threads (updated_at)
WHERE last_turn_id IS NOT NULL
  AND status_message_ts IS NOT NULL
  AND delivery_completed_at IS NULL;

CREATE TABLE IF NOT EXISTS slack_event_receipts (
    event_id text PRIMARY KEY,
    received_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS slack_event_receipts_received_idx
ON slack_event_receipts (received_at DESC);
