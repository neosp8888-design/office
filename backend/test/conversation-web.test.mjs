import assert from "node:assert/strict";
import { mkdtemp, realpath, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  conversationWebRelativePath,
  resolveConversationWebAsset,
  serveConversationWeb,
} from "../src/conversation-web.mjs";

test("conversation web 경로는 index와 정적 파일만 허용한다", () => {
  assert.equal(conversationWebRelativePath("/conversation"), "index.html");
  assert.equal(conversationWebRelativePath("/conversation/"), "index.html");
  assert.equal(conversationWebRelativePath("/conversation/app.js"), "app.js");
  assert.equal(conversationWebRelativePath("/conversation/../secret"), null);
  assert.equal(conversationWebRelativePath("/conversation/%2e%2e/secret"), null);
  assert.equal(conversationWebRelativePath("/api/live-feed"), null);
});

test("conversation web 자산은 지정 root 밖으로 벗어나지 않는다", async () => {
  const root = await mkdtemp(join(tmpdir(), "officestra-conversation-web-"));
  const outside = await mkdtemp(join(tmpdir(), "officestra-outside-"));
  const indexPath = join(root, "index.html");
  await writeFile(indexPath, "<!doctype html><title>OFFICESTRA</title>");
  await writeFile(join(outside, "secret.js"), "secret");
  await symlink(join(outside, "secret.js"), join(root, "linked.js"));
  assert.equal(
    await resolveConversationWebAsset("/conversation", { roots: [root] }),
    await realpath(indexPath),
  );
  assert.equal(
    await resolveConversationWebAsset("/conversation/missing.js", {
      roots: [root],
    }),
    null,
  );
  assert.equal(
    await resolveConversationWebAsset("/conversation/linked.js", {
      roots: [root],
    }),
    null,
  );
});

test("conversation web 응답은 same-origin CSP와 no-store를 사용한다", async () => {
  const root = await mkdtemp(join(tmpdir(), "officestra-conversation-web-"));
  await writeFile(join(root, "index.html"), "<!doctype html>");
  let status;
  let headers;
  let body;
  const response = {
    writeHead(value, fields) {
      status = value;
      headers = fields;
    },
    end(value) {
      body = value;
    },
  };
  assert.equal(
    await serveConversationWeb(response, "/conversation/", { roots: [root] }),
    true,
  );
  assert.equal(status, 200);
  assert.equal(headers["content-type"], "text/html; charset=utf-8");
  assert.equal(headers["cache-control"], "no-store");
  assert.match(
    headers["content-security-policy"],
    /connect-src 'self' ws:\/\/127\.0\.0\.1:\*/,
  );
  assert.doesNotMatch(headers["content-security-policy"], /img-src[^;]*file:/);
  assert.match(String(body), /doctype html/);
});
