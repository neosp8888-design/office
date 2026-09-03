// Antigravity 대화 SQLite에 남은 단계별 추론 텍스트를 읽기 전용으로 해석한다.

import { createRequire } from "node:module";
import { existsSync } from "node:fs";
import {
  antigravityConversationPath,
  nestedFields,
  protobufFields,
  utf8Field,
} from "./antigravity-local-state.mjs";

const require = createRequire(import.meta.url);
// agy는 응답 단계를 step_type 15로 남기고, 그 payload의 20번 필드 안
// 3번 필드에만 추론 요약을 담는다. 1번과 8번 필드는 사용자에게 보이는 답변이다.
const AGENT_RESPONSE_STEP_TYPE = 15;
const RESPONSE_FIELD = 20;
const REASONING_FIELD = 3;
const MAX_PAYLOAD_BYTES = 256 * 1024;
// 다른 백엔드의 추론 활동과 같은 상한을 쓴다.
const MAX_REASONING_LENGTH = 6_000;
// agy는 단계가 끝나야 status를 3으로 바꾼다. 그 전까지는 추론이 자라는 중이다.
const STEP_STATUS_DONE = 3;

// 대화 SQLite의 마지막 단계 번호를 구한다. 턴 시작 전 시점의 기준선으로 쓴다.
export function antigravityLatestStepIndex(sessionID, { root } = {}) {
  const path = antigravityConversationPath(sessionID, root);
  if (!path || !existsSync(path)) {
    return null;
  }
  let database;
  try {
    const { DatabaseSync } = require("node:sqlite");
    database = new DatabaseSync(path, { readOnly: true });
    const row = database.prepare(
      `
        SELECT MAX(idx) AS max_idx
        FROM steps
      `,
    ).get();
    return row && Number.isInteger(row.max_idx) ? row.max_idx : null;
  } catch {
    return null;
  } finally {
    try {
      database?.close();
    } catch {
      // close 실패는 읽기 결과에 영향을 주지 않는다.
    }
  }
}

// 추론은 단계가 끝날 때가 아니라 진행 중에도 조금씩 쌓이므로,
// 기준선 이후에 쌓인 단계별 추론을 돌려주고 호출자가 갱신 여부를 판단한다.
export function antigravityStepReasonings(
  sessionID,
  { minStepIndex = null, root } = {},
) {
  const path = antigravityConversationPath(sessionID, root);
  if (!path || !existsSync(path)) {
    return [];
  }
  let database;
  try {
    const { DatabaseSync } = require("node:sqlite");
    database = new DatabaseSync(path, { readOnly: true });
    const hasMin = Number.isInteger(minStepIndex);
    const rows = database.prepare(
      `
        SELECT idx, status, step_payload
        FROM steps
        WHERE step_type = ?
          AND step_payload IS NOT NULL
          AND length(step_payload) <= ?
          ${hasMin ? "AND idx >= ?" : ""}
        ORDER BY idx
      `,
    ).all(...[
      AGENT_RESPONSE_STEP_TYPE,
      MAX_PAYLOAD_BYTES,
      ...(hasMin ? [minStepIndex] : []),
    ]);
    const reasonings = [];
    for (const row of rows) {
      const text = antigravityStepPayloadReasoning(row.step_payload);
      if (!text) continue;
      reasonings.push({
        stepIndex: Number(row.idx),
        text,
        done: Number(row.status) === STEP_STATUS_DONE,
      });
    }
    return reasonings;
  } catch {
    // 대화 파일이 갱신되는 도중의 읽기 실패는 다음 폴링에서 회복한다.
    return [];
  } finally {
    try {
      database?.close();
    } catch {
      // close 실패는 읽기 결과에 영향을 주지 않는다.
    }
  }
}

export function antigravityStepPayloadReasoning(value) {
  try {
    const response = nestedFields(protobufFields(value), RESPONSE_FIELD);
    const text = utf8Field(response, REASONING_FIELD);
    if (!text) {
      return null;
    }
    return text.length <= MAX_REASONING_LENGTH
      ? text
      : `${text.slice(0, MAX_REASONING_LENGTH - 1)}…`;
  } catch {
    return null;
  }
}
