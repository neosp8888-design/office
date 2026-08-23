// 신규 업무의 공유 폴더 직렬 실행과 과거 workspace 호환 경계를 검증한다.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const serverSource = readFileSync(
  new URL("../src/server.mjs", import.meta.url),
  "utf8",
);
const runtimeSource = readFileSync(
  new URL("../src/agent-runtime.mjs", import.meta.url),
  "utf8",
);
const settingsViewSource = readFileSync(
  new URL("../../Sources/OfficeGame/OfficeGameApp.swift", import.meta.url),
  "utf8",
);
const directorSource = readFileSync(
  new URL("../../Sources/OfficeGame/AgentDirector.swift", import.meta.url),
  "utf8",
);
const dashboardSource = readFileSync(
  new URL(
    "../../Sources/OfficeGame/OfficeDashboardPanels.swift",
    import.meta.url,
  ),
  "utf8",
);
const slackSource = readFileSync(
  new URL("../src/slack-bridge.mjs", import.meta.url),
  "utf8",
);
const migrationSource = readFileSync(
  new URL(
    "../../database/migrations/026_remove_automatic_workspace_approval.sql",
    import.meta.url,
  ),
  "utf8",
);

test("자동 승인 설정 API와 주기 실행 경로를 제공하지 않는다", () => {
  assert.doesNotMatch(serverSource, /\/api\/automation-settings/);
  assert.doesNotMatch(
    serverSource,
    /resumePendingAutomaticWorkspaceApprovals|startAutomaticWorkspaceApprovalRetryLoop/,
  );
  assert.doesNotMatch(
    runtimeSource,
    /handleAutomaticWorkspaceApproval|resumeWorkspaceForAutomaticRepair/,
  );
});

test("신규 업무는 worktree 없이 공유 폴더에서 직원별로 즉시 실행한다", () => {
  const startAcceptedSource = runtimeSource.slice(
    runtimeSource.indexOf("async startAccepted("),
    runtimeSource.indexOf("async ensureWorkspace("),
  );
  assert.match(startAcceptedSource, /isolateGitWorkdir: false/);
  assert.match(startAcceptedSource, /workspace: null/);
  assert.match(startAcceptedSource, /workdir: this\.workdir/);
  assert.match(startAcceptedSource, /this\.running\.set\(characterID, state\)/);
  assert.doesNotMatch(startAcceptedSource, /ensureWorkspace\(/);
  assert.doesNotMatch(runtimeSource, /this\.executionQueue = \[\]/);
  assert.doesNotMatch(runtimeSource, /activeExecutionState/);
});

test("앱은 통합 대기 상태로 업무·설정·화면을 차단하지 않는다", () => {
  assert.doesNotMatch(settingsViewSource, /autoApproveAndMerge/);
  assert.doesNotMatch(directorSource, /pendingWorkspaceReviewCharacters/);
  assert.doesNotMatch(dashboardSource, /WorkspaceReviewPanel\(/);
  assert.doesNotMatch(
    slackSource,
    /officestra\.workspace-approve|officestra\.workspace-reject|변경 통합 대기|통합 충돌/,
  );
});

test("과거 workspace 정리를 위한 호환 API는 유지한다", () => {
  assert.match(serverSource, /function routeWorkspaceReview/);
  assert.match(serverSource, /\(approve\|reject\)/);
  assert.match(serverSource, /route\.action === "approve"/);
  assert.match(runtimeSource, /async approveWorkspace\(/);
  assert.match(runtimeSource, /workspaceManager\.approve\(/);
});

test("마이그레이션은 자동 처리 상태를 제거하고 실행 workspace만 제한한다", () => {
  assert.match(migrationSource, /DROP TABLE IF EXISTS automation_settings/);
  assert.match(migrationSource, /DROP COLUMN IF EXISTS auto_retry_count/);
  assert.match(migrationSource, /DROP COLUMN IF EXISTS auto_repair_paused/);
  assert.match(migrationSource, /DROP COLUMN IF EXISTS auto_waiting_for_peer/);
  assert.match(
    migrationSource,
    /WHERE status IN \('provisioning', 'active'\)/,
  );
  assert.doesNotMatch(
    migrationSource.slice(migrationSource.lastIndexOf("CREATE UNIQUE INDEX")),
    /awaiting_approval|conflict|merging/,
  );
});
