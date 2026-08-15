-- 이 파일은 하나의 CLI 세션이 검토 대기 업무를 보존한 채 다음 업무를
-- 별도 worktree에서 계속할 수 있도록 실행 중 workspace만 하나로 제한한다.

DROP INDEX IF EXISTS task_workspaces_one_open_per_session_idx;

CREATE UNIQUE INDEX task_workspaces_one_open_per_session_idx
ON task_workspaces (cli_session_id)
WHERE status = 'provisioning'
   OR (
       status = 'active'
       AND auto_repair_paused = false
   );
