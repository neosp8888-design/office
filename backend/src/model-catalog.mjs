// 설치된 Codex·Antigravity CLI의 모델 목록과 모델별 실행 옵션을 수집한다.

import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export const MODEL_CATALOG_REFRESH_MILLISECONDS = 12 * 60 * 60 * 1000;
export const MODEL_CATALOG_PROVIDERS = Object.freeze([
  "codex",
  "antigravity",
]);

const COMMAND_TIMEOUT_MILLISECONDS = 30_000;
const MAX_COMMAND_OUTPUT_BYTES = 2 * 1024 * 1024;
const EFFORT_ORDER = Object.freeze([
  "none",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
  "ultra",
]);

const BUILTIN_CATALOGS = Object.freeze({
  codex: catalog([
    model({
      id: "gpt-5.6-sol",
      title: "GPT-5.6-Sol",
      efforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
      defaultEffort: "high",
      supportsFastMode: true,
    }),
    model({
      id: "gpt-5.6-terra",
      title: "GPT-5.6-Terra",
      efforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
      defaultEffort: "high",
      supportsFastMode: true,
    }),
    model({
      id: "gpt-5.6-luna",
      title: "GPT-5.6-Luna",
      efforts: ["low", "medium", "high", "xhigh", "max"],
      defaultEffort: "medium",
      supportsFastMode: true,
    }),
  ]),
  antigravity: catalog([
    model({
      id: "gemini-3.8-flash",
      title: "Gemini 3.8 Flash",
      efforts: ["low", "medium", "high"],
      defaultEffort: "high",
    }),
    model({
      id: "gemini-3.1-pro",
      title: "Gemini 3.1 Pro",
      efforts: ["low", "high"],
      defaultEffort: "high",
    }),
  ]),
});

const SOURCES = Object.freeze({
  codex: Object.freeze({
    arguments: Object.freeze(["debug", "models"]),
    parse: parseCodexModelCatalog,
  }),
  antigravity: Object.freeze({
    arguments: Object.freeze(["models"]),
    parse: parseAntigravityModelCatalog,
  }),
});

export class ModelCatalogValidationError extends Error {}

export function builtinModelCatalog(provider) {
  const value = BUILTIN_CATALOGS[provider];
  if (!value) {
    throw new TypeError(`지원하지 않는 모델 제공자입니다: ${provider}`);
  }
  return clone(value);
}

export function parseCodexModelCatalog(source) {
  let payload;
  try {
    payload = JSON.parse(String(source ?? ""));
  } catch {
    throw new Error("Codex 모델 카탈로그 JSON을 읽지 못했습니다.");
  }
  if (!Array.isArray(payload?.models)) {
    throw new Error("Codex 모델 카탈로그에 models 배열이 없습니다.");
  }

  const models = payload.models
    .filter((entry) => entry?.visibility === "list")
    .map((entry) => {
      const efforts = uniqueEfforts(
        entry.supported_reasoning_levels?.map((level) => level?.effort),
      );
      return model({
        id: entry.slug,
        title: entry.display_name,
        efforts,
        defaultEffort: efforts.includes(entry.default_reasoning_level)
          ? entry.default_reasoning_level
          : preferredEffort(efforts),
        supportsFastMode: entry.additional_speed_tiers?.includes("fast") === true,
        contextWindow: safePositiveInteger(entry.context_window),
        maxContextWindow: safePositiveInteger(entry.max_context_window),
      });
    })
    .filter(Boolean);
  if (models.length === 0) {
    throw new Error("Codex에서 선택 가능한 모델을 찾지 못했습니다.");
  }
  return catalog(models);
}

export function parseAntigravityModelCatalog(source) {
  const rows = String(source ?? "")
    .split(/\r?\n/)
    .map((line) => {
      const [id, ...titleParts] = line.trim().split("\t");
      const title = titleParts.join(" ").trim();
      if (!validModelID(id) || !title) return null;
      const variant = antigravityEffortVariant(id, title);
      return { id, title, variant };
    })
    .filter(Boolean);
  if (rows.length === 0) {
    throw new Error("Antigravity에서 선택 가능한 모델을 찾지 못했습니다.");
  }

  const variantCounts = new Map();
  for (const row of rows) {
    if (!row.variant) continue;
    variantCounts.set(
      row.variant.baseID,
      (variantCounts.get(row.variant.baseID) ?? 0) + 1,
    );
  }

  const collected = new Map();
  for (const row of rows) {
    const shouldGroup = row.variant && (
      row.variant.baseID.startsWith("gemini-") ||
      (variantCounts.get(row.variant.baseID) ?? 0) > 1
    );
    const id = shouldGroup ? row.variant.baseID : row.id;
    const effort = row.variant?.effort ?? "high";
    const current = collected.get(id);
    if (current) {
      current.efforts = uniqueEfforts([...current.efforts, effort]);
      current.defaultEffort = preferredEffort(current.efforts);
      continue;
    }
    collected.set(id, model({
      id,
      title: shouldGroup ? row.variant.baseTitle : row.title,
      efforts: [effort],
      defaultEffort: effort,
      supportsFastMode: false,
    }));
  }

  const models = [...collected.values()].filter(Boolean);
  if (models.length === 0) {
    throw new Error("Antigravity 모델 목록 형식이 올바르지 않습니다.");
  }
  return catalog(models);
}

export function mergeModelCatalog(previous, discovered) {
  const oldCatalog = normalizeCatalog(previous);
  const newCatalog = normalizeCatalog(discovered);
  if (newCatalog.models.length === 0) {
    throw new Error("새 모델 카탈로그가 비어 있습니다.");
  }
  const discoveredIDs = new Set(newCatalog.models.map((entry) => entry.id));
  const unavailable = oldCatalog.models
    .filter((entry) => !discoveredIDs.has(entry.id))
    .map((entry) => ({ ...entry, available: false }));
  return catalog([
    ...newCatalog.models.map((entry) => ({ ...entry, available: true })),
    ...unavailable,
  ]);
}

export function createPostgresModelCatalogStore(pool) {
  if (!pool || typeof pool.query !== "function") {
    throw new TypeError("모델 카탈로그 저장소에는 PostgreSQL pool이 필요합니다.");
  }
  const selection = `
    provider,
    catalog,
    excluded_models AS "excludedModels",
    fetched_at AS "fetchedAt",
    last_attempted_at AS "lastAttemptedAt",
    last_error AS "lastError"
  `;
  return {
    async load() {
      const { rows } = await pool.query(`
        SELECT ${selection}
        FROM agent_model_catalogs
      `);
      return rows;
    },

    async claimRefresh({
      provider,
      attemptedAt,
      minimumIntervalMilliseconds,
      force = false,
    }) {
      const { rows } = await pool.query(
        `
          INSERT INTO agent_model_catalogs (
            provider,
            last_attempted_at,
            updated_at
          )
          VALUES ($1, $2, now())
          ON CONFLICT (provider) DO UPDATE
          SET
            last_attempted_at = EXCLUDED.last_attempted_at,
            updated_at = now()
          WHERE $4::boolean
            OR agent_model_catalogs.last_attempted_at IS NULL
            OR agent_model_catalogs.last_attempted_at <=
              $2::timestamptz - ($3::double precision * interval '1 millisecond')
          RETURNING ${selection}
        `,
        [provider, attemptedAt, minimumIntervalMilliseconds, force],
      );
      return rows[0] ?? null;
    },

    async saveSuccess({ provider, catalog: value, fetchedAt }) {
      const { rows } = await pool.query(
        `
          UPDATE agent_model_catalogs
          SET
            catalog = $2::jsonb,
            fetched_at = $3,
            last_error = NULL,
            updated_at = now()
          WHERE provider = $1
          RETURNING ${selection}
        `,
        [provider, JSON.stringify(value), fetchedAt],
      );
      return rows[0] ?? null;
    },

    async saveFailure({ provider, error }) {
      const { rows } = await pool.query(
        `
          UPDATE agent_model_catalogs
          SET
            last_error = $2,
            updated_at = now()
          WHERE provider = $1
          RETURNING ${selection}
        `,
        [provider, String(error).slice(0, 1_000)],
      );
      return rows[0] ?? null;
    },

    async saveExclusions({ provider, excludedModels, fallbackCatalog }) {
      const { rows } = await pool.query(
        `
          INSERT INTO agent_model_catalogs (
            provider,
            catalog,
            excluded_models,
            updated_at
          )
          VALUES ($1, $2::jsonb, $3::text[], now())
          ON CONFLICT (provider) DO UPDATE
          SET
            excluded_models = EXCLUDED.excluded_models,
            updated_at = now()
          RETURNING ${selection}
        `,
        [provider, JSON.stringify(fallbackCatalog), excludedModels],
      );
      return rows[0] ?? null;
    },
  };
}

export class ModelCatalogService {
  constructor({
    store,
    resolveExecutable = (provider) => provider === "codex" ? "codex" : "agy",
    runCommand = execFileAsync,
    now = () => Date.now(),
    logger = console,
    onChanged = () => {},
    refreshIntervalMilliseconds = MODEL_CATALOG_REFRESH_MILLISECONDS,
    setTimer = setTimeout,
    clearTimer = clearTimeout,
  }) {
    if (!store) throw new TypeError("모델 카탈로그 저장소가 필요합니다.");
    this.store = store;
    this.resolveExecutable = resolveExecutable;
    this.runCommand = runCommand;
    this.now = now;
    this.logger = logger;
    this.onChanged = onChanged;
    this.refreshIntervalMilliseconds = refreshIntervalMilliseconds;
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
      if (MODEL_CATALOG_PROVIDERS.includes(row.provider)) {
        this.rows.set(row.provider, normalizedRow(row));
      }
    }
    return this.snapshot();
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

  catalogFor(provider) {
    const stored = normalizeCatalog(this.rows.get(provider)?.catalog);
    return stored.models.length > 0
      ? stored
      : builtinModelCatalog(provider);
  }

  modelCapabilities(provider, modelID) {
    const id = String(modelID ?? "");
    return this.catalogFor(provider).models.find((entry) => entry.id === id)
      ?? null;
  }

  snapshot() {
    return {
      providers: MODEL_CATALOG_PROVIDERS.map((provider) => {
        const row = this.rows.get(provider);
        const models = this.catalogFor(provider).models
          .filter((entry) => entry.available !== false);
        const availableIDs = new Set(models.map((entry) => entry.id));
        const excludedModels = normalizedExclusions(row?.excludedModels)
          .filter((id) => availableIDs.has(id));
        return {
          backend: provider,
          models,
          excludedModels,
          fetchedAt: row?.fetchedAt ?? null,
          lastAttemptedAt: row?.lastAttemptedAt ?? null,
          lastError: row?.lastError ?? null,
        };
      }),
    };
  }

  async refreshDue({ force = false } = {}) {
    return await Promise.all(
      MODEL_CATALOG_PROVIDERS.map((provider) =>
        this.refreshProvider(provider, { force })
      ),
    );
  }

  async refreshProvider(provider, { force = false } = {}) {
    if (!SOURCES[provider]) {
      throw new TypeError(`지원하지 않는 모델 제공자입니다: ${provider}`);
    }
    const attemptedAt = new Date(this.now());
    const claimed = await this.store.claimRefresh({
      provider,
      attemptedAt,
      minimumIntervalMilliseconds: this.refreshIntervalMilliseconds,
      force,
    });
    if (!claimed) return { provider, status: "fresh" };
    this.rows.set(provider, normalizedRow(claimed));
    try {
      const discovered = await this.fetchProvider(provider);
      const merged = mergeModelCatalog(this.catalogFor(provider), discovered);
      const fetchedAt = new Date(this.now());
      const saved = await this.store.saveSuccess({
        provider,
        catalog: merged,
        fetchedAt,
      });
      this.rows.set(provider, normalizedRow(saved ?? {
        ...claimed,
        catalog: merged,
        fetchedAt,
        lastError: null,
      }));
      this.onChanged(provider);
      return {
        provider,
        status: "updated",
        modelCount: merged.models.filter((entry) => entry.available).length,
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const saved = await this.store.saveFailure({ provider, error: message });
      this.rows.set(provider, normalizedRow(saved ?? {
        ...claimed,
        lastError: message,
      }));
      this.logger.warn?.(
        `${provider} 모델 목록을 갱신하지 못해 마지막 정상값을 유지합니다.`,
        message,
      );
      return { provider, status: "failed", error: message };
    }
  }

  async setExclusions(provider, values) {
    if (!MODEL_CATALOG_PROVIDERS.includes(provider)) {
      throw new ModelCatalogValidationError("지원하지 않는 모델 제공자입니다.");
    }
    if (!Array.isArray(values)) {
      throw new ModelCatalogValidationError("제외 모델은 배열이어야 합니다.");
    }
    const requested = [...new Set(values.map((value) => String(value ?? "")))]
      .filter(Boolean);
    if (requested.some((id) => !validModelID(id))) {
      throw new ModelCatalogValidationError("제외 모델 식별자가 올바르지 않습니다.");
    }
    const available = this.catalogFor(provider).models
      .filter((entry) => entry.available !== false);
    const availableIDs = new Set(available.map((entry) => entry.id));
    const exclusions = requested.filter((id) => availableIDs.has(id));
    if (available.length > 0 && exclusions.length >= available.length) {
      throw new ModelCatalogValidationError(
        "각 CLI에는 표시할 모델을 하나 이상 남겨야 합니다.",
      );
    }
    const saved = await this.store.saveExclusions({
      provider,
      excludedModels: exclusions,
      fallbackCatalog: this.catalogFor(provider),
    });
    const previous = this.rows.get(provider) ?? {};
    this.rows.set(provider, normalizedRow(saved ?? {
      ...previous,
      provider,
      catalog: this.catalogFor(provider),
      excludedModels: exclusions,
    }));
    this.onChanged(provider);
    return this.snapshot();
  }

  async fetchProvider(provider) {
    const source = SOURCES[provider];
    const executable = await this.resolveExecutable(provider);
    const { stdout = "" } = await this.runCommand(
      executable,
      [...source.arguments],
      {
        cwd: homedir(),
        env: process.env,
        timeout: COMMAND_TIMEOUT_MILLISECONDS,
        maxBuffer: MAX_COMMAND_OUTPUT_BYTES,
      },
    );
    if (Buffer.byteLength(stdout, "utf8") > MAX_COMMAND_OUTPUT_BYTES) {
      throw new Error(`${provider} 모델 목록이 허용 크기를 넘었습니다.`);
    }
    return source.parse(stdout);
  }

  async runCycle() {
    if (this.running || this.stopped) return;
    this.running = true;
    try {
      await this.refreshDue();
    } catch (error) {
      this.logger.warn?.(
        "CLI 모델 목록 갱신 주기를 완료하지 못했습니다.",
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
    const next = MODEL_CATALOG_PROVIDERS.map((provider) => {
      const attempted = timestamp(this.rows.get(provider)?.lastAttemptedAt);
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
}

function model({
  id,
  title,
  efforts,
  defaultEffort,
  supportsFastMode = false,
  contextWindow = null,
  maxContextWindow = null,
  available = true,
}) {
  if (!validModelID(id)) return null;
  const normalizedEfforts = uniqueEfforts(efforts);
  if (normalizedEfforts.length === 0) return null;
  return {
    id: String(id),
    title: String(title ?? id).trim() || String(id),
    efforts: normalizedEfforts,
    defaultEffort: normalizedEfforts.includes(defaultEffort)
      ? defaultEffort
      : preferredEffort(normalizedEfforts),
    supportsFastMode: supportsFastMode === true,
    contextWindow: safePositiveInteger(contextWindow),
    maxContextWindow: safePositiveInteger(maxContextWindow),
    available: available !== false,
  };
}

function catalog(models) {
  return { version: 1, models: models.filter(Boolean) };
}

function normalizeCatalog(value) {
  const models = [];
  const seen = new Set();
  for (const entry of Array.isArray(value?.models) ? value.models : []) {
    const normalized = model(entry ?? {});
    if (!normalized || seen.has(normalized.id)) continue;
    seen.add(normalized.id);
    models.push(normalized);
  }
  return catalog(models);
}

function normalizedRow(row) {
  return {
    ...row,
    catalog: normalizeCatalog(row?.catalog),
    excludedModels: normalizedExclusions(row?.excludedModels),
  };
}

function normalizedExclusions(value) {
  return [...new Set(Array.isArray(value) ? value.map(String) : [])]
    .filter(validModelID);
}

function antigravityEffortVariant(id, title) {
  const identifier = String(id).match(/^(.*)-(low|medium|high)$/);
  const display = String(title).match(/^(.*)\s+\((Low|Medium|High)\)$/i);
  if (!identifier || !display) return null;
  const effort = identifier[2].toLowerCase();
  if (display[2].toLowerCase() !== effort) return null;
  return {
    baseID: identifier[1],
    baseTitle: display[1].trim(),
    effort,
  };
}

function uniqueEfforts(values) {
  const unique = [...new Set(
    (Array.isArray(values) ? values : [])
      .map((value) => String(value ?? "").trim().toLowerCase())
      .filter((value) => /^[a-z][a-z0-9_-]{0,31}$/.test(value)),
  )];
  return unique.sort((left, right) => {
    const leftIndex = EFFORT_ORDER.indexOf(left);
    const rightIndex = EFFORT_ORDER.indexOf(right);
    if (leftIndex < 0 && rightIndex < 0) return left.localeCompare(right);
    if (leftIndex < 0) return 1;
    if (rightIndex < 0) return -1;
    return leftIndex - rightIndex;
  });
}

function preferredEffort(efforts) {
  for (const effort of ["high", "medium", ...efforts]) {
    if (efforts.includes(effort)) return effort;
  }
  return efforts[0] ?? "high";
}

function safePositiveInteger(value) {
  const number = Number(value);
  return Number.isSafeInteger(number) && number > 0 ? number : null;
}

function validModelID(value) {
  return /^[A-Za-z0-9][A-Za-z0-9._:-]{0,119}$/.test(String(value ?? ""));
}

function timestamp(value) {
  if (value instanceof Date) return value.getTime();
  if (typeof value === "string") return Date.parse(value);
  return Number(value);
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}
