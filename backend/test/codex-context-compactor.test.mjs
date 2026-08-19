import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import test from "node:test";

import { compactCodexThread } from "../src/codex-context-compactor.mjs";

class FakeChild extends EventEmitter {
  constructor(onMessage) {
    super();
    this.stdin = new PassThrough();
    this.stdout = new PassThrough();
    this.stderr = new PassThrough();
    this.exitCode = null;
    this.signalCode = null;
    let remainder = "";
    this.stdin.on("data", (chunk) => {
      const lines = `${remainder}${String(chunk)}`.split("\n");
      remainder = lines.pop() ?? "";
      for (const line of lines) {
        if (line) onMessage(JSON.parse(line), this);
      }
    });
  }

  send(object) {
    this.stdout.write(`${JSON.stringify(object)}\n`);
  }

  kill(signal) {
    this.signalCode = signal;
    this.exitCode = 0;
    this.stdout.end();
    this.stderr.end();
    queueMicrotask(() => this.emit("close", 0, signal));
    return true;
  }
}

test("Codex 수동 압축은 app-server의 네이티브 compact 요청을 사용한다", async () => {
  const messages = [];
  let spawn;
  const result = await compactCodexThread({
    executable: "codex",
    threadID: "thread-1",
    cwd: "/repo",
    env: { TEST: "1" },
    contextWindow: 872_000,
    autoCompactTokenLimit: 745_560,
    timeoutMs: 1_000,
    spawnProcess: (executable, argumentsList, options) => {
      spawn = { executable, argumentsList, options };
      return new FakeChild((message, child) => {
        messages.push(message);
        if (message.method === "initialize") {
          child.send({ id: message.id, result: { userAgent: "test" } });
        } else if (message.method === "thread/resume") {
          child.send({ id: message.id, result: { thread: { id: "thread-1" } } });
        } else if (message.method === "thread/compact/start") {
          child.send({ id: message.id, result: {} });
          child.send({
            method: "item/completed",
            params: {
              threadId: "thread-1",
              turnId: "turn-compact",
              item: { type: "contextCompaction", id: "item-1" },
              completedAtMs: Date.now(),
            },
          });
        }
      });
    },
  });

  assert.equal(spawn.executable, "codex");
  assert.deepEqual(spawn.argumentsList, [
    "-c",
    "model_context_window=872000",
    "-c",
    "model_auto_compact_token_limit=745560",
    "app-server",
    "--stdio",
  ]);
  assert.equal(spawn.options.cwd, "/repo");
  assert.deepEqual(
    messages.map((message) => message.method),
    [
      "initialize",
      "initialized",
      "thread/resume",
      "thread/compact/start",
    ],
  );
  assert.deepEqual(messages[2].params, {
    threadId: "thread-1",
    cwd: "/repo",
  });
  assert.deepEqual(result, { turnID: "turn-compact" });
});
