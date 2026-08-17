// 이 파일은 캐릭터 실행 설정 변경에 따른 CLI 세션 유지 정책을 검증한다.

import assert from "node:assert/strict";
import test from "node:test";

import {
  characterConfigurationForSync,
  configurationWithRuntimeWorkdir,
  characterSettingsRequireNewSession,
  syncCharacters,
} from "../src/configuration.mjs";

const current = {
  backend: "codex",
  model: "gpt-5.6-sol",
  effort: "high",
  fastMode: true,
  permission: "workspace-write",
};

test("운영 업무 폴더가 있으면 JSON의 임시 경로를 덮어쓴다", () => {
  const configuration = {
    workdir: "/tmp/deleted-worktree",
    characters: [],
  };

  assert.deepEqual(
    configurationWithRuntimeWorkdir(configuration, " /Users/neo/office "),
    {
      workdir: "/Users/neo/office",
      characters: [],
    },
  );
  assert.deepEqual(configuration, {
    workdir: "/tmp/deleted-worktree",
    characters: [],
  });
});

test("운영 업무 폴더가 없으면 JSON 설정을 유지한다", () => {
  const configuration = {
    workdir: "/Users/neo/office",
    characters: [],
  };

  assert.equal(
    configurationWithRuntimeWorkdir(configuration, "  "),
    configuration,
  );
});

test("Fast·모델·추론 변경은 기존 CLI 세션을 유지한다", () => {
  for (const changed of [
    { fastMode: false },
    { model: "gpt-5.6-terra" },
    { effort: "xhigh" },
    {
      model: "gpt-5.6-luna",
      effort: "max",
      fastMode: false,
    },
  ]) {
    assert.equal(
      characterSettingsRequireNewSession(current, {
        ...current,
        ...changed,
      }),
      false,
    );
  }
});

test("권한 변경도 기존 CLI 세션을 유지한다", () => {
  assert.equal(
    characterSettingsRequireNewSession(current, {
      ...current,
      permission: "danger-full-access",
    }),
    false,
  );
});

test("CLI 종류 변경만 새 세션을 요구한다", () => {
  assert.equal(
    characterSettingsRequireNewSession(current, {
      ...current,
      backend: "claude",
    }),
    true,
  );
});

test("동기화할 CLI 경로는 provider 이름과 실행 권한을 모두 확인한다", async () => {
  const executableChecks = [];
  const accessExecutable = async (path, mode) => {
    executableChecks.push({ path, mode });
    if (path.includes("blocked")) throw new Error("not executable");
  };

  assert.deepEqual(
    await characterConfigurationForSync(
      {
        id: "boss",
        backend: "codex",
        executablePath: " /opt/homebrew/bin/codex ",
      },
      accessExecutable,
    ),
    {
      id: "boss",
      backend: "codex",
      executablePath: "/opt/homebrew/bin/codex",
    },
  );
  assert.equal(executableChecks.length, 1);

  for (const character of [
    {
      id: "wrong-provider",
      backend: "codex",
      executablePath: "/usr/local/bin/claude",
    },
    {
      id: "not-executable",
      backend: "claude",
      executablePath: "/blocked/claude",
    },
  ]) {
    const synchronized = await characterConfigurationForSync(
      character,
      accessExecutable,
    );
    assert.equal("executablePath" in synchronized, false);
  }
});

test("기존 직원은 같은 provider의 검증된 최신 CLI 경로만 갱신한다", async () => {
  const queries = [];
  const client = {
    async query(text, values) {
      queries.push({ text, values });
      return { rowCount: 1 };
    },
  };

  await syncCharacters(client, {
    characters: [
      {
        id: "boss",
        name: "백부장",
        seat: "boss",
        backend: "codex",
        identityPrompt: "lead",
        model: "gpt-5.6-sol",
        effort: "ultra",
        fastMode: false,
        permission: "workspace-write",
        executablePath: "/definitely/missing/codex",
      },
    ],
  });

  assert.equal(queries.length, 1);
  assert.match(
    queries[0].text,
    /characters\.backend = EXCLUDED\.backend[\s\S]*EXCLUDED\.config \? 'executablePath'/,
  );
  const conflictUpdate = queries[0].text.split("ON CONFLICT (id) DO UPDATE")[1];
  assert.doesNotMatch(
    conflictUpdate,
    /identity_prompt\s*=/,
    "기동 동기화는 DB에서 관리하는 업무 지침을 덮어쓰지 않아야 합니다.",
  );
  assert.equal(
    "executablePath" in JSON.parse(queries[0].values[9]),
    false,
  );
});
