// 이 파일은 CLI가 보고한 토큰 사용량을 공식 API 단가 기준의 USD 추정 비용으로 환산한다.

const OPENAI_PRICES_PER_MILLION = {
  "gpt-5.6-sol": {
    standard: { input: 5, cached: 0.5, cacheWrite: 6.25, output: 30 },
    fast: { input: 10, cached: 1, cacheWrite: 12.5, output: 60 },
  },
  "gpt-5.6-terra": {
    standard: { input: 2, cached: 0.2, cacheWrite: 2.5, output: 12 },
    fast: { input: 4, cached: 0.4, cacheWrite: 5, output: 24 },
  },
  "gpt-5.6-luna": {
    standard: { input: 0.2, cached: 0.02, cacheWrite: 0.25, output: 1.2 },
    fast: { input: 0.4, cached: 0.04, cacheWrite: 0.5, output: 2.4 },
  },
};

const CLAUDE_STANDARD_PRICES_PER_MILLION = {
  "claude-opus-5": { input: 5, output: 25 },
  "claude-fable-5": { input: 10, output: 50 },
  fable: { input: 10, output: 50 },
};

const CLAUDE_FAST_PRICES_PER_MILLION = {
  "claude-opus-5": { input: 10, output: 50 },
};

const SONNET_FIVE_STANDARD_PRICE_CHANGE = Date.UTC(2026, 8, 1);
const GEMINI_FLASH_PROMOTION_END = Date.UTC(2027, 0, 1);

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

  const prices = OPENAI_PRICES_PER_MILLION[model]?.[
    fastMode === true ? "fast" : "standard"
  ];
  const inputTokens = nonnegativeNumber(usage.inputTokens);
  const outputTokens = nonnegativeNumber(usage.outputTokens);
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
    cachedInputTokens * prices.cached +
    cacheWriteInputTokens * prices.cacheWrite +
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
  const prices = antigravityPrices(
    model,
    inputTokens + cachedInputTokens,
    pricedAt,
  );
  if (!prices) {
    return null;
  }

  // agy stream-json은 캐시 미스 입력과 cache_read_tokens를 별도로 보고한다.
  // output_tokens에는 thinking_tokens가 이미 포함되므로 추론 토큰을 다시
  // 더하지 않는다. 컨텍스트 캐시 보관 시간은 CLI 턴 데이터로 알 수 없어
  // 저장 요금은 이 API 환산 추정치에서 제외한다.
  const cost = (
    inputTokens * prices.input +
    cachedInputTokens * prices.cached +
    outputTokens * prices.output
  ) / 1_000_000;
  return roundedCost(cost);
}

function antigravityPrices(model, promptTokens, pricedAt) {
  const timestamp = priceTimestamp(pricedAt);
  switch (model) {
    case "gemini-3.7-flash":
    case "gemini-3.6-flash":
      return timestamp < GEMINI_FLASH_PROMOTION_END
        ? { input: 0.75, cached: 0.075, output: 3.75 }
        : { input: 1.5, cached: 0.15, output: 7.5 };
    case "gemini-3.5-flash":
      return { input: 1.5, cached: 0.15, output: 9 };
    case "gemini-3.1-pro":
    case "gemini-3.1-pro-preview":
      return promptTokens > 200_000
        ? { input: 4, cached: 0.4, output: 18 }
        : { input: 2, cached: 0.2, output: 12 };
    default:
      return null;
  }
}

function estimateClaudeCost({ model, fastMode, usage, pricedAt }) {
  // Claude result.total_cost_usd는 서브에이전트·압축·내부 호출까지 같은
  // query pipeline 전체를 포함한다. 토큰으로 본체 모델만 다시 계산하면
  // 실제 업무 비용을 과소계상할 수 있으므로 공급자 합계를 우선한다.
  // 다만 CLI 합계는 표준 정가로 계산되어 기간 한정 Sonnet 5 가격을
  // 반영하지 않으므로, modelUsage에서 확인된 Sonnet 5 몫만 보정한다.
  const reportedCost = nonnegativeNumber(usage.reportedCostUsd);
  if (reportedCost !== null) {
    const timestamp = priceTimestamp(pricedAt);
    const reportedSonnet5Cost = nonnegativeNumber(
      usage.reportedSonnet5CostUsd,
    );
    if (
      timestamp < SONNET_FIVE_STANDARD_PRICE_CHANGE &&
      reportedSonnet5Cost !== null
    ) {
      return roundedCost(
        reportedCost - reportedSonnet5Cost / 3,
      );
    }
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
  const timestamp = priceTimestamp(pricedAt);
  return timestamp >= SONNET_FIVE_STANDARD_PRICE_CHANGE
    ? { input: 3, output: 15 }
    : { input: 2, output: 10 };
}

function priceTimestamp(pricedAt) {
  const timestamp = pricedAt instanceof Date
    ? pricedAt.getTime()
    : Number(pricedAt);
  return Number.isFinite(timestamp) ? timestamp : Date.now();
}

function nonnegativeNumber(value) {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
    ? value
    : null;
}

function roundedCost(value) {
  return Math.round(value * 100_000_000) / 100_000_000;
}
