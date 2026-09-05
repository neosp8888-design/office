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
    0.00438,
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
    0.00876,
  );
});

test("Gemini 3.7 Flash는 agy의 분리된 입력·캐시와 합산 출력을 계산한다", () => {
  assert.equal(
    estimateTokenCost({
      backend: "antigravity",
      model: "gemini-3.7-flash",
      fastMode: false,
      pricedAt: new Date("2026-08-28T00:00:00Z"),
      usage: {
        inputTokens: 100_000,
        cachedInputTokens: 20_000,
        outputTokens: 5_000,
        reasoningOutputTokens: 4_000,
      },
    }),
    0.09525,
  );
});

// 3.8-flash 단가는 3.7-flash와 같다.
test("Gemini 3.8 Flash는 3.7 Flash와 같은 단가로 비용을 채운다", () => {
  const usage = {
    inputTokens: 100_000,
    cachedInputTokens: 20_000,
    outputTokens: 5_000,
    reasoningOutputTokens: 4_000,
  };
  const promotion = new Date("2026-08-28T00:00:00Z");
  assert.equal(
    estimateTokenCost({
      backend: "antigravity",
      model: "gemini-3.8-flash",
      fastMode: false,
      pricedAt: promotion,
      usage,
    }),
    estimateTokenCost({
      backend: "antigravity",
      model: "gemini-3.7-flash",
      fastMode: false,
      pricedAt: promotion,
      usage,
    }),
  );
  assert.notEqual(
    estimateTokenCost({
      backend: "antigravity",
      model: "gemini-3.8-flash",
      fastMode: false,
      pricedAt: promotion,
      usage,
    }),
    null,
  );
});

test("Gemini 3.7 Flash는 프로모션 종료 뒤 정가를 사용한다", () => {
  assert.equal(
    estimateTokenCost({
      backend: "antigravity",
      model: "gemini-3.7-flash",
      fastMode: false,
      pricedAt: new Date("2027-01-01T00:00:00Z"),
      usage: {
        inputTokens: 100_000,
        cachedInputTokens: 20_000,
        outputTokens: 5_000,
      },
    }),
    0.1905,
  );
});

test("Gemini 3.1 Pro는 전체 프롬프트 20만 초과 단가를 적용한다", () => {
  assert.equal(
    estimateTokenCost({
      backend: "antigravity",
      model: "gemini-3.1-pro",
      fastMode: false,
      usage: {
        inputTokens: 2_000,
        cachedInputTokens: 200_000,
        outputTokens: 1_000,
      },
    }),
    0.106,
  );
});

test("Gemini 3.5 Flash는 모델별 출력 단가를 사용한다", () => {
  assert.equal(
    estimateTokenCost({
      backend: "antigravity",
      model: "gemini-3.5-flash",
      fastMode: false,
      usage: {
        inputTokens: 1_000,
        cachedInputTokens: 1_000,
        outputTokens: 1_000,
      },
    }),
    0.01065,
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

test("Claude 전체 pipeline 비용은 본체 토큰 재계산보다 우선한다", () => {
  assert.equal(
    estimateTokenCost({
      backend: "claude",
      model: "claude-opus-5",
      fastMode: false,
      usage: {
        inputTokens: 2,
        outputTokens: 4,
        cachedInputTokens: 0,
        cacheWriteInputTokens: 10,
        reportedCostUsd: 0.42,
      },
    }),
    0.42,
  );
});

test("Claude Sonnet 5 공급자 비용은 시점과 무관하게 받은 값을 보존한다", () => {
  assert.equal(
    estimateTokenCost({
      backend: "claude",
      model: "claude-sonnet-5",
      fastMode: false,
      pricedAt: new Date("2026-08-19T00:00:00Z"),
      usage: {
        reportedCostUsd: 1.4559903,
        reportedSonnet5CostUsd: 1.1559903,
      },
    }),
    1.4559903,
  );
});

test("Claude Sonnet 5 공급자 비용은 정가 전환일부터 그대로 보존한다", () => {
  assert.equal(
    estimateTokenCost({
      backend: "claude",
      model: "claude-sonnet-5",
      fastMode: false,
      pricedAt: new Date("2026-09-01T00:00:00Z"),
      usage: {
        reportedCostUsd: 1.1559903,
        reportedSonnet5CostUsd: 1.1559903,
      },
    }),
    1.1559903,
  );
});

// Claude 비용은 Claude Code가 보고한 값만 저장한다. 보고값이 없으면 토큰과
// 단가로 다시 계산하지 않고 비운다.
test("Claude 보고 비용이 없으면 토큰으로 추정하지 않는다", () => {
  for (const [model, speed] of [
    ["claude-opus-5", "standard"],
    ["claude-opus-5", "fast"],
    ["claude-sonnet-5", "standard"],
    ["opus[1m]", "standard"],
  ]) {
    assert.equal(
      estimateTokenCost({
        backend: "claude",
        model,
        fastMode: speed === "fast",
        usage: {
          inputTokens: 10,
          outputTokens: 5,
          cachedInputTokens: 100,
          cacheWriteInputTokens: 50,
          cacheWrite5mInputTokens: 20,
          cacheWrite1hInputTokens: 30,
          speed,
          inferenceGeo: "global",
          reportedCostUsd: null,
        },
      }),
      null,
    );
  }
});

test("Claude 상태줄 차액 0도 보고값으로 보존한다", () => {
  assert.equal(
    estimateTokenCost({
      backend: "claude",
      model: "opus[1m]",
      fastMode: false,
      usage: { inputTokens: 10, outputTokens: 5, reportedCostUsd: 0 },
    }),
    0,
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

  assert.equal(
    estimateTokenCost({
      backend: "antigravity",
      model: "unknown",
      fastMode: false,
      usage,
    }),
    null,
  );
});
