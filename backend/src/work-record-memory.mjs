// 이 파일은 완료 턴을 작업 기록으로 저장하고 파생 RAG 검색 자료를 만든다.

import { basename } from "node:path";

const SEARCH_TOKEN_LIMIT = 10;
const SEARCH_STOP_WORDS = new Set([
  "그냥",
  "계속",
  "계속해",
  "다시",
  "부탁",
  "부탁해",
  "이거",
  "이제",
  "진행",
  "진행해",
  "처리",
  "처리해",
  "확인",
  "확인해",
  "해줘",
]);

export function workRecordTitle(prompt) {
  const firstLine = String(prompt ?? "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find(Boolean) ?? "완료된 업무";
  const compact = firstLine.replace(/\s+/g, " ");
  return compact.length <= 120
    ? compact
    : `${compact.slice(0, 119)}…`;
}

export function completedTurnRecordBody(prompt, response) {
  return [
    "요청",
    String(prompt ?? "").trim(),
    "",
    "결과",
    String(response ?? "").trim(),
  ].join("\n").trim();
}

export function workRecordSearchTSQuery(query) {
  const tokens = String(query ?? "")
    .normalize("NFKC")
    .toLocaleLowerCase("ko-KR")
    .match(/[\p{L}\p{N}_]+/gu) ?? [];
  const unique = [];
  for (const token of tokens) {
    if (
      token.length < 2 ||
      token.length > 64 ||
      SEARCH_STOP_WORDS.has(token) ||
      unique.includes(token)
    ) {
      continue;
    }
    unique.push(token);
    if (unique.length >= SEARCH_TOKEN_LIMIT) {
      break;
    }
  }
  return unique.map((token) => `${token}:*`).join(" | ");
}

export async function persistCompletedTurnWorkRecord(client, {
  repositoryRoot,
  turnID,
  workspaceID = null,
  characterID,
  prompt,
  response,
  backend = null,
  model = null,
  needsInput = false,
  responseSourceCount = 0,
  responseSourceWarning = null,
  reviewStatus = "not_applicable",
  reviewTree = null,
  headCommit = null,
  changedFiles = [],
  recordedAt = null,
}) {
  const root = String(repositoryRoot ?? "").trim();
  if (!root) {
    throw new Error("작업 기록의 저장소 경로가 필요합니다.");
  }
  const title = workRecordTitle(prompt);
  const body = completedTurnRecordBody(prompt, response);
  const metadata = {
    source: "completed_turn",
    needsInput: needsInput === true,
    responseSourceCount: Number(responseSourceCount) || 0,
    ...(responseSourceWarning ? { responseSourceWarning } : {}),
    review: {
      status: reviewStatus,
      ...(reviewTree ? { reviewTree } : {}),
      ...(headCommit ? { headCommit } : {}),
      ...(Array.isArray(changedFiles) && changedFiles.length > 0
        ? { changedFiles }
        : {}),
    },
    ...(backend ? { backend } : {}),
    ...(model ? { model } : {}),
  };
  const result = await client.query(
    `
      WITH selected_project AS (
        INSERT INTO projects (repository_root, name)
        VALUES ($1, $2)
        ON CONFLICT (repository_root) DO UPDATE
        SET
          name = COALESCE(projects.name, EXCLUDED.name),
          updated_at = CASE
            WHEN projects.name IS NULL AND EXCLUDED.name IS NOT NULL
              THEN now()
            ELSE projects.updated_at
          END
        RETURNING id
      ), upserted_record AS (
        INSERT INTO work_records (
          project_id,
          record_type,
          lifecycle_state,
          title,
          body,
          character_id,
          attribution,
          source_turn_id,
          source_workspace_id,
          metadata,
          recorded_at,
          updated_at
        )
        SELECT
          project.id,
          'result',
          'active',
          $6,
          $7,
          $5,
          'character',
          $3,
          $4,
          $8::jsonb,
          COALESCE($9::timestamptz, now()),
          now()
        FROM selected_project AS project
        ON CONFLICT (source_turn_id, record_type)
          WHERE source_turn_id IS NOT NULL AND import_id IS NULL
        DO UPDATE SET id = work_records.id
        RETURNING *
      ), selected_record AS (
        SELECT * FROM upserted_record
        UNION ALL
        SELECT record.*
        FROM work_records AS record
        WHERE record.source_turn_id = $3
          AND record.record_type = 'result'
          AND record.import_id IS NULL
          AND NOT EXISTS (SELECT 1 FROM upserted_record)
      ), inserted_event AS (
        INSERT INTO work_record_events (
          record_id,
          record_version,
          event_type,
          actor_character_id,
          actor_type,
          source_turn_id,
          previous_value,
          next_value,
          idempotency_key,
          occurred_at
        )
        SELECT
          record.id,
          1,
          'created',
          $5,
          'character',
          $3,
          NULL,
          jsonb_build_object(
            'recordType', record.record_type,
            'lifecycleState', record.lifecycle_state,
            'title', record.title
          ),
          'completed-turn:' || $3::text,
          COALESCE($9::timestamptz, now())
        FROM selected_record AS record
        ON CONFLICT DO NOTHING
        RETURNING id
      )
      SELECT record.id::text AS "workRecordId"
      FROM selected_record AS record
    `,
    [
      root,
      basename(root) || null,
      turnID,
      workspaceID,
      characterID,
      title,
      body,
      JSON.stringify(metadata),
      recordedAt,
    ],
  );
  return result.rows?.[0] ?? null;
}

export async function transitionTurnWorkRecordReview(client, {
  turnID,
  status,
  taskCommit = null,
  mergedCommit = null,
  reviewTree = null,
  headCommit = null,
  changedFiles = null,
  errorMessage = null,
  actorType = "user",
  occurredAt = null,
}) {
  const review = {
    status,
    ...(taskCommit ? { taskCommit } : {}),
    ...(mergedCommit ? { mergedCommit } : {}),
    ...(reviewTree ? { reviewTree } : {}),
    ...(headCommit ? { headCommit } : {}),
    ...(Array.isArray(changedFiles) ? { changedFiles } : {}),
    errorMessage: errorMessage ?? null,
  };
  const eventKeyPart = taskCommit || mergedCommit || reviewTree || "none";
  await client.query(
    "SELECT pg_advisory_xact_lock(hashtext($1))",
    [`officestra:work-record:${turnID}`],
  );
  const result = await client.query(
    `
      WITH updated_record AS (
        UPDATE work_records
        SET
          lifecycle_state = CASE
            WHEN $2 = 'rejected' THEN 'archived'
            ELSE 'active'
          END,
          metadata = jsonb_set(
            metadata,
            '{review}',
            COALESCE(metadata->'review', '{}'::jsonb) || $3::jsonb,
            true
          ),
          updated_at = now()
        WHERE source_turn_id = $1
          AND record_type = 'result'
          AND import_id IS NULL
        RETURNING *
      ), inserted_event AS (
        INSERT INTO work_record_events (
          record_id,
          record_version,
          event_type,
          actor_character_id,
          actor_type,
          source_turn_id,
          previous_value,
          next_value,
          idempotency_key,
          occurred_at
        )
        SELECT
          record.id,
          COALESCE((
            SELECT max(event.record_version)
            FROM work_record_events AS event
            WHERE event.record_id = record.id
          ), 0) + 1,
          'state_changed',
          NULL,
          $4,
          $1,
          NULL,
          jsonb_build_object(
            'lifecycleState', record.lifecycle_state,
            'review', record.metadata->'review'
          ),
          $5,
          COALESCE($6::timestamptz, now())
        FROM updated_record AS record
        ON CONFLICT (record_id, idempotency_key)
          WHERE idempotency_key IS NOT NULL
        DO NOTHING
        RETURNING id
      )
      SELECT id::text AS "workRecordId"
      FROM updated_record
    `,
    [
      turnID,
      status,
      JSON.stringify(review),
      actorType,
      `review:${status}:${eventKeyPart}`,
      occurredAt,
    ],
  );
  return result.rows?.[0]?.workRecordId ?? null;
}

export async function reconcileTerminalWorkRecordReviews(client, {
  repositoryRoot = null,
} = {}) {
  const candidates = await client.query(
    `
      WITH terminal_candidates AS (
        SELECT
          record.source_turn_id::text AS "turnID",
          workspace.status,
          workspace.task_commit AS "taskCommit",
          workspace.merged_commit AS "mergedCommit",
          workspace.review_tree AS "reviewTree",
          workspace.head_commit AS "headCommit",
          workspace.changed_files AS "changedFiles",
          record.lifecycle_state AS "lifecycleState",
          record.metadata #>> '{review,status}' AS "reviewStatus",
          record.recorded_at AS "recordedAt",
          record.id AS "recordID"
        FROM work_records AS record
        JOIN projects AS project
          ON project.id = record.project_id
        JOIN task_workspaces AS workspace
          ON workspace.id = record.source_workspace_id
          AND workspace.review_turn_id = record.source_turn_id
        WHERE record.record_type = 'result'
          AND record.import_id IS NULL
          AND record.source_turn_id IS NOT NULL
          AND workspace.status IN ('merged', 'rejected')
          AND ($1::text IS NULL OR project.repository_root = $1)

        UNION ALL

        SELECT
          record.source_turn_id::text AS "turnID",
          'not_required' AS status,
          NULL AS "taskCommit",
          NULL AS "mergedCommit",
          workspace.review_tree AS "reviewTree",
          workspace.head_commit AS "headCommit",
          workspace.changed_files AS "changedFiles",
          record.lifecycle_state AS "lifecycleState",
          record.metadata #>> '{review,status}' AS "reviewStatus",
          record.recorded_at AS "recordedAt",
          record.id AS "recordID"
        FROM work_records AS record
        JOIN projects AS project
          ON project.id = record.project_id
        JOIN task_workspaces AS workspace
          ON workspace.id = record.source_workspace_id
        JOIN LATERAL (
          SELECT turn.id
          FROM turns AS turn
          WHERE turn.task_workspace_id = workspace.id
            AND turn.status = 'completed'
          ORDER BY turn.started_at DESC, turn.id DESC
          LIMIT 1
        ) AS latest_turn
          ON latest_turn.id = record.source_turn_id
        WHERE record.record_type = 'result'
          AND record.import_id IS NULL
          AND record.source_turn_id IS NOT NULL
          AND record.lifecycle_state = 'active'
          AND record.metadata->>'needsInput' IS DISTINCT FROM 'true'
          AND record.metadata #>> '{review,status}'
            IN ('awaiting_approval', 'conflict')
          AND workspace.status = 'closed'
          AND workspace.task_commit IS NULL
          AND workspace.merged_commit IS NULL
          AND workspace.merged_at IS NULL
          AND workspace.rejected_at IS NULL
          AND workspace.review_tree IS NULL
          AND jsonb_array_length(workspace.changed_files) = 0
          AND ($1::text IS NULL OR project.repository_root = $1)
      )
      SELECT *
      FROM terminal_candidates AS candidate
      WHERE (
          candidate.status = 'rejected'
          AND (
            candidate."lifecycleState" IS DISTINCT FROM 'archived'
            OR candidate."reviewStatus" IS DISTINCT FROM 'rejected'
          )
        )
        OR (
          candidate.status IN ('merged', 'not_required')
          AND (
            candidate."lifecycleState" IS DISTINCT FROM 'active'
            OR candidate."reviewStatus" IS DISTINCT FROM candidate.status
          )
        )
      ORDER BY candidate."recordedAt", candidate."recordID"
    `,
    [repositoryRoot],
  );
  const workRecordIDs = [];
  for (const candidate of candidates.rows ?? []) {
    const workRecordID = await transitionTurnWorkRecordReview(client, {
      turnID: candidate.turnID,
      status: candidate.status,
      taskCommit: candidate.taskCommit,
      mergedCommit: candidate.mergedCommit,
      reviewTree: candidate.reviewTree,
      headCommit: candidate.headCommit,
      changedFiles: candidate.changedFiles ?? [],
      actorType: "system",
    });
    if (workRecordID) {
      workRecordIDs.push(workRecordID);
    }
  }
  return workRecordIDs;
}

export async function syncWorkRecordRAGDocuments(client, {
  repositoryRoot = null,
  workRecordID = null,
} = {}) {
  const deleted = await client.query(
    `
      DELETE FROM rag_documents AS document
      USING work_records AS record, projects AS project
      WHERE document.work_record_id = record.id
        AND project.id = record.project_id
        AND ($1::text IS NULL OR project.repository_root = $1)
        AND ($2::uuid IS NULL OR record.id = $2)
        AND NOT EXISTS (
          SELECT 1
          FROM searchable_work_record_ids AS searchable
          WHERE searchable.id = record.id
        )
    `,
    [repositoryRoot, workRecordID],
  );
  const result = await client.query(
    `
      WITH desired_documents AS (
        SELECT
          record.id AS work_record_id,
          record.title,
          COALESCE(
            NULLIF(record.body, ''),
            NULLIF(items.content, ''),
            ''
          ) AS content,
          jsonb_strip_nulls(jsonb_build_object(
            'workRecordId', record.id::text,
            'projectId', record.project_id::text,
            'recordType', record.record_type,
            'lifecycleState', record.lifecycle_state,
            'characterId', record.character_id,
            'attribution', record.attribution,
            'recordedAt', record.recorded_at,
            'sourcePath', record.source_path,
            'sourceCommit', record.source_commit
          )) AS metadata
        FROM work_records AS record
        JOIN searchable_work_record_ids AS searchable
          ON searchable.id = record.id
        JOIN projects AS project ON project.id = record.project_id
        LEFT JOIN LATERAL (
          SELECT string_agg(
            CASE
              WHEN item.is_checked IS TRUE THEN '- [x] ' || item.item_text
              WHEN item.is_checked IS FALSE THEN '- [ ] ' || item.item_text
              ELSE '- ' || item.item_text
            END,
            E'\n' ORDER BY item.ordinal
          ) AS content
          FROM work_record_items AS item
          WHERE item.record_id = record.id
        ) AS items ON true
        WHERE ($1::text IS NULL OR project.repository_root = $1)
          AND ($2::uuid IS NULL OR record.id = $2)
      )
      INSERT INTO rag_documents (
        source,
        title,
        content,
        metadata,
        work_record_id,
        updated_at
      )
      SELECT
        'work_record',
        desired.title,
        desired.content,
        desired.metadata,
        desired.work_record_id,
        now()
      FROM desired_documents AS desired
      ON CONFLICT (work_record_id) WHERE work_record_id IS NOT NULL
      DO UPDATE
      SET
        source = EXCLUDED.source,
        title = EXCLUDED.title,
        content = EXCLUDED.content,
        metadata = EXCLUDED.metadata,
        embedding = NULL,
        embedding_model = NULL,
        embedding_updated_at = NULL,
        embedding_error = NULL,
        updated_at = now()
      WHERE (
        rag_documents.source,
        rag_documents.title,
        rag_documents.content,
        rag_documents.metadata
      ) IS DISTINCT FROM (
        EXCLUDED.source,
        EXCLUDED.title,
        EXCLUDED.content,
        EXCLUDED.metadata
      )
      RETURNING id::text AS "ragDocumentId",
        work_record_id::text AS "workRecordId"
    `,
    [repositoryRoot, workRecordID],
  );
  return {
    changed: result.rowCount ?? 0,
    deleted: deleted.rowCount ?? 0,
    documents: result.rows ?? [],
  };
}
