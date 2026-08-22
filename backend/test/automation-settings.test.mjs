// 자동 승인·병합 제거와 명시적 통합 대기 계약을 검증한다.

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
const reviewViewSource = readFileSync(
  new URL(
    "../../Sources/OfficeGame/WorkspaceReviewView.swift",
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

test("완료된 변경은 자동 통합 없이 명시적 통합 대기로 저장한다", () => {
  assert.match(
    runtimeSource,
    /workspaceReview\.hasChanges\s*\?\s*"awaiting_approval"/,
  );
  assert.doesNotMatch(runtimeSource, /SELECT auto_approve_workspaces/);
  assert.doesNotMatch(runtimeSource, /auto_repair_paused|auto_waiting_for_peer/);
});

test("설정과 검토 화면은 자동·수동 병합 조작을 노출하지 않는다", () => {
  assert.doesNotMatch(settingsViewSource, /autoApproveAndMerge/);
  assert.doesNotMatch(
    reviewViewSource,
    /approveWorkspace-|rejectWorkspace-|retryWorkspace-/,
  );
  assert.match(reviewViewSource, /변경사항 통합 대기/);
  assert.doesNotMatch(
    slackSource,
    /officestra\.workspace-approve|officestra\.workspace-reject/,
  );
});

test("클대리의 명시적 통합에 필요한 핵심 API는 유지한다", () => {
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
