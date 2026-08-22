// 이 파일은 마이그레이션 러너가 적용 이력을 기록하고 같은 파일을 다시 실행하지 않는지 검증한다.

import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { migrate } from "../src/migrate.mjs";

// 실제 DB 없이 실행 순서와 기록만 확인하는 가짜 풀이다.
function fakePool({ failOn = null } = {}) {
  const applied = new Set();
  const log = [];
  let pending = [];
  const run = async (sql, params = []) => {
    const text = String(sql).trim();
    log.push(text.split(/\s+/).slice(0, 3).join(" "));
    if (text.startsWith("SELECT name FROM schema_migrations")) {
      return { rows: [...applied].map((name) => ({ name })) };
    }
    if (text.startsWith("INSERT INTO schema_migrations")) {
      pending.push(params[0]);
      return { rows: [] };
    }
    if (text === "COMMIT") {
      for (const name of pending) applied.add(name);
      pending = [];
      return { rows: [] };
    }
    if (text === "ROLLBACK") {
      pending = [];
      return { rows: [] };
    }
    if (failOn && text.includes(failOn)) {
      throw new Error("check constraint violated");
    }
    return { rows: [] };
  };
  return {
    applied,
    log,
    query: run,
    connect: async () => ({ query: run, release() {} }),
  };
}

async function fixtureDirectory() {
  const directory = await mkdtemp(join(tmpdir(), "office-migrate-"));
  await writeFile(join(directory, "002_second.sql"), "-- second\nSELECT 2;");
  await writeFile(join(directory, "001_first.sql"), "-- first\nSELECT 1;");
  await writeFile(join(directory, "notes.txt"), "무시되는 파일");
  return directory;
}

test("처음 실행하면 모든 SQL을 이름순으로 적용하고 기록한다", async () => {
  const directory = await fixtureDirectory();
  const pool = fakePool();

  const result = await migrate({ pool, directory });

  assert.deepEqual(result.applied, ["001_first.sql", "002_second.sql"]);
  assert.equal(result.skipped, 0);
  assert.deepEqual([...pool.applied], ["001_first.sql", "002_second.sql"]);
  const firstIndex = pool.log.indexOf("-- first SELECT");
  assert.ok(pool.log[firstIndex - 1] === "BEGIN");
  assert.ok(pool.log[firstIndex + 1].startsWith("INSERT INTO schema_migrations"));
  assert.ok(pool.log[firstIndex + 2] === "COMMIT");
});

test("이미 적용한 파일은 다시 실행하지 않는다", async () => {
  const directory = await fixtureDirectory();
  const pool = fakePool();
  await migrate({ pool, directory });
  const before = pool.log.length;

  const result = await migrate({ pool, directory });

  assert.deepEqual(result.applied, []);
  assert.equal(result.skipped, 2);
  const rerun = pool.log.slice(before);
  assert.ok(!rerun.some((entry) => entry.startsWith("-- ")));
  assert.ok(!rerun.includes("BEGIN"));
});

test("파일이 실패하면 되돌리고 기록하지 않으며 앞 파일은 남긴다", async () => {
  const directory = await fixtureDirectory();
  const pool = fakePool({ failOn: "-- second" });

  await assert.rejects(
    migrate({ pool, directory }),
    (error) =>
      error.message.includes("002_second.sql") &&
      error.message.includes("check constraint violated"),
  );

  assert.deepEqual([...pool.applied], ["001_first.sql"]);
  assert.equal(pool.log.at(-1), "ROLLBACK");
});
