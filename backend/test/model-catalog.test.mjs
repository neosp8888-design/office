import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  MODEL_CATALOG_REFRESH_MILLISECONDS,
  ModelCatalogService,
  ModelCatalogValidationError,
  mergeModelCatalog,
  parseAntigravityModelCatalog,
  parseCodexModelCatalog,
} from "../src/model-catalog.mjs";

const codexPayload = JSON.stringify({
  models: [
    {
      slug: "internal-hidden",
      display_name: "Hidden",
      visibility: "hide",
      default_reasoning_level: "high",
      supported_reasoning_levels: [{ effort: "high" }],
    },
    {
      slug: "gpt-next",
      display_name: "GPT Next",
      visibility: "list",
      default_reasoning_level: "medium",
      supported_reasoning_levels: [
        { effort: "low" },
        { effort: "medium" },
        { effort: "high" },
      ],
      additional_speed_tiers: ["fast"],
      service_tiers: [{ id: "priority" }],
      context_window: 300_000,
      max_context_window: 1_000_000,
    },
  ],
});

const antigravityPayload = [
  "gemini-next-high\tGemini Next (High)",
  "gemini-next-medium\tGemini Next (Medium)",
  "gemini-next-low\tGemini Next (Low)",
  "claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)",
  "gpt-oss-120b-medium\tGPT-OSS 120B (Medium)",
].join("\n");

test("Codex JSON은 화면 노출 모델과 실제 옵션만 추린다", () => {
  const parsed = parseCodexModelCatalog(codexPayload);
  assert.equal(parsed.models.length, 1);
  assert.deepEqual(parsed.models[0], {
    id: "gpt-next",
    title: "GPT Next",
    efforts: ["low", "medium", "high"],
    defaultEffort: "medium",
    supportsFastMode: true,
    contextWindow: 300_000,
    maxContextWindow: 1_000_000,
    available: true,
  });
});

test("Antigravity 목록은 Gemini 노력 변형을 한 모델로 합친다", () => {
  const parsed = parseAntigravityModelCatalog(antigravityPayload);
  assert.deepEqual(parsed.models.map((entry) => entry.id), [
    "gemini-next",
    "claude-sonnet-4-6",
    "gpt-oss-120b-medium",
  ]);
  assert.deepEqual(parsed.models[0].efforts, ["low", "medium", "high"]);
  assert.equal(parsed.models[1].defaultEffort, "high");
  assert.deepEqual(parsed.models[2].efforts, ["medium"]);
});

test("사라진 모델은 선택 목록에서 내리되 기존 설정 검증용으로 보존한다", () => {
  const merged = mergeModelCatalog(
    parseCodexModelCatalog(codexPayload),
    parseCodexModelCatalog(JSON.stringify({
      models: [{
        slug: "gpt-newer",
        display_name: "GPT Newer",
        visibility: "list",
        default_reasoning_level: "high",
        supported_reasoning_levels: [{ effort: "high" }],
      }],
    })),
  );
  assert.deepEqual(merged.models.map((entry) => [entry.id, entry.available]), [
    ["gpt-newer", true],
    ["gpt-next", false],
  ]);
});

test("서비스는 12시간 게이트와 제외 모델을 영속 저장한다", async () => {
  let now = Date.parse("2026-09-05T00:00:00Z");
  const store = fakeStore();
  let commandCount = 0;
  const service = new ModelCatalogService({
    store,
    now: () => now,
    resolveExecutable: (provider) => provider,
    runCommand: async (executable) => {
      commandCount += 1;
      return {
        stdout: executable === "codex" ? codexPayload : antigravityPayload,
      };
    },
  });
  await service.loadCached();
  const first = await service.refreshDue();
  assert.deepEqual(first.map((entry) => entry.status), ["updated", "updated"]);
  assert.equal(commandCount, 2);

  now += MODEL_CATALOG_REFRESH_MILLISECONDS - 1;
  const fresh = await service.refreshDue();
  assert.deepEqual(fresh.map((entry) => entry.status), ["fresh", "fresh"]);
  assert.equal(commandCount, 2);

  const snapshot = await service.setExclusions("codex", ["gpt-next"])
    .catch((error) => error);
  assert.ok(snapshot instanceof ModelCatalogValidationError);

  // 단일 모델을 모두 제외할 수 없으므로 모델을 하나 더 발견시킨다.
  const current = store.rows.get("codex");
  current.catalog.models.push({
    ...current.catalog.models[0],
    id: "gpt-second",
    title: "GPT Second",
  });
  service.rows.set("codex", current);
  const saved = await service.setExclusions("codex", ["gpt-next"]);
  assert.deepEqual(
    saved.providers.find((entry) => entry.backend === "codex").excludedModels,
    ["gpt-next"],
  );
});

test("갱신 실패 시 마지막 정상 모델과 제외 설정을 유지한다", async () => {
  const store = fakeStore();
  const service = new ModelCatalogService({
    store,
    resolveExecutable: (provider) => provider,
    runCommand: async () => ({ stdout: codexPayload }),
  });
  await service.loadCached();
  await service.refreshProvider("codex", { force: true });
  await service.setExclusions("codex", []);

  service.runCommand = async () => {
    throw new Error("offline");
  };
  const failed = await service.refreshProvider("codex", { force: true });
  assert.equal(failed.status, "failed");
  assert.equal(service.modelCapabilities("codex", "gpt-next")?.id, "gpt-next");
  assert.equal(service.snapshot().providers[0].lastError, "offline");
});

test("마이그레이션은 모델 카탈로그와 동적 effort 저장을 준비한다", () => {
  const source = readFileSync(
    new URL("../../database/migrations/036_agent_model_catalog.sql", import.meta.url),
    "utf8",
  );
  assert.match(source, /CREATE TABLE IF NOT EXISTS agent_model_catalogs/);
  assert.match(source, /excluded_models text\[\]/);
  assert.match(source, /effort ~ '\^\[a-z\]/);
});

function fakeStore() {
  const rows = new Map();
  return {
    rows,
    async load() {
      return [...rows.values()];
    },
    async claimRefresh({
      provider,
      attemptedAt,
      minimumIntervalMilliseconds,
      force,
    }) {
      const previous = rows.get(provider);
      if (
        !force && previous?.lastAttemptedAt &&
        attemptedAt.getTime() - new Date(previous.lastAttemptedAt).getTime() <
          minimumIntervalMilliseconds
      ) {
        return null;
      }
      const row = {
        provider,
        catalog: previous?.catalog ?? { version: 1, models: [] },
        excludedModels: previous?.excludedModels ?? [],
        fetchedAt: previous?.fetchedAt ?? null,
        lastAttemptedAt: attemptedAt,
        lastError: previous?.lastError ?? null,
      };
      rows.set(provider, row);
      return row;
    },
    async saveSuccess({ provider, catalog, fetchedAt }) {
      const row = {
        ...rows.get(provider),
        catalog,
        fetchedAt,
        lastError: null,
      };
      rows.set(provider, row);
      return row;
    },
    async saveFailure({ provider, error }) {
      const row = { ...rows.get(provider), lastError: String(error) };
      rows.set(provider, row);
      return row;
    },
    async saveExclusions({ provider, excludedModels, fallbackCatalog }) {
      const row = {
        provider,
        catalog: rows.get(provider)?.catalog ?? fallbackCatalog,
        excludedModels,
        fetchedAt: rows.get(provider)?.fetchedAt ?? null,
        lastAttemptedAt: rows.get(provider)?.lastAttemptedAt ?? null,
        lastError: rows.get(provider)?.lastError ?? null,
      };
      rows.set(provider, row);
      return row;
    },
  };
}
