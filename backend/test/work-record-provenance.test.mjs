// 이 파일은 작업 기록 조회 조건과 응답 출처 검증 규칙을 확인한다.

import assert from "node:assert/strict";
import test from "node:test";

import {
  ProvenanceValidationError,
  isUUID,
  normalizeResponseSources,
  parseWorkRecordFilters,
  portableResponseSources,
} from "../src/work-record-provenance.mjs";

test("작업 기록 조회 조건은 기본 범위와 필터를 정규화한다", () => {
  const defaults = parseWorkRecordFilters(new URLSearchParams());
  assert.deepEqual(defaults, {
    projectID: null,
    recordType: null,
    lifecycleState: null,
    attribution: null,
    query: null,
    limit: 50,
    offset: 0,
  });

  const filtered = parseWorkRecordFilters(new URLSearchParams({
    projectId: "2b6181f5-dbb0-4c19-ae2e-0fcb8a42a349",
    kind: "decision",
    state: "legacy",
    attribution: "unknown",
    q: " 세션 유지 ",
    limit: "25",
    offset: "50",
  }));
  assert.equal(filtered.query, "세션 유지");
  assert.equal(filtered.recordType, "decision");
  assert.equal(filtered.limit, 25);
  assert.equal(filtered.offset, 50);
});

test("작업 기록 조회 조건은 잘못된 UUID와 범위를 거절한다", () => {
  assert.throws(
    () => parseWorkRecordFilters(new URLSearchParams({ projectId: "office" })),
    ProvenanceValidationError,
  );
  assert.throws(
    () => parseWorkRecordFilters(new URLSearchParams({ limit: "101" })),
    ProvenanceValidationError,
  );
  assert.throws(
    () => parseWorkRecordFilters(new URLSearchParams({ state: "deleted" })),
    ProvenanceValidationError,
  );
});

test("RAG와 DB와 파일 출처를 순서대로 정규화한다", () => {
  const sources = normalizeResponseSources([
    {
      kind: "rag",
      title: "이전 결정",
      locator: "rag_documents/2b6181f5-dbb0-4c19-ae2e-0fcb8a42a349",
      ragDocumentId: "2b6181f5-dbb0-4c19-ae2e-0fcb8a42a349",
    },
    {
      sourceKind: "database",
      title: "업무 기록",
      locator: "work_records/5e7aa706-3c02-4d7a-8d9d-bfe735731fcb",
      workRecordId: "5e7aa706-3c02-4d7a-8d9d-bfe735731fcb",
      excerpt: "세션은 유지한다.",
    },
    {
      kind: "file",
      title: "설정 파일",
      locator: "/repo/README.md:14",
      metadata: { line: 14 },
    },
  ]);

  assert.deepEqual(sources.map((source) => source.sourceKind), [
    "rag",
    "database",
    "file",
  ]);
  assert.deepEqual(sources.map((source) => source.ordinal), [0, 1, 2]);
  assert.equal(sources[2].title, "설정 파일");
  assert.deepEqual(sources[2].metadata, { line: 14 });
  assert.equal(isUUID(sources[0].ragDocumentID), true);
});

test("출처 UUID는 PostgreSQL 표기와 같은 소문자로 정규화한다", () => {
  const [source] = normalizeResponseSources([{
    kind: "rag",
    title: "이전 결정",
    locator: "rag_documents/2B6181F5-DBB0-4C19-AE2E-0FCB8A42A349",
    ragDocumentId: "2B6181F5-DBB0-4C19-AE2E-0FCB8A42A349",
  }]);

  assert.equal(
    source.ragDocumentID,
    "2b6181f5-dbb0-4c19-ae2e-0fcb8a42a349",
  );
});

test("웹과 도구와 스킬 출처를 안전한 locator로 정규화한다", () => {
  const sources = normalizeResponseSources([
    {
      kind: "web",
      title: "공식 문서",
      locator: "https://example.com/docs?lang=ko",
    },
    {
      kind: "tool",
      title: "GitHub 조회",
      locator: "github/get_pull_request/openai/codex/123",
    },
    {
      kind: "skill",
      title: "브라우저 제어 절차",
      locator: "browser:control-in-app-browser",
    },
  ]);

  assert.deepEqual(sources.map((source) => source.sourceKind), [
    "web",
    "tool",
    "skill",
  ]);
  assert.equal(sources[0].locator, "https://example.com/docs?lang=ko");
  assert.equal(
    sources[1].locator,
    "github/get_pull_request/openai/codex/123",
  );
  assert.equal(sources[2].locator, "browser:control-in-app-browser");
});

test("웹 출처는 위험한 URL과 민감한 쿼리 키를 거절한다", () => {
  for (const locator of [
    "ftp://example.com/reference",
    "https://user:password@example.com/reference",
    "https://example.com/reference?access_token=secret",
    "https://example.com/reference?api-key=secret",
    "https://example.com/reference?signature=secret",
    "https://example.com/callback?code=secret",
    "https://example.com/reference#access_token=secret",
    "https://example.com/reference#oauth_token=secret",
    "https://example.com/reference#access_token%3Dsecret",
  ]) {
    assert.throws(
      () => normalizeResponseSources([{
        kind: "web",
        title: "위험한 링크",
        locator,
      }]),
      /웹 출처 locator/,
    );
  }
});

test("웹 출처는 정상 인용 쿼리와 문서 fragment를 보존한다", () => {
  const sources = normalizeResponseSources([
    {
      kind: "web",
      title: "저자별 문서",
      locator: "https://example.com/reference?author=neo#installation",
    },
    {
      kind: "web",
      title: "인증 문서 섹션",
      locator: "https://example.com/docs#authorization",
    },
    {
      kind: "web",
      title: "접근 토큰 문서 섹션",
      locator: "https://example.com/docs#access-token",
    },
  ]);

  assert.equal(
    sources[0].locator,
    "https://example.com/reference?author=neo#installation",
  );
  assert.equal(sources[1].locator, "https://example.com/docs#authorization");
  assert.equal(sources[2].locator, "https://example.com/docs#access-token");
});

test("도구와 스킬 출처는 식별자가 아닌 locator를 거절한다", () => {
  for (const [kind, locator] of [
    ["tool", "web/search query"],
    ["tool", "web/search?token=secret"],
    ["tool", "web/../secret"],
    ["skill", "playwright-cli/SKILL.md"],
    ["skill", "../../skill"],
  ]) {
    assert.throws(
      () => normalizeResponseSources([{
        kind,
        title: "잘못된 식별자",
        locator,
      }]),
      /locator/,
    );
  }
});

test("응답 출처는 중복과 종류가 다른 참조를 거절한다", () => {
  assert.throws(
    () => normalizeResponseSources([
      { kind: "file", title: "하나", locator: "/repo/a" },
      { kind: "file", title: "둘", locator: "/repo/a" },
    ]),
    /중복/,
  );
  assert.throws(
    () => normalizeResponseSources([{
      kind: "file",
      title: "파일",
      locator: "/repo/a",
      ragDocumentId: "2b6181f5-dbb0-4c19-ae2e-0fcb8a42a349",
    }]),
    /RAG 출처/,
  );
  assert.throws(
    () => normalizeResponseSources([{
      kind: "rag",
      title: "RAG 문서",
      locator: "rag_documents/missing",
    }]),
    /ragDocumentId/,
  );
  assert.throws(
    () => normalizeResponseSources({}),
    ProvenanceValidationError,
  );
});

test("업무 폴더 안 파일 출처는 병합 뒤에도 쓸 상대경로로 바꾼다", () => {
  const sources = normalizeResponseSources([
    {
      kind: "file",
      title: "README",
      locator: "/tmp/worktree/project/README.md:8-10",
    },
    {
      kind: "file",
      title: "외부 설정",
      locator: "/tmp/shared/settings.json",
    },
    {
      kind: "file",
      title: "같은 README",
      locator: "README.md:8-10",
    },
  ]);

  const portable = portableResponseSources(
    sources,
    "/tmp/worktree/project",
  );

  assert.equal(portable[0].locator, "README.md:8-10");
  assert.equal(portable[1].locator, "/tmp/shared/settings.json");
  assert.equal(portable.length, 2);
  assert.deepEqual(portable.map((source) => source.ordinal), [0, 1]);
});
