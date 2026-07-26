-- 이 파일은 캐릭터와 CLI 대화 및 RAG 저장을 위한 PostgreSQL 초기 스키마를 만든다.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS characters (
    id text PRIMARY KEY,
    name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 30),
    seat text NOT NULL,
    backend text NOT NULL CHECK (backend IN ('codex', 'claude')),
    identity_prompt text NOT NULL DEFAULT '',
    config jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS conversations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    title text NOT NULL,
    workdir text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cli_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    character_id text NOT NULL REFERENCES characters(id),
    external_id text,
    started_at timestamptz NOT NULL DEFAULT now(),
    ended_at timestamptz,
    handoff_note text,
    previous_session_id uuid REFERENCES cli_sessions(id),
    UNIQUE (conversation_id, character_id)
);

CREATE TABLE IF NOT EXISTS turns (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cli_session_id uuid NOT NULL REFERENCES cli_sessions(id) ON DELETE CASCADE,
    prompt text NOT NULL,
    started_at timestamptz NOT NULL DEFAULT now(),
    ended_at timestamptz
);

CREATE TABLE IF NOT EXISTS messages (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    turn_id uuid NOT NULL REFERENCES turns(id) ON DELETE CASCADE,
    role text NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
    text text NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS usage_records (
    turn_id uuid PRIMARY KEY REFERENCES turns(id) ON DELETE CASCADE,
    input_tokens bigint,
    output_tokens bigint,
    cached_input_tokens bigint,
    reasoning_output_tokens bigint,
    cost_usd numeric(14, 8)
);

CREATE TABLE IF NOT EXISTS rag_documents (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source text,
    title text,
    content text NOT NULL,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    embedding vector(1536),
    search_document tsvector GENERATED ALWAYS AS (
        to_tsvector(
            'simple',
            coalesce(title, '') || ' ' || content
        )
    ) STORED,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS rag_documents_search_idx
ON rag_documents USING gin (search_document);

CREATE INDEX IF NOT EXISTS rag_documents_embedding_idx
ON rag_documents USING hnsw (embedding vector_cosine_ops);
