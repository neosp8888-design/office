-- 이 파일은 CLI 세션별 Git 작업 공간과 검토 및 병합 상태를 영속화한다.

CREATE TABLE IF NOT EXISTS task_workspaces (
    cli_session_id uuid PRIMARY KEY
        REFERENCES cli_sessions(id) ON DELETE CASCADE,
    status text NOT NULL DEFAULT 'provisioning',
    repository_root text NOT NULL,
    source_workdir text NOT NULL,
    worktree_path text NOT NULL UNIQUE,
    execution_workdir text NOT NULL,
    branch_name text NOT NULL,
    base_branch text NOT NULL,
    base_commit text NOT NULL,
    review_turn_id uuid REFERENCES turns(id) ON DELETE SET NULL,
    review_tree text,
    head_commit text,
    changed_files jsonb NOT NULL DEFAULT '[]'::jsonb,
    task_commit text,
    merged_commit text,
    error_message text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    review_requested_at timestamptz,
    merged_at timestamptz,
    rejected_at timestamptz,
    CONSTRAINT task_workspaces_status_check CHECK (
        status IN (
            'provisioning',
            'active',
            'awaiting_approval',
            'merging',
            'merged',
            'rejected',
            'closed',
            'conflict',
            'failed'
        )
    ),
    CONSTRAINT task_workspaces_changed_files_check CHECK (
        jsonb_typeof(changed_files) = 'array'
    ),
    CONSTRAINT task_workspaces_repository_branch_unique UNIQUE (
        repository_root,
        branch_name
    )
);

CREATE INDEX IF NOT EXISTS task_workspaces_status_updated_idx
ON task_workspaces (status, updated_at DESC);

CREATE INDEX IF NOT EXISTS task_workspaces_review_turn_idx
ON task_workspaces (review_turn_id)
WHERE review_turn_id IS NOT NULL;
