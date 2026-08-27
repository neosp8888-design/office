// 이 파일은 설치 도우미가 전달한 CLI 실행 경로의 검증과 원자적 DB 동기화를 검증한다.

import assert from "node:assert/strict";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  RuntimeCLIPathsValidationError,
  normalizeRuntimeCLIPaths,
  synchronizeRuntimeCLIPaths,
} from "../src/runtime-cli-paths.mjs";

function executableFixture(provider) {
  const directory = mkdtempSync(
    join(tmpdir(), `officestra-runtime-${provider}-`),
  );
  const target = join(directory, `${provider}-target`);
  const link = join(directory, provider);
  writeFileSync(target, "#!/bin/sh\nexit 0\n");
  chmodSync(target, 0o755);
  symlinkSync(target, link);
  return {
    directory,
    link,
    cleanup() {
      rmSync(directory, { recursive: true, force: true });
    },
  };
}

function fakeRuntimeDatabase(initialCharacters, {
  failProvider = null,
} = {}) {
  let committed = new Map(
    initialCharacters.map((character) => [
      character.id,
      {
        ...character,
        config: { ...(character.config ?? {}) },
      },
    ]),
  );
  let staged = null;
  let releaseCount = 0;
  let poolQueryCount = 0;
  const timeline = [];
  const updateQueries = [];
  const client = {
    async query(source, parameters = []) {
      const sql = String(source).replace(/\s+/g, " ").trim();
      if (sql.startsWith("SELECT pg_advisory_lock")) {
        timeline.push(`lock:${parameters[0].split(":").at(-1)}`);
        return { rowCount: 1, rows: [{}] };
      }
      if (sql.startsWith("SELECT pg_advisory_unlock")) {
        timeline.push(`unlock:${parameters[0].split(":").at(-1)}`);
        return { rowCount: 1, rows: [{}] };
      }
      if (sql === "BEGIN") {
        timeline.push("begin");
        staged = new Map(
          [...committed].map(([id, character]) => [
            id,
            { ...character, config: { ...character.config } },
          ]),
        );
        return { rowCount: null, rows: [] };
      }
      if (sql === "COMMIT") {
        timeline.push("commit");
        committed = staged;
        staged = null;
        return { rowCount: null, rows: [] };
      }
      if (sql === "ROLLBACK") {
        timeline.push("rollback");
        staged = null;
        return { rowCount: null, rows: [] };
      }
      if (sql.startsWith("UPDATE characters")) {
        const [provider, executablePath] = parameters;
        timeline.push(`update:${provider}`);
        updateQueries.push({ sql, parameters });
        if (provider === failProvider) {
          throw new Error(`forced provider failure: ${provider}`);
        }
        const rows = [];
        for (const [id, character] of staged) {
          if (
            character.backend !== provider ||
            character.config.executablePath === executablePath
          ) {
            continue;
          }
          staged.set(id, {
            ...character,
            config: {
              ...character.config,
              executablePath,
            },
          });
          rows.push({ id });
        }
        rows.reverse();
        return { rowCount: rows.length, rows };
      }
      throw new Error(`unexpected client query: ${sql}`);
    },
    release() {
      releaseCount += 1;
    },
  };
  const pool = {
    async query(source) {
      const sql = String(source).replace(/\s+/g, " ").trim();
      poolQueryCount += 1;
      assert.equal(sql, "SELECT id FROM characters ORDER BY id");
      return {
        rowCount: committed.size,
        rows: [...committed.keys()].map((id) => ({ id })).reverse(),
      };
    },
    async connect() {
      return client;
    },
  };
  return {
    pool,
    timeline,
    updateQueries,
    character(id) {
      return committed.get(id);
    },
    get releaseCount() {
      return releaseCount;
    },
    get poolQueryCount() {
      return poolQueryCount;
    },
  };
}

test("symlink 경로는 실제 실행 가능한 일반 파일을 가리킬 때 보존한다", () => {
  const codex = executableFixture("codex");
  try {
    assert.deepEqual(
      normalizeRuntimeCLIPaths({ executables: { codex: ` ${codex.link} ` } }),
      { codex: codex.link },
    );
  } finally {
    codex.cleanup();
  }
});

test("Antigravity provider는 agy 실행 파일 경로로 동기화한다", () => {
  const agy = executableFixture("agy");
  try {
    assert.deepEqual(
      normalizeRuntimeCLIPaths({
        executables: { antigravity: agy.link },
      }),
      { antigravity: agy.link },
    );
  } finally {
    agy.cleanup();
  }
});

test("허용되지 않은 키와 안전하지 않은 실행 경로는 모두 거절한다", () => {
  const directory = mkdtempSync(join(tmpdir(), "officestra-runtime-invalid-"));
  const nonExecutableDirectory = join(directory, "blocked");
  const nonExecutable = join(nonExecutableDirectory, "codex");
  const directoryNamedClaude = join(directory, "directory", "claude");
  mkdirSync(nonExecutableDirectory, { recursive: true });
  writeFileSync(nonExecutable, "");
  chmodSync(nonExecutable, 0o644);
  mkdirSync(directoryNamedClaude, { recursive: true });
  try {
    for (const body of [
      null,
      { executables: {}, extra: true },
      { executables: [] },
      { executables: { other: "/tmp/other" } },
      { executables: { codex: null } },
      { executables: { codex: "relative/codex" } },
      { executables: { codex: "/tmp/claude" } },
      { executables: { codex: nonExecutable } },
      { executables: { claude: directoryNamedClaude } },
    ]) {
      assert.throws(
        () => normalizeRuntimeCLIPaths(body),
        RuntimeCLIPathsValidationError,
      );
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("모든 직원 잠금을 정렬 획득한 뒤 provider별 config 경로만 한 트랜잭션에서 병합한다", async () => {
  const codex = executableFixture("codex");
  const claude = executableFixture("claude");
  const database = fakeRuntimeDatabase([
    {
      id: "right-man",
      backend: "claude",
      config: { executablePath: "/old/claude", theme: "night" },
    },
    {
      id: "boss",
      backend: "codex",
      config: { executablePath: "/old/codex", custom: true },
    },
    {
      id: "left-man",
      backend: "codex",
      config: { executablePath: codex.link, custom: "kept" },
    },
  ]);
  try {
    const result = await synchronizeRuntimeCLIPaths({
      pool: database.pool,
      body: {
        executables: {
          claude: claude.link,
          codex: codex.link,
        },
      },
    });

    assert.deepEqual(result, {
      ok: true,
      updatedCharacterIds: ["boss", "right-man"],
    });
    assert.deepEqual(
      database.timeline.filter((event) => event.startsWith("lock:")),
      ["lock:boss", "lock:left-man", "lock:right-man"],
    );
    assert.deepEqual(
      database.timeline.filter((event) => event.startsWith("unlock:")),
      ["unlock:right-man", "unlock:left-man", "unlock:boss"],
    );
    assert.deepEqual(
      database.timeline.filter((event) => event.startsWith("update:")),
      ["update:codex", "update:claude"],
    );
    assert.equal(database.timeline.filter((event) => event === "begin").length, 1);
    assert.equal(database.timeline.filter((event) => event === "commit").length, 1);
    assert.equal(database.timeline.includes("rollback"), false);
    assert.deepEqual(database.character("boss").config, {
      executablePath: codex.link,
      custom: true,
    });
    assert.deepEqual(database.character("right-man").config, {
      executablePath: claude.link,
      theme: "night",
    });
    assert.deepEqual(database.character("left-man").config, {
      executablePath: codex.link,
      custom: "kept",
    });
    for (const { sql } of database.updateQueries) {
      assert.match(sql, /jsonb_set\( COALESCE\(config, '\{\}'::jsonb\)/);
      assert.match(sql, /WHERE backend = \$1/);
      assert.match(sql, /config ->> 'executablePath' IS DISTINCT FROM \$2/);
    }
    assert.equal(database.releaseCount, 1);
  } finally {
    codex.cleanup();
    claude.cleanup();
  }
});

test("provider 두 번째 갱신이 실패하면 첫 번째 config 변경도 롤백한다", async () => {
  const codex = executableFixture("codex");
  const claude = executableFixture("claude");
  const database = fakeRuntimeDatabase(
    [
      {
        id: "boss",
        backend: "codex",
        config: { executablePath: "/old/codex", custom: true },
      },
      {
        id: "right-man",
        backend: "claude",
        config: { executablePath: "/old/claude", theme: "night" },
      },
    ],
    { failProvider: "claude" },
  );
  try {
    await assert.rejects(
      synchronizeRuntimeCLIPaths({
        pool: database.pool,
        body: {
          executables: { codex: codex.link, claude: claude.link },
        },
      }),
      /forced provider failure/,
    );
    assert.deepEqual(database.character("boss").config, {
      executablePath: "/old/codex",
      custom: true,
    });
    assert.equal(database.timeline.includes("commit"), false);
    assert.equal(database.timeline.includes("rollback"), true);
  } finally {
    codex.cleanup();
    claude.cleanup();
  }
});

test("해당 provider 직원이 없으면 정상 성공과 빈 변경 목록을 반환한다", async () => {
  const claude = executableFixture("claude");
  const database = fakeRuntimeDatabase([
    { id: "boss", backend: "codex", config: { custom: true } },
  ]);
  try {
    assert.deepEqual(
      await synchronizeRuntimeCLIPaths({
        pool: database.pool,
        body: { executables: { claude: claude.link } },
      }),
      { ok: true, updatedCharacterIds: [] },
    );
    assert.equal(database.timeline.includes("commit"), true);
  } finally {
    claude.cleanup();
  }
});

test("빈 실행 경로 객체는 DB와 잠금을 건드리지 않고 성공한다", async () => {
  const database = fakeRuntimeDatabase([]);
  assert.deepEqual(
    await synchronizeRuntimeCLIPaths({
      pool: database.pool,
      body: { executables: {} },
    }),
    { ok: true, updatedCharacterIds: [] },
  );
  assert.equal(database.poolQueryCount, 0);
  assert.deepEqual(database.timeline, []);
});

test("server는 신뢰된 JSON PUT route와 400 검증 계약을 연결한다", () => {
  const source = readFileSync(
    new URL("../src/server.mjs", import.meta.url),
    "utf8",
  );
  assert.match(source, /url\.pathname === "\/api\/runtime\/cli-paths"/);
  assert.match(
    source,
    /api\/runtime\/cli-paths"[\s\S]*?trustedJSONMutation\(request, response\)/,
  );
  assert.match(
    source,
    /RuntimeCLIPathsValidationError[\s\S]*?send\(response, 400/,
  );
});
