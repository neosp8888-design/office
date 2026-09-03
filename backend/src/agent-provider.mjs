// 이 파일은 직원별 AI CLI의 실행 파일과 허용 설정을 한곳에서 정의한다.

const PROVIDERS = Object.freeze({
  codex: Object.freeze({
    executable: "codex",
    models: Object.freeze([
      "gpt-5.6-sol",
      "gpt-5.6-terra",
      "gpt-5.6-luna",
    ]),
    efforts: Object.freeze(["high", "xhigh", "max", "ultra"]),
    permissions: Object.freeze([
      "read-only",
      "workspace-write",
      "danger-full-access",
    ]),
  }),
  claude: Object.freeze({
    executable: "claude",
    models: Object.freeze([
      "claude-opus-5",
      "fable",
      "claude-sonnet-5",
    ]),
    efforts: Object.freeze(["high", "xhigh", "max"]),
    permissions: Object.freeze([
      "plan",
      "auto",
      "acceptEdits",
      "bypassPermissions",
    ]),
  }),
  antigravity: Object.freeze({
    executable: "agy",
    // 앞 두 개가 현재 고르는 목록이다. 아래 셋은 목록에서 내렸지만 이미
    // 직원 설정과 지난 턴에 남아 있으므로, 그 값을 다시 저장할 때 검증에서
    // 막히지 않도록 허용 목록에는 남긴다.
    models: Object.freeze([
      "gemini-3.8-flash",
      "gemini-3.1-pro",
      "gemini-3.7-flash",
      "gemini-3.6-flash",
      "gemini-3.5-flash",
    ]),
    efforts: Object.freeze(["low", "medium", "high"]),
    permissions: Object.freeze([
      "plan",
      "accept-edits",
      "dangerously-skip-permissions",
    ]),
  }),
});

export const AGENT_BACKENDS = Object.freeze(Object.keys(PROVIDERS));

export function agentProvider(backend) {
  return PROVIDERS[String(backend ?? "")] ?? null;
}

export function backendExecutableName(backend) {
  return agentProvider(backend)?.executable ?? String(backend ?? "");
}

export function backendModels(backend) {
  return agentProvider(backend)?.models ?? [];
}

export function backendEfforts(backend, model = null) {
  if (backend === "antigravity" && model === "gemini-3.1-pro") {
    return ["low", "high"];
  }
  return agentProvider(backend)?.efforts ?? [];
}

export function backendPermissions(backend) {
  return agentProvider(backend)?.permissions ?? [];
}

export function backendSupportsFastMode(backend, model) {
  return backend === "codex" ||
    (backend === "claude" && model === "claude-opus-5");
}

export function normalizedBackendPermission(backend, permission) {
  if (backend === "claude" && permission === "acceptEdits") {
    return "auto";
  }
  return permission;
}
