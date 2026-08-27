#!/usr/bin/env node

import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const backendDirectory = resolve(String(process.argv[2] ?? ""));
if (!process.argv[2]) {
  throw new Error("패키지 백엔드 디렉터리가 필요합니다.");
}

const embeddingModule = await import(pathToFileURL(
  resolve(backendDirectory, "src", "local-embedding.mjs"),
));
const configurationModule = await import(pathToFileURL(
  resolve(backendDirectory, "src", "local-embedding-config.mjs"),
));
const { LocalEmbeddingService } = embeddingModule;
const { LOCAL_EMBEDDING_DIMENSIONS, LOCAL_EMBEDDING_MODEL_ID } =
  configurationModule;
const service = new LocalEmbeddingService();

try {
  const [vector] = await service.embed([
    "OFFICESTRA 패키지 Release 빌드 임베딩 스모크 테스트",
  ]);
  if (
    !Array.isArray(vector) ||
    vector.length !== LOCAL_EMBEDDING_DIMENSIONS ||
    vector.some((value) => !Number.isFinite(value))
  ) {
    throw new Error(
      `패키지 임베딩 출력이 ${LOCAL_EMBEDDING_DIMENSIONS}차원이 아닙니다.`,
    );
  }
  const norm = Math.sqrt(
    vector.reduce((sum, value) => sum + value * value, 0),
  );
  if (Math.abs(norm - 1) > 0.01) {
    throw new Error(`패키지 임베딩 정규화 값이 잘못됐습니다. norm=${norm}`);
  }
  process.stdout.write(
    `Packaged embedding smoke passed: ${LOCAL_EMBEDDING_MODEL_ID}, ` +
      `${vector.length} dimensions, norm=${norm.toFixed(6)}\n`,
  );
} finally {
  service.close();
}
