// 이 파일은 격리 PostgreSQL에서 완료 턴 기록과 승인별 RAG 수명주기를 검증한다.

import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import test from "node:test";
import pg from "pg";

import {
  findRelevantWorkRecordRAGContext,
  persistCompletedTurnWorkRecord,
  reconcileTerminalWorkRecordReviews,
  syncWorkRecordRAGDocuments,
  transitionTurnWorkRecordReview,
} from "../src/work-record-memory.mjs";

const { Pool } = pg;
const databaseURL = process.env.OFFICE_TEST_DATABASE_URL ?? "";

test(
  "완료·승인·거절 기록과 RAG 수명주기는 PostgreSQL에서 멱등이다",
  { skip: !databaseURL },
  async () => {
    const pool = new Pool({ connectionString: databaseURL });
    const client = await pool.connect();
    const conversationID = randomUUID();
    const sessionID = randomUUID();
    const turnID = randomUUID();
    const earlierTurnID = randomUUID();
    const closedTurnID = randomUUID();
    const workspaceID = randomUUID();
    try {
      await client.query("BEGIN");
      await client.query(
        `
          INSERT INTO characters (
            id,
            name,
            seat,
            backend,
            model,
            effort,
            permission,
            identity_prompt,
            config
          )
          VALUES (
            'memory-test-character',
            '기록 테스트',
            '격리 좌석',
            'codex',
            'gpt-5.6-sol',
            'high',
            'workspace-write',
            '',
            '{}'::jsonb
          )
          ON CONFLICT (id) DO NOTHING
        `,
      );
      await client.query(
        `
          INSERT INTO conversations (id, title, workdir)
          VALUES ($1, '격리 기록 테스트', '/repo')
        `,
        [conversationID],
      );
      await client.query(
        `
          INSERT INTO cli_sessions (
            id,
            conversation_id,
            character_id
          )
          VALUES ($1, $2, 'memory-test-character')
        `,
        [sessionID, conversationID],
      );
      await client.query(
        `
          INSERT INTO turns (
            id,
            cli_session_id,
            backend,
            model,
            effort,
            fast_mode,
            prompt,
            status,
            started_at,
            ended_at
          )
          VALUES (
            $1,
            $2,
            'codex',
            'gpt-5.6-sol',
            'high',
            false,
            '세션 유지 작업을 검증해줘.',
            'completed',
            now() - interval '1 minute',
            now()
          )
        `,
        [turnID, sessionID],
      );
      await client.query(
        `
          INSERT INTO turns (
            id,
            cli_session_id,
            backend,
            model,
            effort,
            fast_mode,
            prompt,
            status,
            started_at,
            ended_at
          )
          VALUES (
            $1,
            $2,
            'codex',
            'gpt-5.6-sol',
            'high',
            false,
            '앞선 작업을 검증해줘.',
            'completed',
            now() - interval '2 minutes',
            now()
          )
        `,
        [earlierTurnID, sessionID],
      );
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
            base_commit,
            review_turn_id,
            review_tree
          )
          VALUES (
            $1,
            $2,
            'awaiting_approval',
            '/repo',
            '/repo',
            $3,
            $3,
            $4,
            'main',
            'base-commit',
            $5,
            'review-tree'
          )
        `,
        [
          workspaceID,
          sessionID,
          `/worktrees/${workspaceID}`,
          `officestra/test/${workspaceID}`,
          turnID,
        ],
      );

      const input = {
        repositoryRoot: "/repo",
        turnID,
        workspaceID,
        characterID: "memory-test-character",
        prompt: "세션 유지 작업을 검증해줘.",
        response: "기존 세션이 유지됩니다.",
        backend: "codex",
        model: "gpt-5.6-sol",
        reviewStatus: "awaiting_approval",
        reviewTree: "review-tree",
      };
      const first = await persistCompletedTurnWorkRecord(client, input);
      const second = await persistCompletedTurnWorkRecord(client, input);
      assert.equal(second.workRecordId, first.workRecordId);
      const earlier = await persistCompletedTurnWorkRecord(client, {
        ...input,
        turnID: earlierTurnID,
        prompt: "앞선 작업을 검증해줘.",
        response: "앞선 작업은 검토가 필요하지 않습니다.",
        reviewStatus: "not_required",
      });

      const pendingSync = await syncWorkRecordRAGDocuments(client, {
        workRecordID: first.workRecordId,
      });
      assert.equal(pendingSync.changed, 0);
      assert.equal(
        Number((await client.query(
          "SELECT count(*) AS count FROM rag_documents WHERE work_record_id = $1",
          [first.workRecordId],
        )).rows[0].count),
        0,
      );

      await client.query(
        "UPDATE task_workspaces SET status = 'merged' WHERE id = $1",
        [workspaceID],
      );
      await client.query(
        `
          UPDATE task_workspaces
          SET task_commit = 'task-commit', merged_commit = 'merge-commit'
          WHERE id = $1
        `,
        [workspaceID],
      );
      assert.deepEqual(await reconcileTerminalWorkRecordReviews(client, {
        repositoryRoot: "/repo",
      }), [first.workRecordId]);
      const earlierAfterReconciliation = await client.query(
        `
          SELECT
            lifecycle_state AS "lifecycleState",
            metadata #>> '{review,status}' AS "reviewStatus"
          FROM work_records
          WHERE id = $1
        `,
        [earlier.workRecordId],
      );
      assert.deepEqual(earlierAfterReconciliation.rows[0], {
        lifecycleState: "active",
        reviewStatus: "not_required",
      });
      await syncWorkRecordRAGDocuments(client, {
        workRecordID: first.workRecordId,
      });
      const indexed = await client.query(
        `
          SELECT id::text AS id
          FROM rag_documents
          WHERE work_record_id = $1
        `,
        [first.workRecordId],
      );
      assert.equal(indexed.rowCount, 1);
      const stableRAGID = indexed.rows[0].id;

      const repeatedSync = await syncWorkRecordRAGDocuments(client, {
        workRecordID: first.workRecordId,
      });
      assert.equal(repeatedSync.changed, 0);
      assert.equal(
        (await client.query(
          "SELECT id::text AS id FROM rag_documents WHERE work_record_id = $1",
          [first.workRecordId],
        )).rows[0].id,
        stableRAGID,
      );

      const context = await findRelevantWorkRecordRAGContext(client, {
        repositoryRoot: "/repo",
        query: "세션 유지 상태",
        limit: 3,
      });
      assert.equal(context[0].ragDocumentId, stableRAGID);
      assert.equal(context[0].workRecordId, first.workRecordId);

      await client.query(
        `
          INSERT INTO turns (
            id,
            cli_session_id,
            task_workspace_id,
            backend,
            model,
            effort,
            fast_mode,
            prompt,
            status,
            started_at,
            ended_at
          )
          VALUES (
            $1,
            $2,
            $3,
            'codex',
            'gpt-5.6-sol',
            'high',
            false,
            '사라진 변경을 닫아줘.',
            'completed',
            now(),
            now()
          )
        `,
        [closedTurnID, sessionID, workspaceID],
      );
      const closedRecord = await persistCompletedTurnWorkRecord(client, {
        ...input,
        turnID: closedTurnID,
        prompt: "사라진 변경을 닫아줘.",
        response: "변경이 없어 작업공간을 닫았습니다.",
        reviewStatus: "awaiting_approval",
      });
      await client.query(
        `
          UPDATE task_workspaces
          SET
            status = 'closed',
            review_turn_id = NULL,
            review_tree = NULL,
            changed_files = '[]'::jsonb,
            task_commit = NULL,
            merged_commit = NULL,
            merged_at = NULL,
            rejected_at = NULL
          WHERE id = $1
        `,
        [workspaceID],
      );
      assert.deepEqual(await reconcileTerminalWorkRecordReviews(client, {
        repositoryRoot: "/repo",
      }), [closedRecord.workRecordId]);
      const closedAfterReconciliation = await client.query(
        `
          SELECT
            lifecycle_state AS "lifecycleState",
            metadata #>> '{review,status}' AS "reviewStatus"
          FROM work_records
          WHERE id = $1
        `,
        [closedRecord.workRecordId],
      );
      assert.deepEqual(closedAfterReconciliation.rows[0], {
        lifecycleState: "active",
        reviewStatus: "not_required",
      });

      await client.query(
        `
          UPDATE task_workspaces
          SET
            status = 'awaiting_approval',
            review_turn_id = $2,
            review_tree = 'review-tree'
          WHERE id = $1
        `,
        [workspaceID, turnID],
      );
      const hiddenWhilePending = await client.query(
        `
          SELECT
            (SELECT count(*) FROM rag_documents
              WHERE work_record_id = $1) AS physical,
            (SELECT count(*) FROM searchable_rag_documents
              WHERE work_record_id = $1) AS searchable
        `,
        [first.workRecordId],
      );
      assert.deepEqual(hiddenWhilePending.rows[0], {
        physical: "1",
        searchable: "0",
      });
      const manualDocument = await client.query(
        `
          INSERT INTO rag_documents (source, title, content, metadata)
          VALUES ('manual-test', '수동 자료', '수동 검색 자료', '{}'::jsonb)
          RETURNING id
        `,
      );
      assert.equal(Number((await client.query(
        `
          SELECT count(*) AS count
          FROM searchable_rag_documents
          WHERE id = $1
        `,
        [manualDocument.rows[0].id],
      )).rows[0].count), 1);

      await client.query(
        "UPDATE task_workspaces SET status = 'rejected' WHERE id = $1",
        [workspaceID],
      );
      await transitionTurnWorkRecordReview(client, {
        turnID,
        status: "rejected",
        reviewTree: "review-tree",
      });
      await syncWorkRecordRAGDocuments(client, {
        workRecordID: first.workRecordId,
      });
      const afterRejection = await persistCompletedTurnWorkRecord(
        client,
        input,
      );
      assert.equal(afterRejection.workRecordId, first.workRecordId);
      const finalCounts = await client.query(
        `
          SELECT
            (SELECT count(*) FROM work_records WHERE source_turn_id = $1)
              AS records,
            (SELECT count(*) FROM work_record_events
              WHERE record_id = $2) AS events,
            (SELECT count(*) FROM rag_documents
              WHERE work_record_id = $2) AS documents,
            (SELECT lifecycle_state FROM work_records WHERE id = $2)
              AS lifecycle_state
        `,
        [turnID, first.workRecordId],
      );
      assert.deepEqual(finalCounts.rows[0], {
        records: "1",
        events: "3",
        documents: "0",
        lifecycle_state: "archived",
      });
    } finally {
      await client.query("ROLLBACK");
      client.release();
      await pool.end();
    }
  },
);

test(
  "동시 완료 저장과 상태 전환은 한 기록과 연속 이벤트 버전을 유지한다",
  { skip: !databaseURL },
  async () => {
    const pool = new Pool({ connectionString: databaseURL });
    const suffix = randomUUID();
    const characterID = `memory-concurrency-${suffix}`;
    const conversationID = randomUUID();
    const sessionID = randomUUID();
    const turnID = randomUUID();
    const repositoryRoot = `/repo-concurrency-${suffix}`;
    const inTransaction = async (operation) => {
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
    };
    try {
      await pool.query(
        `
          INSERT INTO characters (
            id,
            name,
            seat,
            backend,
            model,
            effort,
            permission,
            identity_prompt,
            config
          )
          VALUES (
            $1,
            '동시성 기록 테스트',
            '격리 좌석',
            'codex',
            'gpt-5.6-sol',
            'high',
            'workspace-write',
            '',
            '{}'::jsonb
          )
        `,
        [characterID],
      );
      await pool.query(
        `
          INSERT INTO conversations (id, title, workdir)
          VALUES ($1, '동시성 기록 테스트', $2)
        `,
        [conversationID, repositoryRoot],
      );
      await pool.query(
        `
          INSERT INTO cli_sessions (id, conversation_id, character_id)
          VALUES ($1, $2, $3)
        `,
        [sessionID, conversationID, characterID],
      );
      await pool.query(
        `
          INSERT INTO turns (
            id,
            cli_session_id,
            backend,
            model,
            effort,
            fast_mode,
            prompt,
            status,
            ended_at
          )
          VALUES (
            $1,
            $2,
            'codex',
            'gpt-5.6-sol',
            'high',
            false,
            '동시 저장을 검증해줘.',
            'completed',
            now()
          )
        `,
        [turnID, sessionID],
      );

      const input = {
        repositoryRoot,
        turnID,
        characterID,
        prompt: "동시 저장을 검증해줘.",
        response: "한 기록만 저장됩니다.",
        reviewStatus: "not_applicable",
      };
      const [first, second] = await Promise.all([
        inTransaction((client) =>
          persistCompletedTurnWorkRecord(client, input)
        ),
        inTransaction((client) =>
          persistCompletedTurnWorkRecord(client, input)
        ),
      ]);
      assert.equal(first.workRecordId, second.workRecordId);

      const [firstTransition, secondTransition] = await Promise.all([
        inTransaction((client) =>
          transitionTurnWorkRecordReview(client, {
            turnID,
            status: "not_required",
            reviewTree: "tree-a",
            actorType: "system",
          })
        ),
        inTransaction((client) =>
          transitionTurnWorkRecordReview(client, {
            turnID,
            status: "awaiting_approval",
            reviewTree: "tree-b",
            actorType: "system",
          })
        ),
      ]);
      assert.equal(firstTransition, first.workRecordId);
      assert.equal(secondTransition, first.workRecordId);

      const result = await pool.query(
        `
          SELECT
            (SELECT count(*) FROM work_records
              WHERE source_turn_id = $1) AS records,
            (SELECT array_agg(record_version ORDER BY record_version)
              FROM work_record_events
              WHERE record_id = $2) AS versions
        `,
        [turnID, first.workRecordId],
      );
      assert.deepEqual(result.rows[0], {
        records: "1",
        versions: [1, 2, 3],
      });
    } finally {
      await pool.query(
        `
          DELETE FROM rag_documents
          WHERE work_record_id IN (
            SELECT id FROM work_records WHERE source_turn_id = $1
          )
        `,
        [turnID],
      );
      await pool.query(
        `
          DELETE FROM work_record_events
          WHERE record_id IN (
            SELECT id FROM work_records WHERE source_turn_id = $1
          )
        `,
        [turnID],
      );
      await pool.query(
        "DELETE FROM work_records WHERE source_turn_id = $1",
        [turnID],
      );
      await pool.query("DELETE FROM turns WHERE id = $1", [turnID]);
      await pool.query("DELETE FROM cli_sessions WHERE id = $1", [sessionID]);
      await pool.query(
        "DELETE FROM conversations WHERE id = $1",
        [conversationID],
      );
      await pool.query(
        "DELETE FROM projects WHERE repository_root = $1",
        [repositoryRoot],
      );
      await pool.query("DELETE FROM characters WHERE id = $1", [characterID]);
      await pool.end();
    }
  },
);
