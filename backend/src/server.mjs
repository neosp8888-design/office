// 이 파일은 캐릭터 설정과 CLI 대화 기록 및 RAG 저장 API를 제공한다.

import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { WebSocket, WebSocketServer } from "ws";

import {
  AgentBusyError,
  AgentJobNotFoundError,
  AgentRuntime,
  CharacterNotFoundError,
} from "./agent-runtime.mjs";
import {
  appendLocalImagePreviews,
  generatedImagesForTurn,
} from "./local-artifacts.mjs";
import { pool, withTransaction } from "./db.mjs";
import {
  readCharacterConfiguration,
  syncCharacters,
} from "./configuration.mjs";
import { migrate } from "./migrate.mjs";

const port = Number(process.env.OFFICE_BACKEND_PORT ?? 4317);
const sockets = new Set();
const webSocketServer = new WebSocketServer({ noServer: true });
let runtime;

function broadcast(event) {
  const payload = JSON.stringify(event);
  for (const socket of sockets) {
    if (socket.readyState === WebSocket.OPEN) {
      socket.send(payload);
    }
  }
}

function send(response, status, body) {
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
  });
  response.end(JSON.stringify(body));
}

async function readJSON(request) {
  const chunks = [];
  for await (const chunk of request) {
    chunks.push(chunk);
  }
  if (chunks.length === 0) {
    return {};
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function routeCharacterName(pathname) {
  const match = pathname.match(/^\/api\/characters\/([^/]+)\/name$/);
  return match ? decodeURIComponent(match[1]) : null;
}

function routeCharacterSettings(pathname) {
  const match = pathname.match(/^\/api\/characters\/([^/]+)\/settings$/);
  return match ? decodeURIComponent(match[1]) : null;
}

function routeCharacterIdentityPrompt(pathname) {
  const match = pathname.match(
    /^\/api\/characters\/([^/]+)\/identity-prompt$/,
  );
  return match ? decodeURIComponent(match[1]) : null;
}

function routeCharacterHistory(pathname) {
  const match = pathname.match(/^\/api\/characters\/([^/]+)\/history$/);
  return match ? decodeURIComponent(match[1]) : null;
}

function routeAgentJob(pathname) {
  const match = pathname.match(/^\/api\/agent-jobs\/([^/]+)$/);
  return match ? decodeURIComponent(match[1]) : null;
}

function routeLiveFeedTurn(pathname) {
  const match = pathname.match(/^\/api\/live-feed\/([^/]+)$/);
  return match ? decodeURIComponent(match[1]) : null;
}

async function endActiveSession(client, characterID) {
  await client.query(
    `
      DELETE FROM active_cli_sessions
      WHERE character_id = $1
    `,
    [characterID],
  );

  await client.query(
    `
      UPDATE cli_sessions
      SET ended_at = COALESCE(ended_at, now())
      WHERE character_id = $1
        AND ended_at IS NULL
    `,
    [characterID],
  );
}

async function listCharacters(response) {
  const result = await pool.query(
    `
      SELECT
        id,
        name,
        seat,
        backend,
        model,
        effort,
        fast_mode AS "fastMode",
        permission,
        identity_prompt AS "identityPrompt"
      FROM characters
      ORDER BY
        CASE id
          WHEN 'boss' THEN 1
          WHEN 'left-man' THEN 2
          WHEN 'left-woman' THEN 3
          WHEN 'right-woman' THEN 4
          WHEN 'right-man' THEN 5
          ELSE 99
        END
    `,
  );
  send(response, 200, { characters: result.rows });
}

async function listActiveSessions(response) {
  const result = await pool.query(
    `
      SELECT
        active.character_id AS "characterId",
        session.external_id AS "externalSessionId",
        session.conversation_id AS "conversationId",
        session.started_at AS "startedAt"
      FROM active_cli_sessions AS active
      JOIN cli_sessions AS session
        ON session.id = active.cli_session_id
      WHERE session.external_id IS NOT NULL
        AND session.ended_at IS NULL
      ORDER BY active.character_id
    `,
  );
  send(response, 200, { sessions: result.rows });
}

async function updateCharacterName(response, characterID, body) {
  const name = String(body.name ?? "").trim();
  if (name.length === 0 || name.length > 30) {
    send(response, 400, { error: "이름은 1자 이상 30자 이하여야 합니다." });
    return;
  }

  const result = await pool.query(
    `
      UPDATE characters
      SET name = $2, updated_at = now()
      WHERE id = $1
      RETURNING id, name
    `,
    [characterID, name],
  );
  if (result.rowCount === 0) {
    send(response, 404, { error: "캐릭터를 찾을 수 없습니다." });
    return;
  }
  send(response, 200, result.rows[0]);
}

async function updateCharacterIdentityPrompt(response, characterID, body) {
  const identityPrompt = String(body.identityPrompt ?? "").trim();
  if (identityPrompt.length === 0 || identityPrompt.length > 1200) {
    send(response, 400, {
      error: "역할·업무 지침은 1자 이상 1,200자 이하여야 합니다.",
    });
    return;
  }

  const character = await withTransaction(async (client) => {
    const current = await client.query(
      `
        SELECT id, identity_prompt AS "identityPrompt"
        FROM characters
        WHERE id = $1
        FOR UPDATE
      `,
      [characterID],
    );
    if (current.rowCount === 0) {
      return null;
    }
    if (current.rows[0].identityPrompt === identityPrompt) {
      return current.rows[0];
    }

    const updated = await client.query(
      `
        UPDATE characters
        SET identity_prompt = $2, updated_at = now()
        WHERE id = $1
        RETURNING id, identity_prompt AS "identityPrompt"
      `,
      [characterID, identityPrompt],
    );
    await endActiveSession(client, characterID);
    return updated.rows[0];
  });
  if (!character) {
    send(response, 404, { error: "캐릭터를 찾을 수 없습니다." });
    return;
  }
  send(response, 200, character);
}

async function updateCharacterSettings(response, characterID, body) {
  const backend = String(body.backend ?? "");
  const allowedEfforts = backend === "codex"
    ? ["high", "xhigh", "max", "ultra"]
    : ["high", "xhigh", "max"];
  const effort = String(body.effort ?? "");

  if (!["codex", "claude"].includes(backend)) {
    send(response, 400, { error: "지원하지 않는 CLI입니다." });
    return;
  }
  if (!allowedEfforts.includes(effort)) {
    send(response, 400, { error: "지원하지 않는 추론 레벨입니다." });
    return;
  }

  const allowedModels = backend === "codex"
    ? ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
    : ["claude-opus-5", "fable", "claude-sonnet-5"];
  const model = String(body.model ?? "");
  if (!allowedModels.includes(model)) {
    send(response, 400, { error: "지원하지 않는 모델입니다." });
    return;
  }
  const fastMode = body.fastMode;
  if (typeof fastMode !== "boolean") {
    send(response, 400, { error: "Fast 모드 설정은 참 또는 거짓이어야 합니다." });
    return;
  }
  if (backend === "claude" && fastMode && model !== "claude-opus-5") {
    send(response, 400, {
      error: "Claude Fast 모드는 Opus 5에서만 사용할 수 있습니다.",
    });
    return;
  }
  const allowedPermissions = backend === "codex"
    ? ["read-only", "workspace-write", "danger-full-access"]
    : ["plan", "auto", "acceptEdits", "bypassPermissions"];
  const requestedPermission = String(body.permission ?? "");
  if (!allowedPermissions.includes(requestedPermission)) {
    send(response, 400, { error: "지원하지 않는 권한입니다." });
    return;
  }
  const permission =
    backend === "claude" && requestedPermission === "acceptEdits"
      ? "auto"
      : requestedPermission;

  const character = await withTransaction(async (client) => {
    const current = await client.query(
      `
        SELECT
          id,
          backend,
          model,
          effort,
          fast_mode AS "fastMode",
          permission
        FROM characters
        WHERE id = $1
        FOR UPDATE
      `,
      [characterID],
    );
    if (current.rowCount === 0) {
      return null;
    }

    const previous = current.rows[0];
    const changed =
      previous.backend !== backend ||
      previous.model !== model ||
      previous.effort !== effort ||
      previous.fastMode !== fastMode ||
      previous.permission !== permission;
    if (!changed) {
      return previous;
    }

    const updated = await client.query(
      `
        UPDATE characters
        SET
          backend = $2,
          model = $3,
          effort = $4,
          fast_mode = $5,
          permission = $6,
          updated_at = now()
        WHERE id = $1
        RETURNING
          id,
          backend,
          model,
          effort,
          fast_mode AS "fastMode",
          permission
      `,
      [characterID, backend, model, effort, fastMode, permission],
    );
    await endActiveSession(client, characterID);
    return updated.rows[0];
  });
  if (!character) {
    send(response, 404, { error: "캐릭터를 찾을 수 없습니다." });
    return;
  }
  send(response, 200, character);
}

async function characterHistory(response, characterID) {
  const characterResult = await pool.query(
    `
      SELECT id, name, seat, backend
      FROM characters
      WHERE id = $1
    `,
    [characterID],
  );
  if (characterResult.rowCount === 0) {
    send(response, 404, { error: "캐릭터를 찾을 수 없습니다." });
    return;
  }

  const sessionsResult = await pool.query(
    `
      SELECT
        id,
        external_id AS "externalId",
        started_at AS "startedAt",
        ended_at AS "endedAt"
      FROM cli_sessions
      WHERE character_id = $1
      ORDER BY started_at DESC
    `,
    [characterID],
  );
  const turnsResult = await pool.query(
    `
      SELECT
        t.id,
        t.cli_session_id AS "sessionId",
        t.backend AS "executionBackend",
        t.model AS "executionModel",
        t.effort AS "executionEffort",
        t.fast_mode AS "executionFastMode",
        t.prompt,
        t.started_at AS "startedAt",
        t.ended_at AS "endedAt",
        COALESCE(
          (
            SELECT text
            FROM messages
            WHERE turn_id = t.id AND role = 'assistant'
            ORDER BY received_at DESC
            LIMIT 1
          ),
          ''
        ) AS response
      FROM turns t
      JOIN cli_sessions s ON s.id = t.cli_session_id
      WHERE s.character_id = $1
      ORDER BY t.started_at DESC
    `,
    [characterID],
  );

  const sessions = sessionsResult.rows.map((session) => ({
    ...session,
    turns: turnsResult.rows.filter(
      (turn) => turn.sessionId === session.id,
    ).map((turn) => withArtifactPreviews(turn, session.externalId)),
  }));
  send(response, 200, {
    character: characterResult.rows[0],
    sessions,
  });
}

async function globalHistory(response, url) {
  const characterID = url.searchParams.get("characterId") || null;
  const from = url.searchParams.get("from") || null;
  const to = url.searchParams.get("to") || null;

  const result = await pool.query(
    `
      SELECT
        t.id,
        c.id AS "characterId",
        c.name AS "characterName",
        c.backend,
        t.backend AS "executionBackend",
        t.model AS "executionModel",
        t.effort AS "executionEffort",
        t.fast_mode AS "executionFastMode",
        s.external_id AS "externalSessionId",
        t.prompt,
        COALESCE(
          (
            SELECT text
            FROM messages
            WHERE turn_id = t.id AND role = 'assistant'
            ORDER BY received_at DESC
            LIMIT 1
          ),
          ''
        ) AS response,
        t.started_at AS "startedAt",
        t.ended_at AS "endedAt"
      FROM turns t
      JOIN cli_sessions s ON s.id = t.cli_session_id
      JOIN characters c ON c.id = s.character_id
      WHERE ($1::text IS NULL OR c.id = $1)
        AND ($2::timestamptz IS NULL OR t.started_at >= $2)
        AND ($3::timestamptz IS NULL OR t.started_at <= $3)
      ORDER BY t.started_at DESC
      LIMIT 1000
    `,
    [characterID, from, to],
  );
  send(response, 200, {
    turns: result.rows.map((turn) => withArtifactPreviews(turn)),
  });
}

async function queryLiveFeed({ turnID = null, limit }) {
  const result = await pool.query(
    `
      SELECT
        t.id,
        c.id AS "characterId",
        c.name AS "characterName",
        c.backend AS "characterBackend",
        t.backend,
        t.model,
        t.effort,
        t.fast_mode AS "fastMode",
        s.external_id AS "externalSessionId",
        t.prompt,
        t.status,
        t.needs_input AS "needsInput",
        t.error_message AS "errorMessage",
        t.started_at AS "startedAt",
        t.ended_at AS "endedAt",
        t.updated_at AS "updatedAt",
        COALESCE(
          (
            SELECT text
            FROM messages
            WHERE turn_id = t.id
              AND role = 'assistant'
            ORDER BY received_at DESC
            LIMIT 1
          ),
          ''
        ) AS response,
        COALESCE(
          (
            SELECT json_agg(
              json_build_object(
                'id', activity.id,
                'kind', activity.kind,
                'text', activity.text,
                'status', activity.status,
                'occurredAt', activity.occurred_at
              )
              ORDER BY activity.seq
            )
            FROM turn_activities AS activity
            WHERE activity.turn_id = t.id
          ),
          '[]'::json
        ) AS activities
      FROM turns AS t
      JOIN cli_sessions AS s
        ON s.id = t.cli_session_id
      JOIN characters AS c
        ON c.id = s.character_id
      WHERE ($1::uuid IS NULL OR t.id = $1::uuid)
      ORDER BY t.started_at DESC
      LIMIT $2
    `,
    [turnID, limit],
  );
  return result.rows.map((turn) => withArtifactPreviews(turn));
}

async function liveFeed(response, url) {
  const requestedLimit = Number(url.searchParams.get("limit") ?? 120);
  const limit = Math.max(20, Math.min(requestedLimit, 300));
  send(response, 200, {
    turns: await queryLiveFeed({ limit }),
  });
}

async function liveFeedTurn(response, turnID) {
  const turns = await queryLiveFeed({ turnID, limit: 1 });
  if (turns.length === 0) {
    send(response, 404, { error: "대화를 찾을 수 없습니다." });
    return;
  }
  send(response, 200, { turn: turns[0] });
}

function withArtifactPreviews(turn, sessionID = turn.externalSessionId) {
  const generatedImages = generatedImagesForTurn({
    sessionID,
    startedAt: turn.startedAt,
    endedAt: turn.endedAt,
  });
  return {
    ...turn,
    response: appendLocalImagePreviews(
      turn.response,
      generatedImages,
    ),
  };
}

async function startAgentJob(response, body) {
  if (!runtime) {
    send(response, 503, { error: "CLI 실행기가 준비되지 않았습니다." });
    return;
  }

  try {
    const job = await runtime.start({
      characterID: String(body.characterId ?? ""),
      prompt: body.prompt,
      conversationID: body.conversationId,
      attachmentPaths: body.attachmentPaths,
    });
    send(response, 202, job);
  } catch (error) {
    if (error instanceof CharacterNotFoundError) {
      send(response, 404, { error: error.message });
      return;
    }
    if (error instanceof AgentBusyError) {
      send(response, 409, { error: error.message });
      return;
    }
    throw error;
  }
}

async function cancelAgentJob(response, characterID) {
  if (!runtime) {
    send(response, 503, { error: "CLI 실행기가 준비되지 않았습니다." });
    return;
  }

  try {
    send(response, 200, await runtime.cancel(characterID));
  } catch (error) {
    if (error instanceof AgentJobNotFoundError) {
      send(response, 404, { error: error.message });
      return;
    }
    throw error;
  }
}

async function sessionForTurn(
  client,
  conversationID,
  characterID,
  externalSessionID,
) {
  const activeSession = await client.query(
    `
      SELECT active.cli_session_id
      FROM active_cli_sessions AS active
      WHERE active.character_id = $1
      FOR UPDATE
    `,
    [characterID],
  );
  const previousSessionID =
    activeSession.rows[0]?.cli_session_id ?? null;

  if (!externalSessionID) {
    if (previousSessionID) {
      const previous = await client.query(
        `
          SELECT id
          FROM cli_sessions
          WHERE id = $1
            AND ended_at IS NULL
        `,
        [previousSessionID],
      );
      if (previous.rowCount > 0) {
        return previous.rows[0].id;
      }
      await client.query(
        `
          DELETE FROM active_cli_sessions
          WHERE character_id = $1
        `,
        [characterID],
      );
    }

    const pending = await client.query(
      `
        SELECT id
        FROM cli_sessions
        WHERE conversation_id = $1
          AND character_id = $2
          AND external_id IS NULL
          AND ended_at IS NULL
        ORDER BY started_at DESC, id DESC
        LIMIT 1
      `,
      [conversationID, characterID],
    );
    if (pending.rowCount > 0) {
      return pending.rows[0].id;
    }

    const inserted = await client.query(
      `
        INSERT INTO cli_sessions (
          conversation_id,
          character_id,
          previous_session_id
        )
        VALUES ($1, $2, $3)
        RETURNING id
      `,
      [conversationID, characterID, previousSessionID],
    );
    return inserted.rows[0].id;
  }

  let session = await client.query(
    `
      SELECT id, ended_at AS "endedAt"
      FROM cli_sessions
      WHERE character_id = $1
        AND external_id = $2
    `,
    [characterID, externalSessionID],
  );

  if (session.rows[0]?.endedAt) {
    throw new Error("종료된 CLI 세션은 다시 활성화할 수 없습니다.");
  }

  if (session.rowCount === 0) {
    const pending = await client.query(
      `
        SELECT id
        FROM cli_sessions
        WHERE conversation_id = $1
          AND character_id = $2
          AND external_id IS NULL
          AND ended_at IS NULL
        ORDER BY started_at DESC, id DESC
        LIMIT 1
      `,
      [conversationID, characterID],
    );
    if (pending.rowCount > 0) {
      session = await client.query(
        `
          UPDATE cli_sessions
          SET external_id = $2
          WHERE id = $1
          RETURNING id
        `,
        [pending.rows[0].id, externalSessionID],
      );
    } else {
      session = await client.query(
        `
          INSERT INTO cli_sessions (
            conversation_id,
            character_id,
            external_id,
            previous_session_id
          )
          VALUES ($1, $2, $3, $4)
          RETURNING id
        `,
        [
          conversationID,
          characterID,
          externalSessionID,
          previousSessionID,
        ],
      );
    }
  }

  const sessionID = session.rows[0].id;
  await client.query(
    `
      UPDATE cli_sessions
      SET ended_at = COALESCE(ended_at, now())
      WHERE character_id = $1
        AND id <> $2
        AND ended_at IS NULL
    `,
    [characterID, sessionID],
  );
  await client.query(
    `
      UPDATE cli_sessions
      SET ended_at = NULL
      WHERE id = $1
    `,
    [sessionID],
  );
  await client.query(
    `
      INSERT INTO active_cli_sessions (
        character_id,
        cli_session_id
      )
      VALUES ($1, $2)
      ON CONFLICT (character_id) DO UPDATE
      SET
        cli_session_id = EXCLUDED.cli_session_id,
        activated_at = CASE
          WHEN active_cli_sessions.cli_session_id =
            EXCLUDED.cli_session_id
          THEN active_cli_sessions.activated_at
          ELSE now()
        END,
        updated_at = now()
    `,
    [characterID, sessionID],
  );
  return sessionID;
}

async function recordTurn(response, body) {
  const turnID = body.turnId ?? randomUUID();
  const conversationID = body.conversationId;
  const characterID = body.characterId;
  const externalSessionID = String(
    body.externalSessionId ?? "",
  ).trim() || null;
  const executionBackend = String(body.backend ?? "").trim() || null;
  const executionModel = String(body.model ?? "").trim() || null;
  const executionEffort = String(body.effort ?? "").trim() || null;
  const hasExecutionFastMode = Object.prototype.hasOwnProperty.call(
    body,
    "fastMode",
  );
  const executionFastMode = hasExecutionFastMode &&
      typeof body.fastMode === "boolean"
    ? body.fastMode
    : false;

  if (!conversationID || !characterID || !body.prompt) {
    send(response, 400, { error: "대화, 캐릭터, 프롬프트가 필요합니다." });
    return;
  }
  if (
    executionBackend &&
    !["codex", "claude"].includes(executionBackend)
  ) {
    send(response, 400, { error: "지원하지 않는 실행 CLI입니다." });
    return;
  }
  if (
    executionEffort &&
    !(
      executionBackend === "codex"
        ? ["high", "xhigh", "max", "ultra"]
        : ["high", "xhigh", "max"]
    ).includes(executionEffort)
  ) {
    send(response, 400, { error: "지원하지 않는 실행 추론 레벨입니다." });
    return;
  }
  if (hasExecutionFastMode && typeof body.fastMode !== "boolean") {
    send(response, 400, { error: "실행 Fast 모드 값이 올바르지 않습니다." });
    return;
  }
  if (
    executionBackend === "claude" &&
    executionFastMode === true &&
    executionModel !== "claude-opus-5"
  ) {
    send(response, 400, {
      error: "Claude Fast 모드는 Opus 5에서만 사용할 수 있습니다.",
    });
    return;
  }

  await withTransaction(async (client) => {
    await client.query(
      `
        SELECT id
        FROM characters
        WHERE id = $1
        FOR UPDATE
      `,
      [characterID],
    );

    const existingTurn = await client.query(
      `
        SELECT id
        FROM turns
        WHERE id = $1
      `,
      [turnID],
    );
    if (existingTurn.rowCount > 0) {
      return;
    }

    await client.query(
      `
        INSERT INTO conversations (id, title, workdir)
        VALUES ($1, $2, $3)
        ON CONFLICT (id) DO NOTHING
      `,
      [
        conversationID,
        body.title ?? "새 업무",
        body.workdir ?? "",
      ],
    );

    const sessionID = await sessionForTurn(
      client,
      conversationID,
      characterID,
      externalSessionID,
    );

    const insertedTurn = await client.query(
      `
        INSERT INTO turns (
          id,
          cli_session_id,
          backend,
          model,
          effort,
          fast_mode,
          prompt,
          started_at,
          ended_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        ON CONFLICT (id) DO NOTHING
        RETURNING id
      `,
      [
        turnID,
        sessionID,
        executionBackend,
        executionModel,
        executionEffort,
        executionFastMode,
        body.prompt,
        body.startedAt ?? new Date().toISOString(),
        body.finishedAt ?? new Date().toISOString(),
      ],
    );

    if (insertedTurn.rowCount > 0) {
      await client.query(
        `
          INSERT INTO messages (turn_id, role, text)
          VALUES ($1, 'user', $2), ($1, 'assistant', $3)
        `,
        [turnID, body.prompt, body.response ?? ""],
      );
    }
  });

  send(response, 201, { turnId: turnID });
}

async function addRAGDocument(response, body) {
  const content = String(body.content ?? "").trim();
  if (!content) {
    send(response, 400, { error: "RAG 문서 내용이 필요합니다." });
    return;
  }

  const embedding = Array.isArray(body.embedding)
    ? `[${body.embedding.join(",")}]`
    : null;
  const result = await pool.query(
    `
      INSERT INTO rag_documents (
        source,
        title,
        content,
        metadata,
        embedding
      )
      VALUES ($1, $2, $3, $4::jsonb, $5::vector)
      RETURNING id
    `,
    [
      body.source ?? null,
      body.title ?? null,
      content,
      JSON.stringify(body.metadata ?? {}),
      embedding,
    ],
  );
  send(response, 201, result.rows[0]);
}

async function searchRAG(response, body) {
  const limit = Math.max(1, Math.min(Number(body.limit ?? 5), 20));
  let result;

  if (Array.isArray(body.embedding)) {
    const embedding = `[${body.embedding.join(",")}]`;
    result = await pool.query(
      `
        SELECT
          id,
          source,
          title,
          content,
          metadata,
          1 - (embedding <=> $1::vector) AS score
        FROM rag_documents
        WHERE embedding IS NOT NULL
        ORDER BY embedding <=> $1::vector
        LIMIT $2
      `,
      [embedding, limit],
    );
  } else {
    result = await pool.query(
      `
        SELECT
          id,
          source,
          title,
          content,
          metadata,
          ts_rank(
            search_document,
            websearch_to_tsquery('simple', $1)
          ) AS score
        FROM rag_documents
        WHERE search_document @@ websearch_to_tsquery('simple', $1)
        ORDER BY score DESC
        LIMIT $2
      `,
      [String(body.query ?? ""), limit],
    );
  }
  send(response, 200, { documents: result.rows });
}

const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url ?? "/", "http://127.0.0.1");
    const characterID = routeCharacterName(url.pathname);
    const settingsCharacterID = routeCharacterSettings(url.pathname);
    const identityPromptCharacterID = routeCharacterIdentityPrompt(
      url.pathname,
    );
    const historyCharacterID = routeCharacterHistory(url.pathname);
    const jobCharacterID = routeAgentJob(url.pathname);
    const liveFeedTurnID = routeLiveFeedTurn(url.pathname);

    if (request.method === "GET" && url.pathname === "/health") {
      await pool.query("SELECT 1");
      send(response, 200, { ok: true });
    } else if (
      request.method === "GET" &&
      url.pathname === "/api/characters"
    ) {
      await listCharacters(response);
    } else if (
      request.method === "GET" &&
      url.pathname === "/api/active-sessions"
    ) {
      await listActiveSessions(response);
    } else if (request.method === "GET" && historyCharacterID) {
      await characterHistory(response, historyCharacterID);
    } else if (
      request.method === "GET" &&
      url.pathname === "/api/history"
    ) {
      await globalHistory(response, url);
    } else if (
      request.method === "GET" &&
      url.pathname === "/api/live-feed"
    ) {
      await liveFeed(response, url);
    } else if (request.method === "GET" && liveFeedTurnID) {
      await liveFeedTurn(response, liveFeedTurnID);
    } else if (request.method === "PUT" && characterID) {
      await updateCharacterName(
        response,
        characterID,
        await readJSON(request),
      );
    } else if (request.method === "PUT" && settingsCharacterID) {
      await updateCharacterSettings(
        response,
        settingsCharacterID,
        await readJSON(request),
      );
    } else if (request.method === "PUT" && identityPromptCharacterID) {
      await updateCharacterIdentityPrompt(
        response,
        identityPromptCharacterID,
        await readJSON(request),
      );
    } else if (
      request.method === "POST" &&
      url.pathname === "/api/turns"
    ) {
      await recordTurn(response, await readJSON(request));
    } else if (
      request.method === "POST" &&
      url.pathname === "/api/agent-jobs"
    ) {
      await startAgentJob(response, await readJSON(request));
    } else if (
      request.method === "DELETE" &&
      jobCharacterID
    ) {
      await cancelAgentJob(response, jobCharacterID);
    } else if (
      request.method === "POST" &&
      url.pathname === "/api/rag/documents"
    ) {
      await addRAGDocument(response, await readJSON(request));
    } else if (
      request.method === "POST" &&
      url.pathname === "/api/rag/search"
    ) {
      await searchRAG(response, await readJSON(request));
    } else {
      send(response, 404, { error: "경로를 찾을 수 없습니다." });
    }
  } catch (error) {
    send(response, 500, { error: error.message });
  }
});

webSocketServer.on("connection", (socket) => {
  sockets.add(socket);
  socket.send(JSON.stringify({ type: "ready" }));
  socket.on("close", () => {
    sockets.delete(socket);
  });
  socket.on("error", () => {
    sockets.delete(socket);
  });
});

server.on("upgrade", (request, socket, head) => {
  const url = new URL(request.url ?? "/", "http://127.0.0.1");
  if (url.pathname !== "/ws") {
    socket.destroy();
    return;
  }
  webSocketServer.handleUpgrade(request, socket, head, (client) => {
    webSocketServer.emit("connection", client, request);
  });
});

try {
  await migrate();
  const configuration = await readCharacterConfiguration();
  await withTransaction(async (client) => {
    await syncCharacters(client, configuration);
  });
  runtime = new AgentRuntime({
    pool,
    withTransaction,
    workdir: configuration.workdir,
    broadcast,
  });
  await runtime.recoverInterruptedJobs();
  server.listen(port, "127.0.0.1", () => {
    console.log(`사무실 백엔드 실행 중 http://127.0.0.1:${port}`);
  });
} catch (error) {
  console.error(error);
  await pool.end();
  process.exitCode = 1;
}
