import assert from "node:assert/strict";
import { EventEmitter, once } from "node:events";
import { PassThrough } from "node:stream";
import test from "node:test";

import {
  ClaudePersistentWorker,
  scopedClaudeCumulativeResult,
} from "../src/claude-persistent-worker.mjs";

class FakeChild extends EventEmitter {
  constructor() {
    super();
    this.stdin = new PassThrough();
    this.stdout = new PassThrough();
    this.stderr = new PassThrough();
    this.pid = undefined;
    this.exitCode = null;
    this.killed = false;
  }

  kill(signal) {
    this.killed = true;
    this.exitCode = signal === "SIGKILL" ? 137 : 0;
    this.stdout.end();
    this.stderr.end();
    queueMicrotask(() => this.emit("close", this.exitCode, signal));
    return true;
  }
}

function emit(child, object) {
  child.stdout.write(`${JSON.stringify(object)}\n`);
}

async function submittedMessage(child, run) {
  const input = once(child.stdin, "data");
  const promise = run();
  const [chunk] = await input;
  return { message: JSON.parse(String(chunk)), promise };
}

test("같은 Claude 프로세스가 연속 turn을 받고 누적 사용량은 turn별 증분으로 전달한다", async () => {
  const child = new FakeChild();
  let spawnCount = 0;
  const received = [];
  const worker = new ClaudePersistentWorker({
    executable: "claude",
    argumentsList: ["-p"],
    cwd: "/repo",
    env: {},
    signature: "same",
    spawnProcess: () => {
      spawnCount += 1;
      return child;
    },
    suggestionGraceMs: 100,
  });

  const first = await submittedMessage(child, () => worker.runTurn({
    prompt: "첫 질문",
    onLine: async (line) => received.push(JSON.parse(line)),
  }));
  assert.equal(first.message.message.content, "첫 질문");
  emit(child, {
    type: "system",
    subtype: "init",
    session_id: "session-1",
  });
  emit(child, {
    type: "result",
    subtype: "success",
    is_error: false,
    result: "첫 답",
    total_cost_usd: 1.2,
    usage: { input_tokens: 10, output_tokens: 2 },
    modelUsage: {
      "claude-opus-5": {
        inputTokens: 10,
        outputTokens: 2,
        cacheReadInputTokens: 100,
        cacheCreationInputTokens: 900,
        costUSD: 1.2,
      },
    },
  });
  emit(child, {
    type: "prompt_suggestion",
    suggestion: "첫 추천",
    uuid: "suggestion-1",
  });
  await first.promise;

  const second = await submittedMessage(child, () => worker.runTurn({
    prompt: "둘째 질문",
    onLine: async (line) => received.push(JSON.parse(line)),
  }));
  assert.equal(second.message.message.content, "둘째 질문");
  emit(child, {
    type: "result",
    subtype: "success",
    is_error: false,
    result: "둘째 답",
    total_cost_usd: 1.5,
    usage: { input_tokens: 1, output_tokens: 3 },
    modelUsage: {
      "claude-opus-5": {
        inputTokens: 11,
        outputTokens: 5,
        cacheReadInputTokens: 1_050,
        cacheCreationInputTokens: 920,
        costUSD: 1.5,
      },
    },
  });
  emit(child, {
    type: "prompt_suggestion",
    suggestion: "둘째 추천",
    uuid: "suggestion-2",
  });
  await second.promise;

  assert.equal(spawnCount, 1);
  assert.equal(worker.sessionID, "session-1");
  assert.equal(worker.matches({ signature: "same", sessionID: "session-1" }), true);
  assert.equal(worker.matches({ signature: "same", sessionID: null }), false);
  assert.equal(worker.matches({ signature: "same", sessionID: "session-2" }), false);
  const results = received.filter((event) => event.type === "result");
  assert.equal(results[0].total_cost_usd, 1.2);
  assert.ok(Math.abs(results[1].total_cost_usd - 0.3) < 1e-9);
  assert.deepEqual(results[1].usage, { input_tokens: 1, output_tokens: 3 });
  assert.deepEqual({
    ...results[1].modelUsage["claude-opus-5"],
    costUSD: 0.3,
  }, {
    inputTokens: 1,
    outputTokens: 3,
    cacheReadInputTokens: 950,
    cacheCreationInputTokens: 20,
    costUSD: 0.3,
  });
  assert.ok(
    Math.abs(
      results[1].modelUsage["claude-opus-5"].costUSD - 0.3,
    ) < 1e-9,
  );

  worker.close();
  assert.equal(child.killed, true);
});

test("이전 turn에서 늦은 추천은 다음 turn에 붙이지 않는다", async () => {
  const child = new FakeChild();
  const worker = new ClaudePersistentWorker({
    executable: "claude",
    argumentsList: ["-p"],
    cwd: "/repo",
    env: {},
    signature: "same",
    spawnProcess: () => child,
    suggestionGraceMs: 5,
  });
  const firstEvents = [];
  const first = await submittedMessage(child, () => worker.runTurn({
    prompt: "첫 질문",
    onLine: async (line) => firstEvents.push(JSON.parse(line)),
  }));
  emit(child, {
    type: "result",
    subtype: "success",
    is_error: false,
    result: "첫 답",
    total_cost_usd: 0.1,
  });
  await first.promise;

  const secondEvents = [];
  const second = await submittedMessage(child, () => worker.runTurn({
    prompt: "둘째 질문",
    onLine: async (line) => secondEvents.push(JSON.parse(line)),
  }));
  emit(child, {
    type: "prompt_suggestion",
    suggestion: "늦은 첫 추천",
    uuid: "late-1",
  });
  emit(child, {
    type: "result",
    subtype: "success",
    is_error: false,
    result: "둘째 답",
    total_cost_usd: 0.2,
  });
  emit(child, {
    type: "prompt_suggestion",
    suggestion: "둘째 추천",
    uuid: "suggestion-2",
  });
  await second.promise;

  assert.equal(
    secondEvents.some((event) => event.suggestion === "늦은 첫 추천"),
    false,
  );
  assert.equal(
    secondEvents.some((event) => event.suggestion === "둘째 추천"),
    true,
  );
  worker.close();
});

test("누적 집계가 감소하면 새 query 기준으로 그대로 사용한다", () => {
  const previous = {
    totalCostUsd: 2,
    modelUsage: {
      model: { inputTokens: 200, costUSD: 2 },
    },
  };
  const scoped = scopedClaudeCumulativeResult({
    type: "result",
    total_cost_usd: 0.4,
    modelUsage: {
      model: { inputTokens: 40, costUSD: 0.4 },
    },
  }, previous);
  assert.equal(scoped.result.total_cost_usd, 0.4);
  assert.equal(scoped.result.modelUsage.model.inputTokens, 40);
  assert.equal(scoped.result.modelUsage.model.costUSD, 0.4);
});

test("Claude 수동 압축은 /compact와 완료 경계의 토큰을 사용한다", async () => {
  const child = new FakeChild();
  const worker = new ClaudePersistentWorker({
    executable: "claude",
    argumentsList: ["-p"],
    cwd: "/repo",
    env: {},
    signature: "compact",
    sessionID: "session-1",
    spawnProcess: () => child,
    suggestionGraceMs: 5,
  });

  const submitted = await submittedMessage(child, () => worker.compact());
  assert.equal(submitted.message.message.content, "/compact");
  emit(child, {
    type: "system",
    subtype: "compact_boundary",
    compact_metadata: {
      pre_tokens: 901_000,
      post_tokens: 42_000,
    },
  });
  emit(child, {
    type: "result",
    subtype: "success",
    is_error: false,
    result: "Compacted conversation",
    total_cost_usd: 0.1,
  });
  emit(child, {
    type: "prompt_suggestion",
    suggestion: "계속할까요?",
  });

  assert.deepEqual(await submitted.promise, {
    preTokens: 901_000,
    postTokens: 42_000,
  });
  worker.close();
});
