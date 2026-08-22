// 이 파일은 같은 CLI 세션의 검토본과 다음 실행 workspace가 DB에서 공존하는지 검증한다.

import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import test from "node:test";
import pg from "pg";

const { Pool } = pg;
const databaseURL = process.env.OFFICE_TEST_DATABASE_URL ?? "";

test(
  "격리 PostgreSQL — 검토 workspace는 보존하고 실제 실행 workspace만 하나로 제한한다",
  { skip: !databaseURL },
  async () => {
    const pool = new Pool({ connectionString: databaseURL });
    const client = await pool.connect();
    const suffix = randomUUID().slice(0, 8);
    const characterID = `workspace-index-${suffix}`;
    const conversationID = randomUUID();
    const sessionID = randomUUID();
    let ordinal = 0;

    async function insertWorkspace(status) {
      ordinal += 1;
      const workspaceID = randomUUID();
      const worktreePath = `/tmp/workspace-index-${suffix}-${ordinal}`;
      await client.query(
        `
          INSERT INTO task_workspaces (
            id,
            cli_session_id,
            status,
            repository_root,
            source_workdir,
            worktree_path,
            execution_workdir,
            branch_name,
            base_branch,
            base_commit
          )
          VALUES (
            $1, $2, $3, '/repo', '/repo', $4, $4, $5, 'main', 'base'
          )
        `,
        [
          workspaceID,
          sessionID,
          status,
          worktreePath,
          `workspace-index-${suffix}-${ordinal}`,
        ],
      );
      return workspaceID;
    }

    try {
      await client.query("BEGIN");
      await client.query(
        `
          INSERT INTO characters (
            id, name, seat, backend, model, effort, permission,
            identity_prompt, config
          )
          VALUES (
            $1, $1, '격리 좌석', 'codex', 'gpt-5.6-terra', 'high',
            'workspace-write', '', '{}'::jsonb
          )
        `,
        [characterID],
      );
      await client.query(
        `
          INSERT INTO conversations (id, title, workdir)
          VALUES ($1, 'workspace index test', '/repo')
        `,
        [conversationID],
      );
      await client.query(
        `
          INSERT INTO cli_sessions (id, conversation_id, character_id)
          VALUES ($1, $2, $3)
        `,
        [sessionID, conversationID, characterID],
      );

      await insertWorkspace("awaiting_approval");
      await insertWorkspace("conflict");
      await insertWorkspace("merging");
      const activeWorkspaceID = await insertWorkspace("active");

      await client.query("SAVEPOINT duplicate_workspace");
      let duplicateError = null;
      try {
        await insertWorkspace("provisioning");
      } catch (error) {
        duplicateError = error;
        await client.query("ROLLBACK TO SAVEPOINT duplicate_workspace");
      }
      assert.equal(duplicateError?.code, "23505");
      assert.equal(
        duplicateError?.constraint,
        "task_workspaces_one_open_per_session_idx",
      );

      await client.query(
        `
          UPDATE task_workspaces
          SET status = 'awaiting_approval'
          WHERE id = $1
        `,
        [activeWorkspaceID],
      );
      await insertWorkspace("active");

      const count = await client.query(
        `
          SELECT count(*) AS count
          FROM task_workspaces
          WHERE cli_session_id = $1
        `,
        [sessionID],
      );
      assert.equal(Number(count.rows[0].count), 5);
    } finally {
      await client.query("ROLLBACK");
      client.release();
      await pool.end();
    }
  },
);
