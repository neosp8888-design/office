// 이 파일은 Git worktree 생성부터 검토와 승인 병합 및 정리까지의 안전 경로를 검증한다.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import test from "node:test";

import {
  canonicalProjectRoot,
  GitWorkspaceError,
  GitWorkspaceManager,
} from "../src/git-workspace.mjs";

test("Git 저장소가 아닌 작업 폴더는 기존 실행 경로를 유지한다", async () => {
  const root = mkdtempSync(join(tmpdir(), "office-workspace-nongit-"));
  try {
    const manager = new GitWorkspaceManager({ sourceWorkdir: root });
    assert.equal(await manager.isRepository(), false);
    assert.equal(
      await manager.planProvision({
        workspaceID: "workspace-plan",
        characterID: "boss",
      }),
      null,
    );
    assert.equal(
      await manager.provision({
        workspaceID: "workspace-1",
        characterID: "boss",
      }),
      null,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("손상된 Git 표식은 non-Git으로 우회하지 않고 실패한다", async () => {
  const root = mkdtempSync(join(tmpdir(), "office-workspace-broken-git-"));
  try {
    writeFileSync(
      join(root, ".git"),
      "gitdir: /definitely/missing/officestra-git-dir\n",
    );
    const manager = new GitWorkspaceManager({ sourceWorkdir: root });

    await assert.rejects(
      manager.isRepository(),
      (error) => error instanceof GitWorkspaceError &&
        error.code === "command-failed",
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("저장소 하위 작업 폴더를 같은 상대 위치의 worktree로 격리한다", async () => {
  const fixture = createRepository({ withSubdirectory: true });
  try {
    const manager = new GitWorkspaceManager({
      sourceWorkdir: fixture.sourceWorkdir,
      worktreeRoot: fixture.worktreeRoot,
    });
    assert.equal(
      await canonicalProjectRoot(fixture.sourceWorkdir),
      fixture.repositoryRoot,
    );
    assert.equal(await manager.isRepository(), true);
    const plan = await manager.planProvision({
      workspaceID: "workspace-subdir",
      characterID: "right-woman",
    });
    assert.equal(pathExists(plan.worktreePath), false);
    assert.throws(
      () => git(
        fixture.repositoryRoot,
        "show-ref",
        "--verify",
        `refs/heads/${plan.branchName}`,
      ),
    );

    const workspace = await manager.provisionPlanned(plan);

    assert.equal(workspace.repositoryRoot, fixture.repositoryRoot);
    assert.equal(workspace.sourceWorkdir, fixture.sourceWorkdir);
    assert.equal(workspace.baseBranch, "main");
    assert.equal(workspace.baseCommit, git(fixture.repositoryRoot, "rev-parse", "HEAD"));
    assert.equal(
      relative(workspace.worktreePath, workspace.executionWorkdir),
      "Sources/Feature",
    );
    assert.equal(
      git(workspace.worktreePath, "branch", "--show-current"),
      workspace.branchName,
    );
    assert.equal(readFileSync(join(workspace.executionWorkdir, "note.txt"), "utf8"), "base\n");
  } finally {
    fixture.remove();
  }
});

test("worktree 생성 뒤 실행 폴더 검증 실패는 branch와 worktree를 정리한다", async () => {
  const fixture = createRepository();
  try {
    writeFileSync(
      join(fixture.repositoryRoot, ".gitignore"),
      "ignored-workdir/\n",
    );
    git(fixture.repositoryRoot, "add", ".gitignore");
    git(fixture.repositoryRoot, "commit", "-m", "ignore runtime directory");
    const ignoredWorkdir = join(
      fixture.repositoryRoot,
      "ignored-workdir",
    );
    mkdirSync(ignoredWorkdir);
    writeFileSync(join(ignoredWorkdir, "local.txt"), "local only\n");
    const manager = new GitWorkspaceManager({
      sourceWorkdir: ignoredWorkdir,
      worktreeRoot: fixture.worktreeRoot,
    });
    const plan = await manager.planProvision({
      workspaceID: "workspace-cleanup",
      characterID: "boss",
    });

    await assert.rejects(
      manager.provisionPlanned(plan),
      (error) => error instanceof GitWorkspaceError &&
        error.code === "invalid-state",
    );
    assert.equal(pathExists(plan.worktreePath), false);
    assert.throws(
      () => git(
        fixture.repositoryRoot,
        "show-ref",
        "--verify",
        `refs/heads/${plan.branchName}`,
      ),
    );
    assert.equal(
      git(fixture.repositoryRoot, "worktree", "list", "--porcelain")
        .split("\n")
        .filter((line) => line.startsWith("worktree "))
        .length,
      1,
    );
  } finally {
    fixture.remove();
  }
});

test("재시작 복구는 provisioning worktree와 branch를 정리한다", async () => {
  const fixture = createRepository();
  try {
    const manager = new GitWorkspaceManager({
      sourceWorkdir: fixture.repositoryRoot,
      worktreeRoot: fixture.worktreeRoot,
    });
    const plan = await manager.planProvision({
      workspaceID: "workspace-recovery-cleanup",
      characterID: "boss",
    });
    mkdirSync(join(plan.worktreePath, ".."), { recursive: true });
    git(
      fixture.repositoryRoot,
      "worktree",
      "add",
      "-b",
      plan.branchName,
      plan.worktreePath,
      plan.baseCommit,
    );
    writeFileSync(join(plan.worktreePath, "partial.txt"), "partial\n");

    await manager.cleanupProvisioning(plan);

    assert.equal(pathExists(plan.worktreePath), false);
    assert.throws(
      () => git(
        fixture.repositoryRoot,
        "show-ref",
        "--verify",
        `refs/heads/${plan.branchName}`,
      ),
    );
    assert.equal(
      git(fixture.repositoryRoot, "worktree", "list", "--porcelain")
        .split("\n")
        .filter((line) => line.startsWith("worktree "))
        .length,
      1,
    );
  } finally {
    fixture.remove();
  }
});

test("provisioning 정리는 manager 소유가 아닌 branch를 삭제하지 않는다", async () => {
  const fixture = createRepository();
  try {
    const manager = new GitWorkspaceManager({
      sourceWorkdir: fixture.repositoryRoot,
      worktreeRoot: fixture.worktreeRoot,
    });
    const plan = await manager.planProvision({
      workspaceID: "workspace-recovery-failure",
      characterID: "boss",
    });

    await assert.rejects(
      manager.cleanupProvisioning({
        ...plan,
        branchName: "main",
      }),
      (error) => error instanceof GitWorkspaceError &&
        error.code === "invalid-state",
    );
    assert.equal(
      git(fixture.repositoryRoot, "branch", "--show-current"),
      "main",
    );

    git(fixture.repositoryRoot, "branch", "keep-this-branch");
    await assert.rejects(
      manager.cleanupProvisioning({
        ...plan,
        branchName: "keep-this-branch",
      }),
      (error) => error instanceof GitWorkspaceError &&
        error.code === "invalid-state",
    );
    assert.equal(
      git(
        fixture.repositoryRoot,
        "show-ref",
        "--verify",
        "refs/heads/keep-this-branch",
      ).length > 0,
      true,
    );
  } finally {
    fixture.remove();
  }
});

test("변경이 없는 worktree는 검토 대상을 만들지 않는다", async () => {
  const fixture = createRepository();
  try {
    const { manager, workspace } = await fixture.provision();
    const review = await manager.prepareReview(workspace);

    assert.equal(review.hasChanges, false);
    assert.deepEqual(review.changedFiles, []);
    assert.equal(
      review.reviewTree,
      git(fixture.repositoryRoot, "rev-parse", "HEAD^{tree}"),
    );
  } finally {
    fixture.remove();
  }
});

test("원본 저장소가 dirty여도 원본 변경을 보존하고 검토를 준비한다", async () => {
  const fixture = createRepository();
  try {
    const { manager, workspace } = await fixture.provision();
    writeFileSync(
      join(workspace.worktreePath, "tracked.txt"),
      "task change\n",
    );
    writeFileSync(
      join(fixture.repositoryRoot, "tracked.txt"),
      "direct source edit\n",
    );

    const review = await manager.prepareReview(workspace);

    assert.equal(review.hasChanges, true);
    assert.deepEqual(review.changedFiles, [
      { status: "M", path: "tracked.txt" },
    ]);
    assert.equal(
      readFileSync(join(fixture.repositoryRoot, "tracked.txt"), "utf8"),
      "direct source edit\n",
    );
    assert.equal(
      readFileSync(join(workspace.worktreePath, "tracked.txt"), "utf8"),
      "task change\n",
    );
  } finally {
    fixture.remove();
  }
});

test("원본 저장소의 추적 또는 미추적 변경을 건드리지 않고 worktree를 만든다", async () => {
  for (const dirty of ["tracked", "untracked"]) {
    const fixture = createRepository();
    try {
      if (dirty === "tracked") {
        writeFileSync(join(fixture.repositoryRoot, "tracked.txt"), "dirty\n");
      } else {
        writeFileSync(join(fixture.repositoryRoot, "new.txt"), "dirty\n");
      }
      const manager = new GitWorkspaceManager({
        sourceWorkdir: fixture.repositoryRoot,
        worktreeRoot: fixture.worktreeRoot,
      });

      const workspace = await manager.provision({
        workspaceID: `workspace-${dirty}`,
        characterID: "boss",
      });

      assert.equal(
        readFileSync(join(workspace.worktreePath, "tracked.txt"), "utf8"),
        "base\n",
      );
      if (dirty === "tracked") {
        assert.equal(
          readFileSync(join(fixture.repositoryRoot, "tracked.txt"), "utf8"),
          "dirty\n",
        );
      } else {
        assert.equal(
          readFileSync(join(fixture.repositoryRoot, "new.txt"), "utf8"),
          "dirty\n",
        );
        assert.equal(pathExists(join(workspace.worktreePath, "new.txt")), false);
      }
    } finally {
      fixture.remove();
    }
  }
});

test("worktree 보관 폴더가 원본 저장소 내부면 생성 전에 거절한다", async () => {
  const fixture = createRepository();
  try {
    const nestedRoot = join(fixture.repositoryRoot, ".officestra-worktrees");
    const manager = new GitWorkspaceManager({
      sourceWorkdir: fixture.repositoryRoot,
      worktreeRoot: nestedRoot,
    });

    await assert.rejects(
      manager.provision({
        workspaceID: "workspace-nested",
        characterID: "boss",
      }),
      (error) => error instanceof GitWorkspaceError &&
        error.code === "invalid-state",
    );
    assert.equal(pathExists(nestedRoot), false);
    assert.equal(git(fixture.repositoryRoot, "status", "--porcelain"), "");
  } finally {
    fixture.remove();
  }
});

test("직원이 만든 커밋과 미추적 파일을 하나의 기준 diff에 포함한다", async () => {
  const fixture = createRepository();
  try {
    const { manager, workspace } = await fixture.provision();
    writeFileSync(join(workspace.worktreePath, "tracked.txt"), "agent commit\n");
    git(workspace.worktreePath, "add", "tracked.txt");
    git(workspace.worktreePath, "commit", "-m", "agent change");
    writeFileSync(join(workspace.worktreePath, "untracked.txt"), "new file\n");

    const review = await manager.prepareReview(workspace);
    const patch = await manager.diff({ ...workspace, reviewTree: review.reviewTree });

    assert.equal(review.hasChanges, true);
    assert.deepEqual(review.changedFiles, [
      { status: "M", path: "tracked.txt" },
      { status: "A", path: "untracked.txt" },
    ]);
    assert.match(patch.diff, /agent commit/);
    assert.match(patch.diff, /untracked\.txt/);
    assert.equal(patch.diffTruncated, false);

    const truncated = await manager.diff(
      { ...workspace, reviewTree: review.reviewTree },
      { maxBytes: 12 },
    );
    assert.equal(truncated.diffTruncated, true);
    assert.ok(Buffer.byteLength(truncated.diff) <= 12);
  } finally {
    fixture.remove();
  }
});

test("승인은 직원의 숨은 중간 커밋을 main 이력에 포함하지 않는다", async () => {
  const fixture = createRepository();
  try {
    const { manager, workspace } = await fixture.provision();
    writeFileSync(
      join(workspace.worktreePath, "secret.txt"),
      "temporary secret\n",
    );
    git(workspace.worktreePath, "add", "secret.txt");
    git(workspace.worktreePath, "commit", "-m", "temporary secret");
    const hiddenCommit = git(workspace.worktreePath, "rev-parse", "HEAD");

    unlinkSync(join(workspace.worktreePath, "secret.txt"));
    writeFileSync(
      join(workspace.worktreePath, "tracked.txt"),
      "approved final tree\n",
    );
    git(workspace.worktreePath, "add", "-A");
    git(workspace.worktreePath, "commit", "-m", "visible final change");
    const review = await manager.prepareReview(workspace);
    const patch = await manager.diff({
      ...workspace,
      reviewTree: review.reviewTree,
    });
    assert.doesNotMatch(patch.diff, /temporary secret/);

    const result = await manager.approve(workspace, {
      expectedReviewTree: review.reviewTree,
      commitMessage: "test: squash reviewed tree",
    });
    assert.deepEqual(
      git(
        fixture.repositoryRoot,
        "rev-list",
        "--parents",
        "-n",
        "1",
        result.taskCommit,
      ).split(" "),
      [result.taskCommit, workspace.baseCommit],
    );
    assert.throws(
      () => git(
        fixture.repositoryRoot,
        "merge-base",
        "--is-ancestor",
        hiddenCommit,
        "main",
      ),
    );
    assert.equal(
      git(
        fixture.repositoryRoot,
        "log",
        "main",
        "--format=%H",
        "--",
        "secret.txt",
      ),
      "",
    );
  } finally {
    fixture.remove();
  }
});

test("검토 뒤 변경된 tree는 승인하지 않는다", async () => {
  const fixture = createRepository();
  try {
    const { manager, workspace } = await fixture.provision();
    writeFileSync(join(workspace.worktreePath, "tracked.txt"), "reviewed\n");
    const review = await manager.prepareReview(workspace);
    const sourceHead = git(fixture.repositoryRoot, "rev-parse", "HEAD");
    writeFileSync(join(workspace.worktreePath, "tracked.txt"), "changed later\n");

    await assert.rejects(
      manager.approve(workspace, {
        expectedReviewTree: review.reviewTree,
        commitMessage: "test: approve",
      }),
      (error) => error instanceof GitWorkspaceError &&
        error.code === "changed-after-review",
    );
    assert.equal(git(fixture.repositoryRoot, "rev-parse", "HEAD"), sourceHead);
    assert.equal(readFileSync(join(fixture.repositoryRoot, "tracked.txt"), "utf8"), "base\n");
  } finally {
    fixture.remove();
  }
});

test("검토 후 원본 작업 트리가 dirty면 병합을 막고 업무를 보존한다", async () => {
  const fixture = createRepository();
  try {
    const { manager, workspace } = await fixture.provision();
    writeFileSync(join(workspace.worktreePath, "tracked.txt"), "reviewed\n");
    const review = await manager.prepareReview(workspace);
    writeFileSync(join(fixture.repositoryRoot, "local.txt"), "local\n");

    await assert.rejects(
      manager.approve(workspace, {
        expectedReviewTree: review.reviewTree,
        commitMessage: "test: approve",
      }),
      (error) => error instanceof GitWorkspaceError &&
        error.code === "not-clean",
    );
    assert.equal(readFileSync(join(fixture.repositoryRoot, "tracked.txt"), "utf8"), "base\n");
    assert.equal(readFileSync(join(workspace.worktreePath, "tracked.txt"), "utf8"), "reviewed\n");
  } finally {
    fixture.remove();
  }
});

test("commit hook이 검토 tree를 바꾸면 원본 병합 전에 재승인을 요구한다", async () => {
  const fixture = createRepository();
  try {
    const { manager, workspace } = await fixture.provision();
    writeFileSync(join(workspace.worktreePath, "tracked.txt"), "reviewed\n");
    const review = await manager.prepareReview(workspace);
    const sourceHead = git(fixture.repositoryRoot, "rev-parse", "HEAD");
    const hookPath = join(
      fixture.repositoryRoot,
      ".git",
      "hooks",
      "pre-commit",
    );
    writeFileSync(
      hookPath,
      "#!/bin/sh\nprintf 'hook change\\n' > hook.txt\ngit add hook.txt\n",
    );
    chmodSync(hookPath, 0o755);

    await assert.rejects(
      manager.approve(workspace, {
        expectedReviewTree: review.reviewTree,
        commitMessage: "test: hook changed tree",
      }),
      (error) => error instanceof GitWorkspaceError &&
        error.code === "changed-after-review",
    );
    assert.equal(git(fixture.repositoryRoot, "rev-parse", "HEAD"), sourceHead);
    assert.equal(readFileSync(join(fixture.repositoryRoot, "tracked.txt"), "utf8"), "base\n");
  } finally {
    fixture.remove();
  }
});

test("원본 최신 변경과 충돌하면 main을 바꾸지 않고 중단한다", async () => {
  const fixture = createRepository();
  try {
    const { manager, workspace } = await fixture.provision();
    writeFileSync(join(workspace.worktreePath, "tracked.txt"), "task side\n");
    const review = await manager.prepareReview(workspace);

    writeFileSync(join(fixture.repositoryRoot, "tracked.txt"), "main side\n");
    git(fixture.repositoryRoot, "add", "tracked.txt");
    git(fixture.repositoryRoot, "commit", "-m", "main change");
    const sourceHead = git(fixture.repositoryRoot, "rev-parse", "HEAD");

    await assert.rejects(
      manager.approve(workspace, {
        expectedReviewTree: review.reviewTree,
        commitMessage: "test: conflicting task",
      }),
      (error) => error instanceof GitWorkspaceError &&
        error.code === "conflict",
    );
    assert.equal(git(fixture.repositoryRoot, "rev-parse", "HEAD"), sourceHead);
    assert.equal(git(fixture.repositoryRoot, "status", "--porcelain"), "");
    assert.equal(readFileSync(join(fixture.repositoryRoot, "tracked.txt"), "utf8"), "main side\n");
  } finally {
    fixture.remove();
  }
});

test("병렬 업무 기록 append는 양쪽 내용을 보존해 자동 병합한다", async () => {
  const fixture = createRepository();
  try {
    const checklistBase = "# 체크리스트\n\n## 공통 기록\n- 기준\n";
    const contextBase = "# 컨텍스트\n\n## 공통 기록\n- 기준\n";
    writeFileSync(
      join(fixture.repositoryRoot, "checklist.md"),
      checklistBase,
    );
    writeFileSync(
      join(fixture.repositoryRoot, "context-notes.md"),
      contextBase,
    );
    git(fixture.repositoryRoot, "add", "checklist.md", "context-notes.md");
    git(fixture.repositoryRoot, "commit", "-m", "add work records");

    const { manager, workspace } = await fixture.provision();
    writeFileSync(
      join(workspace.worktreePath, "checklist.md"),
      `${checklistBase}\n## 직원 기록\n- 직원 변경\n`,
    );
    writeFileSync(
      join(workspace.worktreePath, "context-notes.md"),
      `${contextBase}\n## 직원 컨텍스트\n- 직원 변경\n`,
    );
    const review = await manager.prepareReview(workspace);

    writeFileSync(
      join(fixture.repositoryRoot, ".gitattributes"),
      "/checklist.md merge=union\n/context-notes.md merge=union\n",
    );
    writeFileSync(
      join(fixture.repositoryRoot, "checklist.md"),
      `${checklistBase}\n## main 기록\n- main 변경\n`,
    );
    writeFileSync(
      join(fixture.repositoryRoot, "context-notes.md"),
      `${contextBase}\n## main 컨텍스트\n- main 변경\n`,
    );
    git(fixture.repositoryRoot, "add", "-A");
    git(fixture.repositoryRoot, "commit", "-m", "configure work record merge");

    await manager.approve(workspace, {
      expectedReviewTree: review.reviewTree,
      commitMessage: "test: merge parallel work records",
    });

    const checklist = readFileSync(
      join(fixture.repositoryRoot, "checklist.md"),
      "utf8",
    );
    const context = readFileSync(
      join(fixture.repositoryRoot, "context-notes.md"),
      "utf8",
    );
    assert.match(checklist, /직원 변경/);
    assert.match(checklist, /main 변경/);
    assert.match(context, /직원 변경/);
    assert.match(context, /main 변경/);
    assert.equal(git(fixture.repositoryRoot, "status", "--porcelain"), "");
  } finally {
    fixture.remove();
  }
});

test("하위 폴더의 같은 이름 파일은 일반 충돌로 차단한다", async () => {
  const fixture = createRepository();
  try {
    mkdirSync(join(fixture.repositoryRoot, "docs"));
    writeFileSync(
      join(fixture.repositoryRoot, ".gitattributes"),
      "/checklist.md merge=union\n/context-notes.md merge=union\n",
    );
    writeFileSync(
      join(fixture.repositoryRoot, "docs", "checklist.md"),
      "# 사용자 문서\n\n공통 문장\n",
    );
    git(fixture.repositoryRoot, "add", "-A");
    git(fixture.repositoryRoot, "commit", "-m", "add nested checklist");

    const { manager, workspace } = await fixture.provision();
    writeFileSync(
      join(workspace.worktreePath, "docs", "checklist.md"),
      "# 사용자 문서\n\n직원 변경\n",
    );
    const review = await manager.prepareReview(workspace);

    writeFileSync(
      join(fixture.repositoryRoot, "docs", "checklist.md"),
      "# 사용자 문서\n\nmain 변경\n",
    );
    git(fixture.repositoryRoot, "add", "docs/checklist.md");
    git(fixture.repositoryRoot, "commit", "-m", "change nested checklist");
    const sourceHead = git(fixture.repositoryRoot, "rev-parse", "HEAD");

    await assert.rejects(
      manager.approve(workspace, {
        expectedReviewTree: review.reviewTree,
        commitMessage: "test: nested work record conflict",
      }),
      (error) => error instanceof GitWorkspaceError &&
        error.code === "conflict",
    );
    assert.equal(git(fixture.repositoryRoot, "rev-parse", "HEAD"), sourceHead);
    assert.equal(
      readFileSync(
        join(fixture.repositoryRoot, "docs", "checklist.md"),
        "utf8",
      ),
      "# 사용자 문서\n\nmain 변경\n",
    );
  } finally {
    fixture.remove();
  }
});

test("프로젝트 merge hook 실패를 우회하지 않고 원본 병합을 되돌린다", async () => {
  const fixture = createRepository();
  try {
    const { manager, workspace } = await fixture.provision();
    writeFileSync(join(workspace.worktreePath, "tracked.txt"), "hooked\n");
    const review = await manager.prepareReview(workspace);
    const sourceHead = git(fixture.repositoryRoot, "rev-parse", "HEAD");
    const hookPath = join(
      fixture.repositoryRoot,
      ".git",
      "hooks",
      "pre-merge-commit",
    );
    writeFileSync(hookPath, "#!/bin/sh\nexit 1\n");
    chmodSync(hookPath, 0o755);

    await assert.rejects(
      manager.approve(workspace, {
        expectedReviewTree: review.reviewTree,
        commitMessage: "test: hook failure",
      }),
      (error) => error instanceof GitWorkspaceError &&
        error.code === "command-failed",
    );
    assert.equal(git(fixture.repositoryRoot, "rev-parse", "HEAD"), sourceHead);
    assert.equal(git(fixture.repositoryRoot, "status", "--porcelain"), "");
    assert.equal(readFileSync(join(fixture.repositoryRoot, "tracked.txt"), "utf8"), "base\n");
  } finally {
    fixture.remove();
  }
});

test("merge hook의 tracked 변경은 승인 병합을 되돌린다", async () => {
  const fixture = createRepository();
  try {
    const { manager, workspace } = await fixture.provision();
    writeFileSync(join(workspace.worktreePath, "tracked.txt"), "reviewed\n");
    const review = await manager.prepareReview(workspace);
    const sourceHead = git(fixture.repositoryRoot, "rev-parse", "HEAD");
    const hookPath = join(
      fixture.repositoryRoot,
      ".git",
      "hooks",
      "pre-merge-commit",
    );
    writeFileSync(
      hookPath,
      "#!/bin/sh\nprintf 'unreviewed hook change\\n' > tracked.txt\ngit add tracked.txt\n",
    );
    chmodSync(hookPath, 0o755);

    await assert.rejects(
      manager.approve(workspace, {
        expectedReviewTree: review.reviewTree,
        commitMessage: "test: tracked merge hook change",
      }),
      (error) => error instanceof GitWorkspaceError &&
        error.code === "command-failed",
    );
    assert.equal(git(fixture.repositoryRoot, "rev-parse", "HEAD"), sourceHead);
    assert.equal(
      readFileSync(join(fixture.repositoryRoot, "tracked.txt"), "utf8"),
      "base\n",
    );
    assert.equal(git(fixture.repositoryRoot, "status", "--porcelain"), "");
  } finally {
    fixture.remove();
  }
});

test("merge hook의 미추적 산출물은 보존하고 원본 branch만 되돌린다", async () => {
  const fixture = createRepository();
  try {
    const { manager, workspace } = await fixture.provision();
    writeFileSync(join(workspace.worktreePath, "tracked.txt"), "reviewed\n");
    const review = await manager.prepareReview(workspace);
    const sourceHead = git(fixture.repositoryRoot, "rev-parse", "HEAD");
    const hookPath = join(
      fixture.repositoryRoot,
      ".git",
      "hooks",
      "pre-merge-commit",
    );
    writeFileSync(
      hookPath,
      "#!/bin/sh\nprintf 'keep me\\n' > hook-output.txt\n",
    );
    chmodSync(hookPath, 0o755);

    await assert.rejects(
      manager.approve(workspace, {
        expectedReviewTree: review.reviewTree,
        commitMessage: "test: untracked merge hook output",
      }),
      (error) => error instanceof GitWorkspaceError &&
        error.code === "not-clean",
    );
    assert.equal(git(fixture.repositoryRoot, "rev-parse", "HEAD"), sourceHead);
    assert.equal(
      readFileSync(join(fixture.repositoryRoot, "tracked.txt"), "utf8"),
      "base\n",
    );
    assert.equal(
      readFileSync(join(fixture.repositoryRoot, "hook-output.txt"), "utf8"),
      "keep me\n",
    );
    assert.equal(
      git(fixture.repositoryRoot, "status", "--porcelain"),
      "?? hook-output.txt",
    );
  } finally {
    fixture.remove();
  }
});

test("merge hook의 미추적 파일이 원본 tracked 경로와 충돌하면 덮어쓰지 않는다", async () => {
  const fixture = createRepository();
  try {
    const { manager, workspace } = await fixture.provision();
    unlinkSync(join(workspace.worktreePath, "tracked.txt"));
    const review = await manager.prepareReview(workspace);
    const sourceHead = git(fixture.repositoryRoot, "rev-parse", "HEAD");
    const hookPath = join(
      fixture.repositoryRoot,
      ".git",
      "hooks",
      "pre-merge-commit",
    );
    writeFileSync(
      hookPath,
      "#!/bin/sh\nprintf 'preserve collision\\n' > tracked.txt\n",
    );
    chmodSync(hookPath, 0o755);

    await assert.rejects(
      manager.approve(workspace, {
        expectedReviewTree: review.reviewTree,
        commitMessage: "test: untracked merge hook collision",
      }),
      (error) => error instanceof GitWorkspaceError &&
        error.code === "not-clean",
    );
    assert.equal(git(fixture.repositoryRoot, "rev-parse", "HEAD"), sourceHead);
    assert.equal(
      readFileSync(join(fixture.repositoryRoot, "tracked.txt"), "utf8"),
      "preserve collision\n",
    );
    assert.match(
      git(fixture.repositoryRoot, "status", "--porcelain"),
      /tracked\.txt/,
    );
  } finally {
    fixture.remove();
  }
});

test("승인한 tree만 no-ff 병합하고 정리 뒤에도 diff를 읽는다", async () => {
  const fixture = createRepository();
  try {
    const { manager, workspace } = await fixture.provision();
    writeFileSync(join(workspace.worktreePath, "tracked.txt"), "approved\n");
    writeFileSync(join(workspace.worktreePath, "added.txt"), "added\n");
    const review = await manager.prepareReview(workspace);

    const result = await manager.approve(workspace, {
      expectedReviewTree: review.reviewTree,
      commitMessage: "test: approved task",
    });

    assert.equal(result.taskCommit, git(workspace.worktreePath, "rev-parse", "HEAD"));
    assert.equal(result.mergedCommit, git(fixture.repositoryRoot, "rev-parse", "HEAD"));
    assert.equal(
      git(fixture.repositoryRoot, "rev-list", "--parents", "-n", "1", "HEAD")
        .split(" ").length,
      3,
    );
    assert.equal(readFileSync(join(fixture.repositoryRoot, "tracked.txt"), "utf8"), "approved\n");
    assert.equal(readFileSync(join(fixture.repositoryRoot, "added.txt"), "utf8"), "added\n");

    assert.deepEqual(
      await manager.approve(workspace, {
        expectedReviewTree: review.reviewTree,
        commitMessage: "test: duplicate approval",
      }),
      result,
    );

    await manager.cleanup(workspace);
    assert.equal(pathExists(workspace.worktreePath), false);
    assert.throws(
      () => git(fixture.repositoryRoot, "show-ref", "--verify", `refs/heads/${workspace.branchName}`),
    );

    const retainedDiff = await manager.diff({
      ...workspace,
      reviewTree: review.reviewTree,
    });
    assert.match(retainedDiff.diff, /approved/);
    assert.match(retainedDiff.diff, /added\.txt/);
    assert.deepEqual(
      await manager.approve(
        { ...workspace, taskCommit: result.taskCommit },
        {
          expectedReviewTree: review.reviewTree,
          commitMessage: "test: recovered approval",
        },
      ),
      result,
    );
  } finally {
    fixture.remove();
  }
});

function createRepository({ withSubdirectory = false } = {}) {
  const root = realpathSync(
    mkdtempSync(join(tmpdir(), "office-workspace-test-")),
  );
  const repositoryRoot = join(root, "repository");
  const worktreeRoot = join(root, "worktrees");
  mkdirSync(repositoryRoot);
  git(repositoryRoot, "init", "--initial-branch=main");
  git(repositoryRoot, "config", "user.name", "OFFICESTRA Test");
  git(repositoryRoot, "config", "user.email", "officestra-test@example.com");
  writeFileSync(join(repositoryRoot, "tracked.txt"), "base\n");

  let sourceWorkdir = repositoryRoot;
  if (withSubdirectory) {
    sourceWorkdir = join(repositoryRoot, "Sources", "Feature");
    mkdirSync(sourceWorkdir, { recursive: true });
    writeFileSync(join(sourceWorkdir, "note.txt"), "base\n");
  }
  git(repositoryRoot, "add", "-A");
  git(repositoryRoot, "commit", "-m", "initial");

  return {
    root,
    repositoryRoot,
    sourceWorkdir,
    worktreeRoot,
    async provision() {
      const manager = new GitWorkspaceManager({
        sourceWorkdir,
        worktreeRoot,
      });
      const workspace = await manager.provision({
        workspaceID: "workspace-1",
        characterID: "boss",
      });
      return { manager, workspace };
    },
    remove() {
      rmSync(root, { recursive: true, force: true });
    },
  };
}

function git(directory, ...argumentsList) {
  return execFileSync(
    "git",
    ["-C", directory, ...argumentsList],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        GIT_TERMINAL_PROMPT: "0",
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  ).trim();
}

function pathExists(path) {
  try {
    readFileSync(path);
    return true;
  } catch (error) {
    return error.code === "EISDIR";
  }
}
