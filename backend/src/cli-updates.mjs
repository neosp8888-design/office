// 이 파일은 직원이 쓰는 CLI의 설치본과 배포 최신본을 비교하고 갱신한다.

import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export const CLI_PACKAGES = Object.freeze([
  Object.freeze({
    id: "claude",
    label: "Claude Code",
    packageName: "@anthropic-ai/claude-code",
    executable: "claude",
    versionArguments: ["--version"],
  }),
  Object.freeze({
    id: "codex",
    label: "Codex",
    packageName: "@openai/codex",
    executable: "codex",
    versionArguments: ["--version"],
  }),
]);

/// 조회는 네트워크를 타므로 화이트보드 주기보다 짧게 다시 묻지 않는다.
export const UPDATE_CACHE_MILLISECONDS = 9 * 60 * 1000;
const COMMAND_TIMEOUT_MILLISECONDS = 20_000;
const INSTALL_TIMEOUT_MILLISECONDS = 5 * 60 * 1000;

/// `claude 2.1.220 (Claude Code)`나 `codex-cli 0.146.0`처럼 서로 다른
/// 출력에서 버전만 뽑는다.
export function parseInstalledVersion(output) {
  const match = String(output ?? "").match(/\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?/);
  return match ? match[0] : null;
}

/// 사전순 비교로는 2.1.9와 2.1.10을 뒤집는다. 숫자 구간으로 끊어 비교하고,
/// 사전 배포 꼬리표가 붙은 쪽을 낮게 본다.
export function isUpdateAvailable(installed, latest) {
  if (!installed || !latest) {
    return false;
  }
  if (installed === latest) {
    return false;
  }
  const parse = (value) => {
    const [core, prerelease] = String(value).split(/[-+]/, 2);
    return {
      numbers: core.split(".").map((part) => Number.parseInt(part, 10) || 0),
      hasPrerelease: prerelease != null,
    };
  };
  const current = parse(installed);
  const candidate = parse(latest);
  const length = Math.max(current.numbers.length, candidate.numbers.length);
  for (let index = 0; index < length; index += 1) {
    const left = current.numbers[index] ?? 0;
    const right = candidate.numbers[index] ?? 0;
    if (left !== right) {
      return right > left;
    }
  }
  // 숫자가 같으면 사전 배포보다 정식 배포가 새것이다.
  return current.hasPrerelease && !candidate.hasPrerelease;
}

async function readInstalledVersion(entry, runCommand) {
  try {
    const { stdout } = await runCommand(
      entry.executable,
      entry.versionArguments,
      { timeout: COMMAND_TIMEOUT_MILLISECONDS },
    );
    return parseInstalledVersion(stdout);
  } catch {
    return null;
  }
}

async function readLatestVersion(entry, runCommand) {
  try {
    const { stdout } = await runCommand(
      "npm",
      ["view", entry.packageName, "version"],
      { timeout: COMMAND_TIMEOUT_MILLISECONDS },
    );
    return parseInstalledVersion(stdout);
  } catch {
    return null;
  }
}

export function createCLIUpdateChecker({
  runCommand = execFileAsync,
  now = () => Date.now(),
  cacheDuration = UPDATE_CACHE_MILLISECONDS,
} = {}) {
  let cached = null;

  async function read({ force = false } = {}) {
    if (!force && cached && now() - cached.checkedAtMilliseconds < cacheDuration) {
      return cached.payload;
    }
    const packages = await Promise.all(
      CLI_PACKAGES.map(async (entry) => {
        const [installed, latest] = await Promise.all([
          readInstalledVersion(entry, runCommand),
          readLatestVersion(entry, runCommand),
        ]);
        return {
          id: entry.id,
          label: entry.label,
          packageName: entry.packageName,
          installedVersion: installed,
          latestVersion: latest,
          updateAvailable: isUpdateAvailable(installed, latest),
        };
      }),
    );
    const payload = {
      checkedAt: new Date(now()).toISOString(),
      updateAvailable: packages.some((entry) => entry.updateAvailable),
      packages,
    };
    cached = { checkedAtMilliseconds: now(), payload };
    return payload;
  }

  function invalidate() {
    cached = null;
  }

  return { read, invalidate };
}

export class CLIUpdateBusyError extends Error {}

/// 실행 중인 업무가 있으면 갱신하지 않는다. 세션이 쓰는 실행 파일을
/// 도중에 갈아 끼우면 그 대화가 깨진다.
export async function applyCLIUpdates({
  runCommand = execFileAsync,
  packageNames = CLI_PACKAGES.map((entry) => entry.packageName),
  hasRunningWork,
} = {}) {
  if (typeof hasRunningWork === "function" && (await hasRunningWork())) {
    throw new CLIUpdateBusyError(
      "진행 중인 업무가 끝난 뒤에 갱신할 수 있습니다.",
    );
  }
  const { stdout, stderr } = await runCommand(
    "npm",
    ["install", "-g", ...packageNames],
    { timeout: INSTALL_TIMEOUT_MILLISECONDS },
  );
  return {
    ok: true,
    output: String(stdout ?? "").trim() || String(stderr ?? "").trim(),
  };
}
