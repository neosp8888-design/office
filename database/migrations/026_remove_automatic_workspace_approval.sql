-- 자동 승인·병합과 자동 복구 상태를 제거한다. 완료된 변경은 명시적으로
-- 통합될 때까지 awaiting_approval 상태의 격리 worktree에 보존한다.

UPDATE task_workspaces
SET
    status = CASE
        WHEN review_turn_id IS NOT NULL THEN 'awaiting_approval'
        ELSE 'failed'
    END,
    error_message = CASE
        WHEN review_turn_id IS NOT NULL
            THEN '자동 통합이 제거되어 명시적 통합 대기로 전환했습니다.'
        ELSE '자동 복구 작업을 연결할 검토 기록이 없어 작업공간을 중단했습니다.'
    END,
    updated_at = now()
WHERE status = 'active'
  AND auto_retry_count > 0;

DROP INDEX IF EXISTS task_workspaces_one_open_per_session_idx;

ALTER TABLE task_workspaces
DROP CONSTRAINT IF EXISTS task_workspaces_auto_retry_count_check;

ALTER TABLE task_workspaces
DROP COLUMN IF EXISTS auto_retry_count,
DROP COLUMN IF EXISTS auto_repair_paused,
DROP COLUMN IF EXISTS auto_waiting_for_peer;

CREATE UNIQUE INDEX task_workspaces_one_open_per_session_idx
ON task_workspaces (cli_session_id)
WHERE status IN ('provisioning', 'active');

DROP TABLE IF EXISTS automation_settings;
