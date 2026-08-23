// 이 파일은 Slack Socket Mode 메시지를 OFFICESTRA 직원 업무와 실시간 결과로 연결한다.

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import slackBolt from "@slack/bolt";

const { App, LogLevel } = slackBolt;
const TERMINAL_STATUSES = new Set([
  "completed",
  "failed",
  "interrupted",
]);
const POLL_INTERVAL_MS = 1_500;
const STATUS_TEXT_LIMIT = 2_700;
const MESSAGE_TEXT_LIMIT = 35_000;

export async function startSlackBridge({
  pool,
  backendURL = "http://127.0.0.1:4317",
  environment = process.env,
  logger = console,
} = {}) {
  const configuration = readSlackConfiguration({ environment });
  if (!configuration.botToken || !configuration.appToken) {
    return { enabled: false, reason: "missing_tokens" };
  }
  if (configuration.allowedUserIDs.size === 0) {
    logger.warn(
      "Slack 연동 비활성화. OFFICE_SLACK_ALLOWED_USER_IDS가 필요합니다.",
    );
    return { enabled: false, reason: "missing_allowed_users" };
  }

  const app = new App({
    token: configuration.botToken,
    appToken: configuration.appToken,
    socketMode: true,
    logLevel: LogLevel.WARN,
  });

  const context = {
    app,
    pool,
    backendURL: backendURL.replace(/\/$/, ""),
    configuration,
    logger,
    monitors: new Map(),
  };

  app.command("/office", async ({ ack, body, client }) => {
    await ack();
    if (!isAuthorizedSlackRequest(configuration, body)) {
      await client.chat.postMessage({
        channel: body.channel_id,
        text: "OFFICESTRA 사용 권한이 없습니다.",
      });
      return;
    }
    await client.chat.postMessage({
      channel: body.channel_id,
      ...(await employeeSelectionMessage(
        context,
        slackTeamID(body),
        body.user_id,
      )),
    });
  });

  app.action(/^officestra\.select-character\./, async ({
    ack,
    action,
    body,
    client,
  }) => {
    await ack();
    if (!isAuthorizedSlackRequest(configuration, body)) {
      return;
    }
    const character = await characterByID(context, action.value);
    if (!character) {
      await client.chat.update({
        channel: body.channel.id,
        ts: body.message.ts,
        text: "직원 정보를 다시 불러온 뒤 선택해 주세요.",
      });
      return;
    }
    await saveSlackPreference(
      pool,
      slackTeamID(body),
      body.user.id,
      character.id,
    );
    await client.chat.update({
      channel: body.channel.id,
      ts: body.message.ts,
      text: `✅ 기본 직원을 *${escapeSlackText(character.name)}*으로 선택했습니다. 이제 봇에게 업무를 보내세요.`,
    });
  });

  app.event("app_mention", async (args) => {
    await receiveSlackMessage(context, args);
  });

  app.event("message", async (args) => {
    if (args.event?.channel_type !== "im") {
      return;
    }
    await receiveSlackMessage(context, args);
  });

  app.error(async (error) => {
    logger.error("Slack 연결 오류", safeErrorMessage(error));
  });

  await app.start();
  const restoredMonitorCount = await restoreSlackTurnMonitors(context);
  logger.log("OFFICESTRA Slack Socket Mode 연결 완료");
  if (restoredMonitorCount > 0) {
    logger.log(`Slack 업무 모니터 ${restoredMonitorCount}건 복구 완료`);
  }
  return { enabled: true, app };
}

async function receiveSlackMessage(context, { event, body, client, context: boltContext }) {
  if (
    !event ||
    event.bot_id ||
    event.subtype ||
    !event.user ||
    !event.channel ||
    !event.ts ||
    !isAuthorizedSlackRequest(context.configuration, body)
  ) {
    return;
  }
  if (body.event_id && !(await claimSlackEvent(context.pool, body.event_id))) {
    return;
  }

  const teamID = slackTeamID(body);
  const prompt = stripSlackMention(event.text, boltContext?.botUserId);
  if (!prompt) {
    await client.chat.postMessage({
      channel: event.channel,
      thread_ts: event.thread_ts ?? event.ts,
      ...(await employeeSelectionMessage(context, teamID, event.user)),
    });
    return;
  }

  const threadTS = event.thread_ts ?? event.ts;
  const thread = await findOrCreateSlackThread(context, {
    teamID,
    channelID: event.channel,
    threadTS,
    userID: event.user,
  });
  const character = await characterByID(context, thread.characterId);
  if (!character) {
    await client.chat.postMessage({
      channel: event.channel,
      thread_ts: threadTS,
      text: "선택된 직원을 찾을 수 없습니다. `/office`에서 다시 선택해 주세요.",
    });
    return;
  }

  const statusMessage = await client.chat.postMessage({
    channel: event.channel,
    thread_ts: threadTS,
    text: `⏳ ${character.name} 업무를 시작합니다.`,
    blocks: progressBlocks({
      characterName: character.name,
      status: "starting",
    }),
  });

  try {
    const job = await backendJSON(
      `${context.backendURL}/api/agent-jobs`,
      {
        method: "POST",
        body: {
          characterId: character.id,
          prompt,
          conversationId: thread.conversationId,
        },
      },
    );
    await recordSlackTurnLaunch(context.pool, {
      teamID,
      channelID: event.channel,
      threadTS,
      conversationID: job.conversationId,
      turnID: job.turnId,
      statusMessageTS: statusMessage.ts,
    });
    monitorSlackTurn(context, {
      client,
      channelID: event.channel,
      threadTS,
      messageTS: statusMessage.ts,
      turnID: job.turnId,
    });
  } catch (error) {
    await client.chat.update({
      channel: event.channel,
      ts: statusMessage.ts,
      text: `❌ ${character.name} 업무를 시작하지 못했습니다. ${safeErrorMessage(error)}`,
    });
  }
}

function monitorSlackTurn(context, target) {
  if (context.monitors.has(target.turnID)) {
    return;
  }
  const task = runTurnMonitor(context, target)
    .catch((error) => {
      context.logger.error("Slack 업무 모니터 오류", safeErrorMessage(error));
    })
    .finally(() => {
      context.monitors.delete(target.turnID);
    });
  context.monitors.set(target.turnID, task);
}

async function runTurnMonitor(context, target) {
  let previousText = "";
  while (true) {
    let turn;
    try {
      const payload = await backendJSON(
        `${context.backendURL}/api/live-feed/${encodeURIComponent(target.turnID)}`,
      );
      turn = payload.turn;
    } catch (error) {
      if (error.status === 404) {
        await delay(POLL_INTERVAL_MS);
        continue;
      }
      throw error;
    }

    const text = renderSlackTurn(turn);
    if (text !== previousText) {
      await target.client.chat.update({
        channel: target.channelID,
        ts: target.messageTS,
        text,
        blocks: progressBlocks(turn),
      });
      previousText = text;
    }

    if (TERMINAL_STATUSES.has(turn.status)) {
      if (turn.response?.trim()) {
        for (const chunk of splitSlackMessage(turn.response)) {
          await target.client.chat.postMessage({
            channel: target.channelID,
            thread_ts: target.threadTS,
            text: normalizeSlackMarkdown(chunk),
          });
        }
      }
      await markSlackTurnDeliveryCompleted(context.pool, target.turnID);
      return;
    }
    await delay(POLL_INTERVAL_MS);
  }
}

async function employeeSelectionMessage(context, teamID, userID) {
  const [characters, preference] = await Promise.all([
    listCharacters(context),
    slackPreference(context.pool, teamID, userID),
  ]);
  const selectedID = preference?.characterId;
  return {
    text: "OFFICESTRA 직원을 선택하세요.",
    blocks: employeeSelectionBlocks(characters, selectedID),
  };
}

export function employeeSelectionBlocks(characters, selectedID = null) {
  return [
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text: "*OFFICESTRA 직원 선택*\n앞으로 보낼 업무를 담당할 직원을 선택하세요.",
      },
    },
    {
      type: "actions",
      elements: characters.slice(0, 5).map((character) => ({
        type: "button",
        action_id: `officestra.select-character.${character.id}`,
        text: {
          type: "plain_text",
          text: `${character.id === selectedID ? "✓ " : ""}${character.name}`,
          emoji: true,
        },
        value: character.id,
        ...(character.id === selectedID ? { style: "primary" } : {}),
      })),
    },
  ];
}

export function renderSlackTurn(turn) {
  const name = turn.characterName ?? "직원";
  const label = slackStatusLabel(turn);
  const activities = (turn.activities ?? [])
    .filter((activity) => activity.text?.trim())
    .slice(-4)
    .map((activity) => `• ${activity.text.trim()}`)
    .join("\n");
  const partial = !TERMINAL_STATUSES.has(turn.status) && turn.response?.trim()
    ? `\n\n${turn.response.trim().slice(-1_200)}`
    : "";
  const details = [activities, partial].filter(Boolean).join("\n");
  return [`${label} *${escapeSlackText(name)}*`, details]
    .filter(Boolean)
    .join("\n")
    .slice(0, STATUS_TEXT_LIMIT);
}

function progressBlocks(turn) {
  return [
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text: renderSlackTurn(turn),
      },
    },
  ];
}

function slackStatusLabel(turn) {
  if (turn.needsInput) {
    return "❓ 답변 필요";
  }
  switch (turn.status) {
  case "completed":
    return "✅ 완료";
  case "failed":
    return `❌ 실패${turn.errorMessage ? ` · ${turn.errorMessage}` : ""}`;
  case "interrupted":
    return "⏹️ 중단";
  case "starting":
    return "⏳ 업무 시작";
  default:
    return "⏳ 작업 중";
  }
}

async function listCharacters(context) {
  const payload = await backendJSON(`${context.backendURL}/api/characters`);
  return payload.characters ?? [];
}

async function characterByID(context, characterID) {
  const characters = await listCharacters(context);
  return characters.find((character) => character.id === characterID) ?? null;
}

async function findOrCreateSlackThread(context, {
  teamID,
  channelID,
  threadTS,
  userID,
}) {
  const existing = await context.pool.query(
    `
      SELECT
        character_id AS "characterId",
        conversation_id AS "conversationId"
      FROM slack_threads
      WHERE team_id = $1 AND channel_id = $2 AND thread_ts = $3
    `,
    [teamID, channelID, threadTS],
  );
  if (existing.rowCount > 0) {
    return existing.rows[0];
  }

  const preference = await slackPreference(context.pool, teamID, userID);
  const characters = await listCharacters(context);
  const characterID = preference?.characterId ??
    characters.find((character) => character.id === "boss")?.id ??
    characters[0]?.id;
  if (!characterID) {
    throw new Error("등록된 직원이 없습니다.");
  }
  const inserted = await context.pool.query(
    `
      INSERT INTO slack_threads (
        team_id,
        channel_id,
        thread_ts,
        user_id,
        character_id
      )
      VALUES ($1, $2, $3, $4, $5)
      ON CONFLICT (team_id, channel_id, thread_ts)
      DO UPDATE SET updated_at = now()
      RETURNING
        character_id AS "characterId",
        conversation_id AS "conversationId"
    `,
    [teamID, channelID, threadTS, userID, characterID],
  );
  return inserted.rows[0];
}

export async function recordSlackTurnLaunch(pool, {
  teamID,
  channelID,
  threadTS,
  conversationID,
  turnID,
  statusMessageTS,
}) {
  if (!conversationID || !turnID || !statusMessageTS) {
    throw new Error("Slack 업무 연결 정보가 완전하지 않습니다.");
  }
  const result = await pool.query(
    `
      UPDATE slack_threads
      SET
        conversation_id = $4,
        last_turn_id = $5,
        status_message_ts = $6,
        delivery_completed_at = NULL,
        updated_at = now()
      WHERE team_id = $1 AND channel_id = $2 AND thread_ts = $3
      RETURNING conversation_id AS "conversationId"
    `,
    [
      teamID,
      channelID,
      threadTS,
      conversationID,
      turnID,
      statusMessageTS,
    ],
  );
  if (result.rowCount === 0) {
    throw new Error("Slack 스레드 연결 정보를 찾을 수 없습니다.");
  }
  return result.rows[0];
}

export async function pendingSlackTurnTargets(pool) {
  const result = await pool.query(
    `
      SELECT
        channel_id AS "channelID",
        thread_ts AS "threadTS",
        status_message_ts AS "messageTS",
        last_turn_id AS "turnID"
      FROM slack_threads
      WHERE last_turn_id IS NOT NULL
        AND status_message_ts IS NOT NULL
        AND delivery_completed_at IS NULL
      ORDER BY updated_at, team_id, channel_id, thread_ts
    `,
  );
  return result.rows;
}

export async function restoreSlackTurnMonitors(context) {
  const targets = await pendingSlackTurnTargets(context.pool);
  for (const target of targets) {
    monitorSlackTurn(context, {
      ...target,
      client: context.app.client,
    });
  }
  return targets.length;
}

export async function markSlackTurnDeliveryCompleted(pool, turnID) {
  await pool.query(
    `
      UPDATE slack_threads
      SET delivery_completed_at = now(), updated_at = now()
      WHERE last_turn_id = $1
    `,
    [turnID],
  );
}

export async function slackPreference(pool, teamID, userID) {
  const result = await pool.query(
    `
      SELECT character_id AS "characterId"
      FROM slack_user_preferences
      WHERE team_id = $1 AND user_id = $2
      ORDER BY updated_at DESC
      LIMIT 1
    `,
    [teamID, userID],
  );
  return result.rows[0] ?? null;
}

async function saveSlackPreference(pool, teamID, userID, characterID) {
  await pool.query(
    `
      INSERT INTO slack_user_preferences (
        team_id,
        user_id,
        character_id,
        updated_at
      )
      VALUES ($1, $2, $3, now())
      ON CONFLICT (team_id, user_id)
      DO UPDATE SET character_id = EXCLUDED.character_id, updated_at = now()
    `,
    [teamID, userID, characterID],
  );
}

async function claimSlackEvent(pool, eventID) {
  const result = await pool.query(
    `
      INSERT INTO slack_event_receipts (event_id)
      VALUES ($1)
      ON CONFLICT (event_id) DO NOTHING
      RETURNING event_id
    `,
    [eventID],
  );
  return result.rowCount > 0;
}

export function readSlackConfiguration({
  environment = process.env,
  filePath = environment.OFFICE_SLACK_ENV_FILE ??
    join(homedir(), ".officestra", "slack.env"),
} = {}) {
  const fileEnvironment = existsSync(filePath)
    ? parseEnvironmentFile(readFileSync(filePath, "utf8"))
    : {};
  const merged = { ...fileEnvironment };
  for (const [key, value] of Object.entries(environment)) {
    if (typeof value === "string" && value.trim()) {
      merged[key] = value;
    }
  }
  return {
    botToken: merged.SLACK_BOT_TOKEN?.trim() ?? "",
    appToken: merged.SLACK_APP_TOKEN?.trim() ?? "",
    allowedUserIDs: identifierSet(merged.OFFICE_SLACK_ALLOWED_USER_IDS),
    allowedTeamIDs: identifierSet(merged.OFFICE_SLACK_ALLOWED_TEAM_IDS),
    filePath,
  };
}

export function parseEnvironmentFile(source) {
  const result = {};
  for (const rawLine of String(source ?? "").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) {
      continue;
    }
    const separator = line.indexOf("=");
    if (separator < 1) {
      continue;
    }
    const key = line.slice(0, separator).trim();
    let value = line.slice(separator + 1).trim();
    if (
      value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'")))
    ) {
      value = value.slice(1, -1);
    }
    result[key] = value;
  }
  return result;
}

export function stripSlackMention(text, botUserID = null) {
  let value = String(text ?? "");
  if (botUserID) {
    value = value.replaceAll(`<@${botUserID}>`, " ");
  } else {
    value = value.replace(/<@[A-Z0-9]+>/g, " ");
  }
  return value.replace(/\s+/g, " ").trim();
}

export function splitSlackMessage(text, limit = MESSAGE_TEXT_LIMIT) {
  const source = String(text ?? "").trim();
  if (!source) {
    return [];
  }
  const chunks = [];
  let remaining = source;
  while (remaining.length > limit) {
    const newline = remaining.lastIndexOf("\n", limit);
    const boundary = newline > limit * 0.6 ? newline : limit;
    chunks.push(remaining.slice(0, boundary).trim());
    remaining = remaining.slice(boundary).trim();
  }
  if (remaining) {
    chunks.push(remaining);
  }
  return chunks;
}

function normalizeSlackMarkdown(text) {
  return String(text ?? "")
    .replace(/^#{1,6}\s+(.+)$/gm, "*$1*")
    .replace(/\*\*(.+?)\*\*/g, "*$1*");
}

function isAuthorizedSlackRequest(configuration, body) {
  const userID = body.user_id ?? body.user?.id ?? body.event?.user;
  const teamID = slackTeamID(body);
  return Boolean(
    userID &&
    configuration.allowedUserIDs.has(userID) &&
    (
      configuration.allowedTeamIDs.size === 0 ||
      configuration.allowedTeamIDs.has(teamID)
    )
  );
}

function slackTeamID(body) {
  return body.team_id ?? body.team?.id ?? body.authorizations?.[0]?.team_id ?? "";
}

function identifierSet(value) {
  return new Set(
    String(value ?? "")
      .split(/[\s,]+/)
      .map((item) => item.trim())
      .filter(Boolean),
  );
}

async function backendJSON(url, { method = "GET", body } = {}) {
  const response = await fetch(url, {
    method,
    headers: body ? { "content-type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(
      payload.error ?? `OFFICESTRA 백엔드 오류 ${response.status}`,
    );
    error.status = response.status;
    throw error;
  }
  return payload;
}

function escapeSlackText(text) {
  return String(text ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function safeErrorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
