-- 이 파일은 캐릭터별 활성 CLI 세션을 영속화하고 외부 세션 중복을 방지한다.

ALTER TABLE cli_sessions
DROP CONSTRAINT IF EXISTS cli_sessions_conversation_id_character_id_key;

DO $$
DECLARE
    duplicate_session record;
BEGIN
    FOR duplicate_session IN
        SELECT id, keeper_id
        FROM (
            SELECT
                id,
                first_value(id) OVER (
                    PARTITION BY character_id, external_id
                    ORDER BY started_at, id
                ) AS keeper_id
            FROM cli_sessions
            WHERE external_id IS NOT NULL
        ) ranked
        WHERE id <> keeper_id
    LOOP
        UPDATE turns
        SET cli_session_id = duplicate_session.keeper_id
        WHERE cli_session_id = duplicate_session.id;

        UPDATE cli_sessions AS keeper
        SET ended_at = CASE
            WHEN keeper.ended_at IS NULL OR duplicate.ended_at IS NULL
                THEN NULL
            ELSE GREATEST(keeper.ended_at, duplicate.ended_at)
        END
        FROM cli_sessions AS duplicate
        WHERE keeper.id = duplicate_session.keeper_id
          AND duplicate.id = duplicate_session.id;

        UPDATE cli_sessions
        SET previous_session_id = CASE
            WHEN id = duplicate_session.keeper_id THEN NULL
            ELSE duplicate_session.keeper_id
        END
        WHERE previous_session_id = duplicate_session.id;

        DELETE FROM cli_sessions
        WHERE id = duplicate_session.id;
    END LOOP;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS
cli_sessions_character_external_id_unique
ON cli_sessions (character_id, external_id)
WHERE external_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS
cli_sessions_character_id_id_unique
ON cli_sessions (character_id, id);

CREATE INDEX IF NOT EXISTS cli_sessions_character_started_at_idx
ON cli_sessions (character_id, started_at DESC);

CREATE TABLE IF NOT EXISTS active_cli_sessions (
    character_id text PRIMARY KEY REFERENCES characters(id) ON DELETE CASCADE,
    cli_session_id uuid NOT NULL UNIQUE,
    activated_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT active_cli_sessions_character_session_fkey
        FOREIGN KEY (character_id, cli_session_id)
        REFERENCES cli_sessions(character_id, id)
        ON DELETE CASCADE
);

WITH latest_sessions AS (
    SELECT DISTINCT ON (character_id)
        session.id,
        session.character_id,
        session.started_at,
        GREATEST(
            session.started_at,
            COALESCE(MAX(turn.started_at), session.started_at)
        ) AS last_activity_at
    FROM cli_sessions AS session
    LEFT JOIN turns AS turn
        ON turn.cli_session_id = session.id
    WHERE session.external_id IS NOT NULL
      AND session.ended_at IS NULL
    GROUP BY session.id
    ORDER BY
        session.character_id,
        last_activity_at DESC,
        session.id DESC
)
UPDATE cli_sessions AS session
SET ended_at = GREATEST(session.started_at, latest.last_activity_at)
FROM latest_sessions AS latest
WHERE session.character_id = latest.character_id
  AND session.id <> latest.id
  AND session.ended_at IS NULL;

DELETE FROM active_cli_sessions AS active
USING cli_sessions AS session
WHERE active.cli_session_id = session.id
  AND (
      session.external_id IS NULL
      OR session.ended_at IS NOT NULL
  );

INSERT INTO active_cli_sessions (
    character_id,
    cli_session_id,
    activated_at,
    updated_at
)
SELECT
    session.character_id,
    session.id,
    session.started_at,
    now()
FROM (
    SELECT DISTINCT ON (character_id)
        cli_session.id,
        cli_session.character_id,
        cli_session.started_at,
        GREATEST(
            cli_session.started_at,
            COALESCE(MAX(turn.started_at), cli_session.started_at)
        ) AS last_activity_at
    FROM cli_sessions AS cli_session
    LEFT JOIN turns AS turn
        ON turn.cli_session_id = cli_session.id
    WHERE cli_session.external_id IS NOT NULL
      AND cli_session.ended_at IS NULL
    GROUP BY cli_session.id
    ORDER BY
        cli_session.character_id,
        last_activity_at DESC,
        cli_session.id DESC
) AS session
ON CONFLICT (character_id) DO UPDATE
SET
    cli_session_id = EXCLUDED.cli_session_id,
    activated_at = EXCLUDED.activated_at,
    updated_at = now();
