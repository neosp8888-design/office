// 이 파일은 설치 도우미가 찾은 CLI 실행 경로를 운영 직원 설정에 안전하게 동기화한다.

import {
  accessSync,
  constants,
  statSync,
} from "node:fs";
import { basename, isAbsolute } from "node:path";

import { withCharacterSessionLocks } from "./character-settings.mjs";

const supportedProviders = ["codex", "claude"];

export class RuntimeCLIPathsValidationError extends Error {}

function objectValue(value) {
  return value && typeof value === "object" && !Array.isArray(value);
}

export function normalizeRuntimeCLIPaths(body) {
  if (!objectValue(body)) {
    throw new RuntimeCLIPathsValidationError(
      "CLI 경로 요청은 JSON 객체여야 합니다.",
    );
  }
  const unknownBodyKeys = Object.keys(body).filter(
    (key) => key !== "executables",
  );
  if (unknownBodyKeys.length > 0) {
    throw new RuntimeCLIPathsValidationError(
      `지원하지 않는 요청 항목입니다: ${unknownBodyKeys.join(", ")}`,
    );
  }
  if (!objectValue(body.executables)) {
    throw new RuntimeCLIPathsValidationError(
      "executables 객체를 입력하세요.",
    );
  }
  const unknownProviders = Object.keys(body.executables).filter(
    (provider) => !supportedProviders.includes(provider),
  );
  if (unknownProviders.length > 0) {
    throw new RuntimeCLIPathsValidationError(
      `지원하지 않는 CLI입니다: ${unknownProviders.join(", ")}`,
    );
  }

  const executables = {};
  for (const provider of supportedProviders) {
    if (!Object.hasOwn(body.executables, provider)) {
      continue;
    }
    if (typeof body.executables[provider] !== "string") {
      throw new RuntimeCLIPathsValidationError(
        `${provider} 실행 경로는 문자열이어야 합니다.`,
      );
    }
    const executablePath = body.executables[provider].trim();
    if (!executablePath || !isAbsolute(executablePath)) {
      throw new RuntimeCLIPathsValidationError(
        `${provider} 실행 경로는 절대경로여야 합니다.`,
      );
    }
    if (basename(executablePath) !== provider) {
      throw new RuntimeCLIPathsValidationError(
        `${provider} 실행 파일 이름이 올바르지 않습니다.`,
      );
    }
    try {
      if (!statSync(executablePath).isFile()) {
        throw new Error("not a regular file");
      }
      accessSync(executablePath, constants.X_OK);
    } catch {
      throw new RuntimeCLIPathsValidationError(
        `${provider} 실행 경로가 실행 가능한 일반 파일이 아닙니다.`,
      );
    }
    executables[provider] = executablePath;
  }
  return executables;
}

export async function synchronizeRuntimeCLIPaths({ pool, body }) {
  const executables = normalizeRuntimeCLIPaths(body);
  const requestedProviders = supportedProviders.filter((provider) =>
    Object.hasOwn(executables, provider)
  );
  if (requestedProviders.length === 0) {
    return { ok: true, updatedCharacterIds: [] };
  }

  const characterResult = await pool.query(
    "SELECT id FROM characters ORDER BY id",
  );
  const characterIDs = (characterResult.rows ?? []).map((row) => row.id);
  return await withCharacterSessionLocks(
    pool,
    characterIDs,
    async (client) => {
      let transactionStarted = false;
      let committed = false;
      try {
        await client.query("BEGIN");
        transactionStarted = true;
        const updatedCharacterIDs = [];
        for (const provider of requestedProviders) {
          const result = await client.query(
            `
              UPDATE characters
              SET
                config = jsonb_set(
                  COALESCE(config, '{}'::jsonb),
                  '{executablePath}',
                  to_jsonb($2::text),
                  true
                ),
                updated_at = now()
              WHERE backend = $1
                AND config ->> 'executablePath' IS DISTINCT FROM $2
              RETURNING id
            `,
            [provider, executables[provider]],
          );
          updatedCharacterIDs.push(
            ...(result.rows ?? []).map((row) => row.id),
          );
        }
        await client.query("COMMIT");
        committed = true;
        return {
          ok: true,
          updatedCharacterIds: [...new Set(updatedCharacterIDs)].sort(),
        };
      } catch (error) {
        if (transactionStarted && !committed) {
          try {
            await client.query("ROLLBACK");
          } catch {
            // 원래 검증·업데이트 오류를 호출자에게 유지한다.
          }
        }
        throw error;
      }
    },
  );
}

