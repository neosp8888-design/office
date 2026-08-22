// 이 파일은 PostgreSQL 스키마 마이그레이션을 순서대로 적용하고, 적용한 파일을 기록해 다시 실행하지 않는다.

import { readdir, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const MIGRATIONS_TABLE = "schema_migrations";

// 같은 파일을 기동할 때마다 다시 실행하면 뒤 파일이 넓힌 제약을 앞 파일이
// 다시 좁히는 식으로 충돌한다. 적용한 파일 이름을 기록하고 건너뛴다.
export async function migrate({ pool: injectedPool, directory } = {}) {
  const pool = injectedPool ?? (await import("./db.mjs")).pool;
  const migrationsDirectory =
    directory ??
    resolve(fileURLToPath(new URL("../../database/migrations", import.meta.url)));
  const files = (await readdir(migrationsDirectory))
    .filter((name) => name.endsWith(".sql"))
    .sort();

  await pool.query(
    `CREATE TABLE IF NOT EXISTS ${MIGRATIONS_TABLE} (
      name text PRIMARY KEY,
      applied_at timestamptz NOT NULL DEFAULT now()
    )`,
  );
  const { rows } = await pool.query(`SELECT name FROM ${MIGRATIONS_TABLE}`);
  const alreadyApplied = new Set(rows.map((row) => row.name));

  const applied = [];
  for (const file of files) {
    if (alreadyApplied.has(file)) {
      continue;
    }
    const sql = await readFile(resolve(migrationsDirectory, file), "utf8");
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      await client.query(sql);
      await client.query(
        `INSERT INTO ${MIGRATIONS_TABLE} (name) VALUES ($1)`,
        [file],
      );
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw new Error(
        `마이그레이션 ${file} 적용에 실패했습니다. ${
          error instanceof Error ? error.message : String(error)
        }`,
        { cause: error },
      );
    } finally {
      client.release();
    }
    applied.push(file);
  }

  return { applied, skipped: files.length - applied.length };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { pool } = await import("./db.mjs");
  try {
    const result = await migrate({ pool });
    console.log(
      `PostgreSQL 마이그레이션 완료 (적용 ${result.applied.length}개, 건너뜀 ${result.skipped}개)`,
    );
  } finally {
    await pool.end();
  }
}
