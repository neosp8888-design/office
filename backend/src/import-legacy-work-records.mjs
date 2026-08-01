// 이 파일은 v1.0.0 작업 기록을 검증해 PostgreSQL로 한 번만 이관한다.

import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export const LEGACY_SOURCE_COMMIT =
  "50dbd10d7ba675bfd0ddcfaa2d1bbdea580211a8";
export const LEGACY_PARSER_VERSION = "legacy-work-records-v1";
export const LEGACY_SOURCE_FILES = Object.freeze([
  Object.freeze({
    path: "checklist.md",
    sha256: "ab262339307d7ad1435a0851497fb44ce78ffd027879a385c250a802921ecf6c",
    recordType: "task",
    sections: 155,
  }),
  Object.freeze({
    path: "context-notes.md",
    sha256: "bfc45e248dd13ec3244739f1cf557b57b76c0bc296f971ac188548110f382228",
    recordType: "note",
    sections: 76,
  }),
]);
export const LEGACY_EXPECTED_COUNTS = Object.freeze({
  records: 231,
  checklistSections: 155,
  contextNotesSections: 76,
  items: 2_059,
  checklistItems: 1_044,
  checkedItems: 1_006,
  uncheckedItems: 38,
  contextNoteItems: 1_015,
  links: 62,
  unmatchedChecklistSections: 93,
  unmatchedContextNoteSections: 14,
  knownAttributions: 24,
  unknownAttributions: 207,
  duplicateStageNumbers: 21,
});

const DEFAULT_REPOSITORY_PATH = resolve(
  fileURLToPath(new URL("../..", import.meta.url)),
);
const CHARACTER_IDS_BY_COMMIT_NAME = Object.freeze({
  "백부장": "boss",
  "클대리": "left-man",
  "로과장": "left-woman",
  "코과장": "right-man",
  "코대리": "right-woman",
});
const REQUIRED_SCHEMA_TABLES = Object.freeze([
  "projects",
  "work_record_imports",
  "work_records",
  "work_record_items",
  "work_record_links",
  "work_record_events",
]);

export class LegacyWorkRecordImportError extends Error {}

export function parseImportMode(argumentsList) {
  const argumentsSet = new Set(argumentsList);
  const valid = argumentsList.every(
    (argument) => argument === "--dry-run" || argument === "--apply",
  );
  const hasDryRun = argumentsSet.has("--dry-run");
  const hasApply = argumentsSet.has("--apply");
  if (
    !valid ||
    argumentsList.length !== 1 ||
    hasDryRun === hasApply
  ) {
    throw new LegacyWorkRecordImportError(
      "사용법: npm --prefix backend run work-records:import -- --dry-run 또는 --apply",
    );
  }
  return hasApply ? "apply" : "dry-run";
}

export function parseBlamePorcelain(text) {
  const lines = String(text).split("\n");
  const byFinalLine = new Map();
  let current = null;
  for (const line of lines) {
    const header = line.match(
      /^\^?([0-9a-f]{40}) \d+ (\d+)(?: \d+)?$/,
    );
    if (header) {
      current = {
        commit: header[1],
        finalLine: Number(header[2]),
        author: null,
        authorMail: null,
        authorTime: null,
        authorTimezone: null,
        committerTime: null,
        committerTimezone: null,
        summary: null,
      };
      byFinalLine.set(current.finalLine, current);
      continue;
    }
    if (!current) {
      continue;
    }
    if (line.startsWith("author ")) {
      current.author = line.slice("author ".length);
    } else if (line.startsWith("author-mail ")) {
      current.authorMail = line.slice("author-mail ".length);
    } else if (line.startsWith("author-time ")) {
      current.authorTime = Number(line.slice("author-time ".length));
    } else if (line.startsWith("author-tz ")) {
      current.authorTimezone = line.slice("author-tz ".length);
    } else if (line.startsWith("committer-time ")) {
      current.committerTime = Number(line.slice("committer-time ".length));
    } else if (line.startsWith("committer-tz ")) {
      current.committerTimezone = line.slice("committer-tz ".length);
    } else if (line.startsWith("summary ")) {
      current.summary = line.slice("summary ".length);
    }
  }
  return byFinalLine;
}

export function parseLegacySections({
  sourcePath,
  recordType,
  text,
  blameByLine,
  sourceCommit = LEGACY_SOURCE_COMMIT,
}) {
  const sourceText = String(text);
  const headings = [...sourceText.matchAll(/^## (.+)$/gm)];
  return headings.map((heading, sectionOrdinal) => {
    const startOffset = heading.index;
    const endOffset = headings[sectionOrdinal + 1]?.index ?? sourceText.length;
    const rawSection = sourceText.slice(startOffset, endOffset);
    const sourceLineStart = lineNumberAt(sourceText, startOffset);
    const sourceLineEnd = sourceLineStart + occupiedLineCount(rawSection) - 1;
    const blame = blameByLine.get(sourceLineStart);
    if (
      !blame?.commit ||
      !Number.isFinite(blame.committerTime) ||
      !blame.summary
    ) {
      throw new LegacyWorkRecordImportError(
        `${sourcePath}:${sourceLineStart}의 Git 작성 근거를 찾을 수 없습니다.`,
      );
    }
    const title = heading[1].trim();
    const normalizedTitle = normalizeSectionTitle(sourcePath, title);
    const attribution = attributionFromSummary(blame.summary);
    const body = rawSection
      .slice(heading[0].length)
      .replace(/^\r?\n/, "")
      .trim();
    const items = parseSectionItems(rawSection, sourceLineStart);
    const legacyStageNumber = legacyStageNumberFromTitle(title);

    return {
      key: `${sourcePath}:${sectionOrdinal}`,
      projectID: null,
      importID: null,
      recordType,
      lifecycleState: "legacy",
      title,
      normalizedTitle,
      body,
      legacyStageNumber,
      characterID: attribution.characterID,
      attribution: attribution.characterID ? "character" : "unknown",
      sourcePath,
      sourceCommit,
      sourceSectionOrdinal: sectionOrdinal,
      sourceLineStart,
      sourceLineEnd,
      sourceSectionSha256: sha256(rawSection),
      recordedAt: new Date(blame.committerTime * 1_000).toISOString(),
      items,
      metadata: {
        sourceHeading: title,
        normalizedTitle,
        blameCommit: blame.commit,
        blameAuthor: blame.author,
        blameAuthorMail: blame.authorMail,
        blameAuthorTime: Number.isFinite(blame.authorTime)
          ? new Date(blame.authorTime * 1_000).toISOString()
          : null,
        blameAuthorTimezone: blame.authorTimezone,
        blameCommitterTime: new Date(
          blame.committerTime * 1_000,
        ).toISOString(),
        blameCommitterTimezone: blame.committerTimezone,
        blameSummary: blame.summary,
      },
    };
  });
}

export function pairLegacySections(checklistRecords, contextNoteRecords) {
  const checklistByTitle = recordsByNormalizedTitle(checklistRecords);
  const contextByTitle = recordsByNormalizedTitle(contextNoteRecords);
  const links = [];
  for (const [normalizedTitle, checklistMatches] of checklistByTitle) {
    const contextMatches = contextByTitle.get(normalizedTitle) ?? [];
    if (checklistMatches.length !== 1 || contextMatches.length !== 1) {
      continue;
    }
    const checklistRecord = checklistMatches[0];
    const contextRecord = contextMatches[0];
    links.push({
      sourceKey: checklistRecord.key,
      targetKey: contextRecord.key,
      relation: "paired_with",
      normalizedTitle,
    });
  }
  return {
    links,
    unmatchedChecklistSections:
      checklistRecords.length - links.length,
    unmatchedContextNoteSections:
      contextNoteRecords.length - links.length,
  };
}

export async function loadLegacyImportPlan({
  repositoryPath = DEFAULT_REPOSITORY_PATH,
  executeGit = executeGitCommand,
} = {}) {
  const resolvedCommit = String(
    await executeGit(
      repositoryPath,
      ["rev-parse", `${LEGACY_SOURCE_COMMIT}^{commit}`],
    ),
  ).trim();
  if (resolvedCommit !== LEGACY_SOURCE_COMMIT) {
    throw new LegacyWorkRecordImportError(
      `고정 원본 커밋이 다릅니다. 예상 ${LEGACY_SOURCE_COMMIT}, 실제 ${resolvedCommit}`,
    );
  }
  const repositoryRoot = await canonicalRepositoryRoot(
    repositoryPath,
    executeGit,
  );
  const parsedByPath = new Map();
  const sources = [];

  for (const source of LEGACY_SOURCE_FILES) {
    const raw = await executeGit(
      repositoryPath,
      ["show", `${LEGACY_SOURCE_COMMIT}:${source.path}`],
      { binary: true },
    );
    const buffer = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
    const actualSha256 = sha256(buffer);
    if (actualSha256 !== source.sha256) {
      throw new LegacyWorkRecordImportError(
        `${source.path} 해시가 다릅니다. 예상 ${source.sha256}, 실제 ${actualSha256}`,
      );
    }
    const blameText = await executeGit(
      repositoryPath,
      ["blame", "--line-porcelain", LEGACY_SOURCE_COMMIT, "--", source.path],
    );
    const records = parseLegacySections({
      sourcePath: source.path,
      recordType: source.recordType,
      text: buffer.toString("utf8"),
      blameByLine: parseBlamePorcelain(blameText),
      sourceCommit: LEGACY_SOURCE_COMMIT,
    });
    if (records.length !== source.sections) {
      throw new LegacyWorkRecordImportError(
        `${source.path} 섹션 수가 다릅니다. 예상 ${source.sections}, 실제 ${records.length}`,
      );
    }
    parsedByPath.set(source.path, records);
    sources.push({
      kind: "file",
      title: source.path,
      locator: `git:${LEGACY_SOURCE_COMMIT}:${source.path}`,
      sourcePath: source.path,
      sha256: actualSha256,
      sections: records.length,
    });
  }

  const checklistRecords = parsedByPath.get("checklist.md");
  const contextNoteRecords = parsedByPath.get("context-notes.md");
  const pairing = pairLegacySections(checklistRecords, contextNoteRecords);
  const records = [...checklistRecords, ...contextNoteRecords];
  const counts = calculateCounts({
    records,
    checklistRecords,
    contextNoteRecords,
    pairing,
  });
  assertExpectedCounts(counts);
  const plan = {
    parserVersion: LEGACY_PARSER_VERSION,
    project: {
      repositoryRoot,
      name: "OFFICESTRA",
      defaultBranch: "main",
    },
    sourceCommit: LEGACY_SOURCE_COMMIT,
    sources,
    counts,
    records,
    links: pairing.links,
  };
  plan.contentDigest = digestStoredContent(plan);
  return plan;
}

export function summarizeLegacyImport(plan, result = { status: "dry-run" }) {
  return {
    status: result.status,
    project: plan.project,
    sourceCommit: plan.sourceCommit,
    parserVersion: plan.parserVersion,
    contentDigest: plan.contentDigest,
    sources: plan.sources,
    counts: plan.counts,
    ...(result.projectId ? { projectId: result.projectId } : {}),
    ...(result.importId ? { importId: result.importId } : {}),
  };
}

export async function applyLegacyImport(client, plan) {
  await assertImportSchema(client);
  await assertKnownCharacters(client, plan.records);
  const projectID = await ensureProject(client, plan.project);
  const importResult = await createOrFindImport(client, projectID, plan);
  if (!importResult.created) {
    if (importResult.status !== "completed") {
      throw new LegacyWorkRecordImportError(
        `같은 원본의 import가 ${importResult.status} 상태입니다.`,
      );
    }
    await assertStoredImportIntegrity(client, importResult.id, plan);
    return {
      status: "already-imported",
      projectId: projectID,
      importId: importResult.id,
    };
  }

  const conflicting = await client.query(
    `
      SELECT count(*)::integer AS count
      FROM work_records
      WHERE project_id = $1
        AND source_commit = $2
        AND source_path = ANY($3::text[])
    `,
    [
      projectID,
      plan.sourceCommit,
      plan.sources.map((source) => source.sourcePath),
    ],
  );
  if (Number(conflicting.rows[0].count) !== 0) {
    throw new LegacyWorkRecordImportError(
      "동일한 Git 원본 위치의 기존 작업 기록이 있어 이관하지 않았습니다.",
    );
  }

  const recordIDs = new Map();
  for (const record of plan.records) {
    const inserted = await client.query(
      `
        INSERT INTO work_records (
          project_id,
          import_id,
          record_type,
          lifecycle_state,
          title,
          body,
          legacy_stage_number,
          character_id,
          attribution,
          source_path,
          source_commit,
          source_section_ordinal,
          source_line_start,
          source_line_end,
          source_section_sha256,
          metadata,
          recorded_at
        )
        VALUES (
          $1,
          $2,
          $3,
          $4,
          $5,
          $6,
          $7,
          $8,
          $9,
          $10,
          $11,
          $12,
          $13,
          $14,
          $15,
          $16::jsonb,
          $17::timestamptz
        )
        RETURNING id
      `,
      [
        projectID,
        importResult.id,
        record.recordType,
        record.lifecycleState,
        record.title,
        record.body,
        record.legacyStageNumber,
        record.characterID,
        record.attribution,
        record.sourcePath,
        record.sourceCommit,
        record.sourceSectionOrdinal,
        record.sourceLineStart,
        record.sourceLineEnd,
        record.sourceSectionSha256,
        JSON.stringify(record.metadata),
        record.recordedAt,
      ],
    );
    const recordID = inserted.rows[0].id;
    recordIDs.set(record.key, recordID);

    if (record.items.length > 0) {
      await client.query(
        `
          INSERT INTO work_record_items (
            record_id,
            ordinal,
            item_text,
            is_checked,
            metadata
          )
          SELECT
            $1,
            item.ordinal,
            item.item_text,
            item.is_checked,
            item.metadata
          FROM jsonb_to_recordset($2::jsonb) AS item (
            ordinal integer,
            item_text text,
            is_checked boolean,
            metadata jsonb
          )
        `,
        [recordID, JSON.stringify(record.items)],
      );
    }
    await client.query(
      `
        INSERT INTO work_record_events (
          record_id,
          record_version,
          event_type,
          actor_type,
          next_value,
          idempotency_key,
          occurred_at
        )
        VALUES ($1, 1, 'imported', 'import', $2::jsonb, $3, $4::timestamptz)
      `,
      [
        recordID,
        JSON.stringify(eventNextValue(record)),
        eventIdempotencyKey(record),
        record.recordedAt,
      ],
    );
  }

  for (const link of plan.links) {
    await client.query(
      `
        INSERT INTO work_record_links (
          source_record_id,
          target_record_id,
          relation
        )
        VALUES ($1, $2, $3)
      `,
      [recordIDs.get(link.sourceKey), recordIDs.get(link.targetKey), link.relation],
    );
  }

  await client.query(
    `
      UPDATE work_record_imports
      SET status = 'completed', finished_at = now()
      WHERE id = $1
    `,
    [importResult.id],
  );
  await assertStoredImportIntegrity(client, importResult.id, plan);
  return {
    status: "imported",
    projectId: projectID,
    importId: importResult.id,
  };
}

export async function runLegacyImportCommand({
  argumentsList = process.argv.slice(2),
  loadPlan = loadLegacyImportPlan,
  applyInTransaction,
} = {}) {
  const mode = parseImportMode(argumentsList);
  const plan = await loadPlan();
  if (mode === "dry-run") {
    return summarizeLegacyImport(plan);
  }
  if (!applyInTransaction) {
    throw new LegacyWorkRecordImportError(
      "적용 트랜잭션 실행기가 필요합니다.",
    );
  }
  const result = await applyInTransaction(
    (client) => applyLegacyImport(client, plan),
  );
  return summarizeLegacyImport(plan, result);
}

async function executeGitCommand(repositoryPath, argumentsList, { binary = false } = {}) {
  try {
    const { stdout } = await execFileAsync(
      "git",
      ["-C", repositoryPath, ...argumentsList],
      {
        encoding: binary ? null : "utf8",
        maxBuffer: 32 * 1_024 * 1_024,
      },
    );
    return stdout;
  } catch (error) {
    throw new LegacyWorkRecordImportError(
      `Git 원본을 읽지 못했습니다. ${error.message}`,
    );
  }
}

async function canonicalRepositoryRoot(repositoryPath, executeGit) {
  const commonDirectory = String(
    await executeGit(
      repositoryPath,
      ["rev-parse", "--path-format=absolute", "--git-common-dir"],
    ),
  ).trim();
  if (commonDirectory.endsWith("/.git")) {
    return dirname(commonDirectory);
  }
  return String(
    await executeGit(repositoryPath, ["rev-parse", "--show-toplevel"]),
  ).trim();
}

function normalizeSectionTitle(sourcePath, title) {
  const normalized = title.normalize("NFC").replace(/\s+/g, " ").trim();
  if (sourcePath === "checklist.md") {
    return normalized
      .replace(/^(?:\d+단계|추가 작업)(?:\s+|$)/, "")
      .trim();
  }
  if (sourcePath === "context-notes.md") {
    return normalized
      .replace(/^\d{4}-\d{2}-\d{2}(?:\s+|$)/, "")
      .trim();
  }
  return normalized;
}

function legacyStageNumberFromTitle(title) {
  const match = title.match(/^(\d+)단계(?:\s+|$)/);
  return match ? Number(match[1]) : null;
}

function attributionFromSummary(summary) {
  const match = summary.match(
    /^OFFICESTRA: (백부장|코과장|로과장|코대리|클대리) 업무 [0-9a-f]{8}$/,
  );
  const characterID = match
    ? CHARACTER_IDS_BY_COMMIT_NAME[match[1]]
    : null;
  return { characterID };
}

function parseSectionItems(rawSection, sourceLineStart) {
  const items = [];
  for (const [lineOffset, line] of rawSection.split("\n").entries()) {
    const checklist = line.match(/^(\s*)- \[([ xX])\] (.*)$/);
    if (checklist) {
      items.push({
        ordinal: items.length,
        item_text: checklist[3],
        is_checked: checklist[2].toLowerCase() === "x",
        metadata: {
          sourceLine: sourceLineStart + lineOffset,
          indentation: checklist[1].length,
        },
      });
      continue;
    }
    const bullet = line.match(/^(\s*)- (.*)$/);
    if (bullet) {
      items.push({
        ordinal: items.length,
        item_text: bullet[2],
        is_checked: null,
        metadata: {
          sourceLine: sourceLineStart + lineOffset,
          indentation: bullet[1].length,
        },
      });
    }
  }
  return items;
}

function recordsByNormalizedTitle(records) {
  const result = new Map();
  for (const record of records) {
    const matches = result.get(record.normalizedTitle) ?? [];
    matches.push(record);
    result.set(record.normalizedTitle, matches);
  }
  return result;
}

function calculateCounts({
  records,
  checklistRecords,
  contextNoteRecords,
  pairing,
}) {
  const checklistItems = checklistRecords.flatMap((record) => record.items);
  const contextNoteItems = contextNoteRecords.flatMap((record) => record.items);
  const stageCounts = new Map();
  for (const record of checklistRecords) {
    if (record.legacyStageNumber === null) {
      continue;
    }
    stageCounts.set(
      record.legacyStageNumber,
      (stageCounts.get(record.legacyStageNumber) ?? 0) + 1,
    );
  }
  return {
    records: records.length,
    checklistSections: checklistRecords.length,
    contextNotesSections: contextNoteRecords.length,
    items: checklistItems.length + contextNoteItems.length,
    checklistItems: checklistItems.length,
    checkedItems: checklistItems.filter((item) => item.is_checked === true).length,
    uncheckedItems: checklistItems.filter((item) => item.is_checked === false).length,
    contextNoteItems: contextNoteItems.length,
    links: pairing.links.length,
    unmatchedChecklistSections: pairing.unmatchedChecklistSections,
    unmatchedContextNoteSections: pairing.unmatchedContextNoteSections,
    knownAttributions: records.filter((record) => record.characterID).length,
    unknownAttributions: records.filter((record) => !record.characterID).length,
    duplicateStageNumbers: [...stageCounts.values()].filter(
      (count) => count > 1,
    ).length,
  };
}

function assertExpectedCounts(counts) {
  for (const [name, expected] of Object.entries(LEGACY_EXPECTED_COUNTS)) {
    if (counts[name] !== expected) {
      throw new LegacyWorkRecordImportError(
        `${name} 값이 다릅니다. 예상 ${expected}, 실제 ${counts[name]}`,
      );
    }
  }
}

async function assertImportSchema(client) {
  const result = await client.query(
    `
      SELECT ${REQUIRED_SCHEMA_TABLES.map(
        (table, index) => `to_regclass('public.${table}') AS table_${index}`,
      ).join(", ")}
    `,
  );
  const missing = REQUIRED_SCHEMA_TABLES.filter(
    (_, index) => !result.rows[0][`table_${index}`],
  );
  if (missing.length > 0) {
    throw new LegacyWorkRecordImportError(
      `013 마이그레이션이 필요합니다. 누락 테이블 ${missing.join(", ")}`,
    );
  }
}

async function assertKnownCharacters(client, records) {
  const expected = [...new Set(
    records.map((record) => record.characterID).filter(Boolean),
  )].sort();
  const result = await client.query(
    "SELECT id FROM characters WHERE id = ANY($1::text[])",
    [expected],
  );
  const found = new Set(result.rows.map((row) => row.id));
  const missing = expected.filter((id) => !found.has(id));
  if (missing.length > 0) {
    throw new LegacyWorkRecordImportError(
      `직원 원본 ID를 찾을 수 없습니다. ${missing.join(", ")}`,
    );
  }
}

async function ensureProject(client, project) {
  const inserted = await client.query(
    `
      INSERT INTO projects (repository_root, name, default_branch)
      VALUES ($1, $2, $3)
      ON CONFLICT (repository_root) DO NOTHING
      RETURNING id
    `,
    [project.repositoryRoot, project.name, project.defaultBranch],
  );
  if (inserted.rowCount > 0) {
    return inserted.rows[0].id;
  }
  const existing = await client.query(
    "SELECT id FROM projects WHERE repository_root = $1 FOR SHARE",
    [project.repositoryRoot],
  );
  if (existing.rowCount !== 1) {
    throw new LegacyWorkRecordImportError(
      "프로젝트 원본 행을 찾을 수 없습니다.",
    );
  }
  return existing.rows[0].id;
}

async function createOrFindImport(client, projectID, plan) {
  const sourceCounts = JSON.stringify(sourceCountsForPlan(plan));
  const inserted = await client.query(
    `
      INSERT INTO work_record_imports (
        project_id,
        source_commit,
        checklist_sha256,
        context_notes_sha256,
        parser_version,
        status,
        source_counts
      )
      VALUES ($1, $2, $3, $4, $5, 'running', $6::jsonb)
      ON CONFLICT (
        project_id,
        source_commit,
        checklist_sha256,
        context_notes_sha256
      ) DO NOTHING
      RETURNING id, status, parser_version, source_counts
    `,
    [
      projectID,
      plan.sourceCommit,
      sourceSha(plan, "checklist.md"),
      sourceSha(plan, "context-notes.md"),
      plan.parserVersion,
      sourceCounts,
    ],
  );
  if (inserted.rowCount > 0) {
    return { ...inserted.rows[0], created: true };
  }
  const existing = await client.query(
    `
      SELECT id, status, parser_version, source_counts
      FROM work_record_imports
      WHERE project_id = $1
        AND source_commit = $2
        AND checklist_sha256 = $3
        AND context_notes_sha256 = $4
      FOR UPDATE
    `,
    [
      projectID,
      plan.sourceCommit,
      sourceSha(plan, "checklist.md"),
      sourceSha(plan, "context-notes.md"),
    ],
  );
  if (existing.rowCount !== 1) {
    throw new LegacyWorkRecordImportError(
      "기존 import 원본 행을 찾을 수 없습니다.",
    );
  }
  return { ...existing.rows[0], created: false };
}

async function assertStoredImportIntegrity(client, importID, plan) {
  const importRow = await client.query(
    `
      SELECT
        status,
        parser_version AS "parserVersion",
        source_counts AS "sourceCounts"
      FROM work_record_imports
      WHERE id = $1
    `,
    [importID],
  );
  if (importRow.rowCount !== 1 || importRow.rows[0].status !== "completed") {
    throw new LegacyWorkRecordImportError(
      "완료된 import 원본 행을 찾을 수 없습니다.",
    );
  }
  if (importRow.rows[0].parserVersion !== plan.parserVersion) {
    throw new LegacyWorkRecordImportError(
      "저장된 parser_version이 현재 파서와 다릅니다.",
    );
  }
  if (
    canonicalStringify(importRow.rows[0].sourceCounts) !==
    canonicalStringify(sourceCountsForPlan(plan))
  ) {
    throw new LegacyWorkRecordImportError(
      "저장된 source_counts가 현재 이관 계획과 다릅니다.",
    );
  }

  const records = await client.query(
    `
      SELECT
        record_type AS "recordType",
        lifecycle_state AS "lifecycleState",
        title,
        body,
        legacy_stage_number AS "legacyStageNumber",
        character_id AS "characterId",
        attribution,
        source_path AS "sourcePath",
        source_commit AS "sourceCommit",
        source_section_ordinal AS "sourceSectionOrdinal",
        source_line_start AS "sourceLineStart",
        source_line_end AS "sourceLineEnd",
        source_section_sha256 AS "sourceSectionSha256",
        metadata,
        recorded_at AS "recordedAt"
      FROM work_records
      WHERE import_id = $1
      ORDER BY source_path, source_section_ordinal
    `,
    [importID],
  );
  const items = await client.query(
    `
      SELECT
        record.source_path AS "sourcePath",
        record.source_section_ordinal AS "sourceSectionOrdinal",
        item.ordinal,
        item.item_text AS "itemText",
        item.is_checked AS "isChecked",
        item.metadata
      FROM work_record_items AS item
      JOIN work_records AS record ON record.id = item.record_id
      WHERE record.import_id = $1
      ORDER BY record.source_path, record.source_section_ordinal, item.ordinal
    `,
    [importID],
  );
  const links = await client.query(
    `
      SELECT
        source.source_path AS "sourcePath",
        source.source_section_ordinal AS "sourceSectionOrdinal",
        target.source_path AS "targetPath",
        target.source_section_ordinal AS "targetSectionOrdinal",
        link.relation
      FROM work_record_links AS link
      JOIN work_records AS source ON source.id = link.source_record_id
      JOIN work_records AS target ON target.id = link.target_record_id
      WHERE source.import_id = $1 AND target.import_id = $1
      ORDER BY
        source.source_path,
        source.source_section_ordinal,
        target.source_path,
        target.source_section_ordinal,
        link.relation
    `,
    [importID],
  );
  const events = await client.query(
    `
      SELECT
        record.source_path AS "sourcePath",
        record.source_section_ordinal AS "sourceSectionOrdinal",
        event.record_version AS "recordVersion",
        event.event_type AS "eventType",
        event.actor_character_id AS "actorCharacterId",
        event.actor_type AS "actorType",
        event.source_turn_id AS "sourceTurnId",
        event.previous_value AS "previousValue",
        event.next_value AS "nextValue",
        event.idempotency_key AS "idempotencyKey",
        event.occurred_at AS "occurredAt"
      FROM work_record_events AS event
      JOIN work_records AS record ON record.id = event.record_id
      WHERE record.import_id = $1
      ORDER BY record.source_path, record.source_section_ordinal, event.record_version
    `,
    [importID],
  );
  const actual = {
    records: records.rows.map((row) => ({
      ...row,
      recordedAt: normalizeTimestamp(row.recordedAt),
    })),
    items: items.rows,
    links: links.rows,
    events: events.rows.map((row) => ({
      ...row,
      occurredAt: normalizeTimestamp(row.occurredAt),
    })),
  };
  const expected = legacyStoredContent(plan);
  for (const name of ["records", "items", "links", "events"]) {
    if (canonicalStringify(actual[name]) !== canonicalStringify(expected[name])) {
      throw new LegacyWorkRecordImportError(
        `저장된 ${name} 내용이 현재 이관 계획과 다릅니다.`,
      );
    }
  }
}

export function legacyStoredContent(plan) {
  const recordByKey = new Map(
    plan.records.map((record) => [record.key, record]),
  );
  const records = plan.records.map((record) => ({
    recordType: record.recordType,
    lifecycleState: record.lifecycleState,
    title: record.title,
    body: record.body,
    legacyStageNumber: record.legacyStageNumber,
    characterId: record.characterID,
    attribution: record.attribution,
    sourcePath: record.sourcePath,
    sourceCommit: record.sourceCommit,
    sourceSectionOrdinal: record.sourceSectionOrdinal,
    sourceLineStart: record.sourceLineStart,
    sourceLineEnd: record.sourceLineEnd,
    sourceSectionSha256: record.sourceSectionSha256,
    metadata: record.metadata,
    recordedAt: record.recordedAt,
  }));
  const items = plan.records.flatMap((record) =>
    record.items.map((item) => ({
      sourcePath: record.sourcePath,
      sourceSectionOrdinal: record.sourceSectionOrdinal,
      ordinal: item.ordinal,
      itemText: item.item_text,
      isChecked: item.is_checked,
      metadata: item.metadata,
    })),
  );
  const links = plan.links.map((link) => {
    const source = recordByKey.get(link.sourceKey);
    const target = recordByKey.get(link.targetKey);
    return {
      sourcePath: source.sourcePath,
      sourceSectionOrdinal: source.sourceSectionOrdinal,
      targetPath: target.sourcePath,
      targetSectionOrdinal: target.sourceSectionOrdinal,
      relation: link.relation,
    };
  });
  const events = plan.records.map((record) => ({
    sourcePath: record.sourcePath,
    sourceSectionOrdinal: record.sourceSectionOrdinal,
    recordVersion: 1,
    eventType: "imported",
    actorCharacterId: null,
    actorType: "import",
    sourceTurnId: null,
    previousValue: null,
    nextValue: eventNextValue(record),
    idempotencyKey: eventIdempotencyKey(record),
    occurredAt: record.recordedAt,
  }));
  return { records, items, links, events };
}

function digestStoredContent(plan) {
  return sha256(canonicalStringify(legacyStoredContent(plan)));
}

function sourceCountsForPlan(plan) {
  return {
    ...plan.counts,
    contentDigest: plan.contentDigest,
  };
}

function eventNextValue(record) {
  return {
    sourcePath: record.sourcePath,
    sourceCommit: record.sourceCommit,
    sourceSectionOrdinal: record.sourceSectionOrdinal,
    sourceSectionSha256: record.sourceSectionSha256,
  };
}

function eventIdempotencyKey(record) {
  return `legacy-import:v1:${record.sourceSectionSha256}`;
}

function normalizeTimestamp(value) {
  const date = value instanceof Date ? value : new Date(value);
  if (!Number.isFinite(date.getTime())) {
    return String(value);
  }
  return date.toISOString();
}

function canonicalStringify(value) {
  return JSON.stringify(canonicalValue(value));
}

function canonicalValue(value) {
  if (Array.isArray(value)) {
    return value.map((item) => canonicalValue(item));
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonicalValue(value[key])]),
    );
  }
  return value;
}

function sourceSha(plan, sourcePath) {
  const source = plan.sources.find((candidate) => candidate.sourcePath === sourcePath);
  if (!source) {
    throw new LegacyWorkRecordImportError(
      `${sourcePath} 원본 정보를 찾을 수 없습니다.`,
    );
  }
  return source.sha256;
}

function lineNumberAt(text, offset) {
  let line = 1;
  for (let index = 0; index < offset; index += 1) {
    if (text[index] === "\n") {
      line += 1;
    }
  }
  return line;
}

function occupiedLineCount(text) {
  const newlines = [...text.matchAll(/\n/g)].length;
  return text.endsWith("\n") ? newlines : newlines + 1;
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

async function main() {
  const mode = parseImportMode(process.argv.slice(2));
  if (mode === "dry-run") {
    const result = await runLegacyImportCommand({
      argumentsList: ["--dry-run"],
    });
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }

  const { pool, withTransaction } = await import("./db.mjs");
  try {
    const result = await runLegacyImportCommand({
      argumentsList: ["--apply"],
      applyInTransaction: (operation) => withTransaction(operation),
    });
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } finally {
    await pool.end();
  }
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  main().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
