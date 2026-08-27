import { homedir } from "node:os";
import { resolve } from "node:path";

export const LOCAL_EMBEDDING_MODEL_REPOSITORY =
  "onnx-community/bge-m3-ONNX";
export const LOCAL_EMBEDDING_MODEL_REVISION =
  "25b9af8e87a38eb120cfe87125383677b9cd309e";
export const LOCAL_EMBEDDING_MODEL_DTYPE = "q8";
export const LOCAL_EMBEDDING_DIMENSIONS = 1024;
// 업무 기록은 사용자 요청이 제목에 있고 최종 결과가 본문 끝에 있으므로
// 두 구간을 우선한다. M4 CPU에서 긴 self-attention 백필이 폭증하지 않게
// 192토큰으로 제한한다.
export const LOCAL_EMBEDDING_MAX_TOKENS = 192;
export const LOCAL_EMBEDDING_IDLE_TIMEOUT_MS = 5 * 60 * 1000;
export const LOCAL_EMBEDDING_REQUEST_TIMEOUT_MS = 3 * 60 * 1000;
export const LOCAL_EMBEDDING_MODEL_ID = [
  LOCAL_EMBEDDING_MODEL_REPOSITORY,
  LOCAL_EMBEDDING_MODEL_REVISION,
  LOCAL_EMBEDDING_MODEL_DTYPE,
].join("@");

export function localEmbeddingModelDirectory(environment = process.env) {
  const configured = String(
    environment.OFFICE_EMBEDDING_MODEL_DIR ?? "",
  ).trim();
  return configured || resolve(
    homedir(),
    ".officestra",
    "models",
    `bge-m3-onnx-${LOCAL_EMBEDDING_MODEL_REVISION.slice(0, 12)}`,
  );
}
