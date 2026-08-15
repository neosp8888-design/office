// 이 파일은 직원이 쓰는 CLI의 설치본과 배포 최신본을 비교하고 갱신한다.

import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export const CLI_PACKAGES = Object.freeze([
  Object.freeze({
    id: "claude",
    label: "Claude Code",
    packageName: "@anthropic-ai/claude-code",
    backend: "claude",
    executable: "claude",
    versionArguments: ["--version"],
  }),
  Object.freeze({
    id: "codex",
    label: "Codex",
    packageName: "@openai/codex",
    backend: "codex",
    executable: "codex",
    versionArguments: ["--version"],
  }),
]);

/// 조회는 네트워크를 타므로 화이트보드 주기보다 짧게 다시 묻지 않는다.
export const UPDATE_CACHE_MILLISECONDS = 9 * 60 * 1000;
const COMMAND_TIMEOUT_MILLISECONDS = 20_000;

/// 설치는 실제로 쓰는 실행 파일이 있는 곳에 해야 한다. 앱 번들 Node가
/// PATH 앞에 있으면 npm이 자기 자리를 앱 안으로 판단해, 갱신이 번들
/// 안으로 들어가고 정작 직원이 쓰는 CLI는 예전 버전으로 남는다.
export function npmPrefixForExecutable(executablePath) {
  const marker = "/lib/node_modules/";
  const index = String(executablePath ?? "").indexOf(marker);
  if (index < 0) {
    return null;
  }
  return String(executablePath).slice(0, index);
}
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

async function readExecutablePath(entry, runCommand) {
  try {
    const { stdout } = await runCommand("which", [entry.executable], {
      timeout: COMMAND_TIMEOUT_MILLISECONDS,
    });
    const path = String(stdout ?? "").trim().split("\n")[0];
    if (!path) {
      return null;
    }
    // 심볼릭 링크를 따라가야 실제 설치 위치가 나온다.
    const { stdout: resolved } = await runCommand("readlink", ["-f", path], {
      timeout: COMMAND_TIMEOUT_MILLISECONDS,
    });
    return String(resolved ?? "").trim() || path;
  } catch {
    return null;
  }
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
        const [installed, latest, executablePath] = await Promise.all([
          readInstalledVersion(entry, runCommand),
          readLatestVersion(entry, runCommand),
          readExecutablePath(entry, runCommand),
        ]);
        return {
          id: entry.id,
          label: entry.label,
          packageName: entry.packageName,
          installedVersion: installed,
          latestVersion: latest,
          installPrefix: npmPrefixForExecutable(executablePath),
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
export class CLIUpdateUnknownPackageError extends Error {}

/// 하나만 고를 수 있어야 한다. 한쪽만 새 버전이 나왔는데 둘 다 건드릴
/// 이유가 없다.
export function packageNamesForIdentifier(identifier) {
  return packagesForIdentifier(identifier).map((entry) => entry.packageName);
}

export function packagesForIdentifier(identifier) {
  if (identifier == null || identifier === "") {
    return [...CLI_PACKAGES];
  }
  const entry = CLI_PACKAGES.find((item) => item.id === identifier);
  if (!entry) {
    throw new CLIUpdateUnknownPackageError(
      `알 수 없는 CLI입니다. ${identifier}`,
    );
  }
  return [entry];
}

/// 갱신을 막아야 하는 것은 그 CLI를 쓰는 직원뿐이다. 클로드 직원이
/// 일하는 중이라고 코덱스 갱신까지 막을 이유가 없다.
export function backendsForIdentifier(identifier) {
  return packagesForIdentifier(identifier).map((entry) => entry.backend);
}

/// 대상 CLI들이 같은 곳에 설치돼 있을 때만 그 위치를 쓴다. 서로 다르면
/// 한 번의 설치로 둘 다 맞출 수 없으므로 npm 기본 판단에 맡긴다.
export function sharedInstallPrefix(status, identifier) {
  const wanted = new Set(
    packagesForIdentifier(identifier).map((entry) => entry.id),
  );
  const prefixes = new Set(
    (status?.packages ?? [])
      .filter((entry) => wanted.has(entry.id))
      .map((entry) => entry.installPrefix)
      .filter((value) => typeof value === "string" && value.length > 0),
  );
  return prefixes.size === 1 ? [...prefixes][0] : null;
}

export async function applyCLIUpdates({
  runCommand = execFileAsync,
  packageNames = CLI_PACKAGES.map((entry) => entry.packageName),
  backends = CLI_PACKAGES.map((entry) => entry.backend),
  prefix = null,
  hasRunningWork,
} = {}) {
  if (
    typeof hasRunningWork === "function" &&
    (await hasRunningWork(backends))
  ) {
    throw new CLIUpdateBusyError(
      "진행 중인 업무가 끝난 뒤에 업데이트할 수 있습니다.",
    );
  }
  const installArguments = prefix
    ? ["install", "-g", "--prefix", prefix, ...packageNames]
    : ["install", "-g", ...packageNames];
  const { stdout, stderr } = await runCommand(
    "npm",
    installArguments,
    { timeout: INSTALL_TIMEOUT_MILLISECONDS },
  );
  return {
    ok: true,
    output: String(stdout ?? "").trim() || String(stderr ?? "").trim(),
  };
}
