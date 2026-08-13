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

test("백엔드는 대기 중 자동 승인을 주기적으로 겹치지 않게 재시도한다", () => {
  assert.match(
    serverSource,
    /automaticWorkspaceApprovalRetryIntervalMs = 10_000/,
  );
  assert.match(
    serverSource,
    /if \(!runtime \|\| automaticWorkspaceApprovalRetryInFlight\)/,
  );
  assert.match(
    serverSource,
    /runtime\.resumePendingAutomaticWorkspaceApprovals\(\)/,
  );
  assert.match(serverSource, /timer\.unref\(\)/);
  assert.match(serverSource, /startAutomaticWorkspaceApprovalRetryLoop\(\)/);
});

test("live-feed는 자동 병합 예정 여부를 서버에서 판정해 내려준다", () => {
  // 앱이 설정과 상태를 따로 조합하면 타이밍에 따라 승인 버튼이
  // 잠깐 그려진다. 판정은 서버 한 곳에서만 한다.
  assert.match(serverSource, /'automaticApprovalPending', \(/);
  assert.match(
    serverSource,
    /task_workspace\.status = 'awaiting_approval'/,
  );
  assert.match(
    serverSource,
    /AND task_workspace\.auto_repair_paused = false/,
  );
  assert.match(
    serverSource,
    /SELECT auto_approve_workspaces\s+FROM automation_settings\s+WHERE singleton = true/,
  );
  // 설정 행이 없으면 기본 활성화 계약(true)을 따른다.
  assert.match(serverSource, /COALESCE\(\s+\(\s+SELECT auto_approve_workspaces/);
  // 최종 대기 판별에 필요한 원본 플래그도 함께 노출한다.
  assert.match(
    serverSource,
    /'autoRepairPaused', task_workspace\.auto_repair_paused/,
  );
});

test("검토 상세 조회는 설정을 읽지 못하면 수동 검토 화면으로 떨어진다", async () => {
  const { AgentRuntime } = await import("../src/agent-runtime.mjs");
  const runtime = new AgentRuntime({
    pool: {
      query: async () => {
        throw new Error("설정 조회 실패");
      },
    },
    withTransaction: async () => {},
    workdir: "/repo",
    broadcast: () => {},
  });

  assert.equal(
    await runtime.automaticWorkspaceApprovalEnabledBestEffort(),
    false,
  );
});

test("검토 상세 조회는 자동 승인 설정을 payload 판정에 넘긴다", () => {
  const runtimeSource = readFileSync(
    new URL("../src/agent-runtime.mjs", import.meta.url),
    "utf8",
  );
  assert.match(
    runtimeSource,
    /workspaceReviewPayload\(record\.workspace, diff, \{\s*automaticApprovalEnabled:/,
  );
  assert.match(
    runtimeSource,
    /automaticApprovalPending: Boolean\(\s*automaticApprovalEnabled/,
  );
  assert.match(
    runtimeSource,
    /&& workspace\.status === "awaiting_approval"\s*&& !workspace\.autoRepairPaused/,
  );
});
