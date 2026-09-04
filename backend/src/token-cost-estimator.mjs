// 이 파일은 CLI가 보고한 토큰 사용량을 공식 API 단가 기준의 USD 추정 비용으로 환산한다.

import { pricingRateFor } from "./pricing-catalog.mjs";

const CLAUDE_STANDARD_PRICES_PER_MILLION = {
  "claude-opus-5": { input: 5, output: 25 },
  "claude-fable-5": { input: 10, output: 50 },
  fable: { input: 10, output: 50 },
};

const CLAUDE_FAST_PRICES_PER_MILLION = {
  "claude-opus-5": { input: 10, output: 50 },
};

export function estimateTokenCost({
  backend,
  model,
  fastMode,
  usage,
  pricedAt = new Date(),
}) {
  if (!usage) {
    return null;
  }

  if (backend === "claude") {
    return estimateClaudeCost({
      model,
      fastMode,
      usage,
      pricedAt,
    });
  }
  if (backend === "antigravity") {
    return estimateAntigravityCost({ model, usage, pricedAt });
  }
  if (backend !== "codex") {
    return null;
  }

  const inputTokens = nonnegativeNumber(usage.inputTokens);
  const outputTokens = nonnegativeNumber(usage.outputTokens);
  const prices = pricingRateFor({
    backend: "codex",
    model,
    fastMode,
    promptTokens: inputTokens,
    pricedAt,
  });
  if (!prices || inputTokens === null || outputTokens === null) {
    return null;
  }

  const cachedInputTokens = Math.min(
    inputTokens,
    nonnegativeNumber(usage.cachedInputTokens) ?? 0,
  );
  const cacheWriteInputTokens = Math.min(
    Math.max(inputTokens - cachedInputTokens, 0),
    nonnegativeNumber(usage.cacheWriteInputTokens) ?? 0,
  );
  const uncachedInputTokens = Math.max(
    inputTokens - cachedInputTokens - cacheWriteInputTokens,
    0,
  );
  const cost = (
    uncachedInputTokens * prices.input +
    cachedInputTokens * (prices.cached ?? prices.input) +
    cacheWriteInputTokens * (prices.cacheWrite ?? prices.input) +
    outputTokens * prices.output
  ) / 1_000_000;
  return roundedCost(cost);
}

function estimateAntigravityCost({ model, usage, pricedAt }) {
  const inputTokens = nonnegativeNumber(usage.inputTokens);
  const outputTokens = nonnegativeNumber(usage.outputTokens);
  if (inputTokens === null || outputTokens === null) {
    return null;
  }
  const cachedInputTokens = nonnegativeNumber(usage.cachedInputTokens) ?? 0;
  const prices = pricingRateFor({
    backend: "antigravity",
    model,
    promptTokens: inputTokens + cachedInputTokens,
    pricedAt,
  });
  if (!prices) {
    return null;
  }

  // agy stream-json은 캐시 미스 입력과 cache_read_tokens를 별도로 보고한다.
  // output_tokens에는 thinking_tokens가 이미 포함되므로 추론 토큰을 다시
  // 더하지 않는다. 컨텍스트 캐시 보관 시간은 CLI 턴 데이터로 알 수 없어
  // 저장 요금은 이 API 환산 추정치에서 제외한다.
  const cost = (
    inputTokens * prices.input +
    cachedInputTokens * (prices.cached ?? prices.input) +
    outputTokens * prices.output
  ) / 1_000_000;
  return roundedCost(cost);
}

function estimateClaudeCost({ model, fastMode, usage, pricedAt }) {
  // Claude result.total_cost_usd는 서브에이전트·압축·내부 호출까지 같은
  // query pipeline 전체를 포함한다. 토큰으로 본체 모델만 다시 계산하면
  // 실제 업무 비용을 과소계상할 수 있으므로 공급자 합계를 우선한다.
  const reportedCost = nonnegativeNumber(usage.reportedCostUsd);
  if (reportedCost !== null) {
    // Claude Code가 계산한 전체 pipeline 금액은 별도 보정 없이 보존한다.
    return roundedCost(reportedCost);
  }
  const usesFastPricing = usage.speed === "fast" ||
    (usage.speed == null && fastMode === true);
  const prices = usesFastPricing
    ? CLAUDE_FAST_PRICES_PER_MILLION[model]
    : claudeStandardPrices(model, pricedAt);
  const inputTokens = nonnegativeNumber(usage.inputTokens);
  const outputTokens = nonnegativeNumber(usage.outputTokens);
  if (prices && inputTokens !== null && outputTokens !== null) {
    const cachedInputTokens = nonnegativeNumber(usage.cachedInputTokens) ?? 0;
    const totalCacheWriteTokens = nonnegativeNumber(
      usage.cacheWriteInputTokens,
    ) ?? 0;
    const oneHourCacheWriteTokens = nonnegativeNumber(
      usage.cacheWrite1hInputTokens,
    ) ?? 0;
    const explicitFiveMinuteCacheWriteTokens = nonnegativeNumber(
      usage.cacheWrite5mInputTokens,
    ) ?? 0;
    const fiveMinuteCacheWriteTokens = explicitFiveMinuteCacheWriteTokens +
      Math.max(
        totalCacheWriteTokens -
          explicitFiveMinuteCacheWriteTokens -
          oneHourCacheWriteTokens,
        0,
      );
    const geographyMultiplier = usage.inferenceGeo === "us" ? 1.1 : 1;
    const cost = (
      inputTokens * prices.input +
      cachedInputTokens * prices.input * 0.1 +
      fiveMinuteCacheWriteTokens * prices.input * 1.25 +
      oneHourCacheWriteTokens * prices.input * 2 +
      outputTokens * prices.output
    ) / 1_000_000 * geographyMultiplier;
    return roundedCost(cost);
  }

  return null;
}

function claudeStandardPrices(model, pricedAt) {
  if (model !== "claude-sonnet-5") {
    return CLAUDE_STANDARD_PRICES_PER_MILLION[model];
  }
  return { input: 2, output: 10 };
}

function nonnegativeNumber(value) {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
    ? value
    : null;
}

function roundedCost(value) {
  return Math.round(value * 100_000_000) / 100_000_000;
}
