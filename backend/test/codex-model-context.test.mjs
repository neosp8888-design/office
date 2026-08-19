import assert from "node:assert/strict";
import test from "node:test";

import {
  resolveCodexContextConfiguration,
} from "../src/codex-model-context.mjs";

test("Codex는 설치 카탈로그의 최대 창과 직원 임계치를 사용한다", () => {
  const configuration = resolveCodexContextConfiguration(
    {
      backend: "codex",
      model: "gpt-5.6-sol",
      autoCompactPercent: 90,
    },
    {
      environment: { CODEX_HOME: "/virtual/codex" },
      readFile(path) {
        assert.equal(path, "/virtual/codex/models_cache.json");
        return JSON.stringify({
          models: [
            {
              slug: "gpt-5.6-sol",
              context_window: 272_000,
              max_context_window: 872_000,
              effective_context_window_percent: 95,
            },
          ],
        });
      },
    },
  );

  assert.deepEqual(configuration, {
    contextWindow: 872_000,
    usableContextWindow: 828_400,
    autoCompactTokenLimit: 745_560,
  });
});

test("Codex 카탈로그가 없거나 모델이 다르면 기존 기본값을 유지한다", () => {
  const missingCatalog = resolveCodexContextConfiguration(
    { backend: "codex", model: "gpt-5.6-sol" },
    { readFile() { throw new Error("missing"); } },
  );
  const missingModel = resolveCodexContextConfiguration(
    { backend: "codex", model: "gpt-5.6-sol" },
    { readFile: () => JSON.stringify({ models: [] }) },
  );

  assert.equal(missingCatalog, null);
  assert.equal(missingModel, null);
});
