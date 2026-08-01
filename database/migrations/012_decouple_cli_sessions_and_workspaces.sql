-- 이 파일은 CLI 세션과 업무 worktree를 독립 식별자로 분리하고 각 턴을 실행 worktree에 연결한다.

ALTER TABLE task_workspaces
ADD COLUMN IF NOT EXISTS id uuid;

UPDATE task_workspaces
SET id = gen_random_uuid()
WHERE id IS NULL;

ALTER TABLE task_workspaces
ALTER COLUMN id SET DEFAULT gen_random_uuid();

ALTER TABLE task_workspaces
ALTER COLUMN id SET NOT NULL;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'task_workspaces'::regclass
          AND contype = 'p'
          AND pg_get_constraintdef(oid) = 'PRIMARY KEY (cli_session_id)'
    ) THEN
        ALTER TABLE task_workspaces
        DROP CONSTRAINT task_workspaces_pkey;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'task_workspaces'::regclass
          AND contype = 'p'
    ) THEN
        ALTER TABLE task_workspaces
        ADD CONSTRAINT task_workspaces_pkey PRIMARY KEY (id);
    END IF;
END
$$;

ALTER TABLE turns
ADD COLUMN IF NOT EXISTS task_workspace_id uuid;

UPDATE turns AS turn
SET task_workspace_id = workspace.id
FROM task_workspaces AS workspace
WHERE turn.task_workspace_id IS NULL
  AND workspace.review_turn_id = turn.id;

WITH sole_workspace AS (
    SELECT cli_session_id, id
    FROM (
        SELECT
            cli_session_id,
            id,
            count(*) OVER (PARTITION BY cli_session_id) AS workspace_count
        FROM task_workspaces
    ) AS ranked
    WHERE workspace_count = 1
)
UPDATE turns AS turn
SET task_workspace_id = workspace.id
FROM sole_workspace AS workspace
WHERE turn.task_workspace_id IS NULL
  AND turn.cli_session_id = workspace.cli_session_id;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'turns'::regclass
          AND conname = 'turns_task_workspace_id_fkey'
    ) THEN
        ALTER TABLE turns
        ADD CONSTRAINT turns_task_workspace_id_fkey
        FOREIGN KEY (task_workspace_id)
        REFERENCES task_workspaces(id)
        ON DELETE SET NULL;
    END IF;
END
$$;

WITH legacy_ended_candidates AS (
    SELECT DISTINCT ON (session.character_id)
        session.id,
        session.character_id,
        session.started_at
    FROM cli_sessions AS session
    JOIN task_workspaces AS workspace
        ON workspace.cli_session_id = session.id
    JOIN characters AS character
        ON character.id = session.character_id
    JOIN LATERAL (
        SELECT turn.backend
        FROM turns AS turn
        WHERE turn.cli_session_id = session.id
        ORDER BY turn.started_at DESC, turn.id DESC
        LIMIT 1
    ) AS latest_turn ON true
    LEFT JOIN active_cli_sessions AS active
        ON active.character_id = session.character_id
    WHERE active.character_id IS NULL
      AND session.external_id IS NOT NULL
      AND session.ended_at IS NOT NULL
      AND latest_turn.backend = character.backend
      AND (
          (
              workspace.status = 'merged'
              AND session.ended_at = workspace.merged_at
          )
          OR (
              workspace.status = 'rejected'
              AND session.ended_at = workspace.rejected_at
          )
      )
    ORDER BY session.character_id, session.started_at DESC, session.id DESC
), reopened_sessions AS (
    UPDATE cli_sessions AS session
    SET ended_at = NULL
    FROM legacy_ended_candidates AS candidate
    WHERE session.id = candidate.id
    RETURNING session.id, session.character_id
)
INSERT INTO active_cli_sessions (
    character_id,
    cli_session_id,
    activated_at,
    updated_at
)
SELECT character_id, id, now(), now()
FROM reopened_sessions
ON CONFLICT (character_id) DO NOTHING;

CREATE INDEX IF NOT EXISTS task_workspaces_cli_session_id_idx
ON task_workspaces (cli_session_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS task_workspaces_one_open_per_session_idx
ON task_workspaces (cli_session_id)
WHERE status IN (
    'provisioning',
    'active',
    'awaiting_approval',
    'merging',
    'conflict'
);

CREATE INDEX IF NOT EXISTS turns_task_workspace_id_idx
ON turns (task_workspace_id)
WHERE task_workspace_id IS NOT NULL;
