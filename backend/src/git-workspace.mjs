// 이 파일은 업무별 Git worktree를 만들고 검토된 변경만 원본 브랜치에 병합한다.

import { execFile, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import {
  access,
  lstat,
  mkdir,
  readlink,
  realpath,
} from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const DEFAULT_DIFF_BYTES = 512 * 1024;
const GIT_OUTPUT_BYTES = 8 * 1024 * 1024;
const FROZEN_WORK_RECORD_PATHS = new Set([
  "checklist.md",
  "context-notes.md",
]);
const ERROR_CODES = new Set([
  "not-clean",
  "changed-after-review",
  "conflict",
  "invalid-state",
  "command-failed",
]);

export class GitWorkspaceError extends Error {
  constructor(code, message, options = {}) {
    super(message, options);
    if (!ERROR_CODES.has(code)) {
      throw new TypeError(`지원하지 않는 Git workspace 오류 코드입니다: ${code}`);
    }
    this.name = "GitWorkspaceError";
    this.code = code;
  }
}

export class GitWorkspaceManager {
  constructor({ sourceWorkdir, worktreeRoot } = {}) {
    if (!sourceWorkdir) {
      throw new GitWorkspaceError(
        "invalid-state",
        "원본 작업 폴더가 필요합니다.",
      );
    }
    this.sourceWorkdir = resolve(sourceWorkdir);
    this.worktreeRoot = resolve(
      worktreeRoot ?? join(homedir(), ".officestra", "worktrees"),
    );
    this.approvalTail = Promise.resolve();
  }

  async isRepository() {
    const sourceWorkdir = await canonicalDirectory(this.sourceWorkdir);
    return Boolean(await repositoryRootFor(sourceWorkdir));
  }

  async planProvision({ workspaceID, characterID }) {
    const sourceWorkdir = await canonicalDirectory(this.sourceWorkdir);
    const repositoryRoot = await repositoryRootFor(sourceWorkdir);
    if (!repositoryRoot) {
      return null;
    }

    const worktreeRootRelative = relative(
      repositoryRoot,
      this.worktreeRoot,
    );
    if (!isOutsideDirectory(worktreeRootRelative)) {
      throw new GitWorkspaceError(
        "invalid-state",
        "worktree 보관 폴더는 원본 Git 저장소 밖에 있어야 합니다.",
      );
    }
    const sourceRelativePath = relative(repositoryRoot, sourceWorkdir);
    if (isOutsideDirectory(sourceRelativePath)) {
      throw new GitWorkspaceError(
        "invalid-state",
        "원본 작업 폴더가 Git 저장소 밖에 있습니다.",
      );
    }
    const baseBranch = await currentBranch(repositoryRoot);
    const baseCommit = await gitText(repositoryRoot, ["rev-parse", "HEAD"]);
    const branchName = workspaceBranchName(characterID, workspaceID);
    await requireMissingBranch(repositoryRoot, branchName);

    const repositoryKey = createHash("sha256")
      .update(repositoryRoot)
      .digest("hex")
      .slice(0, 12);
    const leafName = `${safeSegment(characterID)}-${safeSegment(workspaceID)}`;
    const worktreePath = join(this.worktreeRoot, repositoryKey, leafName);
    if (await pathExists(worktreePath)) {
      throw new GitWorkspaceError(
        "invalid-state",
        `이미 존재하는 업무 worktree 경로입니다: ${worktreePath}`,
      );
    }

    return {
      repositoryRoot,
      sourceWorkdir,
      worktreePath,
      executionWorkdir: sourceRelativePath
        ? join(worktreePath, sourceRelativePath)
        : worktreePath,
      branchName,
      baseBranch,
      baseCommit,
    };
  }

  async provisionPlanned(plan) {
    validateWorkspaceShape(plan);
    const repositoryRoot = await canonicalDirectory(plan.repositoryRoot);
    const sourceWorkdir = await canonicalDirectory(plan.sourceWorkdir);
    if (
      repositoryRoot !== plan.repositoryRoot ||
      sourceWorkdir !== plan.sourceWorkdir
    ) {
      throw new GitWorkspaceError(
        "invalid-state",
        "계획한 Git 작업 경로가 현재 경로와 다릅니다.",
      );
    }
    if (await currentBranch(repositoryRoot) !== plan.baseBranch) {
      throw new GitWorkspaceError(
        "invalid-state",
        "작업 공간 준비 중 원본 브랜치가 변경됐습니다.",
      );
    }
    const currentHead = await gitText(repositoryRoot, ["rev-parse", "HEAD"]);
    if (currentHead !== plan.baseCommit) {
      throw new GitWorkspaceError(
        "invalid-state",
        "작업 공간 준비 중 원본 커밋이 변경됐습니다.",
      );
    }
    await requireMissingBranch(repositoryRoot, plan.branchName);
    if (await pathExists(plan.worktreePath)) {
      throw new GitWorkspaceError(
        "invalid-state",
        `이미 존재하는 업무 worktree 경로입니다: ${plan.worktreePath}`,
      );
    }

    await mkdir(resolve(plan.worktreePath, ".."), { recursive: true });
    let addAttempted = false;
    try {
      addAttempted = true;
      await gitText(repositoryRoot, [
        "worktree",
        "add",
        "-b",
        plan.branchName,
        plan.worktreePath,
        plan.baseCommit,
      ]);

      const worktreePath = await canonicalDirectory(plan.worktreePath);
      const executionWorkdir = await canonicalDirectory(
        plan.executionWorkdir,
      );
      if (
        worktreePath !== plan.worktreePath ||
        executionWorkdir !== plan.executionWorkdir
      ) {
        throw new GitWorkspaceError(
          "invalid-state",
          "생성한 Git 작업 경로가 계획한 경로와 다릅니다.",
        );
      }

      return {
        ...plan,
        repositoryRoot,
        sourceWorkdir,
        worktreePath,
        executionWorkdir,
      };
    } catch (error) {
      if (addAttempted) {
        await cleanupFailedProvision({
          repositoryRoot,
          worktreePath: plan.worktreePath,
          branchName: plan.branchName,
        });
      }
      throw error;
    }
  }

  async provision(input) {
    const plan = await this.planProvision(input);
    return plan ? this.provisionPlanned(plan) : null;
  }

  async cleanupProvisioning(plan) {
    validateWorkspaceShape(plan);
    const sourceWorkdir = await canonicalDirectory(this.sourceWorkdir);
    const repositoryRoot = await canonicalDirectory(plan.repositoryRoot);
    const managerRepositoryRoot = await repositoryRootFor(sourceWorkdir);
    const relativeWorktreePath = relative(
      this.worktreeRoot,
      plan.worktreePath,
    );
    const worktreeSegments = relativeWorktreePath
      .split(/[\\/]+/)
      .filter(Boolean);
    const expectedRepositoryKey = createHash("sha256")
      .update(repositoryRoot)
      .digest("hex")
      .slice(0, 12);
    if (
      repositoryRoot !== plan.repositoryRoot ||
      sourceWorkdir !== plan.sourceWorkdir ||
      managerRepositoryRoot !== repositoryRoot ||
      !plan.branchName.startsWith("officestra/") ||
      plan.branchName === plan.baseBranch ||
      isOutsideDirectory(relativeWorktreePath) ||
      worktreeSegments.length !== 2 ||
      worktreeSegments[0] !== expectedRepositoryKey
    ) {
      throw new GitWorkspaceError(
        "invalid-state",
        "정리할 provisioning 작업 공간이 현재 manager 계획과 다릅니다.",
      );
    }
    await cleanupFailedProvision({
      repositoryRoot,
      worktreePath: plan.worktreePath,
      branchName: plan.branchName,
    });
    const branchProbe = await gitResult(
      repositoryRoot,
      ["show-ref", "--verify", "--quiet", `refs/heads/${plan.branchName}`],
      { allowedExitCodes: [1] },
    );
    if (
      await pathExists(plan.worktreePath) ||
      branchProbe.exitCode === 0
    ) {
      throw new GitWorkspaceError(
        "command-failed",
        "중단된 Git 작업 공간을 자동으로 정리하지 못했습니다.",
      );
    }
  }

  async prepareReview(workspace) {
    await this.validateSource(workspace, null, { allowDirty: true });
    await this.validateWorkspace(workspace);
    await gitText(workspace.worktreePath, ["add", "-A", "--", "."]);

    const reviewTree = await gitText(
      workspace.worktreePath,
      ["write-tree"],
    );
    const headCommit = await gitText(
      workspace.worktreePath,
      ["rev-parse", "HEAD"],
    );
    await requireBaseAncestor(workspace, headCommit);
    const baseTree = await gitText(
      workspace.repositoryRoot,
      ["rev-parse", `${workspace.baseCommit}^{tree}`],
    );
    const changedFiles = reviewTree === baseTree
      ? []
      : parseChangedFiles(
        (await gitBuffer(workspace.worktreePath, [
          "diff",
          "--cached",
          "--name-status",
          "-z",
          "--find-renames",
          workspace.baseCommit,
          "--",
        ])).stdout,
      );
    requireUnchangedFrozenWorkRecords(changedFiles);

    return {
      hasChanges: reviewTree !== baseTree,
      reviewTree,
      headCommit,
      changedFiles,
    };
  }

  async diff(workspace, { maxBytes = DEFAULT_DIFF_BYTES } = {}) {
    validateWorkspaceShape(workspace);
    if (!Number.isSafeInteger(maxBytes) || maxBytes < 1) {
      throw new GitWorkspaceError(
        "invalid-state",
        "diff 최대 크기는 1 이상의 정수여야 합니다.",
      );
    }
    const reviewTree = String(workspace.reviewTree ?? "").trim();
    if (reviewTree) {
      const repositoryRoot = await canonicalDirectory(
        workspace.repositoryRoot,
      );
      await gitText(repositoryRoot, [
        "cat-file",
        "-e",
        `${reviewTree}^{tree}`,
      ]);
      return limitedGitOutput(
        repositoryRoot,
        [
          "diff",
          "--no-color",
          "--no-ext-diff",
          "--find-renames",
          "--src-prefix=a/",
          "--dst-prefix=b/",
          workspace.baseCommit,
          reviewTree,
          "--",
        ],
        maxBytes,
      );
    }

    await this.validateWorkspace(workspace);
    return limitedGitOutput(
      workspace.worktreePath,
      [
        "diff",
        "--cached",
        "--no-color",
        "--no-ext-diff",
        "--find-renames",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        workspace.baseCommit,
        "--",
      ],
      maxBytes,
    );
  }

  async approve(workspace, { expectedReviewTree, commitMessage } = {}) {
    const previous = this.approvalTail;
    let release;
    this.approvalTail = new Promise((resolveLock) => {
      release = resolveLock;
    });
    await previous;
    try {
      return await this.approveLocked(workspace, {
        expectedReviewTree,
        commitMessage,
      });
    } finally {
      release();
    }
  }

  async approveLocked(workspace, { expectedReviewTree, commitMessage }) {
    if (!String(expectedReviewTree ?? "").trim()) {
      throw new GitWorkspaceError(
        "invalid-state",
        "검토한 Git tree 값이 필요합니다.",
      );
    }
    validateWorkspaceShape(workspace);
    const recoveredMerge = await this.alreadyMerged(
      workspace,
      expectedReviewTree,
    );
    if (recoveredMerge) {
      return recoveredMerge;
    }
    await this.validateWorkspace(workspace);
    const sourceUntrackedPaths = await this.validateSource(
      workspace,
      null,
      { allowUntracked: true },
    );
    await requireNoActiveApprovalHooks(
      workspace.repositoryRoot,
      sourceUntrackedPaths,
    );
    const sourceUntrackedFingerprints = await fingerprintUntrackedPaths(
      workspace.repositoryRoot,
      sourceUntrackedPaths,
    );
    await gitText(workspace.worktreePath, ["add", "-A", "--", "."]);
    const currentTree = await gitText(
      workspace.worktreePath,
      ["write-tree"],
    );
    if (currentTree !== expectedReviewTree) {
      throw new GitWorkspaceError(
        "changed-after-review",
        "검토 후 업무 변경사항이 달라졌습니다. 변경사항을 다시 확인하세요.",
      );
    }

    const workspaceHead = await gitText(
      workspace.worktreePath,
      ["rev-parse", "HEAD"],
    );
    await requireBaseAncestor(workspace, workspaceHead);
    const sourceHead = await gitText(
      workspace.repositoryRoot,
      ["rev-parse", "HEAD"],
    );
    const taskBaseCommit = await taskApprovalBase(
      workspace,
      workspaceHead,
      sourceHead,
    );
    requireUnchangedFrozenWorkRecords(
      parseChangedFiles(
        (await gitBuffer(workspace.worktreePath, [
          "diff",
          "--cached",
          "--name-status",
          "-z",
          "--find-renames",
          taskBaseCommit,
          "--",
        ])).stdout,
      ),
    );
    const baseTree = await gitText(
      workspace.repositoryRoot,
      ["rev-parse", `${taskBaseCommit}^{tree}`],
    );
    if (currentTree === baseTree) {
      throw new GitWorkspaceError(
        "invalid-state",
        "병합할 변경사항이 없습니다.",
      );
    }

    await gitText(workspace.worktreePath, [
      "reset",
      "--soft",
      taskBaseCommit,
    ]);
    const message = String(commitMessage ?? "").trim() ||
      "OFFICESTRA: approve workspace changes";
    await gitText(workspace.worktreePath, [
      "-c",
      "user.name=OFFICESTRA",
      "-c",
      "user.email=officestra@local",
      "commit",
      "--no-gpg-sign",
      "-m",
      message,
    ]);
    const taskCommit = await gitText(
      workspace.worktreePath,
      ["rev-parse", "HEAD"],
    );
    const taskTree = await gitText(
      workspace.worktreePath,
      ["rev-parse", `${taskCommit}^{tree}`],
    );
    if (taskTree !== expectedReviewTree) {
      throw new GitWorkspaceError(
        "changed-after-review",
        "커밋 hook이 검토한 변경사항을 바꿨습니다. 변경사항을 다시 확인하세요.",
      );
    }
    const taskLineage = (
      await gitText(workspace.worktreePath, [
        "rev-list",
        "--parents",
        "-n",
        "1",
        taskCommit,
      ])
    ).split(/\s+/);
    if (
      taskLineage.length !== 2 ||
      taskLineage[1] !== taskBaseCommit
    ) {
      throw new GitWorkspaceError(
        "invalid-state",
        "승인 커밋이 기록한 기준 커밋에서 직접 이어지지 않습니다.",
      );
    }
    await requireClean(
      workspace.worktreePath,
      "업무 worktree에 검토되지 않은 변경사항이 있습니다.",
      "changed-after-review",
    );

    const mergeCheck = await gitResult(
      workspace.repositoryRoot,
      ["merge-tree", "--write-tree", sourceHead, taskCommit],
      { allowedExitCodes: [1] },
    );
    if (mergeCheck.exitCode === 1) {
      throw new GitWorkspaceError(
        "conflict",
        "원본 브랜치의 최신 변경과 업무 변경이 충돌합니다.",
      );
    }
    const expectedMergeTree = mergeCheck.stdout
      .split("\n")[0]
      .trim();
    if (!/^[0-9a-f]{40,64}$/.test(expectedMergeTree)) {
      throw new GitWorkspaceError(
        "command-failed",
        "Git 병합 결과 tree를 확인할 수 없습니다.",
      );
    }
    await requireMergeTreePathsAvailable(
      workspace.repositoryRoot,
      sourceHead,
      expectedMergeTree,
    );
    await this.validateSource(
      workspace,
      sourceHead,
      {
        allowUntracked: true,
        expectedUntrackedPaths: sourceUntrackedPaths,
      },
    );
    await requireNoActiveApprovalHooks(
      workspace.repositoryRoot,
      sourceUntrackedPaths,
    );
    await requireUntrackedFingerprints(
      workspace.repositoryRoot,
      sourceUntrackedFingerprints,
    );
    const mergeResult = await gitResult(
      workspace.repositoryRoot,
      [
        "-c",
        "user.name=OFFICESTRA",
        "-c",
        "user.email=officestra@local",
        "merge",
        "--no-ff",
        "--no-edit",
        "--no-gpg-sign",
        taskCommit,
      ],
      { allowedExitCodes: [1, 2, 128] },
    );
    if (mergeResult.exitCode !== 0) {
      const mergeHead = await gitResult(
        workspace.repositoryRoot,
        ["rev-parse", "--quiet", "--verify", "MERGE_HEAD"],
        { allowedExitCodes: [1, 128] },
      );
      if (mergeHead.exitCode === 0) {
        await gitResult(
          workspace.repositoryRoot,
          ["merge", "--abort"],
          { allowedExitCodes: [1, 128] },
        );
      }
      throw commandError(
        "Git 병합에 실패했습니다.",
        mergeResult,
      );
    }

    let mergedCommit;
    try {
      mergedCommit = await gitText(
        workspace.repositoryRoot,
        ["rev-parse", "HEAD"],
      );
      const mergedTree = await gitText(
        workspace.repositoryRoot,
        ["rev-parse", `${mergedCommit}^{tree}`],
      );
      const mergedLineage = (
        await gitText(workspace.repositoryRoot, [
          "rev-list",
          "--parents",
          "-n",
          "1",
          mergedCommit,
        ])
      ).split(/\s+/);
      await requireSourceReady(
        workspace.repositoryRoot,
        "병합 중 원본 Git 작업 트리의 변경사항이 달라졌습니다.",
        {
          allowUntracked: true,
          expectedUntrackedPaths: sourceUntrackedPaths,
          trackedChangesCode: "command-failed",
        },
      );
      await requireUntrackedFingerprints(
        workspace.repositoryRoot,
        sourceUntrackedFingerprints,
      );
      if (
        mergedTree !== expectedMergeTree ||
        mergedLineage.length !== 3 ||
        mergedLineage[1] !== sourceHead ||
        mergedLineage[2] !== taskCommit
      ) {
        throw new GitWorkspaceError(
          "command-failed",
          "병합 hook이 검토한 tree, Git 이력 또는 원본 작업 파일을 바꿨습니다.",
        );
      }
    } catch (error) {
      let rollback;
      try {
        rollback = await rollbackSourceMerge(
          workspace,
          sourceHead,
          { baselineUntrackedPaths: sourceUntrackedPaths },
        );
      } catch (rollbackError) {
        throw new GitWorkspaceError(
          "command-failed",
          `통합 검증과 원본 브랜치 복구에 실패했습니다. ${
            rollbackError instanceof Error
              ? rollbackError.message
              : String(rollbackError)
          }`,
          { cause: error },
        );
      }
      if (rollback.hasUntrackedChanges) {
        throw new GitWorkspaceError(
          "not-clean",
          "병합 hook의 미추적 산출물은 보존했습니다. 원본 브랜치는 되돌렸으니 파일을 확인한 뒤 다시 승인하세요.",
          { cause: error },
        );
      }
      if (error instanceof GitWorkspaceError && error.code === "not-clean") {
        throw new GitWorkspaceError(
          "not-clean",
          error.message,
          { cause: error },
        );
      }
      throw new GitWorkspaceError(
        "command-failed",
        "병합 hook이 검토 결과를 바꿔 원본 브랜치와 tracked 파일을 되돌렸습니다.",
        { cause: error },
      );
    }
    return { taskCommit, mergedCommit };
  }

  async alreadyMerged(workspace, expectedReviewTree) {
    const targetResult = await gitResult(
      workspace.repositoryRoot,
      ["rev-parse", "--verify", `refs/heads/${workspace.baseBranch}`],
      { allowedExitCodes: [128] },
    );
    if (targetResult.exitCode !== 0) {
      return null;
    }
    const mergedCommit = targetResult.stdout.trim();
    const candidates = [];
    if (workspace.taskCommit) {
      candidates.push(workspace.taskCommit);
    }
    const taskBranchResult = await gitResult(
      workspace.repositoryRoot,
      ["rev-parse", "--verify", `refs/heads/${workspace.branchName}`],
      { allowedExitCodes: [128] },
    );
    if (taskBranchResult.exitCode === 0) {
      candidates.push(taskBranchResult.stdout.trim());
    }

    for (const taskCommit of new Set(candidates.filter(Boolean))) {
      const treeResult = await gitResult(
        workspace.repositoryRoot,
        ["rev-parse", "--verify", `${taskCommit}^{tree}`],
        { allowedExitCodes: [128] },
      );
      if (treeResult.exitCode !== 0 ||
          treeResult.stdout.trim() !== expectedReviewTree) {
        continue;
      }
      const ancestor = await gitResult(
        workspace.repositoryRoot,
        ["merge-base", "--is-ancestor", taskCommit, mergedCommit],
        { allowedExitCodes: [1] },
      );
      if (ancestor.exitCode === 0) {
        return { taskCommit, mergedCommit };
      }
    }
    return null;
  }

  async cleanup(workspace) {
    validateWorkspaceShape(workspace);
    const repositoryRoot = await canonicalDirectory(workspace.repositoryRoot);
    if (await pathExists(workspace.worktreePath)) {
      await this.validateWorkspace(workspace);
      await gitText(repositoryRoot, [
        "worktree",
        "remove",
        workspace.worktreePath,
      ]);
    }

    const branchProbe = await gitResult(
      repositoryRoot,
      ["show-ref", "--verify", "--quiet", `refs/heads/${workspace.branchName}`],
      { allowedExitCodes: [1] },
    );
    if (branchProbe.exitCode === 0) {
      await gitText(repositoryRoot, ["branch", "-d", workspace.branchName]);
    }
  }

  async validateWorkspace(workspace) {
    validateWorkspaceShape(workspace);
    const repositoryRoot = await canonicalDirectory(workspace.repositoryRoot);
    const worktreePath = await canonicalDirectory(workspace.worktreePath);
    if (repositoryRoot !== workspace.repositoryRoot ||
        worktreePath !== workspace.worktreePath) {
      throw new GitWorkspaceError(
        "invalid-state",
        "저장된 Git workspace 경로가 현재 경로와 다릅니다.",
      );
    }

    const actualRoot = await canonicalDirectory(
      await gitText(worktreePath, ["rev-parse", "--show-toplevel"]),
    );
    if (actualRoot !== worktreePath) {
      throw new GitWorkspaceError(
        "invalid-state",
        "업무 worktree 루트가 예상 경로와 다릅니다.",
      );
    }
    const expectedCommonDirectory = await gitText(repositoryRoot, [
      "rev-parse",
      "--path-format=absolute",
      "--git-common-dir",
    ]);
    const actualCommonDirectory = await gitText(worktreePath, [
      "rev-parse",
      "--path-format=absolute",
      "--git-common-dir",
    ]);
    if (resolve(expectedCommonDirectory) !== resolve(actualCommonDirectory)) {
      throw new GitWorkspaceError(
        "invalid-state",
        "업무 worktree가 예상 Git 저장소에 연결되어 있지 않습니다.",
      );
    }
    if (await currentBranch(worktreePath) !== workspace.branchName) {
      throw new GitWorkspaceError(
        "invalid-state",
        "업무 worktree 브랜치가 변경됐습니다.",
      );
    }
  }

  async validateSource(
    workspace,
    expectedHead = null,
    {
      allowDirty = false,
      allowUntracked = false,
      expectedUntrackedPaths = null,
    } = {},
  ) {
    if (await currentBranch(workspace.repositoryRoot) !== workspace.baseBranch) {
      throw new GitWorkspaceError(
        "invalid-state",
        "원본 작업 트리의 브랜치가 변경됐습니다.",
      );
    }
    let untrackedPaths = [];
    if (!allowDirty) {
      untrackedPaths = await requireSourceReady(
        workspace.repositoryRoot,
        "원본 Git 작업 트리에 변경사항이 있어 병합할 수 없습니다.",
        { allowUntracked, expectedUntrackedPaths },
      );
    }
    if (expectedHead) {
      const currentHead = await gitText(
        workspace.repositoryRoot,
        ["rev-parse", "HEAD"],
      );
      if (currentHead !== expectedHead) {
        throw new GitWorkspaceError(
          "invalid-state",
          "병합 준비 중 원본 브랜치가 변경됐습니다.",
        );
      }
    }
    return untrackedPaths;
  }
}

export async function canonicalProjectRoot(sourceWorkdir) {
  const canonicalWorkdir = await canonicalDirectory(resolve(sourceWorkdir));
  return await repositoryRootFor(canonicalWorkdir) ?? canonicalWorkdir;
}

async function repositoryRootFor(sourceWorkdir) {
  let repositoryProbe;
  try {
    repositoryProbe = await gitResult(
      sourceWorkdir,
      ["rev-parse", "--show-toplevel"],
      { allowedExitCodes: [128] },
    );
  } catch (error) {
    if (
      isMissingGitExecutable(error) &&
      !(await hasGitMarker(sourceWorkdir))
    ) {
      return null;
    }
    throw error;
  }
  if (repositoryProbe.exitCode === 0) {
    return canonicalDirectory(repositoryProbe.stdout.trim());
  }
  if (
    isExplicitNonRepository(repositoryProbe) &&
    !(await hasGitMarker(sourceWorkdir))
  ) {
    return null;
  }
  throw commandError(
    "Git 저장소 확인에 실패했습니다.",
    repositoryProbe,
  );
}

function isMissingGitExecutable(error) {
  return error instanceof GitWorkspaceError &&
    error.code === "command-failed" &&
    error.cause?.code === "ENOENT";
}

function isExplicitNonRepository(result) {
  return result.exitCode === 128 &&
    /^fatal: not a git repository(?: \(or any of the parent directories\))?:/m
      .test(result.stderr);
}

async function hasGitMarker(startDirectory) {
  let directory = startDirectory;
  while (true) {
    if (await pathExists(join(directory, ".git"))) {
      return true;
    }
    const parent = dirname(directory);
    if (parent === directory) {
      return false;
    }
    directory = parent;
  }
}

async function requireMissingBranch(repositoryRoot, branchName) {
  const branchProbe = await gitResult(
    repositoryRoot,
    ["show-ref", "--verify", "--quiet", `refs/heads/${branchName}`],
    { allowedExitCodes: [1] },
  );
  if (branchProbe.exitCode === 0) {
    throw new GitWorkspaceError(
      "invalid-state",
      `이미 존재하는 업무 브랜치입니다: ${branchName}`,
    );
  }
}

async function cleanupFailedProvision({
  repositoryRoot,
  worktreePath,
  branchName,
}) {
  try {
    await gitResult(
      repositoryRoot,
      ["worktree", "remove", "--force", worktreePath],
      { allowedExitCodes: [1, 128] },
    );
  } catch {
    // 원래 생성 실패를 유지하며 가능한 정리만 수행한다.
  }
  try {
    await gitResult(
      repositoryRoot,
      ["branch", "-D", branchName],
      { allowedExitCodes: [1, 128] },
    );
  } catch {
    // worktree가 아직 브랜치를 사용 중이면 수동 복구 대상으로 남긴다.
  }
}

async function rollbackSourceMerge(
  workspace,
  sourceHead,
  { baselineUntrackedPaths = [] } = {},
) {
  const repositoryRoot = await canonicalDirectory(workspace.repositoryRoot);
  const baselineUntracked = new Set(baselineUntrackedPaths);
  const untrackedBefore = new Set(parseNullSeparated(
    (await gitBuffer(repositoryRoot, [
      "ls-files",
      "--others",
      "--exclude-standard",
      "-z",
    ])).stdout,
  ));
  const sourcePaths = new Set(parseNullSeparated(
    (await gitBuffer(repositoryRoot, [
      "ls-tree",
      "-r",
      "--name-only",
      "-z",
      sourceHead,
    ])).stdout,
  ));
  const hasUntrackedCollision = [...untrackedBefore]
    .some((path) => sourcePaths.has(path));

  const baseReference = `refs/heads/${workspace.baseBranch}`;
  const currentBaseCommit = await gitText(repositoryRoot, [
    "rev-parse",
    "--verify",
    baseReference,
  ]);
  await gitText(repositoryRoot, [
    "update-ref",
    baseReference,
    sourceHead,
    currentBaseCommit,
  ]);
  await gitText(repositoryRoot, [
    "symbolic-ref",
    "HEAD",
    baseReference,
  ]);
  if (!hasUntrackedCollision) {
    await gitText(repositoryRoot, [
      "restore",
      "--source",
      sourceHead,
      "--staged",
      "--worktree",
      "--",
      ".",
    ]);
  }

  const restoredBranch = await currentBranch(repositoryRoot);
  const restoredHead = await gitText(repositoryRoot, ["rev-parse", "HEAD"]);
  if (
    restoredBranch !== workspace.baseBranch ||
    restoredHead !== sourceHead
  ) {
    throw new GitWorkspaceError(
      "command-failed",
      "원본 Git 브랜치와 head를 복구하지 못했습니다.",
    );
  }

  const untrackedAfter = new Set(parseNullSeparated(
    (await gitBuffer(repositoryRoot, [
      "ls-files",
      "--others",
      "--exclude-standard",
      "-z",
    ])).stdout,
  ));
  if ([...untrackedBefore].some((path) => !untrackedAfter.has(path))) {
    throw new GitWorkspaceError(
      "command-failed",
      "병합 hook의 미추적 산출물을 보존하지 못했습니다.",
    );
  }
  if ([...baselineUntracked].some((path) => !untrackedAfter.has(path))) {
    throw new GitWorkspaceError(
      "command-failed",
      "병합 전 원본의 미추적 파일을 보존하지 못했습니다.",
    );
  }
  const restoredStatus = parseNullSeparated(
    (await gitBuffer(repositoryRoot, [
      "status",
      "--porcelain=v1",
      "-z",
      "--untracked-files=all",
    ])).stdout,
  );
  const hasTrackedChanges = restoredStatus.some(
    (entry) => !entry.startsWith("?? "),
  );
  if (hasTrackedChanges && !hasUntrackedCollision) {
    throw new GitWorkspaceError(
      "command-failed",
      "원본 Git tracked 파일과 index를 복구하지 못했습니다.",
    );
  }
  return {
    hasUntrackedChanges:
      hasUntrackedCollision ||
      [...untrackedAfter].some((path) => !baselineUntracked.has(path)),
  };
}

function parseNullSeparated(buffer) {
  const values = buffer.toString("utf8").split("\0");
  if (values.at(-1) === "") {
    values.pop();
  }
  return values.filter(Boolean);
}

async function canonicalDirectory(path) {
  try {
    return await realpath(path);
  } catch (error) {
    throw new GitWorkspaceError(
      "invalid-state",
      `작업 폴더를 확인할 수 없습니다: ${path}`,
      { cause: error },
    );
  }
}

function validateWorkspaceShape(workspace) {
  const required = [
    "repositoryRoot",
    "sourceWorkdir",
    "worktreePath",
    "executionWorkdir",
    "branchName",
    "baseBranch",
    "baseCommit",
  ];
  if (!workspace || required.some((key) => !workspace[key])) {
    throw new GitWorkspaceError(
      "invalid-state",
      "Git workspace 정보가 올바르지 않습니다.",
    );
  }
}

async function currentBranch(directory) {
  const result = await gitResult(
    directory,
    ["symbolic-ref", "--quiet", "--short", "HEAD"],
    { allowedExitCodes: [1, 128] },
  );
  if (result.exitCode !== 0 || !result.stdout.trim()) {
    throw new GitWorkspaceError(
      "invalid-state",
      "분리된 HEAD에서는 자동 worktree 병합을 사용할 수 없습니다.",
    );
  }
  return result.stdout.trim();
}

async function requireClean(directory, message, code = "not-clean") {
  const status = await gitBuffer(directory, [
    "status",
    "--porcelain=v1",
    "-z",
    "--untracked-files=all",
  ]);
  if (status.stdout.length > 0) {
    throw new GitWorkspaceError(code, message);
  }
}

async function requireSourceReady(
  directory,
  message,
  {
    allowUntracked = false,
    expectedUntrackedPaths = null,
    trackedChangesCode = "not-clean",
  } = {},
) {
  const status = parseNullSeparated(
    (await gitBuffer(directory, [
      "status",
      "--porcelain=v1",
      "-z",
      "--untracked-files=all",
    ])).stdout,
  );
  const hasTrackedChanges = status.some((entry) => !entry.startsWith("?? "));
  const untrackedPaths = status
    .filter((entry) => entry.startsWith("?? "))
    .map((entry) => entry.slice(3));
  if (hasTrackedChanges || (!allowUntracked && untrackedPaths.length > 0)) {
    throw new GitWorkspaceError(trackedChangesCode, message);
  }
  if (
    expectedUntrackedPaths &&
    !samePaths(untrackedPaths, expectedUntrackedPaths)
  ) {
    throw new GitWorkspaceError(
      "not-clean",
      "병합 준비 중 원본 Git의 미추적 파일 목록이 달라졌습니다.",
    );
  }
  return untrackedPaths;
}

async function requireMergeTreePathsAvailable(
  directory,
  sourceTree,
  mergedTree,
) {
  const [sourcePaths, mergedPaths, localPaths, ignoreCaseResult] =
    await Promise.all([
      treePaths(directory, sourceTree),
      treePaths(directory, mergedTree),
      mergeBlockingLocalPaths(directory),
      gitResult(
        directory,
        ["config", "--bool", "core.ignorecase"],
        { allowedExitCodes: [1] },
      ),
    ]);
  const sourcePathSet = new Set(sourcePaths);
  const addedPaths = mergedPaths.filter((path) => !sourcePathSet.has(path));
  const ignoreCase = ignoreCaseResult.stdout.trim() === "true";
  const collision = localPaths.find((localPath) =>
    addedPaths.some((addedPath) =>
      normalizedPathsOverlap(localPath, addedPath, ignoreCase)
    )
  );
  if (collision) {
    throw new GitWorkspaceError(
      "not-clean",
      `원본 로컬 파일이 승인할 변경 경로와 겹칩니다: ${collision}`,
    );
  }
}

function samePaths(left, right) {
  const rightPaths = new Set(right);
  return left.length === rightPaths.size &&
    left.every((path) => rightPaths.has(path));
}

async function treePaths(directory, tree) {
  return parseNullSeparated(
    (await gitBuffer(directory, [
      "ls-tree",
      "-r",
      "--name-only",
      "-z",
      tree,
    ])).stdout,
  );
}

async function mergeBlockingLocalPaths(directory) {
  const results = await Promise.all([
    gitBuffer(directory, [
      "ls-files",
      "--others",
      "--exclude-standard",
      "--directory",
      "-z",
    ]),
    gitBuffer(directory, [
      "ls-files",
      "--others",
      "--ignored",
      "--exclude-standard",
      "--directory",
      "-z",
    ]),
  ]);
  return [...new Set(results.flatMap((result) =>
    parseNullSeparated(result.stdout).map((path) =>
      path.endsWith("/") ? path.slice(0, -1) : path
    )
  ))];
}

function normalizedPathsOverlap(left, right, ignoreCase) {
  const normalize = (path) => {
    const normalized = path.normalize("NFC");
    return ignoreCase ? normalized.toLocaleLowerCase("en-US") : normalized;
  };
  const normalizedLeft = normalize(left);
  const normalizedRight = normalize(right);
  return normalizedLeft === normalizedRight ||
    normalizedLeft.startsWith(`${normalizedRight}/`) ||
    normalizedRight.startsWith(`${normalizedLeft}/`);
}

async function lstatIfPresent(path) {
  try {
    return await lstat(path);
  } catch (error) {
    if (error?.code === "ENOENT" || error?.code === "ENOTDIR") {
      return null;
    }
    throw error;
  }
}

async function requireNoActiveApprovalHooks(directory, untrackedPaths) {
  if (untrackedPaths.length === 0) {
    return;
  }
  const hookNames = [
    "post-index-change",
    "pre-commit",
    "pre-merge-commit",
    "prepare-commit-msg",
    "commit-msg",
    "post-commit",
    "post-merge",
    "reference-transaction",
  ];
  for (const hookName of hookNames) {
    const hookPath = await gitText(directory, [
      "rev-parse",
      "--path-format=absolute",
      "--git-path",
      `hooks/${hookName}`,
    ]);
    const info = await lstatIfPresent(hookPath);
    if (
      info &&
      (info.isFile() || info.isSymbolicLink()) &&
      (info.mode & 0o111) !== 0
    ) {
      throw new GitWorkspaceError(
        "not-clean",
        `원본에 미추적 파일과 활성 Git hook이 함께 있어 통합할 수 없습니다: ${hookName}`,
      );
    }
  }
}

async function fingerprintUntrackedPaths(directory, paths) {
  const fingerprints = new Map();
  for (const path of paths) {
    fingerprints.set(
      path,
      await localPathFingerprint(resolve(directory, path)),
    );
  }
  return fingerprints;
}

async function requireUntrackedFingerprints(directory, fingerprints) {
  for (const [path, expected] of fingerprints) {
    let actual;
    try {
      actual = await localPathFingerprint(resolve(directory, path));
    } catch (error) {
      throw new GitWorkspaceError(
        "not-clean",
        `병합 중 원본 미추적 파일이 달라졌습니다: ${path}`,
        { cause: error },
      );
    }
    if (actual !== expected) {
      throw new GitWorkspaceError(
        "not-clean",
        `병합 중 원본 미추적 파일이 달라졌습니다: ${path}`,
      );
    }
  }
}

async function localPathFingerprint(path) {
  const info = await lstat(path);
  const mode = (info.mode & 0o7777).toString(8);
  if (info.isSymbolicLink()) {
    const target = await readlink(path);
    return `symlink:${mode}:${createHash("sha256").update(target).digest("hex")}`;
  }
  if (!info.isFile()) {
    throw new GitWorkspaceError(
      "not-clean",
      `지원하지 않는 미추적 파일 종류입니다: ${path}`,
    );
  }
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) {
    hash.update(chunk);
  }
  return `file:${mode}:${hash.digest("hex")}`;
}

async function requireBaseAncestor(workspace, headCommit) {
  const result = await gitResult(
    workspace.worktreePath,
    ["merge-base", "--is-ancestor", workspace.baseCommit, headCommit],
    { allowedExitCodes: [1] },
  );
  if (result.exitCode !== 0) {
    throw new GitWorkspaceError(
      "invalid-state",
      "업무 브랜치가 생성 기준 커밋에서 이어지지 않습니다.",
    );
  }
}

async function taskApprovalBase(workspace, workspaceHead, sourceHead) {
  const mergeBaseResult = await gitResult(
    workspace.worktreePath,
    ["merge-base", "--all", workspaceHead, sourceHead],
    { allowedExitCodes: [1] },
  );
  const mergeBases = mergeBaseResult.stdout.trim().split(/\s+/).filter(Boolean);
  if (mergeBaseResult.exitCode !== 0 || mergeBases.length !== 1) {
    throw new GitWorkspaceError(
      "invalid-state",
      "업무 변경과 원본 브랜치의 공통 기준 커밋을 하나로 확인할 수 없습니다.",
    );
  }

  const taskBaseCommit = mergeBases[0];
  const originalBaseResult = await gitResult(
    workspace.worktreePath,
    ["merge-base", "--is-ancestor", workspace.baseCommit, taskBaseCommit],
    { allowedExitCodes: [1] },
  );
  if (originalBaseResult.exitCode !== 0) {
    throw new GitWorkspaceError(
      "invalid-state",
      "업무 승인 기준이 생성 기준 커밋에서 이어지지 않습니다.",
    );
  }
  return taskBaseCommit;
}

function workspaceBranchName(characterID, workspaceID) {
  const character = safeSegment(characterID);
  const workspace = safeSegment(workspaceID);
  const suffix = createHash("sha256")
    .update(`${characterID}\0${workspaceID}`)
    .digest("hex")
    .slice(0, 8);
  return `officestra/${character}/${workspace.slice(0, 48)}-${suffix}`;
}

function safeSegment(value) {
  const normalized = String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^[-.]+|[-.]+$/g, "")
    .slice(0, 64);
  return normalized || "workspace";
}

function isOutsideDirectory(path) {
  return path === ".." || path.startsWith("../") || path.startsWith("..\\");
}

function parseChangedFiles(buffer) {
  const values = buffer.toString("utf8").split("\0");
  if (values.at(-1) === "") {
    values.pop();
  }
  const changedFiles = [];
  for (let index = 0; index < values.length;) {
    const status = values[index++];
    if (!status) {
      break;
    }
    if (status.startsWith("R") || status.startsWith("C")) {
      const previousPath = values[index++];
      const path = values[index++];
      changedFiles.push({ status, path, previousPath });
    } else {
      changedFiles.push({ status, path: values[index++] });
    }
  }
  return changedFiles;
}

function requireUnchangedFrozenWorkRecords(changedFiles) {
  const frozenPaths = [...new Set(
    changedFiles
      .flatMap(({ path, previousPath }) => [previousPath, path])
      .filter((path) => FROZEN_WORK_RECORD_PATHS.has(path)),
  )];
  if (frozenPaths.length > 0) {
    throw new GitWorkspaceError(
      "invalid-state",
      `v1.0 동결 작업 기록은 변경할 수 없습니다: ${frozenPaths.join(", ")}`,
    );
  }
}

async function pathExists(path) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

async function gitText(directory, argumentsList) {
  const result = await gitBuffer(directory, argumentsList);
  return result.stdout.toString("utf8").trim();
}

async function gitBuffer(directory, argumentsList) {
  const result = await gitResult(directory, argumentsList);
  return {
    ...result,
    stdout: Buffer.from(result.stdoutBuffer),
    stderr: Buffer.from(result.stderrBuffer),
  };
}

async function gitResult(
  directory,
  argumentsList,
  { allowedExitCodes = [] } = {},
) {
  try {
    const { stdout, stderr } = await execFileAsync(
      "git",
      ["-C", directory, ...argumentsList],
      {
        encoding: "buffer",
        env: gitEnvironment(),
        maxBuffer: GIT_OUTPUT_BYTES,
        shell: false,
      },
    );
    const stdoutBuffer = Buffer.from(stdout ?? "");
    const stderrBuffer = Buffer.from(stderr ?? "");
    return {
      exitCode: 0,
      stdout: stdoutBuffer.toString("utf8"),
      stderr: stderrBuffer.toString("utf8"),
      stdoutBuffer,
      stderrBuffer,
    };
  } catch (error) {
    const exitCode = Number.isInteger(error.code) ? error.code : null;
    const stdoutBuffer = Buffer.from(error.stdout ?? "");
    const stderrBuffer = Buffer.from(error.stderr ?? "");
    const result = {
      exitCode,
      stdout: stdoutBuffer.toString("utf8"),
      stderr: stderrBuffer.toString("utf8"),
      stdoutBuffer,
      stderrBuffer,
    };
    if (exitCode !== null && allowedExitCodes.includes(exitCode)) {
      return result;
    }
    throw commandError("Git 명령 실행에 실패했습니다.", result, error);
  }
}

function commandError(message, result, cause) {
  const detail = String(result.stderr || result.stdout || "").trim();
  return new GitWorkspaceError(
    "command-failed",
    detail ? `${message} ${detail}` : message,
    cause ? { cause } : {},
  );
}

function limitedGitOutput(directory, argumentsList, maxBytes) {
  return new Promise((resolveOutput, rejectOutput) => {
    const child = spawn(
      "git",
      ["-C", directory, ...argumentsList],
      {
        env: gitEnvironment(),
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    const output = [];
    const errors = [];
    let outputBytes = 0;
    let errorBytes = 0;
    let diffTruncated = false;

    child.stdout.on("data", (chunk) => {
      const remaining = Math.max(0, maxBytes - outputBytes);
      if (remaining > 0) {
        const kept = chunk.subarray(0, remaining);
        output.push(kept);
        outputBytes += kept.length;
      }
      if (chunk.length > remaining) {
        diffTruncated = true;
      }
    });
    child.stderr.on("data", (chunk) => {
      const remaining = Math.max(0, 64 * 1024 - errorBytes);
      if (remaining > 0) {
        const kept = chunk.subarray(0, remaining);
        errors.push(kept);
        errorBytes += kept.length;
      }
    });
    child.on("error", (error) => {
      rejectOutput(new GitWorkspaceError(
        "command-failed",
        "Git diff 명령을 시작하지 못했습니다.",
        { cause: error },
      ));
    });
    child.on("close", (exitCode) => {
      if (exitCode !== 0) {
        rejectOutput(commandError("Git diff 생성에 실패했습니다.", {
          stdout: Buffer.concat(output).toString("utf8"),
          stderr: Buffer.concat(errors).toString("utf8"),
        }));
        return;
      }
      resolveOutput({
        diff: Buffer.concat(output).toString("utf8"),
        diffTruncated,
      });
    });
  });
}

function gitEnvironment() {
  return {
    ...process.env,
    LANG: "C",
    LC_ALL: "C",
    GIT_OPTIONAL_LOCKS: "0",
    GIT_TERMINAL_PROMPT: "0",
    GIT_EDITOR: "true",
    GIT_MERGE_AUTOEDIT: "no",
  };
}
