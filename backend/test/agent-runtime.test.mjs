// 이 파일은 파일 첨부 인수와 실행 중단 상태 저장을 검증한다.

import assert from "node:assert/strict";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  AgentJobNotFoundError,
  AgentRuntime,
  buildArguments,
  promptWithAttachments,
  stageAttachments,
} from "../src/agent-runtime.mjs";

const codexCharacter = {
  backend: "codex",
  model: "gpt-5.6-sol",
  effort: "high",
  permission: "workspace-write",
  name: "코과장",
  seat: "우측 아래",
  identityPrompt: "업무를 정확히 처리한다.",
};

test("Codex에는 PNG와 JPEG만 이미지 인수로 전달한다", () => {
  const argumentsList = buildArguments({
    character: codexCharacter,
    prompt: "파일을 확인해줘.",
    previousSessionID: "session-1",
    attachments: [
      {
        path: "/tmp/photo.png",
        isCodexImage: true,
      },
      {
        path: "/tmp/document.pdf",
        isCodexImage: false,
      },
      {
        path: "/tmp/photo.jpeg",
        isCodexImage: true,
      },
    ],
  });

  assert.deepEqual(
    argumentsList.filter((value) => value.startsWith("/tmp/")),
    ["/tmp/photo.png", "/tmp/photo.jpeg"],
  );
  assert.equal(argumentsList.at(-1), "파일을 확인해줘.");
});

test("업무 프롬프트에 보관된 첨부 경로를 기록한다", () => {
  const prompt = promptWithAttachments("분석해줘.", [
    {
      name: "report.pdf",
      path: "/workspace/.office-attachments/01-report.pdf",
    },
  ]);

  assert.match(prompt, /첨부 파일/);
  assert.match(prompt, /report\.pdf/);
  assert.match(prompt, /\.office-attachments/);
});

test("첨부 원본을 작업 폴더에 보관한다", () => {
  const workdir = mkdtempSync(join(tmpdir(), "office-attachment-test-"));
  const source = join(workdir, "source.txt");
  writeFileSync(source, "attachment body");

  try {
    const [attachment] = stageAttachments({
      attachmentPaths: [source],
      workdir,
    });

    assert.equal(existsSync(attachment.path), true);
    assert.equal(readFileSync(attachment.path, "utf8"), "attachment body");
    assert.match(attachment.path, /\.office-attachments/);
  } finally {
    rmSync(workdir, { recursive: true, force: true });
  }
});

test("실행 중단은 턴을 interrupted로 저장하고 실행 목록에서 제거한다", async () => {
  const queries = [];
  const broadcasts = [];
  const runtime = new AgentRuntime({
    pool: {
      query: async (text, values) => {
        queries.push({ text, values });
        return { rowCount: 1 };
      },
    },
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: (event) => broadcasts.push(event),
  });
  runtime.running.set("boss", {
    turnID: "turn-1",
    process: null,
    cancelRequested: false,
  });

  const result = await runtime.cancel("boss");

  assert.deepEqual(result, {
    turnId: "turn-1",
    status: "interrupted",
  });
  assert.equal(runtime.running.has("boss"), false);
  assert.match(queries[0].text, /status = 'interrupted'/);
  assert.deepEqual(queries[0].values, [
    "turn-1",
    "사용자가 업무를 중단했습니다.",
  ]);
  assert.equal(broadcasts.length, 1);
});

test("실행 중인 업무가 없으면 중단 요청을 거절한다", async () => {
  const runtime = new AgentRuntime({
    pool: {},
    withTransaction: async () => {},
    workdir: "/tmp",
    broadcast: () => {},
  });

  await assert.rejects(
    runtime.cancel("boss"),
    AgentJobNotFoundError,
  );
});
