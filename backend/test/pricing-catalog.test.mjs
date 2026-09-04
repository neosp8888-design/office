// 공식 가격표 파싱, 12시간 갱신 게이트, 마지막 정상값 보존을 검증한다.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  currentPricingCatalog,
  installPricingCatalog,
  mergePricingCatalog,
  parseGeminiPricingHTML,
  parseOpenAIPricingMarkdown,
  pricingRateFor,
  PricingCatalogService,
  resetPricingCatalogsForTesting,
} from "../src/pricing-catalog.mjs";

const OPENAI_FIXTURE = `
# Pricing

### Standard pricing data

| Model | Short context input | Short context cached input | Short context cache writes | Short context output | Long context input | Long context cached input | Long context cache writes | Long context output |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| gpt-new | $3.00 | $0.30 | $3.75 | $15.00 | $6.00 | $0.60 | $7.50 | $22.50 |
| gpt-old (<272K context length) | $1.00 | - | - | $5.00 | - | - | - | - |

### Fast pricing data

| Model | Short context input | Short context cached input | Short context cache writes | Short context output | Long context input | Long context cached input | Long context cache writes | Long context output |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| gpt-new | $6.00 | $0.60 | $7.50 | $30.00 | $12.00 | $1.20 | $15.00 | $45.00 |
`;

const GEMINI_FIXTURE = `
<h2 id="gemini-new-flash">Gemini New Flash</h2>
<em><code>gemini-new-flash</code></em>
<section><h3 data-text="Standard">Standard</h3><table>
<tr><th></th><th>Free Tier</th><th>Paid Tier</th></tr>
<tr><td>Input price</td><td>Free</td><td>$0.75 through December 31, 2026.<br>$1.50 starting January 1, 2027.</td></tr>
<tr><td>Output price (including thinking tokens)</td><td>Free</td><td>$3.75 through December 31, 2026.<br>$7.50 starting January 1, 2027.</td></tr>
<tr><td>Context caching price</td><td>Free</td><td>$0.075 through December 31, 2026.<br>$0.15 starting January 1, 2027.<br>$1.00 / 1,000,000 tokens per hour (storage price)</td></tr>
</table></section>
<h2 id="gemini-new-pro-preview">Gemini New Pro</h2>
<em><code>gemini-new-pro-preview</code></em>
<section><h3 data-text="Standard">Standard</h3><table>
<tr><td>Input price</td><td>Not available</td><td>$2.00, prompts <= 200k tokens<br>$4.00, prompts > 200k tokens</td></tr>
<tr><td>Output price (including thinking tokens)</td><td>Not available</td><td>$12.00, prompts <= 200k tokens<br>$18.00, prompts > 200k</td></tr>
<tr><td>Context caching price</td><td>Not available</td><td>$0.20, prompts <= 200k tokens<br>$0.40, prompts > 200k</td></tr>
</table></section>
`;

test.afterEach(() => resetPricingCatalogsForTesting());

test("OpenAI 가격표에서 Standard·Fast와 장문 단가를 수집한다", () => {
  const parsed = parseOpenAIPricingMarkdown(OPENAI_FIXTURE);
  assert.equal(parsed.models["gpt-old"].standard[0].input, 1);
  assert.deepEqual(parsed.models["gpt-new"].standard[1], {
    minPromptTokens: 272_001,
    input: 6,
    cached: 0.6,
    cacheWrite: 7.5,
    output: 22.5,
  });
  assert.equal(parsed.models["gpt-new"].fast[0].output, 30);
  installPricingCatalog("codex", parsed);
  assert.deepEqual(
    pricingRateFor({
      backend: "codex",
      model: "gpt-new",
      fastMode: true,
      promptTokens: 300_000,
    }),
    { input: 12, cached: 1.2, cacheWrite: 15, output: 45 },
  );
});

test("Gemini 가격표에서 기간·20만 토큰 경계와 preview 별칭을 수집한다", () => {
  installPricingCatalog("antigravity", parseGeminiPricingHTML(GEMINI_FIXTURE));
  assert.deepEqual(
    pricingRateFor({
      backend: "antigravity",
      model: "gemini-new-flash",
      promptTokens: 10,
      pricedAt: new Date("2026-12-31T12:00:00Z"),
    }),
    { input: 0.75, cached: 0.075, output: 3.75 },
  );
  assert.equal(
    pricingRateFor({
      backend: "antigravity",
      model: "gemini-new-flash",
      promptTokens: 10,
      pricedAt: new Date("2027-01-01T00:00:00Z"),
    }).output,
    7.5,
  );
  assert.equal(
    pricingRateFor({
      backend: "antigravity",
      model: "gemini-new-pro",
      promptTokens: 200_001,
    }).output,
    18,
  );
});

test("새 카탈로그는 사라진 구모델의 마지막 정상 단가를 보존한다", () => {
  const merged = mergePricingCatalog(
    { version: 1, models: { legacy: { standard: [{ input: 1, output: 2 }] } } },
    { version: 1, models: { current: { standard: [{ input: 3, output: 4 }] } } },
  );
  assert.equal(merged.models.legacy.standard[0].output, 2);
  assert.equal(merged.models.current.standard[0].output, 4);
});

test("자동 갱신은 재시작과 무관하게 공급자별 12시간에 한 번만 시도한다", async () => {
  let now = Date.parse("2026-09-05T00:00:00Z");
  const store = memoryStore();
  const fetches = [];
  const service = new PricingCatalogService({
    store,
    now: () => now,
    fetchImpl: async (url) => {
      fetches.push(url);
      return response(url.includes("openai") ? OPENAI_FIXTURE : GEMINI_FIXTURE);
    },
  });
  await service.loadCached();
  await service.refreshDue();
  assert.equal(fetches.length, 2);

  now += 11 * 60 * 60 * 1_000;
  await service.refreshDue();
  assert.equal(fetches.length, 2);

  now += 60 * 60 * 1_000;
  await service.refreshDue();
  assert.equal(fetches.length, 4);
});

test("공식 가격표 조회 실패는 마지막 정상 카탈로그를 덮어쓰지 않는다", async () => {
  let now = Date.parse("2026-09-05T00:00:00Z");
  const store = memoryStore();
  const warnings = [];
  const service = new PricingCatalogService({
    store,
    now: () => now,
    logger: { warn: (...values) => warnings.push(values.join(" ")) },
    fetchImpl: async (url) => response(
      url.includes("openai") ? OPENAI_FIXTURE : GEMINI_FIXTURE,
    ),
  });
  await service.loadCached();
  await service.refreshDue();
  assert.ok(currentPricingCatalog("codex").models["gpt-new"]);

  service.fetchImpl = async (url) => {
    if (url.includes("openai")) throw new Error("offline");
    return response(GEMINI_FIXTURE);
  };
  now += 12 * 60 * 60 * 1_000;
  await service.refreshDue();
  assert.ok(currentPricingCatalog("codex").models["gpt-new"]);
  assert.equal(store.rows.get("codex").lastError, "offline");
  assert.equal(warnings.length, 1);
});

test("가격 카탈로그 migration은 두 공급자와 마지막 시도를 저장한다", () => {
  const migration = readFileSync(
    new URL("../../database/migrations/035_pricing_catalog.sql", import.meta.url),
    "utf8",
  );
  assert.match(migration, /CREATE TABLE IF NOT EXISTS pricing_catalogs/);
  assert.match(migration, /'codex', 'antigravity'/);
  assert.match(migration, /last_attempted_at/);
  assert.match(migration, /catalog jsonb/);
});

function response(body) {
  return { ok: true, status: 200, text: async () => body };
}

function memoryStore(initial = []) {
  const rows = new Map(initial.map((row) => [row.provider, { ...row }]));
  return {
    rows,
    async load() {
      return [...rows.values()].map((row) => ({ ...row }));
    },
    async claimRefresh({
      provider,
      sourceURL,
      attemptedAt,
      minimumIntervalMilliseconds,
      force,
    }) {
      const previous = rows.get(provider);
      const last = previous?.lastAttemptedAt == null
        ? Number.NEGATIVE_INFINITY
        : new Date(previous.lastAttemptedAt).getTime();
      if (!force && attemptedAt.getTime() - last < minimumIntervalMilliseconds) {
        return null;
      }
      const next = {
        ...(previous ?? {}),
        provider,
        sourceURL,
        lastAttemptedAt: attemptedAt,
      };
      rows.set(provider, next);
      return { ...next };
    },
    async saveSuccess({ provider, catalog, fetchedAt }) {
      const next = {
        ...rows.get(provider),
        catalog,
        fetchedAt,
        lastError: null,
      };
      rows.set(provider, next);
      return { ...next };
    },
    async saveFailure({ provider, error }) {
      const next = { ...rows.get(provider), lastError: error };
      rows.set(provider, next);
      return { ...next };
    },
  };
}
