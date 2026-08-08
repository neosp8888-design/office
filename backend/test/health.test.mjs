// 이 파일은 health 응답이 다른 4317 프로세스와 업무 폴더를 구분하는지 검증한다.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  OFFICE_BACKEND_API_VERSION,
  OFFICE_BACKEND_SERVICE,
  officeBackendHealth,
  officeBackendMaintenanceStatus,
} from "../src/health.mjs";

test("health 응답은 서비스와 실행 업무 폴더를 식별한다", () => {
  assert.deepEqual(
    officeBackendHealth({
      runtime: {
        workdir: "/Users/example/project",
        repositoryRoot: "/Users/example/project",
        running: new Map([["boss", {}]]),
      },
      pid: 4317,
      releaseID: "release-test",
    }),
    {
      ok: true,
      service: OFFICE_BACKEND_SERVICE,
      apiVersion: OFFICE_BACKEND_API_VERSION,
      pid: 4317,
      releaseID: "release-test",
      acceptingJobs: true,
      draining: false,
      activeTurnCount: 1,
      idle: false,
      workdir: "/Users/example/project",
      repositoryRoot: "/Users/example/project",
      database: { ok: true },
    },
  );
});

test("초기화 전 health 응답은 다른 서비스로 오인할 값을 만들지 않는다", () => {
  const health = officeBackendHealth({ runtime: undefined, pid: 7 });

  assert.equal(health.service, "officestra-backend");
  assert.equal(health.apiVersion, 1);
  assert.equal(health.workdir, null);
  assert.equal(health.repositoryRoot, null);
  assert.equal(health.acceptingJobs, false);
  assert.equal(health.draining, false);
  assert.equal(health.activeTurnCount, 0);
  assert.equal(health.idle, true);
});

test("DB 장애 health도 서비스 소유권과 복구 가능 상태를 보존한다", () => {
  const health = officeBackendHealth({
    runtime: {
      workdir: "/Users/example/project",
      repositoryRoot: "/Users/example/project",
    },
    pid: 4317,
    databaseOK: false,
  });

  assert.equal(health.ok, true);
  assert.equal(health.service, OFFICE_BACKEND_SERVICE);
  assert.equal(health.apiVersion, OFFICE_BACKEND_API_VERSION);
  assert.equal(health.workdir, "/Users/example/project");
  assert.equal(health.acceptingJobs, true);
  assert.equal(health.draining, false);
  assert.equal(health.activeTurnCount, 0);
  assert.equal(health.idle, true);
  assert.deepEqual(health.database, { ok: false });
});

test("health는 runtime의 원자적 drain 상태를 그대로 노출한다", () => {
  const status = {
    acceptingJobs: false,
    draining: true,
    activeTurnCount: 2,
    idle: false,
  };
  const runtime = {
    workdir: "/repo",
    repositoryRoot: "/repo",
    maintenanceStatus: () => status,
  };

  assert.deepEqual(officeBackendMaintenanceStatus(runtime), status);
  assert.deepEqual(
    {
      acceptingJobs: officeBackendHealth({ runtime }).acceptingJobs,
      draining: officeBackendHealth({ runtime }).draining,
      activeTurnCount: officeBackendHealth({ runtime }).activeTurnCount,
      idle: officeBackendHealth({ runtime }).idle,
    },
    status,
  );
});

test("서버는 drain 조회·시작·취소와 신규 업무 503 계약을 연결한다", () => {
  const serverSource = readFileSync(
    new URL("../src/server.mjs", import.meta.url),
    "utf8",
  );
  const maintenanceStart = serverSource.indexOf(
    "async function backendMaintenance",
  );
  const maintenanceEnd = serverSource.indexOf(
    "async function withCharacterSessionLock",
    maintenanceStart,
  );
  assert.ok(maintenanceStart >= 0 && maintenanceEnd > maintenanceStart);
  const maintenanceSource = serverSource.slice(
    maintenanceStart,
    maintenanceEnd,
  );

  assert.match(serverSource, /url\.pathname === "\/api\/maintenance\/drain"/);
  assert.match(maintenanceSource, /method === "GET"/);
  assert.match(maintenanceSource, /runtime\.beginDrain\(\)/);
  assert.match(maintenanceSource, /runtime\.cancelDrain\(\)/);
  assert.match(maintenanceSource, /officeBackendMaintenanceStatus\(runtime\)/);
  assert.match(serverSource, /error instanceof AgentDrainingError[\s\S]*503/);
});
