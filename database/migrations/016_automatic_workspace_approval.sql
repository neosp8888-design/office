-- 이 파일은 업무 변경의 자동 승인 설정과 작업 공간별 자동 복구 상태를 저장한다.

CREATE TABLE IF NOT EXISTS automation_settings (
    singleton boolean PRIMARY KEY DEFAULT true,
    auto_approve_workspaces boolean NOT NULL DEFAULT true,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT automation_settings_singleton_check CHECK (singleton)
);

ALTER TABLE automation_settings
ADD COLUMN IF NOT EXISTS auto_approve_workspaces boolean;

UPDATE automation_settings
SET auto_approve_workspaces = true
WHERE auto_approve_workspaces IS NULL;

ALTER TABLE automation_settings
ALTER COLUMN auto_approve_workspaces SET DEFAULT true;

ALTER TABLE automation_settings
ALTER COLUMN auto_approve_workspaces SET NOT NULL;

INSERT INTO automation_settings (singleton)
VALUES (true)
ON CONFLICT (singleton) DO NOTHING;

ALTER TABLE task_workspaces
ADD COLUMN IF NOT EXISTS auto_retry_count integer;

UPDATE task_workspaces
SET auto_retry_count = 0
WHERE auto_retry_count IS NULL;

ALTER TABLE task_workspaces
ALTER COLUMN auto_retry_count SET DEFAULT 0;

ALTER TABLE task_workspaces
ALTER COLUMN auto_retry_count SET NOT NULL;

ALTER TABLE task_workspaces
ADD COLUMN IF NOT EXISTS auto_repair_paused boolean;

UPDATE task_workspaces
SET auto_repair_paused = false
WHERE auto_repair_paused IS NULL;

ALTER TABLE task_workspaces
ALTER COLUMN auto_repair_paused SET DEFAULT false;

ALTER TABLE task_workspaces
ALTER COLUMN auto_repair_paused SET NOT NULL;

ALTER TABLE task_workspaces
ADD COLUMN IF NOT EXISTS auto_waiting_for_peer boolean;

UPDATE task_workspaces
SET auto_waiting_for_peer = false
WHERE auto_waiting_for_peer IS NULL;

ALTER TABLE task_workspaces
ALTER COLUMN auto_waiting_for_peer SET DEFAULT false;

ALTER TABLE task_workspaces
ALTER COLUMN auto_waiting_for_peer SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'task_workspaces'::regclass
          AND conname = 'task_workspaces_auto_retry_count_check'
    ) THEN
        ALTER TABLE task_workspaces
        ADD CONSTRAINT task_workspaces_auto_retry_count_check
        CHECK (auto_retry_count BETWEEN 0 AND 3);
    END IF;
END
$$;
