import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { isTrustedLoopbackOrigin } from "../src/request-origin-security.mjs";

test("동일한 127.0.0.1 Origin만 로컬 상태 변경에 허용한다", () => {
  const host = "127.0.0.1:4317";

  assert.equal(
    isTrustedLoopbackOrigin({ origin: "http://127.0.0.1:4317", host }),
    true,
  );
  assert.equal(
    isTrustedLoopbackOrigin({ origin: "http://localhost:4317", host }),
    false,
  );
  assert.equal(
    isTrustedLoopbackOrigin({ origin: "http://127.0.0.1:4318", host }),
    false,
  );
  assert.equal(
    isTrustedLoopbackOrigin({ origin: "https://outside.example", host }),
    false,
  );
  assert.equal(
    isTrustedLoopbackOrigin({ origin: "https://127.0.0.1:4317", host }),
    false,
  );
});

test("Origin 없는 네이티브와 CLI 요청은 유지하되 host 없는 웹 요청은 거절한다", () => {
  assert.equal(
    isTrustedLoopbackOrigin({ origin: undefined, host: "127.0.0.1:4317" }),
    true,
  );
  assert.equal(
    isTrustedLoopbackOrigin({ origin: "http://127.0.0.1:4317" }),
    false,
  );
  assert.equal(
    isTrustedLoopbackOrigin({ origin: "not a url", host: "127.0.0.1:4317" }),
    false,
  );
});

test("agent-jobs mutation과 WebSocket upgrade가 같은 Origin guard를 거친다", async () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const source = await readFile(join(here, "..", "src", "server.mjs"), "utf8");

  assert.match(
    source,
    /url\.pathname === "\/api\/agent-jobs"[\s\S]{0,240}!trustedJSONMutation\(request, response\)/,
  );
  assert.match(
    source,
    /server\.on\("upgrade"[\s\S]{0,260}!trustedLoopbackOrigin\(request\)/,
  );
  assert.match(
    source,
    /trustedLoopbackOrigin[\s\S]{0,260}isTrustedLoopbackOrigin/,
  );
});
