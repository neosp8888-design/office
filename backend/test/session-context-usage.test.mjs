// 이 파일은 CLI 기록에서 대화 시점의 컨텍스트 사용량을 뽑아내는 동작을 검증한다.

import assert from "node:assert/strict";
import {
  appendFileSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  claudeContextEntry,
  claudeContextWindow,
  codexContextEntry,
  sessionContextUsage,
} from "../src/session-context-usage.mjs";

function claudeAssistantLine({
  timestamp,
  input,
  cacheRead,
  cacheWrite,
  isSidechain = false,
}) {
  return JSON.stringify({
    type: "assistant",
    isSidechain,
    timestamp,
    message: {
      model: "claude-opus-5",
      usage: {
        input_tokens: input,
        cache_read_input_tokens: cacheRead,
        cache_creation_input_tokens: cacheWrite,
        output_tokens: 100,
      },
    },
  });
}

function codexTokenCountLine({ timestamp, lastInput, window }) {
  return JSON.stringify({
    timestamp,
    type: "event_msg",
    payload: {
      type: "token_count",
      info: {
        total_token_usage: { input_tokens: 999_999, output_tokens: 1 },
        last_token_usage: { input_tokens: lastInput, output_tokens: 1 },
        model_context_window: window,
      },
    },
  });
}

test("Claude 기록은 입력과 캐시를 합쳐 컨텍스트 점유로 계산한다", () => {
  const entry = claudeContextEntry(
    claudeAssistantLine({
      timestamp: "2026-07-31T19:40:22.710Z",
      input: 1,
      cacheRead: 37_274,
      cacheWrite: 231_269,
    }),
  );

  assert.equal(entry.usedTokens, 268_544);
  assert.equal(entry.limitTokens, null);
});

test("Claude 부속 대화와 사용량 없는 줄은 건너뛴다", () => {
  assert.equal(
    claudeContextEntry(
      claudeAssistantLine({
        timestamp: "2026-07-31T19:40:22.710Z",
        input: 1,
        cacheRead: 10,
        cacheWrite: 0,
        isSidechain: true,
      }),
    ),
    null,
  );
  assert.equal(
    claudeContextEntry(
      JSON.stringify({ type: "user", timestamp: "2026-07-31T19:40:00.000Z" }),
    ),
    null,
  );
});

test("Codex 기록은 마지막 요청 입력과 모델 한도를 사용한다", () => {
  const entry = codexContextEntry(
    codexTokenCountLine({
      timestamp: "2026-08-01T05:05:06.005Z",
      lastInput: 57_218,
      window: 258_400,
    }),
  );

  assert.equal(entry.usedTokens, 57_218);
  assert.equal(entry.limitTokens, 258_400);
});

test("누적 사용량은 컨텍스트 점유로 오인하지 않는다", () => {
  const entry = codexContextEntry(
    codexTokenCountLine({
      timestamp: "2026-08-01T05:05:06.005Z",
      lastInput: 38_195,
      window: 258_400,
    }),
  );

  assert.notEqual(entry.usedTokens, 999_999);
});

test("Claude 모델 문자열로 컨텍스트 한도를 찾는다", () => {
  assert.equal(claudeContextWindow("claude-opus-5"), 1_000_000);
  assert.equal(claudeContextWindow("claude-haiku-4-5-20251001"), 200_000);
  assert.equal(claudeContextWindow("gpt-5.6-sol"), null);
  assert.equal(claudeContextWindow(null), null);
});

test("Claude 세션은 대화 종료 시점 이전의 마지막 기록을 사용한다", () => {
  const root = mkdtempSync(join(tmpdir(), "officellm-claude-"));
  try {
    const project = join(root, "-Users-neo-office");
    mkdirSync(project);
    const sessionID = "2206f58e-0bd8-43dd-8068-780090adbaa8";
    writeFileSync(
      join(project, `${sessionID}.jsonl`),
      [
        claudeAssistantLine({
          timestamp: "2026-07-31T19:30:00.000Z",
          input: 2,
          cacheRead: 36_310,
          cacheWrite: 964,
        }),
        claudeAssistantLine({
          timestamp: "2026-07-31T19:40:22.710Z",
          input: 1,
          cacheRead: 37_274,
          cacheWrite: 231_269,
        }),
        claudeAssistantLine({
          timestamp: "2026-07-31T20:10:00.000Z",
          input: 5,
          cacheRead: 900_000,
          cacheWrite: 0,
        }),
      ].join("\n") + "\n",
    );

    assert.deepEqual(
      sessionContextUsage({
        backend: "claude",
        sessionID,
        model: "claude-opus-5",
        at: "2026-07-31T19:40:23.259Z",
        claudeRoot: root,
      }),
      { usedTokens: 268_544, limitTokens: 1_000_000 },
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("이어붙은 기록은 다시 읽어 최신 점유를 반영한다", () => {
  const root = mkdtempSync(join(tmpdir(), "officellm-codex-"));
  try {
    const day = join(root, "2026", "08", "01");
    mkdirSync(day, { recursive: true });
    const sessionID = "019fbbb6-0c8f-7ac2-b1c7-755cf64a5440";
    const path = join(day, `rollout-2026-08-01T14-04-58-${sessionID}.jsonl`);
    writeFileSync(
      path,
      codexTokenCountLine({
        timestamp: "2026-08-01T05:05:06.005Z",
        lastInput: 38_195,
        window: 258_400,
      }) + "\n",
    );

    const first = sessionContextUsage({
      backend: "codex",
      sessionID,
      at: "2026-08-01T06:00:00.000Z",
      codexRoot: root,
    });
    assert.deepEqual(first, { usedTokens: 38_195, limitTokens: 258_400 });

    appendFileSync(
      path,
      codexTokenCountLine({
        timestamp: "2026-08-01T05:30:00.000Z",
        lastInput: 57_218,
        window: 258_400,
      }) + "\n",
    );

    assert.deepEqual(
      sessionContextUsage({
        backend: "codex",
        sessionID,
        at: "2026-08-01T06:00:00.000Z",
        codexRoot: root,
      }),
      { usedTokens: 57_218, limitTokens: 258_400 },
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("기록이나 한도를 찾지 못하면 값을 만들지 않는다", () => {
  const root = mkdtempSync(join(tmpdir(), "officellm-empty-"));
  try {
    assert.equal(
      sessionContextUsage({
        backend: "claude",
        sessionID: "missing-session",
        model: "claude-opus-5",
        at: "2026-08-01T06:00:00.000Z",
        claudeRoot: root,
      }),
      null,
    );
    assert.equal(
      sessionContextUsage({
        backend: "claude",
        sessionID: null,
        model: "claude-opus-5",
        at: "2026-08-01T06:00:00.000Z",
        claudeRoot: root,
      }),
      null,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
