import { createHash } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import {
  copyFile,
  mkdir,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { pipeline } from "node:stream/promises";

import {
  LOCAL_EMBEDDING_MODEL_ID,
  LOCAL_EMBEDDING_MODEL_REPOSITORY,
  LOCAL_EMBEDDING_MODEL_REVISION,
  localEmbeddingModelDirectory,
} from "./local-embedding-config.mjs";

export const LOCAL_EMBEDDING_MODEL_FILES = Object.freeze([
  {
    path: "config.json",
    size: 658,
    sha256: "70dae5884ced999af00244f776ac9eaa71538d68497d3d6a6091e0318cd32905",
  },
  {
    path: "tokenizer_config.json",
    size: 1203,
    sha256: "b87c8703482b0300d3da30e201519aa641f6a450f5eb5bf1e624afbf70c74d80",
  },
  {
    path: "tokenizer.json",
    size: 17082799,
    sha256: "249df0778f236f6ece390de0de746838ef25b9d6954b68c2ee71249e0a9d8fd4",
  },
  {
    path: "onnx/model_quantized.onnx",
    size: 568479395,
    sha256: "2237f770aad5c71bbc1fc2d361a57f9a37400574cc9eff32626f0cdb49234730",
  },
]);

const manifestFile = "OFFICESTRA-MODEL.json";

function modelFileURL(path) {
  const encodedPath = path.split("/").map(encodeURIComponent).join("/");
  return `https://huggingface.co/${LOCAL_EMBEDDING_MODEL_REPOSITORY}/resolve/${LOCAL_EMBEDDING_MODEL_REVISION}/${encodedPath}?download=true`;
}

async function fileHash(path) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) {
    hash.update(chunk);
  }
  return hash.digest("hex");
}

async function validFile(path, expected) {
  try {
    const information = await stat(path);
    if (!information.isFile() || information.size !== expected.size) {
      return false;
    }
    return (await fileHash(path)) === expected.sha256;
  } catch (error) {
    if (error?.code === "ENOENT") {
      return false;
    }
    throw error;
  }
}

async function downloadFile(file, destination, fetchImplementation) {
  const response = await fetchImplementation(modelFileURL(file.path));
  if (!response.ok || !response.body) {
    throw new Error(
      `임베딩 모델 파일을 받지 못했습니다. ${file.path} HTTP ${response.status}`,
    );
  }
  const temporary = resolve(
    tmpdir(),
    `officestra-embedding-${process.pid}-${file.path.replaceAll("/", "-")}.partial`,
  );
  try {
    await pipeline(response.body, createWriteStream(temporary, { mode: 0o600 }));
    if (!(await validFile(temporary, file))) {
      throw new Error(`임베딩 모델 파일 검증에 실패했습니다. ${file.path}`);
    }
    await mkdir(dirname(destination), { recursive: true });
    await copyFile(temporary, destination);
  } finally {
    await rm(temporary, { force: true });
  }
}

async function validManifest(directory) {
  try {
    const parsed = JSON.parse(
      await readFile(resolve(directory, manifestFile), "utf8"),
    );
    return parsed.modelID === LOCAL_EMBEDDING_MODEL_ID &&
      parsed.sourceRepository === LOCAL_EMBEDDING_MODEL_REPOSITORY &&
      parsed.revision === LOCAL_EMBEDDING_MODEL_REVISION &&
      parsed.license === "MIT" &&
      LOCAL_EMBEDDING_MODEL_FILES.every((file) =>
        parsed.files?.[file.path]?.sha256 === file.sha256 &&
        parsed.files?.[file.path]?.size === file.size
      );
  } catch (error) {
    if (error?.code === "ENOENT" || error instanceof SyntaxError) {
      return false;
    }
    throw error;
  }
}

export async function ensureLocalEmbeddingModel({
  environment = process.env,
  fetchImplementation = fetch,
} = {}) {
  const directory = localEmbeddingModelDirectory(environment);
  await mkdir(directory, { recursive: true });
  if (await validManifest(directory)) {
    const filesValid = await Promise.all(
      LOCAL_EMBEDDING_MODEL_FILES.map((file) =>
        validFile(resolve(directory, file.path), file)
      ),
    );
    if (filesValid.every(Boolean)) {
      return { directory, downloaded: [], modelID: LOCAL_EMBEDDING_MODEL_ID };
    }
  }

  const downloaded = [];
  for (const file of LOCAL_EMBEDDING_MODEL_FILES) {
    const destination = resolve(directory, file.path);
    if (await validFile(destination, file)) {
      continue;
    }
    if (environment.OFFICE_EMBEDDING_ALLOW_MODEL_DOWNLOAD === "0") {
      throw new Error(`로컬 임베딩 모델 파일이 없습니다. ${file.path}`);
    }
    await downloadFile(file, destination, fetchImplementation);
    downloaded.push(file.path);
  }
  const files = Object.fromEntries(
    LOCAL_EMBEDDING_MODEL_FILES.map((file) => [
      file.path,
      { size: file.size, sha256: file.sha256 },
    ]),
  );
  await writeFile(
    resolve(directory, manifestFile),
    `${JSON.stringify({
      modelID: LOCAL_EMBEDDING_MODEL_ID,
      sourceRepository: LOCAL_EMBEDDING_MODEL_REPOSITORY,
      revision: LOCAL_EMBEDDING_MODEL_REVISION,
      format: "ONNX Q8",
      license: "MIT",
      files,
    }, null, 2)}\n`,
    { mode: 0o600 },
  );
  return { directory, downloaded, modelID: LOCAL_EMBEDDING_MODEL_ID };
}
