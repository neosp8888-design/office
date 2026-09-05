// 실제 대화 DB는 읽기 전용. 복사한 단계만 임시 SQLite와 메모리 런타임에 재생한다.
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { mkdtempSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TerminalSessionManager, parseAntigravityTerminalStep } from "../../backend/src/terminal-sessions.mjs";

const conversationID = "88ee3317-726c-4b2d-90bc-9b6317cfaab9";
const source = new DatabaseSync(`/Users/neo/.gemini/antigravity-cli/conversations/${conversationID}.db`, { readOnly: true });
const rows = source.prepare("SELECT idx, step_type, status, metadata, step_payload FROM steps WHERE idx BETWEEN 4278 AND 4343 ORDER BY idx").all();
source.close();
const root = mkdtempSync(join(tmpdir(), "officestra-agy-replay-"));
mkdirSync(join(root, "conversations"));
const database = new DatabaseSync(join(root, "conversations", `${conversationID}.db`));
database.exec("CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER, metadata BLOB, step_payload BLOB)");
const turns = new Map();
const calls = [];
const runtime = {
  async prepareTerminalLaunch(characterID) {
    return { character: { id: characterID, backend: "antigravity", model: "gemini-3.8-flash", effort: "high", permission: "dangerously-skip-permissions", identityPrompt: "" },
      externalSessionID: conversationID, sessionID: "replay", conversationID, workdir: root };
  },
  async beginTerminalTurn({ prompt }) { const turnID = `replay-${turns.size + 1}`; turns.set(turnID, { prompt }); return { turnID }; },
  async completeTerminalTurn(entry) { turns.set(entry.turnID, { ...turns.get(entry.turnID), ...entry }); calls.push(entry); },
  async interruptTerminalTurn() { throw new Error("Unexpected interruption"); },
};
const manager = new TerminalSessionManager({ runtime, broadcast() {}, antigravityRoot: root, antigravityPollIntervalMs: 60_000 });
try {
  await manager.open("replay");
  const watcher = manager.sessions.get("replay").watcher;
  await watcher.sweepPromise;
  clearInterval(watcher.pollTimer);
  for (const subscription of watcher.watchers) subscription.close();
  watcher.watchers = [];
  const boundaries = [4294, 4318, 4329, 4335, 4341, 4343];
  let lastIndex = 4277;
  for (const end of boundaries) {
    for (const row of rows.filter((entry) => entry.idx > lastIndex && entry.idx <= end)) {
      database.prepare("INSERT INTO steps VALUES (?, ?, ?, ?, ?)").run(row.idx, row.step_type, row.status, row.metadata, row.step_payload);
    }
    await watcher.sweep();
    lastIndex = end;
  }
  assert.equal(turns.size, 3);
  for (const [offset, end] of [4294, 4318, 4343].entries()) {
    const actual = turns.get(`replay-${offset + 1}`);
    const expected = parseAntigravityTerminalStep(rows.find((row) => row.idx === end));
    assert.equal(actual.response, expected.text);
  }
  const last = turns.get("replay-3");
  assert.equal(calls.filter((entry) => entry.turnID === "replay-3").length, 4);
  assert.equal(watcher.pendingIndexes.size, 0);
  console.log(JSON.stringify({ sourceRows: rows.length, turns: turns.size, finalMatches: 3,
    lastResponseCharacters: last.response.length, lastTurnActivities: last.activities.length,
    lastTurnMessageActivities: last.activities.filter((entry) => entry.kind === "message").length,
    usage: last.usage, productionWrites: 0 }, null, 2));
} finally {
  await manager.close("replay");
  database.close();
}
