-- 이 파일은 백엔드가 실행 중인 CLI 업무와 공개 진행 이벤트를 재접속 가능하게 저장한다.

ALTER TABLE turns
ADD COLUMN IF NOT EXISTS status text;

UPDATE turns
SET status = CASE
    WHEN ended_at IS NULL THEN 'interrupted'
    ELSE 'completed'
END
WHERE status IS NULL;

ALTER TABLE turns
ALTER COLUMN status SET DEFAULT 'completed';

ALTER TABLE turns
ALTER COLUMN status SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'turns_status_check'
    ) THEN
        ALTER TABLE turns
        ADD CONSTRAINT turns_status_check
        CHECK (
            status IN (
                'pending',
                'running',
                'completed',
                'failed',
                'interrupted'
            )
        );
    END IF;
END
$$;

ALTER TABLE turns
ADD COLUMN IF NOT EXISTS needs_input boolean NOT NULL DEFAULT false;

ALTER TABLE turns
ADD COLUMN IF NOT EXISTS error_message text;

ALTER TABLE turns
ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

CREATE TABLE IF NOT EXISTS turn_activities (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    turn_id uuid NOT NULL REFERENCES turns(id) ON DELETE CASCADE,
    seq integer NOT NULL,
    kind text NOT NULL CHECK (
        kind IN ('thinking', 'command', 'tool', 'message')
    ),
    text text NOT NULL,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (turn_id, seq)
);

CREATE INDEX IF NOT EXISTS turn_activities_turn_idx
ON turn_activities (turn_id, seq);

CREATE INDEX IF NOT EXISTS turns_status_started_idx
ON turns (status, started_at DESC);
