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
const agentsInstructions = readFileSync(
  new URL("../../AGENTS.md", import.meta.url),
  "utf8",
);
const claudeInstructions = readFileSync(
  new URL("../../CLAUDE.md", import.meta.url),
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

test("웹소켓은 압축 진행 상태를 시작·완료·실패와 재연결에 제공한다", () => {
  assert.match(serverSource, /compactingCharacterIds:/);
  assert.match(serverSource, /runtime\?\.compactingCharacterIDs\(\)/);
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

test("Codex와 Claude 압축 지침은 직원 호칭 없이 내용을 보존한다", () => {
  for (const instructions of [agentsInstructions, claudeInstructions]) {
    assert.match(instructions, /## 컨텍스트 압축 지침/);
    assert.match(
      instructions,
      /직원 이름과 직급 호칭을 쓰지 않는다/,
    );
    assert.match(instructions, /이름 없이 내용과 결과 중심/);
  }
});
