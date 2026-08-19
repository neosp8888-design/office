import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const serverSource = readFileSync(
  new URL("../src/server.mjs", import.meta.url),
  "utf8",
);
const migrationSource = readFileSync(
  new URL("../../database/migrations/025_context_compaction.sql", import.meta.url),
  "utf8",
);

test("컨텍스트 설정과 수동 압축 API를 신뢰된 로컬 JSON 경로로 연결한다", () => {
  assert.match(serverSource, /function routeCharacterContextSettings/);
  assert.match(serverSource, /function routeCharacterContextCompact/);
  assert.equal(serverSource.includes("context-settings$/"), true);
  assert.equal(serverSource.includes("context\\/compact$/"), true);
  assert.match(
    serverSource,
    /updateCharacterContextSettings[\s\S]*autoCompactPercent < 50[\s\S]*autoCompactPercent > 95/,
  );
  assert.match(
    serverSource,
    /contextCompactCharacterID[\s\S]*trustedJSONMutation[\s\S]*compactCharacterContext/,
  );
});

test("자동 압축 기준 migration은 90% 기본값과 50~95% 제약을 둔다", () => {
  assert.match(
    migrationSource,
    /auto_compact_percent smallint NOT NULL DEFAULT 90/,
  );
  assert.match(
    migrationSource,
    /auto_compact_percent BETWEEN 50 AND 95/,
  );
});
