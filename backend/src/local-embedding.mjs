import { fork } from "node:child_process";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

import {
  LOCAL_EMBEDDING_DIMENSIONS,
  LOCAL_EMBEDDING_IDLE_TIMEOUT_MS,
  LOCAL_EMBEDDING_MODEL_ID,
  LOCAL_EMBEDDING_REQUEST_TIMEOUT_MS,
} from "./local-embedding-config.mjs";
import { ensureLocalEmbeddingModel } from "./local-embedding-model.mjs";

const workerPath = fileURLToPath(
  new URL("./local-embedding-worker.mjs", import.meta.url),
);

export class LocalEmbeddingService {
  constructor({
    idleTimeoutMs = LOCAL_EMBEDDING_IDLE_TIMEOUT_MS,
    requestTimeoutMs = LOCAL_EMBEDDING_REQUEST_TIMEOUT_MS,
    workerFactory = null,
    modelLoader = ensureLocalEmbeddingModel,
    environment = process.env,
  } = {}) {
    this.idleTimeoutMs = idleTimeoutMs;
    this.requestTimeoutMs = requestTimeoutMs;
    this.workerFactory = workerFactory;
    this.modelLoader = modelLoader;
    this.environment = environment;
    this.worker = null;
    this.idleTimer = null;
    this.pending = new Map();
    this.peakWorkerRSSBytes = 0;
    this.lastWorkerRSSBytes = 0;
    this.modelReadyPromise = null;
    this.closed = false;
  }

  get modelID() {
    return LOCAL_EMBEDDING_MODEL_ID;
  }

  get dimensions() {
    return LOCAL_EMBEDDING_DIMENSIONS;
  }

  hasActiveWorker() {
    return this.worker !== null;
  }

  metrics() {
    return {
      active: this.hasActiveWorker(),
      peakWorkerRSSBytes: this.peakWorkerRSSBytes,
      lastWorkerRSSBytes: this.lastWorkerRSSBytes,
    };
  }

  createWorker() {
    if (this.workerFactory) {
      return this.workerFactory();
    }
    return fork(workerPath, [], {
      stdio: ["ignore", "ignore", "pipe", "ipc"],
      // 부모가 --test, --eval 같은 실행 모드여도 워커에는 전달하지 않는다.
      // 전달하면 워커 파일 대신 부모 스크립트를 다시 실행할 수 있다.
      execArgv: [],
      env: {
        ...this.environment,
        HF_HUB_DISABLE_TELEMETRY: "1",
        OFFICE_EMBEDDING_MODEL_DIR: this.modelDirectory,
      },
    });
  }

  async ensureWorker() {
    if (this.worker) {
      return this.worker;
    }
    this.modelReadyPromise ??= this.modelLoader({
      environment: this.environment,
    });
    const model = await this.modelReadyPromise;
    if (this.closed) {
      throw new Error("로컬 임베딩 서비스를 종료했습니다.");
    }
    this.modelDirectory = model.directory;
    if (this.worker) {
      return this.worker;
    }
    const worker = this.createWorker();
    this.worker = worker;
    worker.stderr?.on("data", (data) => {
      const message = String(data ?? "").trim();
      if (message) {
        console.warn("로컬 임베딩 워커:", message);
      }
    });
    worker.on("message", (message) => this.handleMessage(worker, message));
    worker.once("error", (error) => this.handleWorkerExit(worker, error));
    worker.once("exit", (code, signal) => {
      this.handleWorkerExit(
        worker,
        new Error(
          `로컬 임베딩 워커가 종료됐습니다. code=${code} signal=${signal}`,
        ),
      );
    });
    return worker;
  }

  handleMessage(worker, message) {
    if (worker !== this.worker) {
      return;
    }
    const pending = this.pending.get(message?.id);
    if (!pending) {
      return;
    }
    this.pending.delete(message.id);
    clearTimeout(pending.timeout);
    if (message.ok) {
      const result = message.result ?? {};
      this.lastWorkerRSSBytes = Number(result.rssBytes) || 0;
      this.peakWorkerRSSBytes = Math.max(
        this.peakWorkerRSSBytes,
        Number(result.maxRSSBytes) || 0,
        this.lastWorkerRSSBytes,
      );
      pending.resolve(result.vectors ?? []);
      this.scheduleIdleRelease();
    } else {
      pending.reject(new Error(message.error || "로컬 임베딩에 실패했습니다."));
      this.stopWorker(worker);
    }
  }

  handleWorkerExit(worker, error) {
    if (worker !== this.worker) {
      return;
    }
    this.worker = null;
    clearTimeout(this.idleTimer);
    this.idleTimer = null;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(error);
    }
    this.pending.clear();
  }

  scheduleIdleRelease() {
    clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => {
      this.stopWorker(this.worker);
    }, this.idleTimeoutMs);
    this.idleTimer.unref?.();
  }

  stopWorker(worker = this.worker) {
    if (!worker || worker !== this.worker) {
      return;
    }
    this.worker = null;
    clearTimeout(this.idleTimer);
    this.idleTimer = null;
    worker.kill?.("SIGTERM");
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(new Error("로컬 임베딩 워커를 종료했습니다."));
    }
    this.pending.clear();
  }

  async embed(texts) {
    if (this.closed) {
      throw new Error("로컬 임베딩 서비스를 종료했습니다.");
    }
    const normalized = Array.isArray(texts)
      ? texts.map((text) => String(text ?? "").trim())
      : [];
    if (normalized.length === 0 || normalized.some((text) => !text)) {
      throw new Error("임베딩할 비어 있지 않은 텍스트가 필요합니다.");
    }
    const worker = await this.ensureWorker();
    clearTimeout(this.idleTimer);
    this.idleTimer = null;
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error("로컬 임베딩 응답 시간이 초과됐습니다."));
        this.stopWorker(worker);
      }, this.requestTimeoutMs);
      timeout.unref?.();
      this.pending.set(id, { resolve, reject, timeout });
      worker.send({ id, texts }, (error) => {
        if (!error) {
          return;
        }
        const pending = this.pending.get(id);
        if (!pending) {
          return;
        }
        this.pending.delete(id);
        clearTimeout(pending.timeout);
        reject(error);
        this.stopWorker(worker);
      });
    });
  }

  close() {
    this.closed = true;
    this.stopWorker(this.worker);
  }
}
