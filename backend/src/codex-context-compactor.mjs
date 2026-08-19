// Codex app-server의 네이티브 thread/compact/start를 한 번 실행한다.

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const DEFAULT_TIMEOUT_MS = 10 * 60 * 1_000;
const STDERR_TAIL_BYTES = 8_192;

export async function compactCodexThread({
  executable,
  threadID,
  cwd,
  env,
  contextWindow = null,
  autoCompactTokenLimit = null,
  spawnProcess = spawn,
  timeoutMs = DEFAULT_TIMEOUT_MS,
}) {
  const argumentsList = [];
  if (contextWindow > 0 && autoCompactTokenLimit > 0) {
    argumentsList.push(
      "-c",
      `model_context_window=${contextWindow}`,
      "-c",
      `model_auto_compact_token_limit=${autoCompactTokenLimit}`,
    );
  }
  argumentsList.push("app-server", "--stdio");
  const child = spawnProcess(executable, argumentsList, {
    cwd,
    env,
    stdio: ["pipe", "pipe", "pipe"],
    shell: false,
    detached: false,
  });
  const pending = new Map();
  let nextID = 1;
  let stderrTail = "";
  let compacted = false;
  let compactResolve;
  let compactReject;
  const compactedPromise = new Promise((resolve, reject) => {
    compactResolve = resolve;
    compactReject = reject;
  });
  // 비동기 초기화·resume·compact 어느 단계에서 멈춰도 같은 제한으로
  // pending 요청까지 모두 종료한다.
  const timeout = setTimeout(() => {
    fail(new Error("Codex 컨텍스트 압축 시간이 초과됐습니다."));
  }, timeoutMs);
  timeout.unref?.();
  // 초기화 요청이 먼저 실패해도 completion rejection이 unhandled로
  // 보고되지 않게 소비자를 즉시 연결한다. 실제 오류는 아래 await가 전달한다.
  void compactedPromise.catch(() => {});

  child.stderr?.on("data", (chunk) => {
    stderrTail = `${stderrTail}${String(chunk ?? "")}`
      .slice(-STDERR_TAIL_BYTES);
  });

  function finishCompaction(value = {}) {
    if (compacted) return;
    compacted = true;
    compactResolve(value);
  }

  function fail(error) {
    const failure = error instanceof Error ? error : new Error(String(error));
    for (const request of pending.values()) {
      request.reject(failure);
    }
    pending.clear();
    compactReject(failure);
  }

  function send(object) {
    if (!child.stdin?.writable) {
      throw new Error("Codex app-server 입력 스트림이 닫혔습니다.");
    }
    child.stdin.write(`${JSON.stringify(object)}\n`);
  }

  function request(method, params) {
    const id = nextID++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      try {
        send({ id, method, params });
      } catch (error) {
        pending.delete(id);
        reject(error);
      }
    });
  }

  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  const outputTask = (async () => {
    for await (const line of lines) {
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        continue;
      }
      if (Object.prototype.hasOwnProperty.call(message, "id")) {
        const response = pending.get(message.id);
        if (response) {
          pending.delete(message.id);
          if (message.error) {
            response.reject(
              new Error(
                String(message.error.message ?? "Codex 요청이 실패했습니다."),
              ),
            );
          } else {
            response.resolve(message.result);
          }
          continue;
        }
        // 압축 중 서버가 권한이나 사용자 입력을 요구하면 headless 호출은
        // 안전하게 응답할 수 없으므로 즉시 거부한다.
        if (message.method) {
          send({
            id: message.id,
            error: {
              code: -32601,
              message: "OFFICESTRA 압축 호출은 상호작용을 지원하지 않습니다.",
            },
          });
          fail(new Error("Codex 압축 중 사용자 상호작용이 필요합니다."));
        }
        continue;
      }
      if (message.method === "item/completed") {
        const params = message.params ?? {};
        if (
          params.threadId === threadID &&
          params.item?.type === "contextCompaction"
        ) {
          finishCompaction({ turnID: params.turnId ?? null });
        }
      } else if (message.method === "thread/compacted") {
        const params = message.params ?? {};
        if (params.threadId === threadID) {
          finishCompaction({ turnID: params.turnId ?? null });
        }
      } else if (
        message.method === "error" &&
        message.params?.threadId === threadID &&
        message.params?.willRetry !== true
      ) {
        fail(
          new Error(
            String(
              message.params?.error?.message ??
                "Codex 컨텍스트 압축이 실패했습니다.",
            ),
          ),
        );
      } else if (
        message.method === "turn/completed" &&
        message.params?.threadId === threadID &&
        message.params?.turn?.status === "failed"
      ) {
        fail(
          new Error(
            String(
              message.params?.turn?.error?.message ??
                "Codex 컨텍스트 압축이 실패했습니다.",
            ),
          ),
        );
      }
    }
  })().catch(fail);

  child.once("error", fail);
  child.once("close", (code, signal) => {
    if (compacted) return;
    const diagnostic = stderrTail.trim();
    const suffix = diagnostic ? ` ${diagnostic}` : "";
    fail(
      new Error(
        signal
          ? `Codex app-server가 ${signal} 신호로 종료됐습니다.${suffix}`
          : `Codex app-server가 종료 코드 ${code ?? "unknown"}로 끝났습니다.${suffix}`,
      ),
    );
  });

  try {
    await request("initialize", {
      clientInfo: {
        name: "officestra",
        title: "OFFICESTRA",
        version: "1",
      },
      capabilities: {
        experimentalApi: false,
        requestAttestation: false,
      },
    });
    send({ method: "initialized" });
    await request("thread/resume", { threadId: threadID, cwd });
    await request("thread/compact/start", { threadId: threadID });
    return await compactedPromise;
  } finally {
    clearTimeout(timeout);
    try {
      child.stdin?.end();
    } catch {
      // 이미 종료 중인 스트림은 무시한다.
    }
    if (child.exitCode === null && child.signalCode === null) {
      child.kill("SIGTERM");
    }
    await Promise.race([
      outputTask,
      new Promise((resolve) => setTimeout(resolve, 100)),
    ]);
  }
}
