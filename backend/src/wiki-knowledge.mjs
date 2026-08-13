// 이 파일은 승인형 사내 위키의 페이지 조회와 제안 수명주기를 담당한다.

import { workRecordSearchTSQuery } from "./work-record-memory.mjs";
import { syncWorkRecordRAGDocuments } from "./work-record-memory.mjs";

export const WIKI_PROPOSAL_STATES = Object.freeze([
  "candidate",
  "drafted",
  "peer_verified",
  "pending_user",
  "published",
  "rejected",
  "conflict",
]);

export const WIKI_APPROVAL_GRADES = Object.freeze(["auto", "peer", "user"]);

const TERMINAL_STATES = new Set(["published", "rejected", "conflict"]);
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export class WikiKnowledgeError extends Error {
  constructor(message, { statusCode = 400 } = {}) {
    super(message);
    this.name = "WikiKnowledgeError";
    this.statusCode = statusCode;
  }
}

function invalid(message, statusCode = 400) {
  return new WikiKnowledgeError(message, { statusCode });
}

// 페이지 키는 프로젝트 안에서 주제를 가리키는 안정 식별자다.
// 대소문자·공백 변형이 서로 다른 페이지를 만들지 않게 정규화한다.
export function normalizedWikiPageKey(value) {
  const normalized = String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/[\s_]+/g, "-")
    .replace(/[^\p{L}\p{N}-]+/gu, "")
    .replace(/-{2,}/g, "-")
    .replace(/^-+|-+$/g, "");
  if (!normalized || normalized.length > 120) {
    throw invalid("pageKey는 1~120자의 문자·숫자·하이픈이어야 합니다.");
  }
  return normalized;
}

export function normalizedSourceWorkRecordIDs(value, { required }) {
  if (value == null) {
    if (required) {
      throw invalid("source workRecord ID가 최소 1개 필요합니다.");
    }
    return [];
  }
  if (!Array.isArray(value)) {
    throw invalid("sourceWorkRecordIds는 배열이어야 합니다.");
  }
  const unique = [];
  for (const entry of value) {
    const id = String(entry ?? "").trim().toLowerCase();
    if (!UUID_PATTERN.test(id)) {
      throw invalid("sourceWorkRecordIds에 올바르지 않은 UUID가 있습니다.");
    }
    if (!unique.includes(id)) {
      unique.push(id);
    }
  }
  if (required && unique.length === 0) {
    throw invalid("source workRecord ID가 최소 1개 필요합니다.");
  }
  return unique;
}

// 상태 전이 규칙의 단일 판정 지점. DB 없이 검증 가능하도록 순수
// 함수로 유지한다. 반환은 다음 상태, 위반은 예외다.
export function wikiProposalActionOutcome({
  state,
  approvalGrade,
  action,
  actorType = "character",
  authorCharacterID = null,
  actorCharacterID = null,
}) {
  if (!WIKI_PROPOSAL_STATES.includes(state)) {
    throw invalid(`알 수 없는 제안 상태입니다. ${state}`);
  }
  if (!WIKI_APPROVAL_GRADES.includes(approvalGrade)) {
    throw invalid(`알 수 없는 승인 등급입니다. ${approvalGrade}`);
  }
  if (action === "reject") {
    if (TERMINAL_STATES.has(state)) {
      throw invalid("이미 종결된 제안은 거절할 수 없습니다.", 409);
    }
    return "rejected";
  }
  if (action === "verify") {
    if (state !== "drafted") {
      throw invalid("drafted 상태의 제안만 검증할 수 있습니다.", 409);
    }
    if (approvalGrade === "auto") {
      throw invalid("auto 등급 제안은 검증 없이 승인합니다.", 409);
    }
    if (!actorCharacterID) {
      throw invalid("검증에는 characterId가 필요합니다.");
    }
    if (
      approvalGrade === "peer" &&
      authorCharacterID != null &&
      actorCharacterID === authorCharacterID
    ) {
      throw invalid("peer 등급은 작성자가 스스로 검증할 수 없습니다.", 403);
    }
    return approvalGrade === "user" ? "pending_user" : "peer_verified";
  }
  if (action === "approve") {
    if (approvalGrade === "auto") {
      if (state !== "drafted") {
        throw invalid("auto 등급은 drafted 상태에서만 승인합니다.", 409);
      }
      return "published";
    }
    if (approvalGrade === "peer") {
      if (state !== "peer_verified") {
        throw invalid("peer 등급은 검증 완료 후에만 승인합니다.", 409);
      }
      return "published";
    }
    if (state !== "pending_user") {
      throw invalid("user 등급은 pending_user 상태에서만 승인합니다.", 409);
    }
    if (actorType !== "user") {
      throw invalid("user 등급 제안은 사용자만 승인할 수 있습니다.", 403);
    }
    return "published";
  }
  throw invalid(`알 수 없는 동작입니다. ${action}`);
}

function proposalDTO(row) {
  return {
    id: row.id,
    projectId: row.project_id,
    pageKey: row.page_key,
    targetRecordId: row.target_record_id,
    baseVersion: row.base_version,
    state: row.state,
    approvalGrade: row.approval_grade,
    draftTitle: row.draft_title,
    draftBody: row.draft_body,
    sourceWorkRecordIds: Array.isArray(row.source_work_record_ids)
      ? row.source_work_record_ids
      : [],
    authorCharacterId: row.author_character_id,
    authorTurnId: row.author_turn_id,
    verifierCharacterId: row.verifier_character_id,
    reason: row.reason,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    verifiedAt: row.verified_at,
    resolvedAt: row.resolved_at,
  };
}

const PAGE_SELECT = `
  SELECT
    record.id,
    record.project_id AS "projectId",
    project.name AS "projectName",
    record.metadata->>'pageKey' AS "pageKey",
    record.title,
    record.body,
    record.character_id AS "characterId",
    record.recorded_at AS "recordedAt",
    record.updated_at AS "updatedAt",
    COALESCE(
      (
        SELECT MAX(event.record_version)
        FROM work_record_events AS event
        WHERE event.record_id = record.id
      ),
      0
    ) AS version,
    COALESCE(
      (
        SELECT json_agg(link.target_record_id ORDER BY link.created_at, link.target_record_id)
        FROM work_record_links AS link
        WHERE link.source_record_id = record.id
          AND link.relation = 'derived_from'
      ),
      '[]'::json
    ) AS "sourceWorkRecordIds"
  FROM work_records AS record
  JOIN projects AS project ON project.id = record.project_id
`;

export async function listWikiPages(client, { query = null, limit = 20 } = {}) {
  const boundedLimit = Math.min(Math.max(Number(limit) || 20, 1), 100);
  if (query) {
    const tsQuery = workRecordSearchTSQuery(query);
    if (!tsQuery) {
      return [];
    }
    const result = await client.query(
      `
        ${PAGE_SELECT}
        JOIN searchable_wiki_page_documents AS document
          ON document.work_record_id = record.id
        WHERE document.search_document @@ to_tsquery('simple', $1)
        ORDER BY ts_rank(document.search_document, to_tsquery('simple', $1)) DESC,
          record.updated_at DESC
        LIMIT $2
      `,
      [tsQuery, boundedLimit],
    );
    return result.rows;
  }
  const result = await client.query(
    `
      ${PAGE_SELECT}
      WHERE record.record_type = 'synthesis'
        AND record.lifecycle_state = 'active'
      ORDER BY record.updated_at DESC
      LIMIT $1
    `,
    [boundedLimit],
  );
  return result.rows;
}

export async function getWikiPage(client, pageID) {
  const result = await client.query(
    `
      ${PAGE_SELECT}
      WHERE record.id = $1
        AND record.record_type = 'synthesis'
    `,
    [pageID],
  );
  return result.rows[0] ?? null;
}

export async function listWikiProposals(client, { state = null } = {}) {
  if (state != null && !WIKI_PROPOSAL_STATES.includes(state)) {
    throw invalid(`알 수 없는 제안 상태입니다. ${state}`);
  }
  const result = await client.query(
    `
      SELECT *
      FROM wiki_proposals
      WHERE $1::text IS NULL OR state = $1
      ORDER BY updated_at DESC
      LIMIT 200
    `,
    [state],
  );
  return result.rows.map(proposalDTO);
}

async function resolveProjectID(client, { projectId = null, repositoryRoot = null }) {
  if (projectId != null) {
    const result = await client.query(
      "SELECT id FROM projects WHERE id = $1",
      [projectId],
    );
    if (result.rows.length === 0) {
      throw invalid("프로젝트를 찾을 수 없습니다.", 404);
    }
    return result.rows[0].id;
  }
  if (repositoryRoot != null) {
    const result = await client.query(
      "SELECT id FROM projects WHERE repository_root = $1",
      [repositoryRoot],
    );
    if (result.rows.length === 0) {
      throw invalid("프로젝트를 찾을 수 없습니다.", 404);
    }
    return result.rows[0].id;
  }
  throw invalid("projectId 또는 repositoryRoot가 필요합니다.");
}

async function lockWikiPage(client, projectID, pageKey) {
  const result = await client.query(
    `
      SELECT
        record.id,
        record.title,
        record.body,
        COALESCE(
          (
            SELECT MAX(event.record_version)
            FROM work_record_events AS event
            WHERE event.record_id = record.id
          ),
          0
        ) AS version
      FROM work_records AS record
      WHERE record.project_id = $1
        AND record.record_type = 'synthesis'
        AND record.metadata->>'pageKey' = $2
      FOR UPDATE OF record
    `,
    [projectID, pageKey],
  );
  return result.rows[0] ?? null;
}

// 근거 검증은 publish의 유일한 사실 관문이다. 근거가 없거나, 다른
// 프로젝트이거나, 위키 페이지(synthesis)를 근거로 삼는 자기참조는
// 전부 거부한다.
async function assertPublishableSources(client, projectID, sourceIDs) {
  if (sourceIDs.length === 0) {
    throw invalid("근거 workRecord 없이 게시할 수 없습니다.", 422);
  }
  const result = await client.query(
    `
      SELECT id, project_id, record_type
      FROM work_records
      WHERE id = ANY($1::uuid[])
    `,
    [sourceIDs],
  );
  const byID = new Map(result.rows.map((row) => [row.id, row]));
  for (const sourceID of sourceIDs) {
    const row = byID.get(sourceID);
    if (!row) {
      throw invalid(`근거 workRecord가 없습니다. ${sourceID}`, 422);
    }
    if (row.project_id !== projectID) {
      throw invalid(`다른 프로젝트의 workRecord는 근거가 될 수 없습니다. ${sourceID}`, 422);
    }
    if (row.record_type === "synthesis") {
      throw invalid(`위키 페이지는 위키의 근거가 될 수 없습니다. ${sourceID}`, 422);
    }
  }
}

export async function createWikiProposal(client, {
  projectId = null,
  repositoryRoot = null,
  pageKey,
  approvalGrade,
  state = "drafted",
  draftTitle,
  draftBody = "",
  sourceWorkRecordIds = null,
  authorCharacterId = null,
  authorTurnId = null,
  baseVersion = null,
} = {}) {
  if (!["candidate", "drafted"].includes(state)) {
    throw invalid("생성 상태는 candidate 또는 drafted만 허용합니다.");
  }
  if (!WIKI_APPROVAL_GRADES.includes(approvalGrade)) {
    throw invalid(`알 수 없는 승인 등급입니다. ${approvalGrade}`);
  }
  const title = String(draftTitle ?? "").trim();
  if (!title) {
    throw invalid("draftTitle이 필요합니다.");
  }
  if (approvalGrade === "peer" && !authorCharacterId) {
    throw invalid("peer 등급 제안에는 authorCharacterId가 필요합니다.");
  }
  const normalizedKey = normalizedWikiPageKey(pageKey);
  const sources = normalizedSourceWorkRecordIDs(sourceWorkRecordIds, {
    required: state === "drafted",
  });
  const projectID = await resolveProjectID(client, {
    projectId,
    repositoryRoot,
  });
  if (sources.length > 0) {
    await assertPublishableSources(client, projectID, sources);
  }

  const page = await client.query(
    `
      SELECT
        record.id,
        COALESCE(
          (
            SELECT MAX(event.record_version)
            FROM work_record_events AS event
            WHERE event.record_id = record.id
          ),
          0
        ) AS version
      FROM work_records AS record
      WHERE record.project_id = $1
        AND record.record_type = 'synthesis'
        AND record.metadata->>'pageKey' = $2
    `,
    [projectID, normalizedKey],
  );
  const targetRecordID = page.rows[0]?.id ?? null;
  const currentVersion = page.rows[0]?.version ?? 0;
  const requestedBase = baseVersion == null ? currentVersion : Number(baseVersion);
  if (!Number.isInteger(requestedBase) || requestedBase < 0) {
    throw invalid("baseVersion은 0 이상의 정수여야 합니다.");
  }

  const result = await client.query(
    `
      INSERT INTO wiki_proposals (
        project_id,
        page_key,
        target_record_id,
        base_version,
        state,
        approval_grade,
        draft_title,
        draft_body,
        source_work_record_ids,
        author_character_id,
        author_turn_id
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10, $11)
      RETURNING *
    `,
    [
      projectID,
      normalizedKey,
      targetRecordID,
      requestedBase,
      state,
      approvalGrade,
      title,
      String(draftBody ?? ""),
      JSON.stringify(sources),
      authorCharacterId,
      authorTurnId,
    ],
  );
  return proposalDTO(result.rows[0]);
}

async function lockWikiProposal(client, proposalID) {
  const result = await client.query(
    "SELECT * FROM wiki_proposals WHERE id = $1 FOR UPDATE",
    [proposalID],
  );
  if (result.rows.length === 0) {
    throw invalid("제안을 찾을 수 없습니다.", 404);
  }
  return result.rows[0];
}

export async function verifyWikiProposal(client, {
  proposalID,
  verifierCharacterID = null,
}) {
  const proposal = await lockWikiProposal(client, proposalID);
  const nextState = wikiProposalActionOutcome({
    state: proposal.state,
    approvalGrade: proposal.approval_grade,
    action: "verify",
    actorCharacterID: verifierCharacterID,
    authorCharacterID: proposal.author_character_id,
  });
  const result = await client.query(
    `
      UPDATE wiki_proposals
      SET state = $2,
        verifier_character_id = $3,
        verified_at = now(),
        updated_at = now()
      WHERE id = $1
      RETURNING *
    `,
    [proposalID, nextState, verifierCharacterID],
  );
  return proposalDTO(result.rows[0]);
}

export async function rejectWikiProposal(client, {
  proposalID,
  reason = null,
}) {
  const proposal = await lockWikiProposal(client, proposalID);
  wikiProposalActionOutcome({
    state: proposal.state,
    approvalGrade: proposal.approval_grade,
    action: "reject",
  });
  const result = await client.query(
    `
      UPDATE wiki_proposals
      SET state = 'rejected',
        reason = $2,
        resolved_at = now(),
        updated_at = now()
      WHERE id = $1
      RETURNING *
    `,
    [proposalID, reason],
  );
  return proposalDTO(result.rows[0]);
}

async function markProposalConflict(client, proposalID, reason) {
  const result = await client.query(
    `
      UPDATE wiki_proposals
      SET state = 'conflict',
        reason = $2,
        resolved_at = now(),
        updated_at = now()
      WHERE id = $1
      RETURNING *
    `,
    [proposalID, reason],
  );
  return proposalDTO(result.rows[0]);
}

// 승인은 전이 판정과 게시를 한 트랜잭션에서 끝낸다. base version이
// 현재 페이지 버전과 다르면 게시하지 않고 conflict로 종결한다.
export async function approveWikiProposal(client, {
  proposalID,
  actorType = "character",
  actorCharacterID = null,
}) {
  const proposal = await lockWikiProposal(client, proposalID);
  wikiProposalActionOutcome({
    state: proposal.state,
    approvalGrade: proposal.approval_grade,
    action: "approve",
    actorType,
    actorCharacterID,
    authorCharacterID: proposal.author_character_id,
  });

  const sources = normalizedSourceWorkRecordIDs(
    proposal.source_work_record_ids,
    { required: true },
  );
  await assertPublishableSources(client, proposal.project_id, sources);

  const page = await lockWikiPage(
    client,
    proposal.project_id,
    proposal.page_key,
  );
  const currentVersion = page?.version ?? 0;
  if (currentVersion !== proposal.base_version) {
    const conflicted = await markProposalConflict(
      client,
      proposalID,
      `기준 버전 ${proposal.base_version}이(가) 현재 버전 ${currentVersion}과 다릅니다.`,
    );
    return { proposal: conflicted, conflicted: true };
  }

  let pageID = page?.id ?? null;
  if (pageID == null) {
    const inserted = await client.query(
      `
        INSERT INTO work_records (
          project_id,
          record_type,
          lifecycle_state,
          title,
          body,
          character_id,
          attribution,
          metadata
        )
        VALUES ($1, 'synthesis', 'active', $2, $3, $4, 'character',
          jsonb_build_object('pageKey', $5::text))
        RETURNING id
      `,
      [
        proposal.project_id,
        proposal.draft_title,
        proposal.draft_body,
        proposal.author_character_id,
        proposal.page_key,
      ],
    );
    pageID = inserted.rows[0].id;
  } else {
    await client.query(
      `
        UPDATE work_records
        SET title = $2,
          body = $3,
          updated_at = now()
        WHERE id = $1
      `,
      [pageID, proposal.draft_title, proposal.draft_body],
    );
  }

  await client.query(
    `
      INSERT INTO work_record_events (
        record_id,
        record_version,
        event_type,
        actor_character_id,
        actor_type,
        source_turn_id,
        previous_value,
        next_value
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, $8::jsonb)
    `,
    [
      pageID,
      currentVersion + 1,
      page == null ? "created" : "updated",
      actorCharacterID,
      actorType,
      proposal.author_turn_id,
      page == null
        ? null
        : JSON.stringify({ title: page.title, body: page.body }),
      JSON.stringify({
        title: proposal.draft_title,
        body: proposal.draft_body,
      }),
    ],
  );

  await client.query(
    `
      DELETE FROM work_record_links
      WHERE source_record_id = $1
        AND relation = 'derived_from'
    `,
    [pageID],
  );
  for (const sourceID of sources) {
    await client.query(
      `
        INSERT INTO work_record_links (
          source_record_id,
          target_record_id,
          relation
        )
        VALUES ($1, $2, 'derived_from')
        ON CONFLICT DO NOTHING
      `,
      [pageID, sourceID],
    );
  }

  await syncWorkRecordRAGDocuments(client, { workRecordID: pageID });

  const result = await client.query(
    `
      UPDATE wiki_proposals
      SET state = 'published',
        target_record_id = $2,
        resolved_at = now(),
        updated_at = now()
      WHERE id = $1
      RETURNING *
    `,
    [proposalID, pageID],
  );
  return { proposal: proposalDTO(result.rows[0]), conflicted: false };
}

// 동시 게시 경합으로 page_key 유니크 제약이 터지면 트랜잭션이
// 중단되므로, 새 트랜잭션에서 제안을 conflict로 종결할 때 쓴다.
export function isWikiPageKeyRaceError(error) {
  return (
    error != null &&
    typeof error === "object" &&
    error.code === "23505" &&
    String(error.constraint ?? "").includes("synthesis_page_key")
  );
}

export async function resolveWikiPageKeyRace(client, proposalID) {
  return await markProposalConflict(
    client,
    proposalID,
    "같은 pageKey의 페이지가 동시에 게시됐습니다.",
  );
}
