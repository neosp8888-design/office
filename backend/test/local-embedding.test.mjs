import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";

import { LocalEmbeddingService } from "../src/local-embedding.mjs";
import { LOCAL_EMBEDDING_IDLE_TIMEOUT_MS } from "../src/local-embedding-config.mjs";

class FakeWorker extends EventEmitter {
  constructor() {
    super();
    this.stderr = new EventEmitter();
    this.killCount = 0;
  }

  send(message, callback) {
    callback?.(null);
    queueMicrotask(() => {
      this.emit("message", {
        id: message.id,
        ok: true,
        result: {
          vectors: message.texts.map(() => [1, 0]),
          rssBytes: 2048,
          maxRSSBytes: 4096,
        },
      });
    });
  }

  kill() {
    this.killCount += 1;
  }
}

test("운영 기본 유휴 언로드 시간은 정확히 5분이다", () => {
  assert.equal(LOCAL_EMBEDDING_IDLE_TIMEOUT_MS, 300_000);
});

test("임베딩 워커는 필요할 때 한 번 만들고 유휴 제한 뒤 종료한다", async () => {
  const workers = [];
  const service = new LocalEmbeddingService({
    idleTimeoutMs: 20,
    requestTimeoutMs: 1000,
    modelLoader: async () => ({ directory: "/model" }),
    workerFactory() {
      const worker = new FakeWorker();
      workers.push(worker);
      return worker;
    },
  });

  assert.equal(service.hasActiveWorker(), false);
  assert.deepEqual(await service.embed(["검색 질문"]), [[1, 0]]);
  assert.equal(service.hasActiveWorker(), true);
  assert.equal(workers.length, 1);
  assert.deepEqual(service.metrics(), {
    active: true,
    peakWorkerRSSBytes: 4096,
    lastWorkerRSSBytes: 2048,
  });

  await new Promise((resolve) => setTimeout(resolve, 60));
  assert.equal(service.hasActiveWorker(), false);
  assert.equal(workers[0].killCount, 1);
});

test("동시에 요청해도 모델 준비 후 워커는 하나만 생성한다", async () => {
  const workers = [];
  let releaseModel;
  const modelReady = new Promise((resolve) => {
    releaseModel = resolve;
  });
  const service = new LocalEmbeddingService({
    idleTimeoutMs: 1000,
    requestTimeoutMs: 1000,
    modelLoader: async () => {
      await modelReady;
      return { directory: "/model" };
    },
    workerFactory() {
      const worker = new FakeWorker();
      workers.push(worker);
      return worker;
    },
  });

  const first = service.embed(["첫 질문"]);
  const second = service.embed(["둘째 질문"]);
  releaseModel();
  await Promise.all([first, second]);
  assert.equal(workers.length, 1);
  service.close();
});
