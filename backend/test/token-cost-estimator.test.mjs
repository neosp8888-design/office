// 이 파일은 공식 토큰 단가에 따른 완료 턴의 USD 추정 비용 계산을 검증한다.

import assert from "node:assert/strict";
import test from "node:test";

import { estimateTokenCost } from "../src/token-cost-estimator.mjs";

const usage = {
  inputTokens: 1_000,
  cachedInputTokens: 200,
  cacheWriteInputTokens: 100,
  outputTokens: 50,
};

test("GPT-5.6 Sol Standard 비용을 캐시 종류별로 계산한다", () => {
  assert.equal(
    estimateTokenCost({
      backend: "codex",
      model: "gpt-5.6-sol",
      fastMode: false,
      usage,
    }),
    0.005725,
  );
});

test("GPT-5.6 Sol Fast 비용은 Fast 공식 단가를 사용한다", () => {
  assert.equal(
    estimateTokenCost({
      backend: "codex",
      model: "gpt-5.6-sol",
      fastMode: true,
      usage,
    }),
    0.01145,
  );
});

test("Claude CLI가 보고한 누적 비용을 그대로 보존한다", () => {
  assert.equal(
    estimateTokenCost({
      backend: "claude",
      model: "claude-opus-5",
      fastMode: true,
      usage: { reportedCostUsd: 0.13599125 },
    }),
    0.13599125,
  );
});

test("Claude Opus 5 토큰 비용은 캐시 생성과 읽기를 분리한다", () => {
  assert.equal(
    estimateTokenCost({
      backend: "claude",
      model: "claude-opus-5",
      fastMode: false,
      usage: {
        inputTokens: 2,
        outputTokens: 4,
        cachedInputTokens: 0,
        cacheWriteInputTokens: 21_741,
        cacheWrite5mInputTokens: 21_741,
        cacheWrite1hInputTokens: 0,
        speed: "standard",
        inferenceGeo: "global",
      },
    }),
    0.13599125,
  );
});

test("Claude Opus 5 Fast 비용은 실제 speed와 캐시 배수를 사용한다", () => {
  assert.equal(
    estimateTokenCost({
      backend: "claude",
      model: "claude-opus-5",
      fastMode: false,
      usage: {
        inputTokens: 10,
        outputTokens: 5,
        cachedInputTokens: 100,
        cacheWriteInputTokens: 50,
        cacheWrite5mInputTokens: 20,
        cacheWrite1hInputTokens: 30,
        speed: "fast",
        inferenceGeo: "global",
      },
    }),
    0.0013,
  );
});

test("단가를 모르는 모델은 비용을 꾸며내지 않는다", () => {
  assert.equal(
    estimateTokenCost({
      backend: "codex",
      model: "unknown",
      fastMode: false,
      usage,
    }),
    null,
  );
});
