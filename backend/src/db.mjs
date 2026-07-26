// 이 파일은 사무실 백엔드가 PostgreSQL 연결을 공유하도록 제공한다.

import pg from "pg";

const { Pool } = pg;

export const pool = new Pool({
  connectionString:
    process.env.DATABASE_URL ??
    "postgres://office:office-local@127.0.0.1:54329/office",
});

export async function withTransaction(operation) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const result = await operation(client);
    await client.query("COMMIT");
    return result;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally {
    client.release();
  }
}
