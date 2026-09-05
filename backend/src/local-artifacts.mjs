// 이 파일은 CLI가 만든 로컬 이미지를 찾아 Markdown 응답에 미리보기로 첨부한다.

import { createHash } from "node:crypto";
import {
  existsSync,
  readFileSync,
  readdirSync,
  statSync,
} from "node:fs";
import { homedir } from "node:os";
import {
  extname,
  isAbsolute,
  join,
  normalize,
} from "node:path";
import {
  fileURLToPath,
  pathToFileURL,
} from "node:url";

const IMAGE_EXTENSIONS = new Set([
  ".bmp",
  ".gif",
  ".heic",
  ".jpeg",
  ".jpg",
  ".png",
  ".tif",
  ".tiff",
  ".webp",
]);
const imageIdentityCache = new Map();
const IMAGE_IDENTITY_CACHE_LIMIT = 256;
// 미리보기는 선택적인 보강 정보다. 외장 디스크 권한·분리·파일 이동으로
// 읽을 수 없는 경우에도 DB 대화와 턴 기록은 정상적으로 반환해야 한다.
const UNAVAILABLE_ARTIFACT_CODES = new Set([
  "EPERM", "EACCES", "ENOENT", "ENOTDIR", "EIO", "ESTALE", "ENXIO",
]);

export function listGeneratedImages(
  sessionID,
  generatedRoot = join(homedir(), ".codex", "generated_images"),
) {
  if (!sessionID) {
    return [];
  }
  const directory = join(generatedRoot, sessionID);
  if (!existsSync(directory)) {
    return [];
  }

  let entries;
  try {
    entries = readdirSync(directory, { withFileTypes: true });
  } catch (error) {
    if (UNAVAILABLE_ARTIFACT_CODES.has(error?.code)) {
      return [];
    }
    throw error;
  }
  return entries
    .filter((entry) => entry.isFile())
    .map((entry) => join(directory, entry.name))
    .filter(isLocalImage)
    .sort();
}

export function generatedImageRoot(backend) {
  return backend === "antigravity"
    ? join(homedir(), ".gemini", "antigravity-cli", "brain")
    : join(homedir(), ".codex", "generated_images");
}

export function generatedImagesForTurn({
  sessionID,
  startedAt,
  endedAt,
  generatedRoot,
  backend = "codex",
}) {
  const start = new Date(startedAt).getTime();
  const end = endedAt ? new Date(endedAt).getTime() : Date.now();
  if (!Number.isFinite(start) || !Number.isFinite(end)) {
    return [];
  }

  return listGeneratedImages(
    sessionID,
    generatedRoot ?? generatedImageRoot(backend),
  ).filter((path) => {
    try {
      const modifiedAt = statSync(path).mtimeMs;
      return modifiedAt >= start - 2_000 && modifiedAt <= end + 2_000;
    } catch (error) {
      if (UNAVAILABLE_ARTIFACT_CODES.has(error?.code)) {
        return false;
      }
      throw error;
    }
  });
}

export function appendLocalImagePreviews(markdown, candidatePaths = []) {
  const source = String(markdown ?? "").trim();
  const destinations = markdownDestinations(source);
  const previewedPaths = destinations
    .filter((destination) => destination.isImage)
    .map((destination) => localImagePath(destination.value))
    .filter(Boolean);
  const previewed = new Set(
    previewedPaths.map(imageContentIdentity),
  );
  const includedPaths = new Set(previewedPaths);
  const linked = destinations
    .filter((destination) => !destination.isImage)
    .map((destination) => localImagePath(destination.value))
    .filter(Boolean);

  const paths = [];
  // 응답에서 명시한 프로젝트 파일을 생성 임시 원본보다 우선한다.
  // 경로가 달라도 내용이 같은 이미지는 미리보기를 한 번만 붙인다.
  for (const value of [...linked, ...candidatePaths]) {
    const path = localImagePath(String(value));
    if (!path || includedPaths.has(path)) {
      continue;
    }
    const identity = imageContentIdentity(path);
    if (previewed.has(identity)) {
      continue;
    }
    includedPaths.add(path);
    previewed.add(identity);
    paths.push(path);
    if (paths.length === 8) {
      break;
    }
  }
  if (paths.length === 0) {
    return source;
  }

  const previews = paths.map((path, index) => {
    const url = pathToFileURL(path).href;
    return `[![생성 이미지 ${index + 1}](<${url}>)](<${url}>)`;
  });
  return `${source}\n\n${previews.join("\n\n")}`;
}

function imageContentIdentity(path) {
  try {
    const stats = statSync(path);
    const cacheKey = `${path}\u001f${stats.size}\u001f${stats.mtimeMs}`;
    const cached = imageIdentityCache.get(cacheKey);
    if (cached) {
      return cached;
    }
    const identity = `${stats.size}:${createHash("sha256")
      .update(readFileSync(path))
      .digest("hex")}`;
    imageIdentityCache.set(cacheKey, identity);
    if (imageIdentityCache.size > IMAGE_IDENTITY_CACHE_LIMIT) {
      imageIdentityCache.delete(imageIdentityCache.keys().next().value);
    }
    return identity;
  } catch {
    return `path:${path}`;
  }
}

function markdownDestinations(markdown) {
  const expression =
    /(!?)\[(?!\!)[^\]\n]*\]\((?:<([^>\n]+)>|([^\s)\n]+))\)/g;
  return [...markdown.matchAll(expression)].map((match) => ({
    isImage: match[1] === "!",
    value: match[2] ?? match[3],
  }));
}

function localImagePath(value) {
  let path;
  try {
    if (value.startsWith("file:")) {
      path = fileURLToPath(value);
    } else if (isAbsolute(value)) {
      path = decodeURIComponent(value);
    } else {
      return null;
    }
  } catch {
    return null;
  }

  const normalized = normalize(path);
  return isLocalImage(normalized) ? normalized : null;
}

function isLocalImage(path) {
  if (!IMAGE_EXTENSIONS.has(extname(path).toLowerCase())) {
    return false;
  }
  try {
    return existsSync(path) && statSync(path).isFile();
  } catch {
    return false;
  }
}
