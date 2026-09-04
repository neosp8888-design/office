// 이 파일은 공식 가격표를 읽어 Codex와 Antigravity의 토큰 비용 계산에 제공한다.

export const PRICING_CATALOG_REFRESH_MILLISECONDS = 12 * 60 * 60 * 1_000;

export const PRICING_CATALOG_SOURCES = Object.freeze({
  codex: Object.freeze({
    url: "https://developers.openai.com/api/docs/pricing.md",
    parse: parseOpenAIPricingMarkdown,
  }),
  antigravity: Object.freeze({
    url: "https://ai.google.dev/gemini-api/docs/pricing?hl=en",
    parse: parseGeminiPricingHTML,
  }),
});

const MAX_SOURCE_BYTES = 6 * 1_024 * 1_024;
const DEFAULT_REQUEST_TIMEOUT_MILLISECONDS = 15_000;
const LONG_CONTEXT_THRESHOLD = 272_000;

const BUILTIN_PRICING_CATALOGS = Object.freeze({
  codex: catalog({
    "gpt-6-astra": openAIModel(
      [10, 1, 12.5, 50, 20, 2, 25, 75],
      [20, 2, 25, 100, 40, 4, 50, 150],
    ),
    "gpt-5.6-sol": openAIModel(
      [4, 0.4, 5, 20, 8, 0.8, 10, 30],
      [8, 0.8, 10, 40, 16, 1.6, 20, 60],
    ),
    "gpt-5.6": openAIModel(
      [4, 0.4, 5, 20, 8, 0.8, 10, 30],
      [8, 0.8, 10, 40, 16, 1.6, 20, 60],
    ),
    "gpt-5.6-terra": openAIModel(
      [2, 0.2, 2.5, 12, 4, 0.4, 5, 18],
      [4, 0.4, 5, 24, 8, 0.8, 10, 36],
    ),
    "gpt-5.6-luna": openAIModel(
      [0.2, 0.02, 0.25, 1.2, 0.4, 0.04, 0.5, 1.8],
      [0.4, 0.04, 0.5, 2.4, 0.8, 0.08, 1, 3.6],
    ),
  }),
  antigravity: catalog({
    "gemini-3.8-flash": geminiFlashRules(),
    "gemini-3.7-flash": geminiFlashRules(),
    "gemini-3.6-flash": geminiFlashRules(),
    "gemini-3.5-flash": {
      standard: [{ input: 1.5, cached: 0.15, output: 9 }],
    },
    "gemini-3.1-pro": geminiProRules(),
    "gemini-3.1-pro-preview": geminiProRules(),
  }),
});

let runtimeCatalogs = clone(BUILTIN_PRICING_CATALOGS);

function catalog(models) {
  return { version: 1, models };
}

function openAIModel(standard, fast) {
  return {
    standard: contextRules(standard),
    fast: contextRules(fast),
  };
}

function contextRules(values) {
  const [input, cached, cacheWrite, output, longInput, longCached,
    longCacheWrite, longOutput] = values;
  return [
    {
      maxPromptTokens: LONG_CONTEXT_THRESHOLD,
      input,
      cached,
      cacheWrite,
      output,
    },
    {
      minPromptTokens: LONG_CONTEXT_THRESHOLD + 1,
      input: longInput,
      cached: longCached,
      cacheWrite: longCacheWrite,
      output: longOutput,
    },
  ];
}

function geminiFlashRules() {
  return {
    standard: [
      {
        effectiveUntil: "2027-01-01T00:00:00.000Z",
        input: 0.75,
        cached: 0.075,
        output: 3.75,
      },
      {
        effectiveFrom: "2027-01-01T00:00:00.000Z",
        input: 1.5,
        cached: 0.15,
        output: 7.5,
      },
    ],
  };
}

function geminiProRules() {
  return {
    standard: [
      {
        maxPromptTokens: 200_000,
        input: 2,
        cached: 0.2,
        output: 12,
      },
      {
        minPromptTokens: 200_001,
        input: 4,
        cached: 0.4,
        output: 18,
      },
    ],
  };
}

export function parseOpenAIPricingMarkdown(source) {
  const models = {};
  for (const [heading, mode] of [
    ["### Standard pricing data", "standard"],
    ["### Fast pricing data", "fast"],
  ]) {
    const section = markdownSection(source, heading);
    for (const line of section.split("\n")) {
      if (!line.trim().startsWith("|")) continue;
      const cells = markdownCells(line);
      if (cells.length < 9 || cells[0] === "Model" || /^-+$/.test(cells[0])) {
        continue;
      }
      const model = normalizeOpenAIModelID(cells[0]);
      if (!validModelID(model)) continue;
      const short = rateFromCells(cells.slice(1, 5));
      const long = rateFromCells(cells.slice(5, 9));
      if (!short) continue;
      const rules = [];
      if (long) {
        rules.push({ maxPromptTokens: LONG_CONTEXT_THRESHOLD, ...short });
        rules.push({ minPromptTokens: LONG_CONTEXT_THRESHOLD + 1, ...long });
      } else {
        rules.push(short);
      }
      models[model] = {
        ...(models[model] ?? {}),
        [mode]: rules,
      };
    }
  }
  if (Object.keys(models).length === 0) {
    throw new Error("OpenAI 가격표에서 모델 단가를 찾지 못했습니다.");
  }
  if (models["gpt-5.6-sol"] && !models["gpt-5.6"]) {
    models["gpt-5.6"] = clone(models["gpt-5.6-sol"]);
  }
  return catalog(models);
}

function markdownSection(source, heading) {
  const text = String(source ?? "");
  const start = text.indexOf(heading);
  if (start < 0) return "";
  const bodyStart = start + heading.length;
  const next = text.slice(bodyStart).search(/^###\s+/m);
  return next < 0
    ? text.slice(bodyStart)
    : text.slice(bodyStart, bodyStart + next);
}

function markdownCells(line) {
  return line.trim().replace(/^\|/, "").replace(/\|$/, "")
    .split("|").map((cell) => cell.trim());
}

function normalizeOpenAIModelID(value) {
  return String(value ?? "")
    .replace(/[`*_]/g, "")
    .replace(/\s*\(<[^)]*\)\s*$/, "")
    .trim()
    .toLowerCase();
}

function rateFromCells(cells) {
  const [input, cached, cacheWrite, output] = cells.map(markdownPrice);
  if (input === null || output === null) return null;
  return compactRate({ input, cached, cacheWrite, output });
}

function markdownPrice(value) {
  const text = String(value ?? "").replace(/[,`*]/g, "").trim();
  if (!text || text === "-") return null;
  const match = text.match(/^\$?([0-9]+(?:\.[0-9]+)?)/);
  return match ? safePrice(match[1]) : null;
}

export function parseGeminiPricingHTML(source) {
  const html = String(source ?? "");
  const models = {};
  const headings = [...html.matchAll(/<h2\b[^>]*id="([^"]+)"[^>]*>/gi)];
  for (let index = 0; index < headings.length; index += 1) {
    const heading = headings[index];
    const sectionID = String(heading[1] ?? "").toLowerCase();
    if (!sectionID.startsWith("gemini-")) continue;
    const section = html.slice(
      heading.index,
      headings[index + 1]?.index ?? html.length,
    );
    const standardHeading = section.search(
      /<h3\b[^>]*(?:data-text="Standard"|>\s*Standard\s*<)/i,
    );
    if (standardHeading < 0) continue;
    const header = section.slice(0, standardHeading);
    const table = section.slice(standardHeading).match(
      /<table\b[^>]*>([\s\S]*?)<\/table>/i,
    )?.[1];
    if (!table) continue;
    const priceCells = geminiStandardPriceCells(table);
    const rules = combineGeminiPriceRules(priceCells);
    if (rules.length === 0) continue;
    const identifiers = new Set(
      [...header.matchAll(/<code\b[^>]*>(gemini-[^<]+)<\/code>/gi)]
        .map((match) => htmlText(match[1]).toLowerCase())
        .filter(validModelID),
    );
    if (identifiers.size === 0 && validModelID(sectionID)) {
      identifiers.add(sectionID);
    }
    for (const identifier of identifiers) {
      models[identifier] = { standard: clone(rules) };
      if (identifier.endsWith("-preview")) {
        models[identifier.slice(0, -"-preview".length)] ??= {
          standard: clone(rules),
        };
      }
    }
  }
  if (Object.keys(models).length === 0) {
    throw new Error("Gemini 가격표에서 모델 단가를 찾지 못했습니다.");
  }
  return catalog(models);
}

function geminiStandardPriceCells(table) {
  const result = {};
  for (const row of table.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)) {
    const cells = [...row[1].matchAll(/<td\b[^>]*>([\s\S]*?)<\/td>/gi)]
      .map((match) => match[1]);
    if (cells.length < 2) continue;
    const label = htmlText(cells[0]).toLowerCase();
    const paid = cells.at(-1);
    if (label === "input price") result.input = paid;
    if (label.startsWith("output price")) result.output = paid;
    if (label === "context caching price") result.cached = paid;
  }
  return result;
}

function combineGeminiPriceRules(cells) {
  const combined = new Map();
  for (const field of ["input", "output", "cached"]) {
    for (const rule of geminiDimensionRules(cells[field])) {
      const constraints = {
        ...(rule.minPromptTokens == null
          ? {}
          : { minPromptTokens: rule.minPromptTokens }),
        ...(rule.maxPromptTokens == null
          ? {}
          : { maxPromptTokens: rule.maxPromptTokens }),
        ...(rule.effectiveFrom == null
          ? {}
          : { effectiveFrom: rule.effectiveFrom }),
        ...(rule.effectiveUntil == null
          ? {}
          : { effectiveUntil: rule.effectiveUntil }),
      };
      const key = JSON.stringify(constraints);
      const current = combined.get(key) ?? constraints;
      current[field] ??= rule.price;
      combined.set(key, current);
    }
  }
  return [...combined.values()]
    .filter((rule) => finitePrice(rule.input) && finitePrice(rule.output))
    .map(compactRate);
}

function geminiDimensionRules(value) {
  if (!value) return [];
  const rules = [];
  for (const fragment of String(value).split(/<br\s*\/?\s*>/i)) {
    const text = htmlText(fragment);
    if (!text || /storage price/i.test(text)) continue;
    const price = text.match(/\$\s*([0-9]+(?:[.,][0-9]+)?)/);
    if (!price) continue;
    const rule = { price: safePrice(price[1].replace(",", ".")) };
    if (rule.price === null) continue;
    const less = text.match(/(?:<=|≤)\s*([0-9.]+)\s*([km]?)/i);
    const greater = text.match(/>\s*([0-9.]+)\s*([km]?)/i);
    if (less) rule.maxPromptTokens = scaledTokenCount(less[1], less[2]);
    if (greater) {
      const boundary = scaledTokenCount(greater[1], greater[2]);
      if (boundary !== null) rule.minPromptTokens = boundary + 1;
    }
    const through = text.match(
      /through\s+([A-Za-z]+\s+\d{1,2},\s+\d{4})/i,
    );
    const starting = text.match(
      /starting\s+([A-Za-z]+\s+\d{1,2},\s+\d{4})/i,
    );
    if (through) rule.effectiveUntil = dayAfterUTC(through[1]);
    if (starting) rule.effectiveFrom = dateAtUTC(starting[1]);
    rules.push(rule);
  }
  return rules;
}

function htmlText(value) {
  return String(value ?? "")
    .replace(/<[^>]*>/g, " ")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")
    .replace(/&nbsp;|&#160;/g, " ")
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/\s+/g, " ")
    .trim();
}

function scaledTokenCount(value, suffix) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) return null;
  const multiplier = String(suffix ?? "").toLowerCase() === "m"
    ? 1_000_000
    : String(suffix ?? "").toLowerCase() === "k"
      ? 1_000
      : 1;
  return Math.round(number * multiplier);
}

function dateAtUTC(value) {
  const timestamp = Date.parse(`${value} 00:00:00 UTC`);
  return Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : null;
}

function dayAfterUTC(value) {
  const timestamp = Date.parse(`${value} 00:00:00 UTC`);
  return Number.isFinite(timestamp)
    ? new Date(timestamp + 24 * 60 * 60 * 1_000).toISOString()
    : null;
}

export function mergePricingCatalog(base, update) {
  const left = normalizedCatalog(base);
  const right = normalizedCatalog(update);
  const models = clone(left.models);
  for (const [model, modes] of Object.entries(right.models)) {
    models[model] = {
      ...(models[model] ?? {}),
      ...clone(modes),
    };
  }
  return catalog(models);
}

export function installPricingCatalog(provider, value) {
  if (!PRICING_CATALOG_SOURCES[provider]) {
    throw new TypeError(`지원하지 않는 가격 제공자입니다: ${provider}`);
  }
  const merged = mergePricingCatalog(runtimeCatalogs[provider], value);
  runtimeCatalogs = { ...runtimeCatalogs, [provider]: merged };
  return clone(merged);
}

export function resetPricingCatalogsForTesting() {
  runtimeCatalogs = clone(BUILTIN_PRICING_CATALOGS);
}

export function currentPricingCatalog(provider) {
  return clone(runtimeCatalogs[provider] ?? catalog({}));
}

export function pricingRateFor({
  backend,
  model,
  fastMode = false,
  promptTokens = 0,
  pricedAt = new Date(),
}) {
  const provider = backend === "codex"
    ? "codex"
    : backend === "antigravity"
      ? "antigravity"
      : null;
  if (!provider) return null;
  const modes = runtimeCatalogs[provider]?.models?.[String(model ?? "")];
  const mode = provider === "codex" && fastMode ? "fast" : "standard";
  const rules = modes?.[mode];
  if (!Array.isArray(rules)) return null;
  const timestamp = priceTimestamp(pricedAt);
  const tokens = Number.isFinite(Number(promptTokens))
    ? Math.max(0, Number(promptTokens))
    : 0;
  const selected = rules.find((rule) => ruleMatches(rule, tokens, timestamp));
  return selected
    ? compactRate({
        input: selected.input,
        cached: selected.cached,
        cacheWrite: selected.cacheWrite,
        output: selected.output,
      })
    : null;
}

function ruleMatches(rule, promptTokens, timestamp) {
  if (rule.minPromptTokens != null && promptTokens < rule.minPromptTokens) {
    return false;
  }
  if (rule.maxPromptTokens != null && promptTokens > rule.maxPromptTokens) {
    return false;
  }
  const from = rule.effectiveFrom == null
    ? null
    : Date.parse(rule.effectiveFrom);
  const until = rule.effectiveUntil == null
    ? null
    : Date.parse(rule.effectiveUntil);
  return !(
    (Number.isFinite(from) && timestamp < from) ||
    (Number.isFinite(until) && timestamp >= until)
  );
}

function normalizedCatalog(value) {
  const models = {};
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return catalog(models);
  }
  const sourceModels = value.models;
  if (!sourceModels || typeof sourceModels !== "object" || Array.isArray(sourceModels)) {
    return catalog(models);
  }
  for (const [model, modes] of Object.entries(sourceModels)) {
    if (!validModelID(model) || !modes || typeof modes !== "object") continue;
    const normalizedModes = {};
    for (const mode of ["standard", "fast"]) {
      const rules = Array.isArray(modes[mode])
        ? modes[mode].map(normalizedRule).filter(Boolean)
        : [];
      if (rules.length > 0) normalizedModes[mode] = rules;
    }
    if (Object.keys(normalizedModes).length > 0) models[model] = normalizedModes;
  }
  return catalog(models);
}

function normalizedRule(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const input = safePrice(value.input);
  const output = safePrice(value.output);
  if (input === null || output === null) return null;
  const rule = compactRate({
    input,
    output,
    cached: safePrice(value.cached),
    cacheWrite: safePrice(value.cacheWrite),
  });
  for (const field of ["minPromptTokens", "maxPromptTokens"]) {
    const number = Number(value[field]);
    if (Number.isFinite(number) && number >= 0) rule[field] = Math.round(number);
  }
  for (const field of ["effectiveFrom", "effectiveUntil"]) {
    const timestamp = Date.parse(value[field]);
    if (Number.isFinite(timestamp)) rule[field] = new Date(timestamp).toISOString();
  }
  return rule;
}

function compactRate(value) {
  const result = {};
  for (const field of [
    "minPromptTokens",
    "maxPromptTokens",
    "effectiveFrom",
    "effectiveUntil",
    "input",
    "cached",
    "cacheWrite",
    "output",
  ]) {
    if (value[field] !== null && value[field] !== undefined) {
      result[field] = value[field];
    }
  }
  return result;
}

function safePrice(value) {
  if (value === null || value === undefined || value === "") return null;
  const number = Number(value);
  return finitePrice(number) ? number : null;
}

function finitePrice(value) {
  return Number.isFinite(value) && value >= 0 && value <= 10_000;
}

function validModelID(value) {
  return /^[a-z0-9][a-z0-9._:-]{1,119}$/.test(String(value ?? ""));
}

function priceTimestamp(value) {
  const timestamp = value instanceof Date
    ? value.getTime()
    : typeof value === "string"
      ? Date.parse(value)
      : Number(value);
  return Number.isFinite(timestamp) ? timestamp : Date.now();
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

export function createPostgresPricingCatalogStore(pool) {
  if (!pool || typeof pool.query !== "function") {
    throw new TypeError("가격 카탈로그 저장소에는 PostgreSQL pool이 필요합니다.");
  }
  return {
    async load() {
      const { rows } = await pool.query(`
        SELECT
          provider,
          source_url AS "sourceURL",
          catalog,
          fetched_at AS "fetchedAt",
          last_attempted_at AS "lastAttemptedAt",
          last_error AS "lastError"
        FROM pricing_catalogs
      `);
      return rows;
    },

    async claimRefresh({
      provider,
      sourceURL,
      attemptedAt,
      minimumIntervalMilliseconds,
      force = false,
    }) {
      const { rows } = await pool.query(
        `
          INSERT INTO pricing_catalogs (
            provider,
            source_url,
            last_attempted_at,
            updated_at
          )
          VALUES ($1, $2, $3, now())
          ON CONFLICT (provider) DO UPDATE
          SET
            source_url = EXCLUDED.source_url,
            last_attempted_at = EXCLUDED.last_attempted_at,
            updated_at = now()
          WHERE $5::boolean
            OR pricing_catalogs.last_attempted_at IS NULL
            OR pricing_catalogs.last_attempted_at <=
              $3::timestamptz - ($4::double precision * interval '1 millisecond')
          RETURNING
            provider,
            source_url AS "sourceURL",
            catalog,
            fetched_at AS "fetchedAt",
            last_attempted_at AS "lastAttemptedAt",
            last_error AS "lastError"
        `,
        [
          provider,
          sourceURL,
          attemptedAt,
          minimumIntervalMilliseconds,
          force,
        ],
      );
      return rows[0] ?? null;
    },

    async saveSuccess({ provider, catalog: value, fetchedAt }) {
      const { rows } = await pool.query(
        `
          UPDATE pricing_catalogs
          SET
            catalog = $2::jsonb,
            fetched_at = $3,
            last_error = NULL,
            updated_at = now()
          WHERE provider = $1
          RETURNING
            provider,
            source_url AS "sourceURL",
            catalog,
            fetched_at AS "fetchedAt",
            last_attempted_at AS "lastAttemptedAt",
            last_error AS "lastError"
        `,
        [provider, JSON.stringify(value), fetchedAt],
      );
      return rows[0] ?? null;
    },

    async saveFailure({ provider, error }) {
      const { rows } = await pool.query(
        `
          UPDATE pricing_catalogs
          SET
            last_error = $2,
            updated_at = now()
          WHERE provider = $1
          RETURNING
            provider,
            source_url AS "sourceURL",
            catalog,
            fetched_at AS "fetchedAt",
            last_attempted_at AS "lastAttemptedAt",
            last_error AS "lastError"
        `,
        [provider, String(error).slice(0, 1_000)],
      );
      return rows[0] ?? null;
    },
  };
}

export class PricingCatalogService {
  constructor({
    store,
    fetchImpl = globalThis.fetch,
    now = () => Date.now(),
    logger = console,
    refreshIntervalMilliseconds = PRICING_CATALOG_REFRESH_MILLISECONDS,
    requestTimeoutMilliseconds = DEFAULT_REQUEST_TIMEOUT_MILLISECONDS,
    setTimer = setTimeout,
    clearTimer = clearTimeout,
  }) {
    if (!store) throw new TypeError("가격 카탈로그 저장소가 필요합니다.");
    if (typeof fetchImpl !== "function") {
      throw new TypeError("가격 카탈로그를 조회할 fetch 구현이 필요합니다.");
    }
    this.store = store;
    this.fetchImpl = fetchImpl;
    this.now = now;
    this.logger = logger;
    this.refreshIntervalMilliseconds = refreshIntervalMilliseconds;
    this.requestTimeoutMilliseconds = requestTimeoutMilliseconds;
    this.setTimer = setTimer;
    this.clearTimer = clearTimer;
    this.rows = new Map();
    this.timer = null;
    this.running = false;
    this.stopped = true;
  }

  async loadCached() {
    const rows = await this.store.load();
    for (const row of rows) {
      if (!PRICING_CATALOG_SOURCES[row.provider]) continue;
      this.rows.set(row.provider, row);
      if (row.catalog) installPricingCatalog(row.provider, row.catalog);
    }
    return this.status();
  }

  start() {
    if (!this.stopped) return;
    this.stopped = false;
    void this.runCycle();
  }

  stop() {
    this.stopped = true;
    if (this.timer) this.clearTimer(this.timer);
    this.timer = null;
  }

  async refreshDue({ force = false } = {}) {
    return await Promise.all(
      Object.keys(PRICING_CATALOG_SOURCES).map(
        (provider) => this.refreshProvider(provider, { force }),
      ),
    );
  }

  async refreshProvider(provider, { force = false } = {}) {
    const source = PRICING_CATALOG_SOURCES[provider];
    if (!source) throw new TypeError(`지원하지 않는 가격 제공자입니다: ${provider}`);
    const attemptedAt = new Date(this.now());
    const claimed = await this.store.claimRefresh({
      provider,
      sourceURL: source.url,
      attemptedAt,
      minimumIntervalMilliseconds: this.refreshIntervalMilliseconds,
      force,
    });
    if (!claimed) return { provider, status: "fresh" };
    this.rows.set(provider, claimed);
    try {
      const body = await this.fetchSource(source.url);
      const parsed = source.parse(body);
      const merged = mergePricingCatalog(
        this.rows.get(provider)?.catalog ?? currentPricingCatalog(provider),
        parsed,
      );
      const fetchedAt = new Date(this.now());
      const saved = await this.store.saveSuccess({
        provider,
        catalog: merged,
        fetchedAt,
      });
      this.rows.set(provider, saved ?? {
        ...claimed,
        catalog: merged,
        fetchedAt,
        lastError: null,
      });
      installPricingCatalog(provider, merged);
      return {
        provider,
        status: "updated",
        modelCount: Object.keys(merged.models).length,
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const saved = await this.store.saveFailure({ provider, error: message });
      this.rows.set(provider, saved ?? {
        ...claimed,
        lastError: message,
      });
      this.logger.warn?.(
        `${provider} 공식 가격표를 갱신하지 못해 마지막 정상값을 유지합니다.`,
        message,
      );
      return { provider, status: "failed", error: message };
    }
  }

  status() {
    return Object.keys(PRICING_CATALOG_SOURCES).map((provider) => {
      const row = this.rows.get(provider);
      return {
        provider,
        sourceURL: PRICING_CATALOG_SOURCES[provider].url,
        fetchedAt: row?.fetchedAt ?? null,
        lastAttemptedAt: row?.lastAttemptedAt ?? null,
        lastError: row?.lastError ?? null,
        modelCount: Object.keys(currentPricingCatalog(provider).models).length,
      };
    });
  }

  async runCycle() {
    if (this.running || this.stopped) return;
    this.running = true;
    try {
      await this.refreshDue();
    } catch (error) {
      this.logger.warn?.(
        "공식 가격표 갱신 주기를 완료하지 못했습니다.",
        error instanceof Error ? error.message : String(error),
      );
    } finally {
      this.running = false;
      this.scheduleNextCycle();
    }
  }

  scheduleNextCycle() {
    if (this.stopped) return;
    if (this.timer) this.clearTimer(this.timer);
    const now = this.now();
    const next = Object.keys(PRICING_CATALOG_SOURCES).map((provider) => {
      const attempted = Date.parse(this.rows.get(provider)?.lastAttemptedAt);
      return Number.isFinite(attempted)
        ? attempted + this.refreshIntervalMilliseconds
        : now;
    });
    const delay = Math.max(1_000, Math.min(...next) - now);
    this.timer = this.setTimer(() => {
      this.timer = null;
      void this.runCycle();
    }, delay);
    this.timer?.unref?.();
  }

  async fetchSource(url) {
    const controller = new AbortController();
    const timeout = setTimeout(
      () => controller.abort(),
      this.requestTimeoutMilliseconds,
    );
    timeout.unref?.();
    try {
      const response = await this.fetchImpl(url, {
        headers: {
          accept: "text/html,text/markdown;q=0.9,text/plain;q=0.8",
          "user-agent": "OFFICESTRA pricing catalog",
        },
        signal: controller.signal,
      });
      if (!response?.ok) {
        throw new Error(`가격표 HTTP ${response?.status ?? "응답 없음"}`);
      }
      const body = await response.text();
      if (Buffer.byteLength(body, "utf8") > MAX_SOURCE_BYTES) {
        throw new Error("가격표 응답이 허용 크기를 넘었습니다.");
      }
      return body;
    } finally {
      clearTimeout(timeout);
    }
  }
}
