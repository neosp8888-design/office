// Antigravity 대화 DB에서 단계별 추론 요약을 읽어오는 경로를 검증한다.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import {
  antigravityStepPayloadReasoning,
  antigravityStepReasoning,
} from "../src/antigravity-reasoning.mjs";

const sessionID = "9dc0e8e9-427e-43a8-9803-345c9cda9d2c";

test("응답 단계 payload에서 답변이 아니라 추론 필드만 읽는다", () => {
  assert.equal(
    antigravityStepPayloadReasoning(stepPayload({
      answer: "요청하신 파일을 만들었습니다.",
      reasoning: "**Prioritizing Tool Usage**\n\n도구 선택을 먼저 검토했다.",
    })),
    "**Prioritizing Tool Usage**\n\n도구 선택을 먼저 검토했다.",
  );
});

test("추론이 비어 있는 단계는 활동을 만들지 않도록 null을 준다", () => {
  assert.equal(
    antigravityStepPayloadReasoning(stepPayload({ answer: "391" })),
    null,
  );
  assert.equal(antigravityStepPayloadReasoning(Buffer.alloc(0)), null);
});

test("추론이 길면 다른 백엔드와 같은 6,000자 상한으로 자른다", () => {
  const text = antigravityStepPayloadReasoning(stepPayload({
    reasoning: "가".repeat(6_500),
  }));

  assert.equal(text.length, 6_000);
  assert.equal(text.endsWith("…"), true);
});

test("대화 DB에서 해당 단계의 추론만 골라 읽는다", () => {
  const root = mkdtempSync(join(tmpdir(), "officestra-agy-reasoning-"));
  const database = new DatabaseSync(join(root, `${sessionID}.db`));
  try {
    database.exec(`
      CREATE TABLE steps (
        idx INTEGER PRIMARY KEY,
        step_type INTEGER,
        step_payload BLOB
      );
    `);
    const insert = database.prepare(
      "INSERT INTO steps (idx, step_type, step_payload) VALUES (?, ?, ?)",
    );
    insert.run(0, 14, stepPayload({ answer: "사용자 입력" }));
    insert.run(1, 15, stepPayload({ reasoning: "먼저 파일을 만들기로 했다." }));
    insert.run(2, 132, stepPayload({ reasoning: "도구 단계는 무시한다." }));
    insert.run(3, 15, stepPayload({ answer: "작업을 마쳤습니다." }));
    database.close();

    assert.equal(
      antigravityStepReasoning(sessionID, 1, { root }),
      "먼저 파일을 만들기로 했다.",
    );
    assert.equal(antigravityStepReasoning(sessionID, 2, { root }), null);
    assert.equal(antigravityStepReasoning(sessionID, 3, { root }), null);
    assert.equal(antigravityStepReasoning(sessionID, 99, { root }), null);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("세션 ID나 대화 파일이 없으면 조용히 건너뛴다", () => {
  const root = mkdtempSync(join(tmpdir(), "officestra-agy-reasoning-"));
  try {
    assert.equal(antigravityStepReasoning("세션 아님", 1, { root }), null);
    assert.equal(antigravityStepReasoning(sessionID, 1, { root }), null);
    assert.equal(antigravityStepReasoning(sessionID, -1, { root }), null);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

// agy의 응답 단계는 20번 필드 안에 답변(1·8번)과 추론(3번)을 함께 담는다.
function stepPayload({ answer, reasoning } = {}) {
  const response = [];
  if (answer) response.push(bytesField(1, Buffer.from(answer)));
  if (reasoning) response.push(bytesField(3, Buffer.from(reasoning)));
  if (answer) response.push(bytesField(8, Buffer.from(answer)));
  return Buffer.concat([
    bytesField(5, Buffer.concat([bytesField(12, Buffer.from("execution-1"))])),
    bytesField(20, Buffer.concat(response)),
  ]);
}

function bytesField(number, value) {
  const buffer = Buffer.from(value);
  return Buffer.concat([
    varint(BigInt((number << 3) | 2)),
    varint(BigInt(buffer.length)),
    buffer,
  ]);
}

function varint(value) {
  const bytes = [];
  let current = value;
  do {
    let byte = Number(current & 0x7fn);
    current >>= 7n;
    if (current > 0n) byte |= 0x80;
    bytes.push(byte);
  } while (current > 0n);
  return Buffer.from(bytes);
}
