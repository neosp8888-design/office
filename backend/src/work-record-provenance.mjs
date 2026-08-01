// 이 파일은 작업 기록 조회 조건과 응답 출처 입력을 안전한 형식으로 정규화한다.

import { isAbsolute, relative, sep } from "node:path";

const RECORD_TYPES = new Set([
  "task",
  "decision",
  "constraint",
  "evidence",
  "status",
  "result",
  "note",
]);
const LIFECYCLE_STATES = new Set([
  "legacy",
  "active",
  "superseded",
  "archived",
]);
const ATTRIBUTIONS = new Set([
  "character",
  "user",
  "commit",
  "unknown",
  "system",
]);
const SOURCE_KINDS = new Set(["rag", "database", "file"]);
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export class ProvenanceValidationError extends Error {}

export function isUUID(value) {
  return UUID_PATTERN.test(String(value ?? ""));
}

export function parseWorkRecordFilters(searchParams) {
  const projectID = optionalUUID(searchParams.get("projectId"), "projectId");
  const recordType = optionalChoice(
    searchParams.get("kind"),
    RECORD_TYPES,
    "kind",
  );
  const lifecycleState = optionalChoice(
    searchParams.get("state"),
    LIFECYCLE_STATES,
    "state",
  );
  const attribution = optionalChoice(
    searchParams.get("attribution"),
    ATTRIBUTIONS,
    "attribution",
  );
  const query = optionalText(searchParams.get("q"), 500, "q");
  const limit = boundedInteger(searchParams.get("limit"), {
    field: "limit",
    fallback: 50,
    minimum: 1,
    maximum: 100,
  });
  const offset = boundedInteger(searchParams.get("offset"), {
    field: "offset",
    fallback: 0,
    minimum: 0,
    maximum: 100_000,
  });

  return {
    projectID,
    recordType,
    lifecycleState,
    attribution,
    query,
    limit,
    offset,
  };
}

export function normalizeResponseSources(value, { maximum = 50 } = {}) {
  if (!Array.isArray(value)) {
    throw new ProvenanceValidationError("출처 목록은 배열이어야 합니다.");
  }
  if (value.length > maximum) {
    throw new ProvenanceValidationError(
      `출처는 한 응답에 ${maximum}개까지 저장할 수 있습니다.`,
    );
  }

  const identities = new Set();
  return value.map((source, ordinal) => {
    if (!source || typeof source !== "object" || Array.isArray(source)) {
      throw new ProvenanceValidationError("각 출처는 객체여야 합니다.");
    }
    const sourceKind = requiredChoice(
      source.sourceKind ?? source.kind,
      SOURCE_KINDS,
      "sourceKind",
    );
    const title = requiredText(source.title, 200, "title");
    const locator = requiredText(source.locator, 2_000, "locator");
    const excerpt = optionalText(source.excerpt, 1_000, "excerpt");
    const ragDocumentID = optionalUUID(
      source.ragDocumentId,
      "ragDocumentId",
    );
    const workRecordID = optionalUUID(
      source.workRecordId,
      "workRecordId",
    );
    if (sourceKind === "rag" && !ragDocumentID) {
      throw new ProvenanceValidationError(
        "RAG 출처에는 ragDocumentId가 필요합니다.",
      );
    }
    if (ragDocumentID && sourceKind !== "rag") {
      throw new ProvenanceValidationError(
        "ragDocumentId는 RAG 출처에만 사용할 수 있습니다.",
      );
    }
    if (workRecordID && sourceKind !== "database") {
      throw new ProvenanceValidationError(
        "workRecordId는 DB 출처에만 사용할 수 있습니다.",
      );
    }
    if (
      sourceKind === "database" &&
      /^work_records(?:\/|:)/.test(locator) &&
      !workRecordID
    ) {
      throw new ProvenanceValidationError(
        "work_records 출처에는 workRecordId가 필요합니다.",
      );
    }
    const metadata = source.metadata ?? {};
    if (
      !metadata ||
      typeof metadata !== "object" ||
      Array.isArray(metadata)
    ) {
      throw new ProvenanceValidationError("metadata는 객체여야 합니다.");
    }
    const identity = `${sourceKind}\n${locator}`;
    if (identities.has(identity)) {
      throw new ProvenanceValidationError("같은 출처가 중복됐습니다.");
    }
    identities.add(identity);

    return {
      ordinal,
      sourceKind,
      title,
      locator,
      excerpt,
      ragDocumentID,
      workRecordID,
      metadata,
    };
  });
}

export function portableResponseSources(sources, workdir) {
  const baseDirectory = String(workdir ?? "").trim();
  if (!baseDirectory) {
    return sources;
  }
  const converted = sources.map((source) => {
    if (source.sourceKind !== "file") {
      return source;
    }
    const match = source.locator.match(/^(.*)(:\d+(?:-\d+)?)$/);
    const path = match?.[1] ?? source.locator;
    const lineSuffix = match?.[2] ?? "";
    if (!isAbsolute(path)) {
      return source;
    }
    const relativePath = relative(baseDirectory, path);
    if (
      !relativePath ||
      isAbsolute(relativePath) ||
      relativePath === ".." ||
      relativePath.startsWith(`..${sep}`)
    ) {
      return source;
    }
    return {
      ...source,
      locator: `${relativePath}${lineSuffix}`,
    };
  });
  const identities = new Set();
  const unique = [];
  for (const source of converted) {
    const identity = `${source.sourceKind}\n${source.locator}`;
    if (identities.has(identity)) {
      continue;
    }
    identities.add(identity);
    unique.push({ ...source, ordinal: unique.length });
  }
  return unique;
}

export async function replaceTurnResponseSources(client, turnID, sources) {
  await validateSourceReferences(client, sources);
  await client.query(
    "DELETE FROM turn_response_sources WHERE turn_id = $1",
    [turnID],
  );
  const stored = [];
  for (const source of sources) {
    const result = await client.query(
      `
        INSERT INTO turn_response_sources (
          turn_id,
          ordinal,
          source_kind,
          title,
          locator,
          excerpt,
          rag_document_id,
          work_record_id,
          metadata
        )
        VALUES (
          $1,
          $2,
          $3,
          $4,
          $5,
          $6,
          $7::uuid,
          $8::uuid,
          $9::jsonb
        )
        RETURNING
          id,
          source_kind AS "sourceKind",
          title,
          locator,
          excerpt,
          rag_document_id AS "ragDocumentId",
          work_record_id AS "workRecordId"
      `,
      [
        turnID,
        source.ordinal,
        source.sourceKind,
        source.title,
        source.locator,
        source.excerpt,
        source.ragDocumentID,
        source.workRecordID,
        JSON.stringify(source.metadata),
      ],
    );
    stored.push(result.rows[0]);
  }
  return stored;
}

async function validateSourceReferences(client, sources) {
  await validateSourceReferenceSet(
    client,
    sources.map((source) => source.ragDocumentID).filter(Boolean),
    "rag_documents",
    "RAG 출처 문서",
  );
  await validateSourceReferenceSet(
    client,
    sources.map((source) => source.workRecordID).filter(Boolean),
    "work_records",
    "DB 작업 기록",
  );
}

async function validateSourceReferenceSet(client, values, table, label) {
  const ids = [...new Set(values)];
  if (ids.length === 0) {
    return;
  }
  const result = await client.query(
    `SELECT id::text FROM ${table} WHERE id = ANY($1::uuid[])`,
    [ids],
  );
  const found = new Set(result.rows.map((row) => row.id));
  if (ids.some((id) => !found.has(id))) {
    throw new ProvenanceValidationError(
      `${label} 참조를 찾을 수 없습니다.`,
    );
  }
}

function optionalChoice(value, choices, field) {
  const text = String(value ?? "").trim();
  return text ? requiredChoice(text, choices, field) : null;
}

function requiredChoice(value, choices, field) {
  const text = String(value ?? "").trim();
  if (!choices.has(text)) {
    throw new ProvenanceValidationError(`${field} 값이 올바르지 않습니다.`);
  }
  return text;
}

function requiredText(value, maximum, field) {
  const text = String(value ?? "").trim();
  if (!text || text.length > maximum) {
    throw new ProvenanceValidationError(
      `${field} 값은 1자 이상 ${maximum}자 이하여야 합니다.`,
    );
  }
  return text;
}

function optionalText(value, maximum, field) {
  if (value === null || value === undefined) {
    return null;
  }
  const text = String(value).trim();
  if (!text) {
    return null;
  }
  if (text.length > maximum) {
    throw new ProvenanceValidationError(
      `${field} 값은 ${maximum}자 이하여야 합니다.`,
    );
  }
  return text;
}

function optionalUUID(value, field) {
  const text = String(value ?? "").trim();
  if (!text) {
    return null;
  }
  if (!isUUID(text)) {
    throw new ProvenanceValidationError(`${field} 값은 UUID여야 합니다.`);
  }
  return text.toLowerCase();
}

function boundedInteger(value, { field, fallback, minimum, maximum }) {
  if (value === null || value === undefined || value === "") {
    return fallback;
  }
  const number = Number(value);
  if (!Number.isInteger(number) || number < minimum || number > maximum) {
    throw new ProvenanceValidationError(
      `${field} 값은 ${minimum} 이상 ${maximum} 이하 정수여야 합니다.`,
    );
  }
  return number;
}
