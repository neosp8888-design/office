// 이 파일은 CLI가 만든 로컬 이미지를 찾아 Markdown 응답에 미리보기로 첨부한다.

import {
  existsSync,
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

  return readdirSync(directory, { withFileTypes: true })
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
    const modifiedAt = statSync(path).mtimeMs;
    return modifiedAt >= start - 2_000 && modifiedAt <= end + 2_000;
  });
}

export function appendLocalImagePreviews(markdown, candidatePaths = []) {
  const source = String(markdown ?? "").trim();
  const destinations = markdownDestinations(source);
  const previewed = new Set(
    destinations
      .filter((destination) => destination.isImage)
      .map((destination) => localImagePath(destination.value))
      .filter(Boolean),
  );
  const linked = destinations
    .filter((destination) => !destination.isImage)
    .map((destination) => localImagePath(destination.value))
    .filter(Boolean);

  const paths = [];
  for (const value of [...candidatePaths, ...linked]) {
    const path = localImagePath(String(value));
    if (!path || previewed.has(path)) {
      continue;
    }
    previewed.add(path);
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
