// 이 파일은 CLI 버전 비교와 갱신 실행 조건을 검증한다.

import assert from "node:assert/strict";
import test from "node:test";

import {
  CLIUpdateBusyError,
  CLIUpdateUnknownPackageError,
  applyCLIUpdates,
  backendsForIdentifier,
  packageNamesForIdentifier,
  createCLIUpdateChecker,
  isUpdateAvailable,
  parseInstalledVersion,
} from "../src/cli-updates.mjs";

test("서로 다른 출력 형식에서 설치 버전만 뽑는다", () => {
  assert.equal(
    parseInstalledVersion("2.1.220 (Claude Code)"),
    "2.1.220",
  );
  assert.equal(parseInstalledVersion("codex-cli 0.146.0"), "0.146.0");
  assert.equal(
    parseInstalledVersion("codex-cli 0.148.0-alpha.9"),
    "0.148.0-alpha.9",
  );
  assert.equal(parseInstalledVersion("버전 없음"), null);
  assert.equal(parseInstalledVersion(null), null);
});

test("버전 비교는 사전순이 아니라 숫자 구간으로 한다", () => {
  // 사전순으로 하면 2.1.9가 2.1.10보다 크다고 잘못 판정한다.
  assert.equal(isUpdateAvailable("2.1.9", "2.1.10"), true);
  assert.equal(isUpdateAvailable("2.1.10", "2.1.9"), false);
  assert.equal(isUpdateAvailable("2.1.220", "2.1.233"), true);
  assert.equal(isUpdateAvailable("2.1.233", "2.1.233"), false);
  assert.equal(isUpdateAvailable("0.146.0", "0.147.0"), true);
  assert.equal(isUpdateAvailable("1.9.0", "2.0.0"), true);
  assert.equal(isUpdateAvailable(null, "2.0.0"), false);
  assert.equal(isUpdateAvailable("2.0.0", null), false);
});

test("사전 배포본은 같은 숫자의 정식 배포본보다 낮게 본다", () => {
  assert.equal(isUpdateAvailable("0.148.0-alpha.9", "0.148.0"), true);
  assert.equal(isUpdateAvailable("0.148.0", "0.148.0-alpha.9"), false);
});

test("조회 결과는 캐시하고 강제 조회는 다시 묻는다", async () => {
  let calls = 0;
  let clock = 0;
  const checker = createCLIUpdateChecker({
    runCommand: async (command, args) => {
      calls += 1;
      if (command === "npm") {
        return { stdout: "2.1.233\n" };
      }
      void args;
      return { stdout: "2.1.220 (Claude Code)\n" };
    },
    now: () => clock,
    cacheDuration: 1_000,
  });

  const first = await checker.read();
  assert.equal(first.updateAvailable, true);
  assert.equal(first.packages.length, 2);
  const callsAfterFirst = calls;

  await checker.read();
  assert.equal(calls, callsAfterFirst, "캐시 동안에는 다시 묻지 않는다.");

  await checker.read({ force: true });
  assert.ok(calls > callsAfterFirst, "강제 조회는 다시 물어야 한다.");

  clock += 2_000;
  const callsBeforeExpiry = calls;
  await checker.read();
  assert.ok(
    calls > callsBeforeExpiry,
    "캐시가 만료되면 다시 물어야 한다.",
  );
});

test("버전 조회가 실패해도 갱신 여부만 모른 채 응답한다", async () => {
  const checker = createCLIUpdateChecker({
    runCommand: async () => {
      throw new Error("명령을 찾을 수 없습니다");
    },
    now: () => 0,
  });
  const status = await checker.read();
  assert.equal(status.updateAvailable, false);
  for (const entry of status.packages) {
    assert.equal(entry.installedVersion, null);
    assert.equal(entry.latestVersion, null);
    assert.equal(entry.updateAvailable, false);
  }
});

test("진행 중 업무가 있으면 갱신을 거부한다", async () => {
  let installed = false;
  await assert.rejects(
    applyCLIUpdates({
      runCommand: async () => {
        installed = true;
        return { stdout: "" };
      },
      hasRunningWork: async () => true,
    }),
    CLIUpdateBusyError,
  );
  assert.equal(
    installed,
    false,
    "세션이 쓰는 실행 파일을 도중에 갈아 끼우면 안 됩니다.",
  );
});

test("업무가 없으면 두 패키지를 한 번에 전역 설치한다", async () => {
  const commands = [];
  const result = await applyCLIUpdates({
    runCommand: async (command, args) => {
      commands.push([command, ...args]);
      return { stdout: "updated 2 packages\n" };
    },
    hasRunningWork: async () => false,
  });

  assert.equal(result.ok, true);
  assert.equal(commands.length, 1);
  assert.deepEqual(commands[0], [
    "npm",
    "install",
    "-g",
    "@anthropic-ai/claude-code",
    "@openai/codex",
  ]);
});

test("업데이트는 CLI별로 따로 고를 수 있다", () => {
  assert.deepEqual(
    packageNamesForIdentifier("claude"),
    ["@anthropic-ai/claude-code"],
  );
  assert.deepEqual(packageNamesForIdentifier("codex"), ["@openai/codex"]);
  // 지정이 없으면 둘 다 갱신한다.
  assert.deepEqual(packageNamesForIdentifier(null), [
    "@anthropic-ai/claude-code",
    "@openai/codex",
  ]);
  assert.throws(
    () => packageNamesForIdentifier("gemini"),
    CLIUpdateUnknownPackageError,
  );
});

test("한쪽만 고르면 그 패키지만 설치한다", async () => {
  const commands = [];
  await applyCLIUpdates({
    runCommand: async (command, args) => {
      commands.push([command, ...args]);
      return { stdout: "" };
    },
    packageNames: packageNamesForIdentifier("codex"),
    hasRunningWork: async () => false,
  });
  assert.deepEqual(commands[0], [
    "npm",
    "install",
    "-g",
    "@openai/codex",
  ]);
});

test("진행 중 업무 거부 문구는 업데이트라는 말을 쓴다", async () => {
  await assert.rejects(
    applyCLIUpdates({
      runCommand: async () => ({ stdout: "" }),
      hasRunningWork: async () => true,
    }),
    (error) =>
      error instanceof CLIUpdateBusyError &&
      error.message === "진행 중인 업무가 끝난 뒤에 업데이트할 수 있습니다.",
  );
});

test("갱신을 막는 판정은 그 CLI를 쓰는 직원만 본다", async () => {
  assert.deepEqual(backendsForIdentifier("claude"), ["claude"]);
  assert.deepEqual(backendsForIdentifier("codex"), ["codex"]);
  assert.deepEqual(backendsForIdentifier(null), ["claude", "codex"]);

  // 클로드 직원이 일하는 중이어도 코덱스는 갱신할 수 있어야 한다.
  const asked = [];
  const runningBackends = new Set(["claude"]);
  const result = await applyCLIUpdates({
    runCommand: async () => ({ stdout: "" }),
    packageNames: packageNamesForIdentifier("codex"),
    backends: backendsForIdentifier("codex"),
    hasRunningWork: async (backends) => {
      asked.push(backends);
      return backends.some((backend) => runningBackends.has(backend));
    },
  });
  assert.equal(result.ok, true);
  assert.deepEqual(asked, [["codex"]]);

  // 같은 CLI를 쓰는 직원이 일하는 중이면 막는다.
  await assert.rejects(
    applyCLIUpdates({
      runCommand: async () => ({ stdout: "" }),
      packageNames: packageNamesForIdentifier("claude"),
      backends: backendsForIdentifier("claude"),
      hasRunningWork: async (backends) =>
        backends.some((backend) => runningBackends.has(backend)),
    }),
    CLIUpdateBusyError,
  );
});
