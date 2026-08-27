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
    models: Object.freeze([
      "gemini-3.7-flash",
      "gemini-3.6-flash",
      "gemini-3.5-flash",
      "gemini-3.1-pro",
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
