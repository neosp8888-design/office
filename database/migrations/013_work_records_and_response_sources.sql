-- 이 파일은 작업 기록 원본과 턴별 응답 출처를 기존 자료 손실 없이 추가한다.

CREATE TABLE IF NOT EXISTS projects (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    repository_root text NOT NULL,
    name text,
    default_branch text,
    archived_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT projects_repository_root_unique UNIQUE (repository_root)
);

CREATE TABLE IF NOT EXISTS work_record_imports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
    source_commit text NOT NULL,
    checklist_sha256 text NOT NULL,
    context_notes_sha256 text NOT NULL,
    parser_version text NOT NULL,
    status text NOT NULL DEFAULT 'planned',
    source_counts jsonb NOT NULL DEFAULT '{}'::jsonb,
    error_message text,
    started_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    CONSTRAINT work_record_imports_status_check CHECK (
        status IN ('planned', 'running', 'completed', 'failed')
    ),
    CONSTRAINT work_record_imports_source_counts_check CHECK (
        jsonb_typeof(source_counts) = 'object'
    ),
    CONSTRAINT work_record_imports_source_unique UNIQUE (
        project_id,
        source_commit,
        checklist_sha256,
        context_notes_sha256
    ),
    CONSTRAINT work_record_imports_record_reference_unique UNIQUE (
        id,
        project_id,
        source_commit
    )
);

CREATE TABLE IF NOT EXISTS work_records (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
    import_id uuid,
    record_type text NOT NULL,
    lifecycle_state text NOT NULL DEFAULT 'active',
    title text NOT NULL,
    body text NOT NULL DEFAULT '',
    legacy_stage_number integer,
    character_id text REFERENCES characters(id) ON DELETE SET NULL,
    attribution text NOT NULL DEFAULT 'unknown',
    source_turn_id uuid REFERENCES turns(id) ON DELETE SET NULL,
    source_workspace_id uuid REFERENCES task_workspaces(id) ON DELETE SET NULL,
    source_path text,
    source_commit text,
    source_section_ordinal integer,
    source_line_start integer,
    source_line_end integer,
    source_section_sha256 text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    recorded_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    search_document tsvector GENERATED ALWAYS AS (
        to_tsvector('simple', coalesce(title, '') || ' ' || coalesce(body, ''))
    ) STORED,
    CONSTRAINT work_records_type_check CHECK (
        record_type IN (
            'task',
            'decision',
            'constraint',
            'evidence',
            'status',
            'result',
            'note'
        )
    ),
    CONSTRAINT work_records_lifecycle_check CHECK (
        lifecycle_state IN ('legacy', 'active', 'superseded', 'archived')
    ),
    CONSTRAINT work_records_attribution_check CHECK (
        attribution IN ('character', 'user', 'commit', 'unknown', 'system')
    ),
    CONSTRAINT work_records_metadata_check CHECK (
        jsonb_typeof(metadata) = 'object'
    ),
    CONSTRAINT work_records_source_ordinal_check CHECK (
        source_section_ordinal IS NULL OR source_section_ordinal >= 0
    ),
    CONSTRAINT work_records_source_lines_check CHECK (
        (source_line_start IS NULL AND source_line_end IS NULL)
        OR (
            source_line_start IS NOT NULL
            AND source_line_end IS NOT NULL
            AND source_line_start > 0
            AND source_line_end >= source_line_start
        )
    ),
    CONSTRAINT work_records_import_source_check CHECK (
        import_id IS NULL
        OR (
            source_path IS NOT NULL
            AND source_commit IS NOT NULL
            AND source_section_ordinal IS NOT NULL
            AND source_section_sha256 IS NOT NULL
        )
    ),
    CONSTRAINT work_records_import_project_commit_fkey FOREIGN KEY (
        import_id,
        project_id,
        source_commit
    ) REFERENCES work_record_imports (
        id,
        project_id,
        source_commit
    ) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS work_records_source_unique_idx
ON work_records (
    project_id,
    source_path,
    source_commit,
    source_section_ordinal
)
WHERE source_path IS NOT NULL
  AND source_commit IS NOT NULL
  AND source_section_ordinal IS NOT NULL;

CREATE INDEX IF NOT EXISTS work_records_project_state_idx
ON work_records (project_id, lifecycle_state, recorded_at DESC);

CREATE INDEX IF NOT EXISTS work_records_character_idx
ON work_records (character_id, recorded_at DESC)
WHERE character_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS work_records_search_idx
ON work_records USING gin (search_document);

CREATE TABLE IF NOT EXISTS work_record_items (
    record_id uuid NOT NULL REFERENCES work_records(id) ON DELETE CASCADE,
    ordinal integer NOT NULL,
    item_text text NOT NULL,
    is_checked boolean,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (record_id, ordinal),
    CONSTRAINT work_record_items_ordinal_check CHECK (ordinal >= 0),
    CONSTRAINT work_record_items_metadata_check CHECK (
        jsonb_typeof(metadata) = 'object'
    )
);

CREATE TABLE IF NOT EXISTS work_record_links (
    source_record_id uuid NOT NULL
        REFERENCES work_records(id) ON DELETE CASCADE,
    target_record_id uuid NOT NULL
        REFERENCES work_records(id) ON DELETE RESTRICT,
    relation text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source_record_id, target_record_id, relation),
    CONSTRAINT work_record_links_relation_check CHECK (
        relation IN ('paired_with', 'supersedes', 'derived_from', 'related')
    ),
    CONSTRAINT work_record_links_distinct_check CHECK (
        source_record_id <> target_record_id
    )
);

CREATE INDEX IF NOT EXISTS work_record_links_target_idx
ON work_record_links (target_record_id, relation);

CREATE TABLE IF NOT EXISTS work_record_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    record_id uuid NOT NULL REFERENCES work_records(id) ON DELETE RESTRICT,
    record_version integer NOT NULL,
    event_type text NOT NULL,
    actor_character_id text REFERENCES characters(id) ON DELETE SET NULL,
    actor_type text NOT NULL DEFAULT 'system',
    source_turn_id uuid REFERENCES turns(id) ON DELETE SET NULL,
    previous_value jsonb,
    next_value jsonb,
    idempotency_key text,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT work_record_events_version_unique UNIQUE (
        record_id,
        record_version
    ),
    CONSTRAINT work_record_events_version_check CHECK (record_version > 0),
    CONSTRAINT work_record_events_type_check CHECK (
        event_type IN ('created', 'updated', 'state_changed', 'linked', 'imported')
    ),
    CONSTRAINT work_record_events_actor_check CHECK (
        actor_type IN ('character', 'user', 'system', 'import', 'unknown')
    ),
    CONSTRAINT work_record_events_previous_check CHECK (
        previous_value IS NULL OR jsonb_typeof(previous_value) = 'object'
    ),
    CONSTRAINT work_record_events_next_check CHECK (
        next_value IS NULL OR jsonb_typeof(next_value) = 'object'
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS work_record_events_idempotency_idx
ON work_record_events (record_id, idempotency_key)
WHERE idempotency_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS work_record_events_record_time_idx
ON work_record_events (record_id, occurred_at, id);

ALTER TABLE turns
ADD COLUMN IF NOT EXISTS response_source_warning text;

CREATE TABLE IF NOT EXISTS turn_response_sources (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    turn_id uuid NOT NULL REFERENCES turns(id) ON DELETE CASCADE,
    ordinal integer NOT NULL,
    source_kind text NOT NULL,
    title text NOT NULL,
    locator text NOT NULL,
    excerpt text,
    rag_document_id uuid REFERENCES rag_documents(id) ON DELETE SET NULL,
    work_record_id uuid REFERENCES work_records(id) ON DELETE SET NULL,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT turn_response_sources_kind_check CHECK (
        source_kind IN ('rag', 'database', 'file')
    ),
    CONSTRAINT turn_response_sources_ordinal_check CHECK (ordinal >= 0),
    CONSTRAINT turn_response_sources_metadata_check CHECK (
        jsonb_typeof(metadata) = 'object'
    ),
    CONSTRAINT turn_response_sources_turn_ordinal_unique UNIQUE (
        turn_id,
        ordinal
    ),
    CONSTRAINT turn_response_sources_turn_locator_unique UNIQUE (
        turn_id,
        source_kind,
        locator
    )
);

CREATE INDEX IF NOT EXISTS turn_response_sources_rag_idx
ON turn_response_sources (rag_document_id)
WHERE rag_document_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS turn_response_sources_work_record_idx
ON turn_response_sources (work_record_id)
WHERE work_record_id IS NOT NULL;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'task_workspaces'::regclass
          AND conname = 'task_workspaces_cli_session_id_fkey'
          AND confdeltype <> 'r'
    ) THEN
        ALTER TABLE task_workspaces
        DROP CONSTRAINT task_workspaces_cli_session_id_fkey;

        ALTER TABLE task_workspaces
        ADD CONSTRAINT task_workspaces_cli_session_id_fkey
        FOREIGN KEY (cli_session_id)
        REFERENCES cli_sessions(id)
        ON DELETE RESTRICT
        NOT VALID;

        ALTER TABLE task_workspaces
        VALIDATE CONSTRAINT task_workspaces_cli_session_id_fkey;
    ELSIF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'task_workspaces'::regclass
          AND conname = 'task_workspaces_cli_session_id_fkey'
    ) THEN
        ALTER TABLE task_workspaces
        ADD CONSTRAINT task_workspaces_cli_session_id_fkey
        FOREIGN KEY (cli_session_id)
        REFERENCES cli_sessions(id)
        ON DELETE RESTRICT;
    END IF;
END
$$;
