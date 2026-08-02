// 이 파일은 자동 승인 설정 API와 기본 활성화 DB 계약을 검증한다.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const serverSource = readFileSync(
  new URL("../src/server.mjs", import.meta.url),
  "utf8",
);
const migrationSource = readFileSync(
  new URL(
    "../../database/migrations/016_automatic_workspace_approval.sql",
    import.meta.url,
  ),
  "utf8",
);

test("자동 승인 설정 API는 동일한 공개 JSON 키로 조회하고 저장한다", () => {
  assert.match(
    serverSource,
    /GET[\s\S]*\/api\/automation-settings/,
  );
  assert.match(
    serverSource,
    /PUT[\s\S]*\/api\/automation-settings/,
  );
  assert.match(
    serverSource,
    /auto_approve_workspaces AS "autoApproveAndMerge"/,
  );
  assert.match(
    serverSource,
    /typeof body\.autoApproveAndMerge !== "boolean"/,
  );
  assert.match(
    serverSource,
    /\[body\.autoApproveAndMerge\]/,
  );
});

test("자동 승인은 기본 활성화되고 workspace 재시도 횟수는 0부터 시작한다", () => {
  assert.match(
    migrationSource,
    /auto_approve_workspaces boolean NOT NULL DEFAULT true/,
  );
  assert.match(
    migrationSource,
    /SET auto_approve_workspaces = true/,
  );
  assert.match(
    serverSource,
    /result\.rows\?\.\[0\]\?\.autoApproveAndMerge\s*\?\? true/,
  );
  assert.match(
    migrationSource,
    /auto_retry_count integer/,
  );
  assert.match(
    migrationSource,
    /ALTER COLUMN auto_retry_count SET DEFAULT 0/,
  );
  assert.match(
    migrationSource,
    /CHECK \(auto_retry_count BETWEEN 0 AND 3\)/,
  );
  assert.match(
    migrationSource,
    /auto_repair_paused boolean/,
  );
  assert.match(
    migrationSource,
    /ALTER COLUMN auto_repair_paused SET DEFAULT false/,
  );
  assert.match(
    migrationSource,
    /auto_waiting_for_peer boolean/,
  );
  assert.match(
    migrationSource,
    /ALTER COLUMN auto_waiting_for_peer SET DEFAULT false/,
  );
  assert.match(
    serverSource,
    /'autoRetryCount', task_workspace\.auto_retry_count/,
  );
});

test("자동 승인 설정을 다시 켜면 보류된 승인 queue를 즉시 재개한다", () => {
  const updateStart = serverSource.indexOf(
    "async function updateAutomationSettings",
  );
  const updateEnd = serverSource.indexOf(
    "async function updateCharacterName",
  );
  const updateSource = serverSource.slice(updateStart, updateEnd);

  assert.match(updateSource, /if \(body\.autoApproveAndMerge\)/);
  assert.match(
    updateSource,
    /runtime\?\.resumePendingAutomaticWorkspaceApprovals\(\)/,
  );
});

test("백엔드 시작은 중단 복구 뒤 기존 자동 승인 대기를 이어서 처리한다", () => {
  const recoverIndex = serverSource.indexOf(
    "await runtime.recoverInterruptedJobs()",
  );
  const approvalIndex = serverSource.indexOf(
    "await runtime.resumePendingAutomaticWorkspaceApprovals()",
  );
  const wakeIndex = serverSource.indexOf(
    "await runtime.wakePeerWaitingAutomaticApprovals({ resume: false })",
  );
  const listenIndex = serverSource.indexOf("server.listen(");

  assert.ok(recoverIndex >= 0);
  assert.ok(wakeIndex > recoverIndex);
  assert.ok(approvalIndex > wakeIndex);
  assert.ok(listenIndex > approvalIndex);
});
