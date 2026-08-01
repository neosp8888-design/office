// 이 파일은 기존 PostgreSQL 작업 기록을 파생 RAG 문서로 다시 색인한다.

import { fileURLToPath } from "node:url";

import { pool } from "./db.mjs";
import { syncWorkRecordRAGDocuments } from "./work-record-memory.mjs";

export const INDEX_WORK_RECORDS_USAGE = [
  "사용법",
  "node src/index-work-records.mjs --apply --repository-root <절대경로>",
].join("\n");

export async function indexWorkRecords(client, { repositoryRoot } = {}) {
  const root = String(repositoryRoot ?? "").trim();
  if (!root) {
    throw new Error("색인할 저장소 절대경로가 필요합니다.");
  }
  if (!root.startsWith("/")) {
    throw new Error("색인할 저장소는 절대경로로 지정하세요.");
  }
  return syncWorkRecordRAGDocuments(client, { repositoryRoot: root });
}

export function parseIndexWorkRecordArguments(argumentsList) {
  let apply = false;
  let help = false;
  let repositoryRoot = null;
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === "--help" || argument === "-h") {
      if (help) {
        throw new Error("도움말 옵션을 중복 지정할 수 없습니다.");
      }
      help = true;
      continue;
    }
    if (argument === "--apply") {
      if (apply) {
        throw new Error("--apply 옵션을 중복 지정할 수 없습니다.");
      }
      apply = true;
      continue;
    }
    if (argument === "--repository-root") {
      if (repositoryRoot !== null) {
        throw new Error("--repository-root 옵션을 중복 지정할 수 없습니다.");
      }
      const value = argumentsList[index + 1];
      if (!value || value.startsWith("--")) {
        throw new Error("--repository-root 뒤에 절대경로를 입력하세요.");
      }
      repositoryRoot = value;
      index += 1;
      continue;
    }
    throw new Error(`알 수 없는 옵션입니다. ${argument}`);
  }
  if (help) {
    if (argumentsList.length > 1) {
      throw new Error("도움말은 다른 옵션과 함께 사용할 수 없습니다.");
    }
    return { help: true, apply: false, repositoryRoot: null };
  }
  if (!apply) {
    throw new Error("실제 색인에는 --apply 확인이 필요합니다.");
  }
  const root = String(repositoryRoot ?? "").trim();
  if (!root) {
    throw new Error("--repository-root로 색인 범위를 지정하세요.");
  }
  if (!root.startsWith("/")) {
    throw new Error("--repository-root는 절대경로여야 합니다.");
  }
  return { help: false, apply: true, repositoryRoot: root };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const options = parseIndexWorkRecordArguments(process.argv.slice(2));
    if (options.help) {
      console.log(INDEX_WORK_RECORDS_USAGE);
      process.exitCode = 0;
    } else {
      const result = await indexWorkRecords(pool, {
        repositoryRoot: options.repositoryRoot,
      });
      console.log(JSON.stringify({
        changed: result.changed,
        deleted: result.deleted,
      }));
    }
  } catch (error) {
    console.error(
      error instanceof Error ? error.message : String(error),
    );
    console.error(INDEX_WORK_RECORDS_USAGE);
    process.exitCode = 1;
  } finally {
    await pool.end();
  }
}
