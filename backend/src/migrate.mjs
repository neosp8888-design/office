// 이 파일은 PostgreSQL과 pgvector 초기 스키마를 순서대로 적용한다.

import { readdir, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { pool } from "./db.mjs";

export async function migrate() {
  const migrationsDirectory = resolve(
    fileURLToPath(new URL("../../database/migrations", import.meta.url)),
  );
  const files = (await readdir(migrationsDirectory))
    .filter((name) => name.endsWith(".sql"))
    .sort();

  for (const file of files) {
    const sql = await readFile(resolve(migrationsDirectory, file), "utf8");
    await pool.query(sql);
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    await migrate();
    console.log("PostgreSQL 마이그레이션 완료");
  } finally {
    await pool.end();
  }
}
