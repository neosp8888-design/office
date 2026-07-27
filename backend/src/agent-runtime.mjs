// 이 파일은 백엔드에서 CLI 업무를 실행하고 공개 진행 상태를 PostgreSQL과 WebSocket에 전달한다.

import { spawn } from "node:child_process";
import { once } from "node:events";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, extname, join } from "node:path";
import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";

import {
  decodeAgentResponse,
  parseAgentEvent,
} from "./agent-event-parser.mjs";
import {
  appendLocalImagePreviews,
  listGeneratedImages,
} from "./local-artifacts.mjs";

const RESPONSE_INSTRUCTION = `
사용자 판단이 반드시 필요해 더 진행할 수 없을 때만 최종 응답을 정확히 다음 형식으로 작성한다.
[NEED_INPUT]
사용자에게 보여줄 질문 원문
표식 다음에는 질문과 판단에 필요한 선택지만 작성한다. 사용자 확인 없이 할 수 있는 작업은 먼저 진행한다.
`.trim();

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
        UPDATE turns
        SET
          status = 'interrupted',
          error_message =
            '백엔드가 재시작되어 이전 실시간 출력 연결이 종료됐습니다.',
          ended_at = COALESCE(ended_at, now()),
          updated_at = now()
        WHERE status IN ('pending', 'running')
        RETURNING id
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
      responseText: "",
      partialText: "",
      lastPartialPersistedAt: 0,
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
    } finally {
      this.running.delete(characterID);
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
            prompt,
            status,
            started_at,
            updated_at
          )
          VALUES ($1, $2, $3, $4, $5, $6, 'running', now(), now())
        `,
        [
          turnID,
          sessionID,
          character.backend,
          character.model,
          character.effort,
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

    if (state.cancelRequested) {
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

    const candidate = state.responseText || state.partialText;
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
      if (
        event.sessionID &&
        event.sessionID !== state.externalSessionID
      ) {
        await this.activateSession(state, event.sessionID);
      }
      if (event.activity) {
        await this.addActivity(state, event.activity);
      }
      if (event.responseDelta) {
        state.partialText += event.responseDelta;
        await this.persistPartialResponse(state);
      }
      if (event.responseText) {
        state.responseText = event.responseText;
        await this.persistResponseDraft(state, event.responseText);
      }
      if (event.warning) {
        state.warning = event.warning;
      }
      if (event.failure) {
        state.failure = event.failure;
      }
    }
  }

  async activateSession(state, externalSessionID) {
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
    this.broadcast({ type: "session.changed", turnId: state.turnID });
  }

  async addActivity(state, activity) {
    const key = `${activity.kind}\n${activity.text}`;
    if (state.lastActivity === key) {
      return;
    }
    state.lastActivity = key;
    state.sequence += 1;
    await this.pool.query(
      `
        INSERT INTO turn_activities (turn_id, seq, kind, text)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (turn_id, seq) DO NOTHING
      `,
      [
        state.turnID,
        state.sequence,
        activity.kind,
        activity.text,
      ],
    );
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
    await this.persistResponseDraft(state, state.partialText);
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

  async complete(state, decoded) {
    if (state.cancelRequested) {
      return;
    }
    const generatedImages = listGeneratedImages(
      state.externalSessionID,
    ).filter((path) => !state.initialGeneratedImages.has(path));
    const responseText = appendLocalImagePreviews(
      decoded.text,
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
    });
    this.running.delete(state.character.id);
    this.broadcast({
      type: "feed.changed",
      turnId: state.turnID,
      characterId: state.character.id,
    });
  }

  async fail(state, error) {
    if (!this.running.has(state.character.id)) {
      return;
    }
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
    this.running.delete(state.character.id);
    this.broadcast({
      type: "feed.changed",
      turnId: state.turnID,
      characterId: state.character.id,
    });
  }
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
  );
  if (!previousSessionID) {
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
  const argumentsList = [
    "-p",
    prompt,
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--effort",
    character.effort,
    "--permission-mode",
    character.permission,
  ];
  if (character.model) {
    argumentsList.push("--model", character.model);
  }
  if (previousSessionID) {
    argumentsList.push("--resume", previousSessionID);
  } else {
    argumentsList.push(
      "--append-system-prompt",
      identityPrompt(character),
    );
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
