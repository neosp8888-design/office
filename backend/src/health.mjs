// 이 파일은 4317 포트의 프로세스가 현재 OFFICESTRA 백엔드인지 식별한다.

export const OFFICE_BACKEND_SERVICE = "officestra-backend";
export const OFFICE_BACKEND_API_VERSION = 1;

export function officeBackendMaintenanceStatus(runtime) {
  if (typeof runtime?.maintenanceStatus === "function") {
    return runtime.maintenanceStatus();
  }
  const activeTurnCount = runtime?.running?.size ?? 0;
  const draining = runtime?.draining === true;
  return {
    acceptingJobs: Boolean(runtime) && !draining,
    draining,
    activeTurnCount,
    idle: activeTurnCount === 0,
  };
}

export function officeBackendHealth({
  runtime,
  pid = process.pid,
  databaseOK = true,
  releaseID = process.env.OFFICESTRA_RELEASE_ID ?? null,
} = {}) {
  const maintenance = officeBackendMaintenanceStatus(runtime);
  return {
    ok: true,
    service: OFFICE_BACKEND_SERVICE,
    apiVersion: OFFICE_BACKEND_API_VERSION,
    pid,
    releaseID,
    ...maintenance,
    workdir: runtime?.workdir ?? null,
    repositoryRoot: runtime?.repositoryRoot ?? null,
    database: { ok: databaseOK },
  };
}
