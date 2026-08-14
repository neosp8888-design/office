// WKWebView 대화 화면을 백엔드와 같은 origin에서 제공한다.

import { access, readFile, realpath } from "node:fs/promises";
import { dirname, extname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const CONTENT_TYPES = new Map([
  [".css", "text/css; charset=utf-8"],
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".svg", "image/svg+xml"],
]);

export function conversationWebRoots({
  moduleURL = import.meta.url,
  overrideRoot = process.env.OFFICESTRA_CONVERSATION_WEB_ROOT,
} = {}) {
  const moduleDirectory = dirname(fileURLToPath(moduleURL));
  const roots = [
    overrideRoot,
    // Source checkout: backend/src -> repository root.
    resolve(
      moduleDirectory,
      "../../Sources/OfficeGame/Resources/conversation-web",
    ),
    // App bundle: Resources/OFFICESTRARuntime/backend/src -> Resources.
    resolve(moduleDirectory, "../../../conversation-web"),
  ];
  return [...new Set(roots.filter(Boolean).map((root) => resolve(root)))];
}

export function conversationWebRelativePath(pathname) {
  if (pathname === "/conversation" || pathname === "/conversation/") {
    return "index.html";
  }
  if (!pathname.startsWith("/conversation/")) {
    return null;
  }
  let relativePath;
  try {
    relativePath = decodeURIComponent(pathname.slice("/conversation/".length));
  } catch {
    return null;
  }
  if (!relativePath || relativePath.includes("\0")) {
    return null;
  }
  const normalized = relativePath.replaceAll("\\", "/");
  if (
    normalized.startsWith("/") ||
    normalized.split("/").some((component) => component === "..")
  ) {
    return null;
  }
  return normalized;
}

export async function resolveConversationWebAsset(
  pathname,
  { roots = conversationWebRoots() } = {},
) {
  const relativePath = conversationWebRelativePath(pathname);
  if (!relativePath) {
    return null;
  }
  for (const root of roots) {
    const candidate = resolve(root, relativePath);
    if (candidate !== root && !candidate.startsWith(`${root}${sep}`)) {
      continue;
    }
    try {
      await access(candidate);
      const [canonicalRoot, canonicalCandidate] = await Promise.all([
        realpath(root),
        realpath(candidate),
      ]);
      if (
        canonicalCandidate !== canonicalRoot &&
        !canonicalCandidate.startsWith(`${canonicalRoot}${sep}`)
      ) {
        continue;
      }
      return canonicalCandidate;
    } catch {
      // 개발 checkout과 앱 번들 후보를 차례로 확인한다.
    }
  }
  return null;
}

export async function serveConversationWeb(response, pathname, options = {}) {
  const assetPath = await resolveConversationWebAsset(pathname, options);
  if (!assetPath) {
    return false;
  }
  const body = await readFile(assetPath);
  response.writeHead(200, {
    "content-type": CONTENT_TYPES.get(extname(assetPath).toLowerCase())
      ?? "application/octet-stream",
    "cache-control": "no-store",
    "content-security-policy": [
      "default-src 'self'",
      "script-src 'self'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data:",
      "connect-src 'self' ws://127.0.0.1:* ws://localhost:* ws://[::1]:*",
      "font-src 'self' data:",
      "object-src 'none'",
      "base-uri 'none'",
      "frame-ancestors 'none'",
    ].join("; "),
    "x-content-type-options": "nosniff",
  });
  response.end(body);
  return true;
}
