// 이 파일은 승인형 위키 제안 수명주기와 게시·검색 분리를 검증한다.

import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import pg from "pg";

import {
  WikiKnowledgeError,
  approveWikiProposal,
  archiveWikiPage,
  createWikiProposal,
  getWikiPage,
  listWikiPages,
  listWikiProposals,
  normalizedSourceWorkRecordIDs,
  normalizedWikiPageKey,
  rejectWikiProposal,
  verifyWikiProposal,
  wikiProposalActionOutcome,
} from "../src/wiki-knowledge.mjs";

const { Pool } = pg;
const databaseURL = process.env.OFFICE_TEST_DATABASE_URL ?? "";

test("페이지 키는 파서와 같은 소문자 슬러그만 허용한다", () => {
  assert.equal(normalizedWikiPageKey("  design-decisions  "), "design-decisions");
  assert.throws(() => normalizedWikiPageKey("   "), WikiKnowledgeError);
  assert.throws(() => normalizedWikiPageKey("!!!"), WikiKnowledgeError);
  assert.throws(() => normalizedWikiPageKey("Design-Decisions"), WikiKnowledgeError);
  assert.throws(() => normalizedWikiPageKey("보안-사건"), WikiKnowledgeError);
  assert.throws(() => normalizedWikiPageKey("a_b"), WikiKnowledgeError);
  assert.throws(
    () => normalizedWikiPageKey("a".repeat(81)),
    WikiKnowledgeError,
  );
});

test("근거 ID 목록은 UUID만 허용하고 중복을 제거한다", () => {
  const id = "3f2b8c1a-4d5e-4f60-8a71-92b3c4d5e6f7";
  assert.deepEqual(
    normalizedSourceWorkRecordIDs([id, id.toUpperCase()], { required: true }),
    [id],
  );
  assert.deepEqual(
    normalizedSourceWorkRecordIDs(null, { required: false }),
    [],
  );
  assert.throws(
    () => normalizedSourceWorkRecordIDs(null, { required: true }),
    WikiKnowledgeError,
  );
  assert.throws(
    () => normalizedSourceWorkRecordIDs(["잘못된-값"], { required: true }),
    WikiKnowledgeError,
  );
  assert.throws(
    () => normalizedSourceWorkRecordIDs("not-array", { required: false }),
    WikiKnowledgeError,
  );
});

test("전이 판정표 — 검증은 drafted에서만, 등급별 다음 상태가 다르다", () => {
  assert.equal(
    wikiProposalActionOutcome({
      state: "drafted",
      approvalGrade: "peer",
      action: "verify",
      authorCharacterID: "author",
      actorCharacterID: "reviewer",
    }),
    "peer_verified",
  );
  assert.equal(
    wikiProposalActionOutcome({
      state: "drafted",
      approvalGrade: "user",
      action: "verify",
      actorCharacterID: "reviewer",
    }),
    "pending_user",
  );
  // peer 등급 자기 검증 금지.
  assert.throws(
    () =>
      wikiProposalActionOutcome({
        state: "drafted",
        approvalGrade: "peer",
        action: "verify",
        authorCharacterID: "author",
        actorCharacterID: "author",
      }),
    (error) => error instanceof WikiKnowledgeError && error.statusCode === 403,
  );
  // auto 등급은 검증 단계가 없다.
  assert.throws(
    () =>
      wikiProposalActionOutcome({
        state: "drafted",
        approvalGrade: "auto",
        action: "verify",
        actorCharacterID: "reviewer",
      }),
    (error) => error instanceof WikiKnowledgeError && error.statusCode === 409,
  );
  assert.throws(
    () =>
      wikiProposalActionOutcome({
        state: "peer_verified",
        approvalGrade: "peer",
        action: "verify",
        actorCharacterID: "reviewer",
      }),
    (error) => error instanceof WikiKnowledgeError && error.statusCode === 409,
  );
});

test("전이 판정표 — 승인은 등급별 허용 상태가 고정된다", () => {
  assert.equal(
    wikiProposalActionOutcome({
      state: "drafted",
      approvalGrade: "auto",
      action: "approve",
    }),
    "published",
  );
  assert.equal(
    wikiProposalActionOutcome({
      state: "peer_verified",
      approvalGrade: "peer",
      action: "approve",
    }),
    "published",
  );
  assert.equal(
    wikiProposalActionOutcome({
      state: "pending_user",
      approvalGrade: "user",
      action: "approve",
      actorType: "user",
    }),
    "published",
  );
  // user 등급은 pending_user 이전이나 직원 승인으로는 게시되지 않는다.
  assert.throws(
    () =>
      wikiProposalActionOutcome({
        state: "drafted",
        approvalGrade: "user",
        action: "approve",
        actorType: "user",
      }),
    (error) => error instanceof WikiKnowledgeError && error.statusCode === 409,
  );
  assert.throws(
    () =>
      wikiProposalActionOutcome({
        state: "pending_user",
        approvalGrade: "user",
        action: "approve",
        actorType: "character",
      }),
    (error) => error instanceof WikiKnowledgeError && error.statusCode === 403,
  );
  assert.throws(
    () =>
      wikiProposalActionOutcome({
        state: "drafted",
        approvalGrade: "peer",
        action: "approve",
      }),
    (error) => error instanceof WikiKnowledgeError && error.statusCode === 409,
  );
});

test("전이 판정표 — 거절은 종결 전 상태에서만 가능하다", () => {
  for (const state of ["candidate", "drafted", "peer_verified", "pending_user"]) {
    assert.equal(
      wikiProposalActionOutcome({
        state,
        approvalGrade: "peer",
        action: "reject",
      }),
      "rejected",
    );
  }
  for (const state of ["published", "rejected", "conflict"]) {
    assert.throws(
      () =>
        wikiProposalActionOutcome({
          state,
          approvalGrade: "peer",
          action: "reject",
        }),
      (error) => error instanceof WikiKnowledgeError && error.statusCode === 409,
    );
  }
});

test("위키 mutation 라우트는 trustedJSONMutation을 거친다", () => {
  const serverSource = readFileSync(
    new URL("../src/server.mjs", import.meta.url),
    "utf8",
  );
  for (const handler of [
    "async function createWikiProposalEndpoint",
    "async function wikiProposalActionEndpoint",
  ]) {
    const body = serverSource.slice(serverSource.indexOf(handler));
    assert.ok(
      body.indexOf("trustedJSONMutation(request, response)") >= 0 &&
        body.indexOf("trustedJSONMutation(request, response)") <
          body.indexOf("readJSON(request)"),
      `${handler}는 본문을 읽기 전에 출처를 확인해야 합니다.`,
    );
  }
  const approvalHandler = serverSource.slice(
    serverSource.indexOf("async function wikiProposalActionEndpoint"),
    serverSource.indexOf("async function searchRAG"),
  );
  assert.match(approvalHandler, /actorType:\s*"user"/);
  assert.doesNotMatch(approvalHandler, /body\.actor/);
  assert.match(approvalHandler, /x-officestra-user-decision/);
  assert.match(
    approvalHandler,
    /사내 위키 화면에서 사용자가 직접 결정해야 합니다/,
  );
  const deleteHandler = serverSource.slice(
    serverSource.indexOf("async function deleteWikiPageEndpoint"),
    serverSource.indexOf("async function wikiProposalsEndpoint"),
  );
  assert.match(deleteHandler, /trustedJSONMutation\(request, response\)/);
  assert.match(deleteHandler, /x-officestra-user-decision/);
  assert.match(deleteHandler, /`delete:\$\{pageID\}`/);
  assert.match(deleteHandler, /archiveWikiPage\(/);
  assert.match(
    serverSource,
    /request\.method === "DELETE" &&\s*routeWikiPage\(url\.pathname\)/,
  );
});

test("021·022 마이그레이션은 검색 분리와 기존 DB 업그레이드를 함께 보장한다", () => {
  const migrationSource = readFileSync(
    new URL(
      "../../database/migrations/021_wiki_knowledge.sql",
      import.meta.url,
    ),
    "utf8",
  );
  assert.ok(
    migrationSource.includes("CREATE OR REPLACE VIEW searchable_rag_documents") &&
      migrationSource.includes("record.record_type = 'synthesis'"),
    "searchable_rag_documents가 synthesis 파생 문서를 제외해야 합니다.",
  );
  assert.ok(
    migrationSource.includes(
      "CREATE OR REPLACE VIEW searchable_wiki_page_documents",
    ),
    "위키 전용 검색 뷰가 필요합니다.",
  );
  assert.ok(
    migrationSource.includes("work_records_synthesis_page_key_idx"),
    "synthesis pageKey는 프로젝트별 유일해야 합니다.",
  );
  const runtimeMigrationSource = readFileSync(
    new URL("../../database/migrations/022_wiki_proposal_runtime.sql", import.meta.url),
    "utf8",
  );
  assert.ok(
    runtimeMigrationSource.includes("ADD COLUMN IF NOT EXISTS proposal_kind") &&
      runtimeMigrationSource.includes("wiki_proposals_turn_ordinal_idx") &&
      runtimeMigrationSource.includes("ALTER COLUMN proposal_kind SET NOT NULL"),
    "이미 021이 적용된 DB도 종류와 순번 멱등 키를 추가해야 합니다.",
  );
});

test(
  "격리 PostgreSQL — 제안 생성·검증·승인·게시·CAS 충돌·검색 분리",
  { skip: !databaseURL },
  async () => {
    const pool = new Pool({ connectionString: databaseURL });
    const client = await pool.connect();
    const suffix = randomUUID().slice(0, 8);
    const repositoryRoot = `/tmp/wiki-test-${suffix}`;
    const authorID = `wiki-author-${suffix}`;
    const reviewerID = `wiki-reviewer-${suffix}`;
    const pageKey = `incident-${suffix}`;
    let projectID = null;
    let otherProjectID = null;
    try {
      for (const characterID of [authorID, reviewerID]) {
        await client.query(
          `
            INSERT INTO characters (
              id, name, seat, backend, model, effort, permission,
              identity_prompt, config
            )
            VALUES ($1, $1, '격리 좌석', 'codex', 'gpt-5.6-sol', 'high',
              'workspace-write', '', '{}'::jsonb)
            ON CONFLICT (id) DO NOTHING
          `,
          [characterID],
        );
      }
      const project = await client.query(
        `
          INSERT INTO projects (name, repository_root)
          VALUES ($1, $2)
          RETURNING id
        `,
        [`wiki-test-${suffix}`, repositoryRoot],
      );
      projectID = project.rows[0].id;
      const otherProject = await client.query(
        `
          INSERT INTO projects (name, repository_root)
          VALUES ($1, $2)
          RETURNING id
        `,
        [`wiki-test-other-${suffix}`, `${repositoryRoot}-other`],
      );
      otherProjectID = otherProject.rows[0].id;

      async function insertSourceRecord(ownerProjectID, title) {
        const inserted = await client.query(
          `
            INSERT INTO work_records (
              project_id, record_type, lifecycle_state, title, body,
              character_id, attribution, metadata
            )
            VALUES ($1, 'result', 'active', $2, '근거 본문', $3,
              'character', '{}'::jsonb)
            RETURNING id
          `,
          [ownerProjectID, title, authorID],
        );
        return inserted.rows[0].id;
      }
      const sourceA = await insertSourceRecord(projectID, "근거 A");
      const sourceB = await insertSourceRecord(projectID, "근거 B");
      const foreignSource = await insertSourceRecord(otherProjectID, "외부 근거");

      // 1) peer 등급 수명주기: drafted → peer_verified → published v1.
      const created = await createWikiProposal(client, {
        projectId: projectID,
        pageKey,
        kind: "incident",
        approvalGrade: "peer",
        draftTitle: "침해 사건 요약",
        draftBody: "SSH root 침해와 채굴기 제거 사건의 합의본.",
        sourceWorkRecordIds: [sourceA, sourceB],
        authorCharacterId: authorID,
      });
      assert.equal(created.state, "drafted");
      assert.equal(created.pageKey, pageKey);
      assert.equal(created.kind, "incident");
      assert.equal(created.approvalTier, "peer");
      assert.deepEqual(
        [...created.sourceRecordIds].sort(),
        [sourceA, sourceB].sort(),
      );
      assert.equal(created.baseVersion, 0);

      await assert.rejects(
        verifyWikiProposal(client, {
          proposalID: created.id,
          verifierCharacterID: authorID,
        }),
        (error) =>
          error instanceof WikiKnowledgeError && error.statusCode === 403,
      );
      const verified = await verifyWikiProposal(client, {
        proposalID: created.id,
        verifierCharacterID: reviewerID,
      });
      assert.equal(verified.state, "peer_verified");
      assert.equal(verified.verifierCharacterId, reviewerID);

      const approved = await approveWikiProposal(client, {
        proposalID: created.id,
        actorType: "character",
        actorCharacterID: reviewerID,
      });
      assert.equal(approved.conflicted, false);
      assert.equal(approved.proposal.state, "published");
      const pageID = approved.proposal.targetRecordId;
      assert.ok(pageID);

      const page = await getWikiPage(client, pageID);
      assert.equal(page.pageKey, pageKey);
      assert.equal(page.kind, "incident");
      assert.equal(page.version, 1);
      assert.deepEqual(
        page.sources.map((source) => source.workRecordId).sort(),
        [sourceA, sourceB].sort(),
      );

      // 게시본만 RAG에 파생되고, 원본 검색에서는 제외되며 위키 뷰에는
      // 나타난다.
      const ragRow = await client.query(
        "SELECT id FROM rag_documents WHERE work_record_id = $1",
        [pageID],
      );
      assert.equal(ragRow.rows.length, 1);
      const inRecordSearch = await client.query(
        "SELECT 1 FROM searchable_rag_documents WHERE work_record_id = $1",
        [pageID],
      );
      assert.equal(inRecordSearch.rows.length, 0);
      const inWikiSearch = await client.query(
        "SELECT 1 FROM searchable_wiki_page_documents WHERE work_record_id = $1",
        [pageID],
      );
      assert.equal(inWikiSearch.rows.length, 1);
      const searched = await listWikiPages(client, { query: "침해 사건" });
      assert.ok(searched.some((row) => row.id === pageID));
      assert.deepEqual(
        await listWikiPages(client, {
          repositoryRoot: `${repositoryRoot}-other`,
        }),
        [],
      );
      assert.equal(
        await getWikiPage(client, pageID, {
          repositoryRoot: `${repositoryRoot}-other`,
        }),
        null,
      );

      // 2) auto 등급 재게시: base 1 → published v2.
      const second = await createWikiProposal(client, {
        projectId: projectID,
        pageKey,
        kind: "incident",
        approvalGrade: "auto",
        draftTitle: "침해 사건 요약",
        draftBody: "재부팅 후 점검 결과를 추가한 개정본.",
        sourceWorkRecordIds: [sourceA],
        authorCharacterId: authorID,
      });
      assert.equal(second.baseVersion, 1);
      const secondApproved = await approveWikiProposal(client, {
        proposalID: second.id,
        actorType: "system",
      });
      assert.equal(secondApproved.proposal.state, "published");
      const revised = await getWikiPage(client, pageID);
      assert.equal(revised.version, 2);
      assert.ok(revised.body.includes("재부팅"));
      assert.deepEqual(
        revised.sources.map((source) => source.workRecordId),
        [sourceA],
      );

      // 3) 낡은 base version은 게시되지 않고 conflict로 종결된다.
      const stale = await createWikiProposal(client, {
        projectId: projectID,
        pageKey,
        kind: "incident",
        approvalGrade: "auto",
        draftTitle: "낡은 개정",
        draftBody: "버전 1 기준으로 작성된 초안.",
        sourceWorkRecordIds: [sourceB],
        authorCharacterId: authorID,
        baseVersion: 1,
      });
      const staleOutcome = await approveWikiProposal(client, {
        proposalID: stale.id,
        actorType: "system",
      });
      assert.equal(staleOutcome.conflicted, true);
      assert.equal(staleOutcome.proposal.state, "conflict");
      const unchanged = await getWikiPage(client, pageID);
      assert.equal(unchanged.version, 2);
      assert.ok(unchanged.body.includes("재부팅"));

      // 4) user 등급은 pending_user에서 사용자만 게시할 수 있다.
      const userGrade = await createWikiProposal(client, {
        projectId: projectID,
        pageKey,
        kind: "incident",
        approvalGrade: "user",
        draftTitle: "침해 사건 요약",
        draftBody: "사용자 선호를 반영한 개정본.",
        sourceWorkRecordIds: [sourceA, sourceB],
        authorCharacterId: authorID,
      });
      const pendingUser = await verifyWikiProposal(client, {
        proposalID: userGrade.id,
        verifierCharacterID: reviewerID,
      });
      assert.equal(pendingUser.state, "pending_user");
      await assert.rejects(
        approveWikiProposal(client, {
          proposalID: userGrade.id,
          actorType: "character",
          actorCharacterID: reviewerID,
        }),
        (error) =>
          error instanceof WikiKnowledgeError && error.statusCode === 403,
      );
      const userApproved = await approveWikiProposal(client, {
        proposalID: userGrade.id,
        actorType: "user",
      });
      assert.equal(userApproved.proposal.state, "published");
      assert.equal((await getWikiPage(client, pageID)).version, 3);

      // 5) 근거 규칙: 자기참조(synthesis)와 다른 프로젝트 근거는 거부.
      await assert.rejects(
        createWikiProposal(client, {
          projectId: projectID,
          pageKey: `self-${suffix}`,
          kind: "incident",
          approvalGrade: "auto",
          draftTitle: "자기참조",
          sourceWorkRecordIds: [pageID],
          authorCharacterId: authorID,
        }),
        (error) =>
          error instanceof WikiKnowledgeError && error.statusCode === 422,
      );
      await assert.rejects(
        createWikiProposal(client, {
          projectId: projectID,
          pageKey: `foreign-${suffix}`,
          kind: "incident",
          approvalGrade: "auto",
          draftTitle: "외부 근거",
          sourceWorkRecordIds: [foreignSource],
          authorCharacterId: authorID,
        }),
        (error) =>
          error instanceof WikiKnowledgeError && error.statusCode === 422,
      );
      await assert.rejects(
        createWikiProposal(client, {
          projectId: projectID,
          pageKey: `empty-${suffix}`,
          kind: "incident",
          approvalGrade: "auto",
          draftTitle: "근거 없음",
          sourceWorkRecordIds: [],
          authorCharacterId: authorID,
        }),
        (error) => error instanceof WikiKnowledgeError,
      );

      const unapprovedSource = await client.query(
        `
          INSERT INTO work_records (
            project_id, record_type, lifecycle_state, title, body,
            character_id, attribution, metadata
          )
          VALUES (
            $1, 'result', 'active', '승인 전 근거', '검토 대기 본문', $2,
            'character',
            '{"review":{"status":"awaiting_approval"}}'::jsonb
          )
          RETURNING id
        `,
        [projectID, authorID],
      );
      const blockedPublish = await createWikiProposal(client, {
        projectId: projectID,
        pageKey: `unapproved-${suffix}`,
        kind: "decision",
        approvalGrade: "auto",
        draftTitle: "승인 전 게시 금지",
        sourceWorkRecordIds: [unapprovedSource.rows[0].id],
        authorCharacterId: authorID,
      });
      await assert.rejects(
        approveWikiProposal(client, {
          proposalID: blockedPublish.id,
          actorType: "system",
        }),
        (error) =>
          error instanceof WikiKnowledgeError && error.statusCode === 422,
      );

      // 6) 초안은 work_records를 만들지 않으므로 어떤 검색에도 없다.
      const draftOnly = await createWikiProposal(client, {
        projectId: projectID,
        pageKey: `draft-only-${suffix}`,
        kind: "decision",
        approvalGrade: "peer",
        draftTitle: "초안 전용",
        draftBody: "게시 전 초안 본문",
        sourceWorkRecordIds: [sourceA],
        authorCharacterId: authorID,
      });
      const draftPages = await client.query(
        `
          SELECT 1 FROM work_records
          WHERE record_type = 'synthesis'
            AND metadata->>'pageKey' = $1
        `,
        [`draft-only-${suffix}`],
      );
      assert.equal(draftPages.rows.length, 0);

      // 7) 거절과 종결 후 재조작 금지.
      const rejected = await rejectWikiProposal(client, {
        proposalID: draftOnly.id,
        reason: "초안 품질 미달",
      });
      assert.equal(rejected.state, "rejected");
      assert.equal(rejected.reason, "초안 품질 미달");
      await assert.rejects(
        verifyWikiProposal(client, {
          proposalID: draftOnly.id,
          verifierCharacterID: reviewerID,
        }),
        (error) =>
          error instanceof WikiKnowledgeError && error.statusCode === 409,
      );

      const proposals = await listWikiProposals(client, {
        state: "published",
      });
      assert.ok(proposals.some((row) => row.id === created.id));

      // 8) 사용자 삭제: archived로 바뀌어 목록·검색·단건 조회에서 사라지고,
      //    같은 키의 제안이 다시 승인되면 active로 돌아온다.
      const archived = await archiveWikiPage(client, { pageID });
      assert.equal(archived.lifecycleState, "archived");
      assert.equal(await getWikiPage(client, pageID), null);
      assert.ok(
        !(await listWikiPages(client)).some((row) => row.id === pageID),
      );
      assert.ok(
        !(await listWikiPages(client, { query: "침해 사건" })).some(
          (row) => row.id === pageID,
        ),
      );
      await assert.rejects(
        archiveWikiPage(client, { pageID }),
        (error) =>
          error instanceof WikiKnowledgeError && error.statusCode === 404,
      );
      const archivedEvents = await client.query(
        `
          SELECT event_type, actor_type, next_value
          FROM work_record_events
          WHERE record_id = $1
          ORDER BY record_version DESC
          LIMIT 1
        `,
        [pageID],
      );
      assert.equal(archivedEvents.rows[0].event_type, "state_changed");
      assert.equal(archivedEvents.rows[0].actor_type, "user");
      assert.equal(archivedEvents.rows[0].next_value.lifecycleState, "archived");

      const revival = await createWikiProposal(client, {
        projectId: projectID,
        pageKey,
        kind: "incident",
        approvalGrade: "auto",
        draftTitle: "삭제 뒤 다시 게시",
        draftBody: "다시 살아난 본문",
        sourceWorkRecordIds: [sourceA],
        authorCharacterId: authorID,
        baseVersion: 4,
      });
      const revived = await approveWikiProposal(client, {
        proposalID: revival.id,
        actorType: "system",
      });
      assert.equal(revived.proposal.state, "published");
      assert.equal((await getWikiPage(client, pageID))?.title, "삭제 뒤 다시 게시");
    } finally {
      await client.query(
        "DELETE FROM wiki_proposals WHERE project_id = ANY($1::uuid[])",
        [[projectID, otherProjectID].filter(Boolean)],
      );
      await client.query(
        `
          DELETE FROM work_record_links
          WHERE source_record_id IN (
            SELECT id FROM work_records WHERE project_id = ANY($1::uuid[])
          )
        `,
        [[projectID, otherProjectID].filter(Boolean)],
      );
      await client.query(
        `
          DELETE FROM work_record_events
          WHERE record_id IN (
            SELECT id FROM work_records WHERE project_id = ANY($1::uuid[])
          )
        `,
        [[projectID, otherProjectID].filter(Boolean)],
      );
      await client.query(
        "DELETE FROM work_records WHERE project_id = ANY($1::uuid[])",
        [[projectID, otherProjectID].filter(Boolean)],
      );
      await client.query(
        "DELETE FROM projects WHERE id = ANY($1::uuid[])",
        [[projectID, otherProjectID].filter(Boolean)],
      );
      await client.query(
        "DELETE FROM characters WHERE id = ANY($1::text[])",
        [[authorID, reviewerID]],
      );
      client.release();
      await pool.end();
    }
  },
);
