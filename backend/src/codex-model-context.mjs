// 설치된 Codex 모델 카탈로그에서 선택 모델의 가장 긴 지원 창을 읽는다.

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export function resolveCodexContextConfiguration(
  character,
  {
    environment = process.env,
    home = homedir(),
    readFile = readFileSync,
  } = {},
) {
  const model = String(character?.model ?? "").trim();
  if (character?.backend !== "codex" || !model) {
    return null;
  }

  const codexHome = String(environment.CODEX_HOME ?? "").trim() ||
    join(home, ".codex");
  let catalog;
  try {
    catalog = JSON.parse(
      readFile(join(codexHome, "models_cache.json"), "utf8"),
    );
  } catch {
    return null;
  }
  const entry = Array.isArray(catalog?.models)
    ? catalog.models.find((candidate) => candidate?.slug === model)
    : null;
  if (!entry) {
    return null;
  }

  const defaultWindow = positiveInteger(entry.context_window);
  const maximumWindow = positiveInteger(entry.max_context_window) ??
    defaultWindow;
  if (!maximumWindow) {
    return null;
  }
  const effectivePercent = boundedPercent(
    entry.effective_context_window_percent,
    100,
  );
  const autoCompactPercent = boundedPercent(
    character.autoCompactPercent,
    90,
    50,
    95,
  );
  const usableContextWindow = Math.floor(
    maximumWindow * effectivePercent / 100,
  );
  const autoCompactTokenLimit = Math.floor(
    usableContextWindow * autoCompactPercent / 100,
  );

  return {
    contextWindow: maximumWindow,
    usableContextWindow,
    autoCompactTokenLimit,
  };
}

function positiveInteger(value) {
  const numeric = Number(value);
  return Number.isInteger(numeric) && numeric > 0 ? numeric : null;
}

function boundedPercent(value, fallback, minimum = 1, maximum = 100) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return fallback;
  }
  return Math.min(maximum, Math.max(minimum, Math.round(numeric)));
}
