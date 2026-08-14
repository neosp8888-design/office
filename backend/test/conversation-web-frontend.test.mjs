import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const assetRoot = join(
  here,
  "..",
  "..",
  "Sources",
  "OfficeGame",
  "Resources",
  "conversation-web",
);

await import(`${pathToFileURL(join(assetRoot, "app.js")).href}?frontend-test`);
const helpers = globalThis.OFFICESTRAConversation.test;

test("conversation web markdown은 표, 목록, 코드 펜스를 구조화한다", () => {
  const html = helpers.renderMarkdown(`
| 항목 | 결과 |
|---|---:|
| 테스트 | 통과 |

- 첫째
- 둘째

\`\`\`swift
let answer = 42
\`\`\`
  `);

  assert.match(html, /<table>/);
  assert.match(html, /<th>항목<\/th>/);
  assert.match(html, /<ul><li>첫째<\/li><li>둘째<\/li><\/ul>/);
  assert.match(html, /class="language-swift"/);
  assert.match(html, /let answer = 42/);
});

test("conversation web markdown은 원시 HTML과 위험한 URL을 실행하지 않는다", () => {
  const html = helpers.renderMarkdown(
    '<script>alert("x")</script> [열기](javascript:alert(1))',
  );

  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /&lt;script&gt;/);
  assert.doesNotMatch(html, /data-open-link="javascript:/);
  assert.equal(helpers.safeDestination("javascript:alert(1)"), "");
});

test("확인 질문은 마지막 연속 선택지 블록만 분리한다", () => {
  const parsed = helpers.parseQuestion(`배포 방법을 선택해 주세요.

1. 지금 배포
2. 나중에 배포`);

  assert.equal(parsed.question, "배포 방법을 선택해 주세요.");
  assert.deepEqual(
    parsed.choices.map(({ title, response }) => ({ title, response })),
    [
      { title: "지금 배포", response: "1. 지금 배포" },
      { title: "나중에 배포", response: "2. 나중에 배포" },
    ],
  );
});

test("직원별 캐시는 섞이지 않고 시작 시각 오름차순으로 표시한다", () => {
  const suffix = Math.random().toString(36).slice(2);
  const left = `left-${suffix}`;
  const right = `right-${suffix}`;
  helpers.mergeTurns([
    {
      id: "second",
      characterId: left,
      startedAt: "2026-08-14T02:00:00.000Z",
      prompt: "둘째",
    },
    {
      id: "other",
      characterId: right,
      startedAt: "2026-08-14T00:00:00.000Z",
      prompt: "다른 직원",
    },
    {
      id: "first",
      characterId: left,
      startedAt: "2026-08-14T01:00:00.000Z",
      prompt: "첫째",
    },
  ]);

  assert.deepEqual(helpers.turnsFor(left).map((turn) => turn.id), ["first", "second"]);
  assert.deepEqual(helpers.turnsFor(right).map((turn) => turn.id), ["other"]);
});

test("live snapshot은 밀려난 turn을 제거하고 archive turn은 보존한다", () => {
  const suffix = Math.random().toString(36).slice(2);
  const characterId = `snapshot-${suffix}`;
  const turn = (id, startedAt) => ({ id, characterId, startedAt, prompt: id });

  helpers.applyLiveSnapshot([
    turn("live-old", "2026-08-14T01:00:00.000Z"),
    turn("live-kept", "2026-08-14T02:00:00.000Z"),
  ]);
  helpers.mergeArchiveTurns([
    turn("archive-kept", "2026-08-14T00:00:00.000Z"),
  ]);
  helpers.applyLiveSnapshot([
    turn("live-kept", "2026-08-14T02:00:00.000Z"),
    turn("live-new", "2026-08-14T03:00:00.000Z"),
  ]);

  assert.deepEqual(
    helpers.turnsFor(characterId).map((candidate) => candidate.id),
    ["archive-kept", "live-kept", "live-new"],
  );
});

test("optimistic local ID는 server ID로 한 번에 교체된다", () => {
  const suffix = Math.random().toString(36).slice(2);
  const characterId = `reconcile-${suffix}`;
  const localId = `local-${suffix}`;
  const serverId = `server-${suffix}`;

  globalThis.OFFICESTRAConversation.upsertTurn({
    id: localId,
    characterId,
    startedAt: "2026-08-14T01:00:00.000Z",
    prompt: "낙관적 질문",
  });

  assert.equal(
    globalThis.OFFICESTRAConversation.reconcileTurnId(
      localId,
      serverId,
      characterId,
    ),
    true,
  );
  assert.deepEqual(
    helpers.turnsFor(characterId).map(({ id, prompt }) => ({ id, prompt })),
    [{ id: serverId, prompt: "낙관적 질문" }],
  );
});

test("conversation web 자산은 외부 CDN 없이 독립 실행된다", async () => {
  const [html, css, javascript] = await Promise.all([
    readFile(join(assetRoot, "index.html"), "utf8"),
    readFile(join(assetRoot, "app.css"), "utf8"),
    readFile(join(assetRoot, "app.js"), "utf8"),
  ]);

  assert.match(html, /href="app\.css"/);
  assert.match(html, /src="app\.js"/);
  assert.doesNotMatch(`${html}\n${css}\n${javascript}`, /cdn\.|unpkg|jsdelivr/i);
  assert.match(css, /overflow-anchor:\s*none/);
  assert.match(css, /#bottom-sentinel[\s\S]*overflow-anchor:\s*auto/);
  assert.match(javascript, /messageHandlers\?\.officestraConversation/);
  assert.match(javascript, /officestra:visibility/);
  assert.match(javascript, /type:\s*"answerQuestion",\s*text:\s*answer/);
  assert.match(javascript, /\/api\/live-feed/);
  assert.match(javascript, /\/api\/archive-feed/);
  assert.match(javascript, /new WebSocket/);
  assert.match(javascript, /function disconnectWebSocket\(\)/);
  assert.match(
    javascript,
    /if \(!next && state\.transport === "direct"\) disconnectWebSocket\(\)/,
  );
});

test("완료 상태의 현재 확인 질문만 답변 입력을 표시한다", () => {
  globalThis.OFFICESTRAConversation.setPendingQuestionTurnIds([
    "current-question",
  ]);

  assert.equal(
    helpers.showsQuestionComposer({
      id: "current-question",
      status: "completed",
      needsInput: true,
    }),
    true,
  );
  assert.equal(
    helpers.showsQuestionComposer({
      id: "answered-old-question",
      status: "completed",
      needsInput: true,
    }),
    false,
  );
});

test("답변 전송 실패로 pending ID가 복원되면 질문 입력도 복원한다", () => {
  const turnId = `restored-question-${Math.random().toString(36).slice(2)}`;
  const turn = {
    id: turnId,
    status: "completed",
    needsInput: true,
  };

  globalThis.OFFICESTRAConversation.setPendingQuestionTurnIds([turnId]);
  helpers.dismissQuestionTurn(turnId);
  assert.equal(helpers.showsQuestionComposer(turn), false);

  globalThis.OFFICESTRAConversation.setPendingQuestionTurnIds([turnId]);
  assert.equal(helpers.showsQuestionComposer(turn), true);
});

test("같은 길이의 응답 교체도 카드 revision을 바꾼다", () => {
  const original = helpers.normalizeTurn({
    id: "same-length",
    characterId: "right-man",
    updatedAt: "2026-08-14T00:00:00.000Z",
    response: "old",
  });
  const replacement = { ...original, response: "new" };

  assert.notEqual(
    helpers.revisionFor(original),
    helpers.revisionFor(replacement),
  );
});

test("출처, 경고, 작업공간 파일 변경도 카드 revision에 포함한다", () => {
  const original = helpers.normalizeTurn({
    id: "metadata-revision",
    characterId: "left-woman",
    updatedAt: "2026-08-14T00:00:00.000Z",
    response: "완료",
    sources: [],
    workspace: {
      status: "awaiting_approval",
      reviewTree: "tree-1",
      changedFiles: [{ status: "M", path: "first.swift" }],
    },
  });
  const sourceChanged = {
    ...original,
    sources: [{
      id: "source-1",
      sourceKind: "file",
      title: "근거",
      locator: "Sources/first.swift",
    }],
  };
  const warningChanged = {
    ...original,
    responseSourceWarning: "출처 확인 필요",
  };
  const workspaceChanged = {
    ...original,
    workspace: {
      ...original.workspace,
      changedFiles: [{ status: "M", path: "second.swift" }],
    },
  };

  assert.notEqual(helpers.revisionFor(original), helpers.revisionFor(sourceChanged));
  assert.notEqual(helpers.revisionFor(original), helpers.revisionFor(warningChanged));
  assert.notEqual(helpers.revisionFor(original), helpers.revisionFor(workspaceChanged));
});

test("수동 작업공간 승인은 상세 GET과 diff 확인 전까지 잠긴다", async () => {
  const suffix = Math.random().toString(36).slice(2);
  const characterId = `workspace-review-${suffix}`;
  const turnId = `turn-${suffix}`;
  const summaryWorkspace = {
    status: "awaiting_approval",
    branchName: "task/test",
    baseBranch: "main",
    reviewTree: "review-tree-1",
    headCommit: "head-1",
    changedFiles: [{ status: "M", path: "summary.txt" }],
    automaticApprovalPending: false,
  };
  helpers.mergeTurns([{
    id: turnId,
    characterId,
    startedAt: "2026-08-14T00:00:00.000Z",
    workspace: summaryWorkspace,
  }]);
  const turn = helpers.turnsFor(characterId)[0];
  const originalFetch = globalThis.fetch;
  let request = null;
  globalThis.OFFICESTRAConversation.configure({
    baseURL: "http://127.0.0.1:4317",
  });
  globalThis.fetch = async (url, options) => {
    request = { url: String(url), options };
    return {
      ok: true,
      status: 200,
      json: async () => ({
        workspace: {
          ...summaryWorkspace,
          changedFiles: [{ status: "M", path: "detail.txt" }],
          diff: "diff --git a/detail.txt b/detail.txt",
          diffTruncated: false,
        },
      }),
    };
  };

  try {
    assert.equal(helpers.workspaceReviewIsManual(turn.workspace), true);
    assert.equal(helpers.workspaceReviewCanDecide(turn), false);
    assert.equal(await helpers.loadWorkspaceReview(turn), true);
    assert.equal(
      request.url,
      `http://127.0.0.1:4317/api/workspace-reviews/${turnId}`,
    );
    assert.equal(request.options.method, undefined);
    assert.equal(
      helpers.workspaceForDisplay(turn).diff,
      "diff --git a/detail.txt b/detail.txt",
    );
    assert.equal(helpers.workspaceReviewCanDecide(turn), false);
    assert.equal(helpers.markWorkspaceDiffInspected(turn), true);
    assert.equal(helpers.workspaceReviewCanDecide(turn), true);

    helpers.mergeTurns([{
      id: turnId,
      characterId,
      startedAt: "2026-08-14T00:00:00.000Z",
      workspace: summaryWorkspace,
    }]);
    const refreshed = helpers.turnsFor(characterId)[0];
    assert.equal(
      helpers.workspaceForDisplay(refreshed).diff,
      "diff --git a/detail.txt b/detail.txt",
    );
    assert.equal(helpers.workspaceReviewCanDecide(refreshed), true);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("자동 승인 대기 작업공간은 수동 승인 대상으로 열지 않는다", () => {
  const workspace = {
    status: "awaiting_approval",
    reviewTree: "automatic-tree",
    automaticApprovalPending: true,
  };

  assert.equal(helpers.workspaceReviewIsManual(workspace), false);
});

test("keyed DOM 조정은 그대로인 카드 노드를 제거하거나 재생성하지 않는다", () => {
  const first = { dataset: { turnId: "first" } };
  const second = { dataset: { turnId: "second" } };
  const added = { dataset: { turnId: "added" } };
  const parent = fakeParent([first, second]);

  helpers.reconcileKeyedChildren(parent, [first, added, second]);

  assert.deepEqual(parent.children, [first, added, second]);
  assert.equal(parent.children[0], first);
  assert.equal(parent.children[2], second);
  assert.deepEqual(parent.removed, []);
});

test("숨은 직원 페이지는 WebSocket 이벤트를 fetch하지 않는다", () => {
  globalThis.OFFICESTRAConversation.setVisibility(false);
  assert.equal(helpers.shouldRefreshRealtime(), false);

  globalThis.OFFICESTRAConversation.setVisibility(true);
  assert.equal(helpers.shouldRefreshRealtime(), true);
});

test("실행 모델, 추론, 모드, 비용과 문맥 사용률을 표시용 값으로 만든다", () => {
  const turn = {
    characterName: "코대리",
    backend: "claude",
    model: "claude-opus-5",
    effort: "high",
    fastMode: true,
    estimatedCostUsd: 1.234,
    sessionContext: { usedTokens: 25_000, limitTokens: 100_000 },
  };

  assert.equal(
    helpers.turnTitleText(turn),
    "코대리 · claude · claude-opus-5 · high · Fast",
  );
  assert.deepEqual(helpers.turnMetaDetails(turn), ["$1.23", "문맥 25%"]);
});

test("협업 활동은 담당자, 동작, 프롬프트, 결과와 상태를 보존한다", () => {
  const text = helpers.activityDisplayText({
    kind: "collaboration",
    text: "협업 완료",
    collaboration: {
      agentLabel: "검증 담당",
      action: "spawn",
      agentStatus: "completed",
      prompt: "회귀를 확인해 주세요",
      message: "문제 없음",
    },
  });

  assert.match(text, /검증 담당 · spawn · completed/);
  assert.match(text, /회귀를 확인해 주세요/);
  assert.match(text, /문제 없음/);
  assert.match(text, /협업 완료/);
});

function fakeParent(initialChildren) {
  return {
    children: [...initialChildren],
    removed: [],
    insertBefore(node, referenceNode) {
      const previousIndex = this.children.indexOf(node);
      if (previousIndex >= 0) this.children.splice(previousIndex, 1);
      const referenceIndex = referenceNode == null
        ? this.children.length
        : this.children.indexOf(referenceNode);
      this.children.splice(
        referenceIndex < 0 ? this.children.length : referenceIndex,
        0,
        node,
      );
      return node;
    },
    removeChild(node) {
      const index = this.children.indexOf(node);
      if (index >= 0) this.children.splice(index, 1);
      this.removed.push(node);
      return node;
    },
  };
}
