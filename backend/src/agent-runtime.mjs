// 이 파일은 백엔드에서 CLI 업무를 실행하고 공개 진행 상태를 PostgreSQL과 WebSocket에 전달한다.

import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import {
  closeSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import {
  basename,
  extname,
  isAbsolute,
  join,
  resolve,
} from "node:path";
import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";

import {
  decodeAgentResponse,
  fileChangeActivityText,
  parseAgentEvent,
} from "./agent-event-parser.mjs";
import {
  appendLocalImagePreviews,
  listGeneratedImages,
} from "./local-artifacts.mjs";
import { estimateTokenCost } from "./token-cost-estimator.mjs";

const RESPONSE_INSTRUCTION = `
사용자 판단이 반드시 필요해 더 진행할 수 없을 때만 최종 응답을 정확히 다음 형식으로 작성한다.
[NEED_INPUT]
사용자에게 보여줄 질문 원문
표식 다음에는 질문과 판단에 필요한 선택지만 작성한다. 사용자 확인 없이 할 수 있는 작업은 먼저 진행한다.
`.trim();

const MAX_FILE_SNAPSHOT_BYTES = 8 * 1024 * 1024;
const MAX_TURN_SNAPSHOT_BYTES = 24 * 1024 * 1024;
const ROLLOUT_TAIL_CHUNK_BYTES = 64 * 1024;
const rolloutPathCache = new Map();

export class AgentBusyError extends Error {}
export class AgentJobNotFoundError extends Error {}
export class CharacterNotFoundError extends Error {}

export class AgentRuntime {
  constructor({ pool, withTransaction, workdir, broadcast }) {
    this.pool = pool;
    this.withTransaction = withTransaction;
    this.workdir = workdir;
    this.broadcast = broadcast;
    this.running = new Map();
  }

  async recoverInterruptedJobs() {
    const result = await this.pool.query(
      `
        WITH existing_terminal_turns AS (
          SELECT id, status
          FROM turns
          WHERE status IN ('completed', 'failed', 'interrupted')
        ), interrupted_turns AS (
          UPDATE turns
          SET
            status = 'interrupted',
            error_message =
              '백엔드가 재시작되어 이전 실시간 출력 연결이 종료됐습니다.',
            ended_at = COALESCE(ended_at, now()),
            updated_at = now()
          WHERE status IN ('pending', 'running')
          RETURNING id
        ), terminal_turns AS (
          SELECT id, status FROM existing_terminal_turns
          UNION ALL
          SELECT id, 'interrupted' AS status FROM interrupted_turns
        ), closed_activities AS (
          UPDATE turn_activities AS activity
          SET status = CASE
            WHEN turn.status = 'completed' THEN 'completed'
            ELSE 'failed'
          END
          FROM terminal_turns AS turn
          WHERE activity.turn_id = turn.id
            AND activity.status = 'running'
          RETURNING activity.id
        )
        SELECT id FROM interrupted_turns
      `,
    );
    return result.rowCount;
  }

  async start({
    characterID,
    prompt,
    conversationID,
    attachmentPaths = [],
  }) {
    const cleanPrompt = String(prompt ?? "").trim();
    if (!cleanPrompt && attachmentPaths.length === 0) {
      throw new Error("업무 내용을 입력하세요.");
    }

    const attachments = stageAttachments({
      attachmentPaths,
      workdir: this.workdir,
    });
    const effectivePrompt = promptWithAttachments(
      cleanPrompt || "첨부 파일을 확인해줘.",
      attachments,
    );

    let prepared;
    try {
      prepared = await this.prepareTurn({
        characterID,
        prompt: effectivePrompt,
        conversationID: conversationID || randomUUID(),
      });
    } catch (error) {
      removeStagedAttachments(attachments);
      throw error;
    }

    const resumedCodexSession =
      prepared.character.backend === "codex" &&
      Boolean(prepared.externalSessionID);
    const usageBaseline = resumedCodexSession
      ? latestCodexUsageFromRollout(
        findRolloutPath(prepared.externalSessionID),
      )
      : null;
    const state = {
      ...prepared,
      process: null,
      attachments,
      cancelRequested: false,
      initialGeneratedImages: new Set(
        listGeneratedImages(prepared.externalSessionID),
      ),
      sequence: 0,
      lastActivity: null,
      activityRecords: new Map(),
      fileChangeSnapshots: new Map(),
      rolloutReader: createRolloutReader(
        prepared.externalSessionID,
        true,
      ),
      hasSeenInitialCodexReasoning: false,
      pendingInitialCodexReasoning: null,
      pendingAgentMessage: null,
      visibleAgentMessages: [],
      streamMessageID: null,
      responseText: "",
      partialText: "",
      lastPartialPersistedAt: 0,
      resumedCodexSession,
      usageBaseline,
      usage: null,
      warning: null,
      failure: null,
    };
    this.running.set(characterID, state);
    this.broadcast({ type: "feed.changed", turnId: state.turnID });

    void this.execute(state).catch(async (error) => {
      await this.fail(state, error);
    });

    return {
      turnId: state.turnID,
      conversationId: state.conversationID,
      status: "running",
    };
  }

  async cancel(characterID) {
    const state = this.running.get(characterID);
    if (!state) {
      throw new AgentJobNotFoundError(
        "실행 중인 업무를 찾을 수 없습니다.",
      );
    }

    state.cancelRequested = true;
    terminateProcessGroup(state.process);
    const message = "사용자가 업무를 중단했습니다.";
    try {
      await this.completePendingInitialCodexReasoning(state);
      await this.finalizeRunningActivities(state, "failed");
      await this.pool.query(
        `
          UPDATE turns
          SET
            status = 'interrupted',
            needs_input = false,
            error_message = $2,
            ended_at = now(),
            updated_at = now()
          WHERE id = $1
        `,
        [state.turnID, message],
      );
      await this.persistUsageRecord(this.pool, state);
    } finally {
      if (this.running.get(characterID) === state) {
        this.running.delete(characterID);
      }
      this.broadcast({
        type: "feed.changed",
        turnId: state.turnID,
        characterId: characterID,
      });
    }

    return {
      turnId: state.turnID,
      status: "interrupted",
    };
  }

  async prepareTurn({ characterID, prompt, conversationID }) {
    return this.withTransaction(async (client) => {
      const characterResult = await client.query(
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
            identity_prompt AS "identityPrompt",
            config
          FROM characters
          WHERE id = $1
          FOR UPDATE
        `,
        [characterID],
      );
      if (characterResult.rowCount === 0) {
        throw new CharacterNotFoundError(
          "캐릭터를 찾을 수 없습니다.",
        );
      }

      const busy = await client.query(
        `
          SELECT turn.id
          FROM turns AS turn
          JOIN cli_sessions AS session
            ON session.id = turn.cli_session_id
          WHERE session.character_id = $1
            AND turn.status IN ('pending', 'running')
          LIMIT 1
        `,
        [characterID],
      );
      if (busy.rowCount > 0) {
        throw new AgentBusyError(
          "이 직원은 이미 업무를 처리하고 있습니다.",
        );
      }

      const activeResult = await client.query(
        `
          SELECT
            session.id,
            session.external_id AS "externalSessionID",
            session.conversation_id AS "conversationID"
          FROM active_cli_sessions AS active
          JOIN cli_sessions AS session
            ON session.id = active.cli_session_id
          WHERE active.character_id = $1
            AND session.ended_at IS NULL
          LIMIT 1
        `,
        [characterID],
      );

      let sessionID;
      let externalSessionID;
      let effectiveConversationID;
      if (activeResult.rowCount > 0) {
        const active = activeResult.rows[0];
        sessionID = active.id;
        externalSessionID = active.externalSessionID;
        effectiveConversationID = active.conversationID;
      } else {
        effectiveConversationID = conversationID;
        await client.query(
          `
            INSERT INTO conversations (id, title, workdir)
            VALUES ($1, $2, $3)
            ON CONFLICT (id) DO NOTHING
          `,
          [
            effectiveConversationID,
            prompt.slice(0, 60),
            this.workdir,
          ],
        );

        const previous = await client.query(
          `
            SELECT id
            FROM cli_sessions
            WHERE character_id = $1
            ORDER BY started_at DESC, id DESC
            LIMIT 1
          `,
          [characterID],
        );
        const insertedSession = await client.query(
          `
            INSERT INTO cli_sessions (
              conversation_id,
              character_id,
              previous_session_id
            )
            VALUES ($1, $2, $3)
            RETURNING id
          `,
          [
            effectiveConversationID,
            characterID,
            previous.rows[0]?.id ?? null,
          ],
        );
        sessionID = insertedSession.rows[0].id;
        externalSessionID = null;
      }

      const turnID = randomUUID();
      const character = characterResult.rows[0];
      await client.query(
        `
          INSERT INTO turns (
            id,
            cli_session_id,
            backend,
            model,
            effort,
            fast_mode,
            prompt,
            status,
            started_at,
            updated_at
          )
          VALUES ($1, $2, $3, $4, $5, $6, $7, 'running', now(), now())
        `,
        [
          turnID,
          sessionID,
          character.backend,
          character.model,
          character.effort,
          character.fastMode,
          prompt,
        ],
      );
      await client.query(
        `
          INSERT INTO messages (turn_id, role, text)
          VALUES
            ($1, 'user', $2),
            ($1, 'assistant', '')
        `,
        [turnID, prompt],
      );

      return {
        turnID,
        sessionID,
        conversationID: effectiveConversationID,
        externalSessionID,
        character,
        prompt,
      };
    });
  }

  async execute(state) {
    const executable = locateExecutable(state.character);
    const cliArguments = buildArguments({
      character: state.character,
      prompt: state.prompt,
      previousSessionID: state.externalSessionID,
      attachments: state.attachments,
    });
    const child = spawn(executable, cliArguments, {
      cwd: this.workdir,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
      shell: false,
      detached: process.platform !== "win32",
    });
    state.process = child;

    const outputTask = this.consumeOutput(state, child.stdout);
    const errorTask = collectStream(child.stderr);
    const [exitCode] = await once(child, "close");
    await outputTask;
    const stderr = (await errorTask).trim();

    if (await this.settleCancelledOutput(state)) {
      return;
    }
    if (state.failure) {
      throw new Error(state.failure);
    }
    if (exitCode !== 0) {
      throw new Error(
        state.warning ||
        stderr ||
        `CLI가 종료 코드 ${exitCode}로 끝났습니다.`,
      );
    }

    const candidate = this.finalResponseCandidate(state);
    const decoded = decodeAgentResponse(candidate);
    if (!decoded.text) {
      throw new Error("CLI 최종 메시지가 없습니다.");
    }
    await this.complete(state, decoded);
  }

  async consumeOutput(state, stream) {
    const lines = createInterface({
      input: stream,
      crlfDelay: Infinity,
    });
    for await (const line of lines) {
      const event = parseAgentEvent(line, state.character.backend);
      if (!event) {
        continue;
      }
      if (event.usage) {
        const usage = usageForTurn(state, event.usage);
        if (usage) {
          state.usage = usage;
        }
      }
      this.enrichFileChangeEvent(state, event);
      if (
        event.sessionID &&
        event.sessionID !== state.externalSessionID
      ) {
        await this.activateSession(state, event.sessionID);
      }
      if (event.streamMessageID) {
        state.streamMessageID = event.streamMessageID;
        state.partialText = "";
        state.responseText = "";
        state.lastPartialPersistedAt = 0;
      }
      const activities = [
        ...(Array.isArray(event.activities) ? event.activities : []),
        ...(event.activity ? [event.activity] : []),
      ];
      const pendingReasoningBeforeEvent = activities.length > 0
        ? state.pendingInitialCodexReasoning
        : null;
      if (activities.length > 0) {
        await this.promotePendingAgentMessage(state);
        for (const activity of activities) {
          await this.addParsedActivity(
            state,
            this.scopedActivity(state, activity),
          );
        }
        if (pendingReasoningBeforeEvent) {
          await this.completePendingInitialCodexReasoning(
            state,
            pendingReasoningBeforeEvent,
          );
        }
      }
      if (event.agentMessage) {
        const key = event.agentMessageKey ?? null;
        if (state.character.backend === "codex") {
          await this.completePendingInitialCodexReasoning(state);
          await this.addActivity(state, {
            kind: "message",
            text: event.agentMessage,
            eventKey: key ? `message:${key}` : null,
            status: "completed",
            preserveOccurredAt: true,
          });
        } else {
          if (
            state.pendingAgentMessage &&
            state.pendingAgentMessage.key !== key
          ) {
            await this.promotePendingAgentMessage(state);
          }
          state.pendingAgentMessage = {
            key,
            text: event.agentMessage,
          };
        }
        this.rememberVisibleAgentMessage(
          state,
          key,
          event.agentMessage,
        );
        state.responseText = event.agentMessage;
        state.partialText = event.agentMessage;
        await this.persistResponseDraft(
          state,
          this.visibleResponseText(state),
        );
      }
      if (event.responseDelta) {
        state.partialText += event.responseDelta;
        await this.persistPartialResponse(state);
      }
      if (event.responseText) {
        this.rememberVisibleAgentMessage(
          state,
          null,
          event.responseText,
        );
        state.responseText = event.responseText;
        await this.persistResponseDraft(
          state,
          this.visibleResponseText(state),
        );
      }
      if (event.warning) {
        state.warning = event.warning;
      }
      if (event.failure) {
        state.failure = event.failure;
      }
    }
    await this.completePendingInitialCodexReasoning(state);
  }

  scopedActivity(state, activity) {
    if (!activity.messageScoped || !state.streamMessageID) {
      return activity;
    }
    return {
      ...activity,
      eventKey: `${state.streamMessageID}:${activity.eventKey}`,
      messageScoped: false,
    };
  }

  enrichFileChangeEvent(state, event) {
    const fileChange = event.fileChange;
    if (!fileChange?.eventKey) {
      return;
    }
    state.fileChangeSnapshots ??= new Map();
    if (fileChange.phase === "item.started") {
      state.fileChangeSnapshots.set(
        fileChange.eventKey,
        captureFileSnapshots(this.workdir, fileChange.changes),
      );
      return;
    }
    if (fileChange.phase !== "item.completed") {
      return;
    }

    const snapshots = state.fileChangeSnapshots.get(fileChange.eventKey);
    state.fileChangeSnapshots.delete(fileChange.eventKey);
    const statistics = rolloutFileChangeStatistics(
      state.rolloutReader,
      this.workdir,
      fileChange.changes,
    ) ?? fileChangeStatistics(
      this.workdir,
      snapshots,
      fileChange.changes,
    );
    if (statistics && event.activity) {
      event.activity.text = fileChangeActivityText(
        fileChange.changes,
        statistics,
      );
    }
  }

  async addParsedActivity(state, activity) {
    const isInitialCodexReasoning =
      activity.isCodexReasoning === true &&
      state.hasSeenInitialCodexReasoning !== true;
    if (!isInitialCodexReasoning) {
      await this.addActivity(state, activity);
      return;
    }

    state.hasSeenInitialCodexReasoning = true;
    if (activity.status !== "completed" || !activity.eventKey) {
      await this.addActivity(state, activity);
      return;
    }

    await this.addActivity(state, {
      ...activity,
      status: "running",
    });
    state.pendingInitialCodexReasoning = {
      ...activity,
      status: "completed",
      preserveOccurredAt: true,
    };
  }

  async completePendingInitialCodexReasoning(state, expected = null) {
    const pending = state.pendingInitialCodexReasoning;
    if (
      !pending ||
      (expected && pending.eventKey !== expected.eventKey)
    ) {
      return;
    }

    state.pendingInitialCodexReasoning = null;
    try {
      await this.addActivity(state, pending);
    } catch (error) {
      state.pendingInitialCodexReasoning ??= pending;
      throw error;
    }
  }

  rememberVisibleAgentMessage(state, key, text) {
    const value = String(text ?? "").trim();
    if (!value) {
      return;
    }
    const messages = state.visibleAgentMessages ?? [];
    state.visibleAgentMessages = messages;
    if (key) {
      const existingIndex = messages.findIndex(
        (message) => message.key === key,
      );
      if (existingIndex >= 0) {
        messages[existingIndex] = { key, text: value };
        return;
      }
      messages.push({ key, text: value });
      return;
    }
    if (messages.at(-1)?.text !== value) {
      messages.push({ key, text: value });
    }
  }

  visibleResponseText(state, currentText = "") {
    const values = (state.visibleAgentMessages ?? [])
      .map((message) => message.text)
      .filter(Boolean);
    const current = String(currentText ?? "");
    if (current.trim() && values.at(-1) !== current.trim()) {
      values.push(current);
    }
    return values.join("\n\n");
  }

  finalResponseCandidate(state) {
    const candidates = [
      state.responseText,
      state.partialText,
      state.visibleAgentMessages?.at(-1)?.text,
    ];
    return candidates.find(
      (value) => String(value ?? "").trim().length > 0,
    ) ?? "";
  }

  completedResponseText(state, decoded) {
    const values = (state.visibleAgentMessages ?? [])
      .map((message) => message.text)
      .filter(Boolean);
    if (
      decoded.needsInput &&
      values.at(-1) === state.responseText
    ) {
      values[values.length - 1] = decoded.text;
    } else if (values.at(-1) !== decoded.text) {
      values.push(decoded.text);
    }
    return values.join("\n\n");
  }

  async normalizeCompletedCodexMessageActivity(state, decoded) {
    if (state.character.backend !== "codex" || !decoded.needsInput) {
      return;
    }
    const finalMessage = state.visibleAgentMessages?.at(-1);
    const eventKey = finalMessage?.key
      ? `message:${finalMessage.key}`
      : null;
    if (
      !eventKey ||
      !state.activityRecords.has(eventKey) ||
      finalMessage.text === decoded.text
    ) {
      return;
    }

    const originalText = finalMessage.text;
    await this.addActivity(state, {
      kind: "message",
      text: decoded.text,
      eventKey,
      status: "completed",
      preserveOccurredAt: true,
    });
    finalMessage.text = decoded.text;
    if (state.responseText === originalText) {
      state.responseText = decoded.text;
    }
    if (state.partialText === originalText) {
      state.partialText = decoded.text;
    }
  }

  async promotePendingAgentMessage(state) {
    const pending = state.pendingAgentMessage;
    if (!pending) {
      return;
    }
    state.pendingAgentMessage = null;
    await this.addActivity(state, {
      kind: "message",
      text: pending.text,
      eventKey: pending.key ? `message:${pending.key}` : null,
      status: "completed",
      preserveText: false,
    });
    if (state.responseText === pending.text) {
      state.responseText = "";
      state.partialText = "";
    }
  }

  async activateSession(state, externalSessionID) {
    const isNewSession = !state.externalSessionID;
    await this.withTransaction(async (client) => {
      await client.query(
        `
          UPDATE cli_sessions
          SET external_id = $2
          WHERE id = $1
            AND (external_id IS NULL OR external_id = $2)
        `,
        [state.sessionID, externalSessionID],
      );
      await client.query(
        `
          UPDATE cli_sessions
          SET ended_at = COALESCE(ended_at, now())
          WHERE character_id = $1
            AND id <> $2
            AND ended_at IS NULL
        `,
        [state.character.id, state.sessionID],
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
        [state.character.id, state.sessionID],
      );
    });
    state.externalSessionID = externalSessionID;
    state.rolloutReader = createRolloutReader(
      externalSessionID,
      !isNewSession,
    );
    this.broadcast({ type: "session.changed", turnId: state.turnID });
  }

  async addActivity(state, activity) {
    const eventKey = activity.eventKey ?? null;
    const existing = eventKey
      ? state.activityRecords.get(eventKey)
      : null;
    const text = activity.preserveText && existing
      ? existing.text
      : activity.text;
    const status = activity.status ?? "completed";
    if (
      existing &&
      existing.kind === activity.kind &&
      existing.text === text &&
      existing.status === status
    ) {
      return;
    }
    const duplicateKey = `${activity.kind}\n${text}\n${status}`;
    if (!eventKey && state.lastActivity === duplicateKey) {
      return;
    }
    state.lastActivity = duplicateKey;

    if (existing) {
      await this.pool.query(
        `
          UPDATE turn_activities
          SET
            kind = $3,
            text = $4,
            status = $5
          WHERE turn_id = $1
            AND seq = $2
        `,
        [
          state.turnID,
          existing.sequence,
          activity.kind,
          text,
          status,
        ],
      );
      state.activityRecords.set(eventKey, {
        sequence: existing.sequence,
        kind: activity.kind,
        text,
        status,
      });
      await this.touchTurn(state.turnID);
      this.broadcast({
        type: "feed.changed",
        turnId: state.turnID,
        characterId: state.character.id,
      });
      return;
    }

    state.sequence += 1;
    await this.pool.query(
      `
        INSERT INTO turn_activities (
          turn_id,
          seq,
          kind,
          text,
          event_key,
          status
        )
        VALUES ($1, $2, $3, $4, $5, $6)
        ON CONFLICT (turn_id, seq) DO NOTHING
      `,
      [
        state.turnID,
        state.sequence,
        activity.kind,
        text,
        eventKey,
        status,
      ],
    );
    if (eventKey) {
      state.activityRecords.set(eventKey, {
        sequence: state.sequence,
        kind: activity.kind,
        text,
        status,
      });
    }
    await this.touchTurn(state.turnID);
    this.broadcast({
      type: "feed.changed",
      turnId: state.turnID,
      characterId: state.character.id,
    });
  }

  async persistPartialResponse(state) {
    const now = Date.now();
    if (now - state.lastPartialPersistedAt < 250) {
      return;
    }
    state.lastPartialPersistedAt = now;
    await this.persistResponseDraft(
      state,
      this.visibleResponseText(state, state.partialText),
    );
  }

  async persistResponseDraft(state, text) {
    await this.pool.query(
      `
        UPDATE messages
        SET text = $2, received_at = now()
        WHERE turn_id = $1
          AND role = 'assistant'
      `,
      [state.turnID, text],
    );
    await this.touchTurn(state.turnID);
    this.broadcast({
      type: "feed.changed",
      turnId: state.turnID,
      characterId: state.character.id,
    });
  }

  async touchTurn(turnID) {
    await this.pool.query(
      `
        UPDATE turns
        SET updated_at = now()
        WHERE id = $1
      `,
      [turnID],
    );
  }

  async finalizeRunningActivities(state, status) {
    await this.pool.query(
      `
        UPDATE turn_activities
        SET status = $2
        WHERE turn_id = $1
          AND status = 'running'
      `,
      [state.turnID, status],
    );
    if (state.activityRecords instanceof Map) {
      for (const [eventKey, activity] of state.activityRecords) {
        if (activity.status === "running") {
          state.activityRecords.set(eventKey, { ...activity, status });
        }
      }
    }
  }

  async settleCancelledOutput(state) {
    if (!state.cancelRequested) {
      return false;
    }
    await this.finalizeRunningActivities(state, "failed");
    this.broadcast({
      type: "feed.changed",
      turnId: state.turnID,
      characterId: state.character.id,
    });
    return true;
  }

  async persistUsageRecord(client, state) {
    if (!state.usage) {
      return;
    }
    const usage = state.usage;
    const costUsd = estimateTokenCost({
      backend: state.character.backend,
      model: state.character.model,
      fastMode: state.character.fastMode,
      usage,
    });
    await client.query(
      `
        INSERT INTO usage_records (
          turn_id,
          input_tokens,
          output_tokens,
          cached_input_tokens,
          reasoning_output_tokens,
          cost_usd,
          cache_write_input_tokens,
          cache_write_5m_input_tokens,
          cache_write_1h_input_tokens
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        ON CONFLICT (turn_id) DO UPDATE
        SET
          input_tokens = EXCLUDED.input_tokens,
          output_tokens = EXCLUDED.output_tokens,
          cached_input_tokens = EXCLUDED.cached_input_tokens,
          reasoning_output_tokens = EXCLUDED.reasoning_output_tokens,
          cost_usd = EXCLUDED.cost_usd,
          cache_write_input_tokens = EXCLUDED.cache_write_input_tokens,
          cache_write_5m_input_tokens = EXCLUDED.cache_write_5m_input_tokens,
          cache_write_1h_input_tokens = EXCLUDED.cache_write_1h_input_tokens
      `,
      [
        state.turnID,
        usage.inputTokens,
        usage.outputTokens,
        usage.cachedInputTokens,
        usage.reasoningOutputTokens,
        costUsd,
        usage.cacheWriteInputTokens,
        usage.cacheWrite5mInputTokens,
        usage.cacheWrite1hInputTokens,
      ],
    );
  }

  async complete(state, decoded) {
    if (state.cancelRequested) {
      return;
    }
    await this.completePendingInitialCodexReasoning(state);
    await this.finalizeRunningActivities(state, "completed");
    await this.normalizeCompletedCodexMessageActivity(state, decoded);
    const generatedImages = listGeneratedImages(
      state.externalSessionID,
    ).filter((path) => !state.initialGeneratedImages.has(path));
    const responseText = appendLocalImagePreviews(
      this.completedResponseText(state, decoded),
      generatedImages,
    );

    await this.withTransaction(async (client) => {
      await client.query(
        `
          UPDATE messages
          SET text = $2, received_at = now()
          WHERE turn_id = $1
            AND role = 'assistant'
        `,
        [state.turnID, responseText],
      );
      await client.query(
        `
          UPDATE turns
          SET
            status = 'completed',
            needs_input = $2,
            error_message = NULL,
            ended_at = now(),
            updated_at = now()
          WHERE id = $1
        `,
        [state.turnID, decoded.needsInput],
      );
      await this.persistUsageRecord(client, state);
    });
    if (this.running.get(state.character.id) === state) {
      this.running.delete(state.character.id);
    }
    this.broadcast({
      type: "feed.changed",
      turnId: state.turnID,
      characterId: state.character.id,
    });
  }

  async fail(state, error) {
    if (this.running.get(state.character.id) !== state) {
      return;
    }
    await this.completePendingInitialCodexReasoning(state);
    await this.finalizeRunningActivities(state, "failed");
    const message =
      error instanceof Error ? error.message : String(error);
    await this.withTransaction(async (client) => {
      await client.query(
        `
          UPDATE turns
          SET
            status = 'failed',
            error_message = $2,
            ended_at = now(),
            updated_at = now()
          WHERE id = $1
        `,
        [state.turnID, message],
      );
      await this.persistUsageRecord(client, state);
      if (!state.externalSessionID) {
        await client.query(
          `
            UPDATE cli_sessions
            SET ended_at = COALESCE(ended_at, now())
            WHERE id = $1
          `,
          [state.sessionID],
        );
      }
    });
    if (this.running.get(state.character.id) === state) {
      this.running.delete(state.character.id);
    }
    this.broadcast({
      type: "feed.changed",
      turnId: state.turnID,
      characterId: state.character.id,
    });
  }
}

function captureFileSnapshots(workdir, changes) {
  const snapshots = new Map();
  let remainingBytes = MAX_TURN_SNAPSHOT_BYTES;
  for (const change of changes ?? []) {
    const path = resolvedChangePath(workdir, change?.path);
    if (!path || snapshots.has(path)) {
      continue;
    }
    const snapshot = readFileSnapshot(path, remainingBytes);
    if (!snapshot) {
      continue;
    }
    remainingBytes -= snapshot.length;
    snapshots.set(path, snapshot);
  }
  return snapshots;
}

function fileChangeStatistics(workdir, snapshots, changes) {
  if (!(snapshots instanceof Map)) {
    return null;
  }
  const directory = mkdtempSync(join(tmpdir(), "office-file-diff-"));
  try {
    const beforeDirectory = join(directory, "before");
    const afterDirectory = join(directory, "after");
    mkdirSync(beforeDirectory);
    mkdirSync(afterDirectory);
    const uniquePaths = normalizedChangePaths(workdir, changes);
    if (uniquePaths.length === 0) {
      return null;
    }

    let remainingAfterBytes = MAX_TURN_SNAPSHOT_BYTES;
    for (const [index, path] of uniquePaths.entries()) {
      const before = snapshots.get(path);
      const after = readFileSnapshot(path, remainingAfterBytes);
      if (!Buffer.isBuffer(before) || !Buffer.isBuffer(after)) {
        return null;
      }
      remainingAfterBytes -= after.length;
      const name = String(index).padStart(5, "0");
      writeFileSync(join(beforeDirectory, name), before);
      writeFileSync(join(afterDirectory, name), after);
    }

    const result = spawnSync(
      "/usr/bin/git",
      [
        "diff",
        "--no-index",
        "--numstat",
        "--no-ext-diff",
        "--no-textconv",
        "--",
        beforeDirectory,
        afterDirectory,
      ],
      { encoding: "utf8", maxBuffer: 1_000_000 },
    );
    if (result.error || ![0, 1].includes(result.status)) {
      return null;
    }
    const lines = String(result.stdout ?? "")
      .trim()
      .split("\n")
      .filter(Boolean);
    if (lines.length !== uniquePaths.length) {
      return null;
    }

    let additions = 0;
    let deletions = 0;
    for (const line of lines) {
      const [added, deleted] = line.split("\t");
      const addedCount = Number.parseInt(added, 10);
      const deletedCount = Number.parseInt(deleted, 10);
      if (!Number.isFinite(addedCount) || !Number.isFinite(deletedCount)) {
        return null;
      }
      additions += addedCount;
      deletions += deletedCount;
    }
    return { additions, deletions };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

function createRolloutReader(sessionID, startAtEnd) {
  const path = findRolloutPath(sessionID);
  if (!path) {
    return null;
  }
  return {
    path,
    offset: startAtEnd ? statSync(path).size : 0,
    remainder: "",
    pending: [],
  };
}

function findRolloutPath(sessionID) {
  const id = String(sessionID ?? "").trim();
  if (!id) {
    return null;
  }
  const cached = rolloutPathCache.get(id);
  if (cached && existsSync(cached)) {
    return cached;
  }
  const root = join(homedir(), ".codex", "sessions");
  if (!existsSync(root)) {
    return null;
  }
  let entries;
  try {
    entries = readdirSync(root, { recursive: true });
  } catch {
    return null;
  }
  const relative = entries.find((entry) => {
    const value = String(entry);
    return value.endsWith(".jsonl") && value.includes(id);
  });
  if (!relative) {
    return null;
  }
  const path = join(root, String(relative));
  rolloutPathCache.set(id, path);
  return path;
}

export function latestCodexUsageFromRollout(path) {
  if (!path) {
    return null;
  }
  let descriptor;
  try {
    const size = statSync(path).size;
    descriptor = openSync(path, "r");
    let end = size;
    let leadingFragment = "";
    while (end > 0) {
      const start = Math.max(0, end - ROLLOUT_TAIL_CHUNK_BYTES);
      const length = end - start;
      const buffer = Buffer.alloc(length);
      const bytesRead = readSync(
        descriptor,
        buffer,
        0,
        length,
        start,
      );
      const lines = (
        buffer.subarray(0, bytesRead).toString("utf8") + leadingFragment
      ).split("\n");
      leadingFragment = lines.shift() ?? "";
      for (let index = lines.length - 1; index >= 0; index -= 1) {
        const usage = codexRolloutUsage(lines[index]);
        if (usage) {
          return usage;
        }
      }
      end = start;
    }
    return codexRolloutUsage(leadingFragment);
  } catch {
    return null;
  } finally {
    if (descriptor !== undefined) {
      closeSync(descriptor);
    }
  }
}

export function codexUsageDelta(usage, baseline) {
  if (!usage || !baseline) {
    return null;
  }
  const result = { ...usage };
  for (const field of [
    "inputTokens",
    "outputTokens",
    "cachedInputTokens",
    "cacheWriteInputTokens",
    "cacheWrite5mInputTokens",
    "cacheWrite1hInputTokens",
    "reasoningOutputTokens",
  ]) {
    const current = usage[field];
    const previous = baseline[field];
    if (current == null) {
      result[field] = null;
      continue;
    }
    if (previous == null) {
      result[field] = current;
      continue;
    }
    if (current < previous) {
      return null;
    }
    result[field] = current - previous;
  }
  return result;
}

function usageForTurn(state, usage) {
  if (
    state.character?.backend !== "codex" ||
    !state.resumedCodexSession
  ) {
    return usage;
  }
  if (!state.usageBaseline) {
    return null;
  }
  return codexUsageDelta(usage, state.usageBaseline) ?? usage;
}

function codexRolloutUsage(line) {
  let record;
  try {
    record = JSON.parse(line);
  } catch {
    return null;
  }
  if (record?.payload?.type !== "token_count") {
    return null;
  }
  const usage = record.payload.info?.total_token_usage;
  const inputTokens = nonnegativeTokenCount(usage?.input_tokens);
  const outputTokens = nonnegativeTokenCount(usage?.output_tokens);
  if (inputTokens === null || outputTokens === null) {
    return null;
  }
  return {
    inputTokens,
    outputTokens,
    cachedInputTokens: nonnegativeTokenCount(
      usage.cached_input_tokens,
    ),
    cacheWriteInputTokens: nonnegativeTokenCount(
      usage.cache_write_input_tokens,
    ),
    cacheWrite5mInputTokens: null,
    cacheWrite1hInputTokens: null,
    reasoningOutputTokens: nonnegativeTokenCount(
      usage.reasoning_output_tokens,
    ),
    serviceTier: null,
    speed: null,
    inferenceGeo: null,
    reportedCostUsd: null,
  };
}

function nonnegativeTokenCount(value) {
  return typeof value === "number" &&
      Number.isFinite(value) &&
      value >= 0
    ? value
    : null;
}

function rolloutFileChangeStatistics(reader, workdir, changes) {
  if (!reader || !readRolloutPatchEvents(reader, workdir)) {
    return null;
  }
  const expectedPaths = normalizedChangePaths(workdir, changes);
  const matchIndex = reader.pending.findIndex((event) =>
    sameStringArrays(event.paths, expectedPaths)
  );
  if (matchIndex < 0) {
    return null;
  }
  const [event] = reader.pending.splice(matchIndex, 1);
  return event.statistics;
}

function readRolloutPatchEvents(reader, workdir) {
  let size;
  try {
    size = statSync(reader.path).size;
  } catch {
    return false;
  }
  if (size < reader.offset) {
    reader.offset = 0;
    reader.remainder = "";
    reader.pending = [];
  }
  if (size === reader.offset) {
    return true;
  }

  const length = size - reader.offset;
  const buffer = Buffer.alloc(length);
  let descriptor;
  let bytesRead = 0;
  try {
    descriptor = openSync(reader.path, "r");
    while (bytesRead < length) {
      const count = readSync(
        descriptor,
        buffer,
        bytesRead,
        length - bytesRead,
        reader.offset + bytesRead,
      );
      if (count <= 0) {
        break;
      }
      bytesRead += count;
    }
  } catch {
    return false;
  } finally {
    if (descriptor !== undefined) {
      closeSync(descriptor);
    }
  }
  if (bytesRead === 0) {
    return false;
  }
  reader.offset += bytesRead;
  const lines = (
    reader.remainder + buffer.subarray(0, bytesRead).toString("utf8")
  ).split("\n");
  reader.remainder = lines.pop() ?? "";
  for (const line of lines) {
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }
    const payload = record?.payload;
    if (
      payload?.type !== "patch_apply_end" ||
      payload.status !== "completed" ||
      payload.success === false ||
      !payload.changes ||
      typeof payload.changes !== "object"
    ) {
      continue;
    }
    const paths = normalizedChangePaths(
      workdir,
      Object.keys(payload.changes).map((path) => ({ path })),
    );
    let additions = 0;
    let deletions = 0;
    let isComplete = paths.length > 0;
    for (const change of Object.values(payload.changes)) {
      const statistics = unifiedDiffStatistics(change?.unified_diff);
      if (!statistics) {
        isComplete = false;
        break;
      }
      additions += statistics.additions;
      deletions += statistics.deletions;
    }
    if (isComplete) {
      reader.pending.push({
        paths,
        statistics: { additions, deletions },
      });
    }
  }
  return true;
}

function unifiedDiffStatistics(value) {
  if (typeof value !== "string" || !value) {
    return null;
  }
  let additions = 0;
  let deletions = 0;
  let hasHunk = false;
  let isInsideHunk = false;
  for (const line of value.replaceAll("\r\n", "\n").split("\n")) {
    if (line.startsWith("@@")) {
      hasHunk = true;
      isInsideHunk = true;
      continue;
    }
    if (!isInsideHunk) {
      continue;
    }
    if (line.startsWith("+")) {
      additions += 1;
    } else if (line.startsWith("-")) {
      deletions += 1;
    }
  }
  return hasHunk ? { additions, deletions } : null;
}

function normalizedChangePaths(workdir, changes) {
  return [...new Set(
    (changes ?? [])
      .map((change) => resolvedChangePath(workdir, change?.path))
      .filter(Boolean),
  )].sort();
}

function sameStringArrays(left, right) {
  return left.length === right.length &&
    left.every((value, index) => value === right[index]);
}

function readFileSnapshot(path, byteLimit) {
  try {
    const metadata = statSync(path);
    if (
      !metadata.isFile() ||
      metadata.size > MAX_FILE_SNAPSHOT_BYTES ||
      metadata.size > byteLimit
    ) {
      return null;
    }
    return readFileSync(path);
  } catch (error) {
    return error?.code === "ENOENT" ? Buffer.alloc(0) : null;
  }
}

function resolvedChangePath(workdir, value) {
  const path = String(value ?? "").trim();
  if (!path) {
    return null;
  }
  return isAbsolute(path) ? path : resolve(workdir, path);
}

export function buildArguments({
  character,
  prompt,
  previousSessionID,
  attachments = [],
}) {
  return character.backend === "codex"
    ? codexArguments(
      character,
      prompt,
      previousSessionID,
      attachments,
    )
    : claudeArguments(character, prompt, previousSessionID);
}

function locateExecutable(character) {
  const configured = character.config?.executablePath;
  if (configured && existsSync(configured)) {
    return configured;
  }

  const home = homedir();
  const candidates = [
    join(home, ".local", "bin", character.backend),
    join("/opt/homebrew/bin", character.backend),
    join("/usr/local/bin", character.backend),
  ];
  if (character.backend === "claude") {
    const versionsDirectory = join(home, ".nvm", "versions", "node");
    if (existsSync(versionsDirectory)) {
      const versionCandidates = readdirSync(versionsDirectory)
        .sort()
        .reverse()
        .map((version) =>
          join(versionsDirectory, version, "bin", "claude")
        );
      candidates.unshift(...versionCandidates);
    }
  }

  return candidates.find(existsSync) ?? character.backend;
}

function codexArguments(
  character,
  prompt,
  previousSessionID,
  attachments,
) {
  const argumentsList = ["exec"];
  let effectivePrompt = prompt;
  if (previousSessionID) {
    argumentsList.push("resume", previousSessionID, "--json");
  } else {
    argumentsList.push("--json", "--skip-git-repo-check");
    effectivePrompt = identityPrompt(character, prompt);
  }
  if (character.model) {
    argumentsList.push("-c", `model="${character.model}"`);
  }
  argumentsList.push(
    "-c",
    `model_reasoning_effort="${character.effort}"`,
    "-c",
    "features.fast_mode=true",
    "-c",
    `service_tier="${character.fastMode ? "fast" : "default"}"`,
    "-c",
    'model_reasoning_summary="detailed"',
    "-c",
    "show_raw_agent_reasoning=true",
  );
  if (previousSessionID) {
    argumentsList.push(
      "-c",
      `sandbox_mode="${character.permission}"`,
      "-c",
      `developer_instructions=${JSON.stringify(identityPrompt(character))}`,
    );
  } else {
    argumentsList.push("-s", character.permission);
  }
  for (const attachment of attachments) {
    if (attachment.isCodexImage) {
      argumentsList.push("-i", attachment.path);
    }
  }
  argumentsList.push(effectivePrompt);
  return argumentsList;
}

function claudeArguments(character, prompt, previousSessionID) {
  if (character.fastMode && character.model !== "claude-opus-5") {
    throw new Error("Claude Fast 모드는 Opus 5에서만 사용할 수 있습니다.");
  }
  const argumentsList = [
    "-p",
    prompt,
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--settings",
    JSON.stringify({ fastMode: character.fastMode === true }),
    "--effort",
    character.effort,
    "--permission-mode",
    character.permission,
  ];
  if (character.model) {
    argumentsList.push("--model", character.model);
  }
  argumentsList.push(
    "--append-system-prompt",
    identityPrompt(character),
  );
  if (previousSessionID) {
    argumentsList.push("--resume", previousSessionID);
  }
  return argumentsList;
}

function identityPrompt(character, prompt = null) {
  const identity = `
너는 이 사무실의 ${character.name}이다. ${character.seat}에 앉아 있다.
${character.identityPrompt}

응답 규칙
${RESPONSE_INSTRUCTION}
  `.trim();
  return prompt ? `${identity}\n\n사용자 업무\n${prompt}` : identity;
}

export function promptWithAttachments(prompt, attachments) {
  if (attachments.length === 0) {
    return prompt;
  }
  const references = attachments.map(
    (attachment) =>
      `- ${JSON.stringify(attachment.name)}: ` +
      JSON.stringify(attachment.path),
  );
  return [
    prompt,
    "",
    "첨부 파일",
    "다음 로컬 파일을 업무 자료로 사용하세요.",
    ...references,
  ].join("\n");
}

export function stageAttachments({ attachmentPaths, workdir }) {
  if (!Array.isArray(attachmentPaths)) {
    throw new Error("첨부 파일 목록이 올바르지 않습니다.");
  }
  const uniquePaths = [
    ...new Set(
      attachmentPaths.map((path) => String(path ?? "").trim()),
    ),
  ].filter(Boolean);
  if (uniquePaths.length > 20) {
    throw new Error("첨부 파일은 한 번에 20개까지 선택할 수 있습니다.");
  }
  if (uniquePaths.length === 0) {
    return [];
  }

  const directory = join(
    workdir,
    ".office-attachments",
    randomUUID(),
  );
  mkdirSync(directory, { recursive: true });

  try {
    return uniquePaths.map((path, index) => {
      const sourcePath = realpathSync(path);
      if (!statSync(sourcePath).isFile()) {
        throw new Error(`파일만 첨부할 수 있습니다. ${path}`);
      }
      const name = basename(sourcePath);
      const stagedPath = join(
        directory,
        `${String(index + 1).padStart(2, "0")}-${name}`,
      );
      copyFileSync(sourcePath, stagedPath);
      return {
        name,
        path: stagedPath,
        directory,
        isCodexImage: [".png", ".jpg", ".jpeg"].includes(
          extname(name).toLowerCase(),
        ),
      };
    });
  } catch (error) {
    rmSync(directory, { recursive: true, force: true });
    throw error;
  }
}

function removeStagedAttachments(attachments) {
  const directory = attachments[0]?.directory;
  if (directory) {
    rmSync(directory, { recursive: true, force: true });
  }
}

function terminateProcessGroup(child) {
  if (!child || child.exitCode !== null || !child.pid) {
    return;
  }
  const processID =
    process.platform === "win32" ? child.pid : -child.pid;
  try {
    if (process.platform === "win32") {
      child.kill("SIGTERM");
    } else {
      process.kill(processID, "SIGTERM");
    }
  } catch {
    return;
  }

  const forceTermination = setTimeout(() => {
    if (child.exitCode !== null) {
      return;
    }
    try {
      if (process.platform === "win32") {
        child.kill("SIGKILL");
      } else {
        process.kill(processID, "SIGKILL");
      }
    } catch {
      // 이미 종료된 프로세스는 추가 조치가 필요 없다.
    }
  }, 1_500);
  forceTermination.unref();
}

async function collectStream(stream) {
  let output = "";
  for await (const chunk of stream) {
    output += chunk.toString("utf8");
    if (output.length > 200_000) {
      output = output.slice(-200_000);
    }
  }
  return output;
}
