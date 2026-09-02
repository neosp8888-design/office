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

export function antigravityStepReasoning(sessionID, stepIndex, { root } = {}) {
  const path = antigravityConversationPath(sessionID, root);
  const index = Number(stepIndex);
  if (!path || !Number.isInteger(index) || index < 0 || !existsSync(path)) {
    return null;
  }
  let database;
  try {
    const { DatabaseSync } = require("node:sqlite");
    database = new DatabaseSync(path, { readOnly: true });
    const row = database.prepare(
      `
        SELECT step_payload
        FROM steps
        WHERE idx = ?
          AND step_type = ?
          AND step_payload IS NOT NULL
          AND length(step_payload) <= ?
      `,
    ).get(index, AGENT_RESPONSE_STEP_TYPE, MAX_PAYLOAD_BYTES);
    return row ? antigravityStepPayloadReasoning(row.step_payload) : null;
  } catch {
    // 대화 파일이 갱신되는 도중의 읽기 실패는 다음 단계에서 회복한다.
    return null;
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
