// 이 파일은 공급자 직접 한도와 PostgreSQL 사용량 집계 계약을 검증한다.

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { PassThrough } from "node:stream";
import test from "node:test";

import {
  createUsageSummaryReader,
  parseAntigravityRateLimits,
  parseClaudeRateLimits,
  parseCodexRateLimits,
  readClaudeRateLimits,
  readCodexRateLimits,
  readAntigravityRateLimits,
  readUsageActivity,
} from "../src/usage-summary.mjs";

function emptyActivityFixture(costEstimateSupported = true) {
  return {
    todayCostUSD: 0,
    recentTokens: 0,
    last30DaysCostUSD: 0,
    last30DaysTokens: 0,
    costEstimateSupported,
  };
}

test("Codex app-server 한도는 창 길이로 5시간과 7일을 구분한다", () => {
  assert.deepEqual(
    parseCodexRateLimits({
      rateLimits: {
        planType: "pro",
        primary: {
          usedPercent: 24.6,
          windowDurationMins: 300,
          resetsAt: 1_800_000_000,
        },
        secondary: {
          usedPercent: 41,
          windowDurationMins: 10_080,
          resetsAt: 1_800_600_000,
        },
      },
    }),
    {
      fiveHour: {
        remaining: 75,
        resetAt: "2027-01-15T08:00:00.000Z",
      },
      weekly: {
        remaining: 59,
        resetAt: "2027-01-22T06:40:00.000Z",
      },
      plan: "Pro 20x",
    },
  );
});

test("Codex 직접 조회는 백엔드 작업 폴더와 무관한 홈에서 실행한다", async () => {
  let invocation;
  const child = new EventEmitter();
  child.stdin = new PassThrough();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.kill = () => {};
  child.stdin.setEncoding("utf8");
  child.stdin.on("data", (message) => {
    if (!message.includes('"id":2')) return;
    child.stdout.write(`${JSON.stringify({
      id: 2,
      result: {
        rateLimits: {
          planType: "pro",
          primary: {
            usedPercent: 34,
            windowDurationMins: 10_080,
            resetsAt: 1_800_000_000,
          },
        },
      },
    })}\n`);
  });
  const pool = {
    query: async () => ({
      rows: [{ path: "/opt/test/bin/codex" }],
    }),
  };

  const result = await readCodexRateLimits({
    pool,
    spawnProcess: (executable, arguments_, options) => {
      invocation = { executable, arguments_, options };
      return child;
    },
  });

  assert.equal(invocation.executable, "/opt/test/bin/codex");
  assert.deepEqual(invocation.arguments_, ["app-server", "--stdio"]);
  assert.equal(invocation.options.cwd, homedir());
  assert.equal(result.weekly.remaining, 66);
  assert.equal(result.plan, "Pro 20x");
});

test("Claude OAuth 사용률은 남은 비율로 변환한다", () => {
  assert.deepEqual(
    parseClaudeRateLimits(
      {
        five_hour: {
          utilization: 63,
          resets_at: "2026-08-12T10:00:00Z",
        },
        seven_day: {
          utilization: 11,
          resets_at: "2026-08-13T00:00:00Z",
        },
      },
      "max",
    ),
    {
      fiveHour: {
        remaining: 37,
        resetAt: "2026-08-12T10:00:00.000Z",
      },
      weekly: {
        remaining: 89,
        resetAt: "2026-08-13T00:00:00.000Z",
      },
      plan: "Max",
    },
  );
});

test("Claude의 구체 한도 등급은 Max 배수를 보존한다", () => {
  const parsed = parseClaudeRateLimits(
    {
      five_hour: null,
      seven_day: null,
    },
    "default_claude_max_5x",
  );

  assert.equal(parsed.plan, "Max 5x");
});

test("Claude 직접 조회는 기존 OAuth 토큰을 읽기 전용으로 전달한다", async () => {
  let request;
  const result = await readClaudeRateLimits({
    credentialReader: async () => ({
      accessToken: "test-token",
      plan: "max",
    }),
    fetchImplementation: async (url, options) => {
      request = { url, options };
      return {
        ok: true,
        status: 200,
        json: async () => ({
          five_hour: { utilization: 10, resets_at: null },
          seven_day: { utilization: 20, resets_at: null },
        }),
      };
    },
  });

  assert.equal(request.url, "https://api.anthropic.com/api/oauth/usage");
  assert.equal(request.options.method, "GET");
  assert.equal(request.options.headers.authorization, "Bearer test-token");
  assert.equal(request.options.headers["anthropic-beta"], "oauth-2025-04-20");
  assert.equal(result.fiveHour.remaining, 90);
  assert.equal(result.weekly.remaining, 80);
});

test("Antigravity Gemini 주간 잔량을 실제 quota bucket에서 읽는다", () => {
  assert.deepEqual(
    parseAntigravityRateLimits({
      response: {
        groups: [
          {
            displayName: "Gemini Models",
            buckets: [
              {
                bucketId: "gemini-weekly",
                window: "weekly",
                remainingFraction: 0.8529488,
                resetTime: "2026-09-03T13:44:43Z",
              },
            ],
          },
        ],
      },
    }),
    {
      fiveHour: null,
      weekly: {
        remaining: 85,
        resetAt: "2026-09-03T13:44:43.000Z",
      },
      plan: null,
    },
  );
});

test("Antigravity 한도 조회는 설정된 agy 실행 파일을 사용한다", async () => {
  let invocation;
  const result = await readAntigravityRateLimits({
    pool: {
      query: async () => ({ rows: [{ path: "/opt/test/bin/agy" }] }),
    },
    quotaProbe: async (options) => {
      invocation = options;
      return {
        response: {
          groups: [{
            displayName: "Gemini Models",
            buckets: [{
              bucketId: "gemini-weekly",
              remainingFraction: 0.42,
              resetTime: null,
            }],
          }],
        },
      };
    },
  });

  assert.equal(invocation.executable, "/opt/test/bin/agy");
  assert.equal(result.weekly.remaining, 42);
});

test("DB 통계는 공급자별 오늘과 30일 값을 숫자로 정규화한다", async () => {
  let query;
  const pool = {
    query: async (text, values) => {
      query = { text, values };
      return {
        rows: [
          {
            provider: "codex",
            todayCostUSD: "1.25",
            recentTokens: "1234",
            last30DaysCostUSD: "9.5",
            last30DaysTokens: "9876",
          },
        ],
      };
    },
  };
  const now = new Date("2026-08-12T12:00:00+09:00");

  const activity = await readUsageActivity(pool, now);

  assert.deepEqual(activity.codex, {
    todayCostUSD: 1.25,
    recentTokens: 1234,
    last30DaysCostUSD: 9.5,
    last30DaysTokens: 9876,
    costEstimateSupported: true,
  });
  assert.deepEqual(activity.claude, {
    todayCostUSD: 0,
    recentTokens: 0,
    last30DaysCostUSD: 0,
    last30DaysTokens: 0,
    costEstimateSupported: true,
  });
  assert.deepEqual(activity.antigravity, emptyActivityFixture(false));
  assert.match(query.text, /usage_records AS usage/);
  assert.match(query.text, /IN \('claude', 'antigravity'\)/);
  assert.equal(query.values.length, 2);
});

test("한도는 짧게 캐시하고 DB 통계는 매 요청 최신값을 읽는다", async () => {
  let codexReads = 0;
  let claudeReads = 0;
  let antigravityReads = 0;
  let activityReads = 0;
  const fixedNow = new Date("2026-08-12T00:00:00Z");
  const reader = createUsageSummaryReader({
    pool: {},
    codexReader: async () => {
      codexReads += 1;
      return {
        fiveHour: { remaining: 70, resetAt: null },
        weekly: { remaining: 60, resetAt: null },
        plan: "Pro",
      };
    },
    claudeReader: async () => {
      claudeReads += 1;
      return {
        fiveHour: { remaining: 50, resetAt: null },
        weekly: { remaining: 40, resetAt: null },
        plan: "Max",
      };
    },
    antigravityReader: async () => {
      antigravityReads += 1;
      return {
        fiveHour: null,
        weekly: { remaining: 85, resetAt: null },
        plan: null,
      };
    },
    activityReader: async () => {
      activityReads += 1;
      return {
        codex: {
          todayCostUSD: activityReads,
          recentTokens: 0,
          last30DaysCostUSD: 0,
          last30DaysTokens: 0,
        },
        claude: {
          todayCostUSD: 0,
          recentTokens: 0,
          last30DaysCostUSD: 0,
          last30DaysTokens: 0,
          costEstimateSupported: true,
        },
        antigravity: emptyActivityFixture(false),
      };
    },
    now: () => fixedNow,
  });

  const first = await reader();
  const second = await reader();
  const forced = await reader({ force: true });

  assert.equal(first.codexFiveHour, 70);
  assert.equal(second.codexActivity.todayCostUSD, 2);
  assert.equal(forced.codexActivity.todayCostUSD, 3);
  assert.equal(codexReads, 2);
  // Claude 한도는 토큰당 호출 간격이 좁아 force여도 캐시 수명 안에서는
  // 업스트림을 다시 부르지 않고 직전 값을 그대로 쓴다.
  assert.equal(claudeReads, 1);
  assert.equal(antigravityReads, 1);
  assert.equal(forced.claudeFiveHour, 50);
  assert.equal(forced.antigravityWeekly, 85);
  assert.equal(activityReads, 3);
});

test("Claude 한도 조회가 실패해도 직전 값을 유지하고 오류만 표시한다", async () => {
  let claudeReads = 0;
  let current = new Date("2026-08-23T00:00:00Z");
  const reader = createUsageSummaryReader({
    pool: {},
    codexReader: async () => ({
      fiveHour: { remaining: 70, resetAt: null },
      weekly: { remaining: 60, resetAt: null },
      plan: "Pro",
    }),
    claudeReader: async () => {
      claudeReads += 1;
      if (claudeReads === 1) {
        return {
          fiveHour: { remaining: 48, resetAt: null },
          weekly: { remaining: 13, resetAt: null },
          plan: "Max",
        };
      }
      throw new Error("Claude 계정 한도 조회가 실패했습니다 (HTTP 429).");
    },
    antigravityReader: async () => ({
      fiveHour: null,
      weekly: { remaining: 85, resetAt: null },
      plan: null,
    }),
    activityReader: async () => ({
      codex: emptyActivityFixture(),
      claude: emptyActivityFixture(),
      antigravity: emptyActivityFixture(false),
    }),
    now: () => current,
  });

  const healthy = await reader();
  assert.equal(healthy.claudeFiveHour, 48);
  assert.equal(healthy.claudeLimitStale, false);
  assert.equal(healthy.claudeLimitError, null);

  // 캐시 수명이 지난 뒤 429가 나도 값은 남고 오류만 붙는다.
  current = new Date("2026-08-23T00:06:00Z");
  const failed = await reader({ force: true });
  assert.equal(claudeReads, 2);
  assert.equal(failed.claudeFiveHour, 48, "직전 정상값을 유지한다");
  assert.equal(failed.claudeWeekly, 13);
  assert.equal(failed.claudeLimitStale, true);
  assert.match(failed.claudeLimitError, /429/);
  assert.equal(failed.codexFiveHour, 70, "코덱스 한도는 영향받지 않는다");
});

test("Claude 한도 조회가 실패하면 백오프 동안 다시 부르지 않는다", async () => {
  let claudeReads = 0;
  let current = new Date("2026-08-23T00:00:00Z");
  const reader = createUsageSummaryReader({
    pool: {},
    codexReader: async () => null,
    claudeReader: async () => {
      claudeReads += 1;
      throw new Error("Claude 계정 한도 조회가 실패했습니다 (HTTP 429).");
    },
    antigravityReader: async () => null,
    activityReader: async () => ({
      codex: emptyActivityFixture(),
      claude: emptyActivityFixture(),
      antigravity: emptyActivityFixture(false),
    }),
    now: () => current,
  });

  await reader();
  assert.equal(claudeReads, 1);

  // 백오프(90초) 안에서는 강제 갱신을 눌러도 업스트림을 부르지 않는다.
  current = new Date("2026-08-23T00:00:30Z");
  await reader({ force: true });
  assert.equal(claudeReads, 1);

  // 백오프가 지나면 다시 시도한다.
  current = new Date("2026-08-23T00:02:00Z");
  await reader({ force: true });
  assert.equal(claudeReads, 2);
});

test("한 공급자 실패는 다른 한도와 DB 통계를 가리지 않는다", async () => {
  const reader = createUsageSummaryReader({
    pool: {},
    codexReader: async () => {
      throw new Error("codex unavailable");
    },
    claudeReader: async () => ({
      fiveHour: { remaining: 80, resetAt: null },
      weekly: { remaining: 90, resetAt: null },
      plan: "Max",
    }),
    antigravityReader: async () => ({
      fiveHour: null,
      weekly: { remaining: 85, resetAt: null },
      plan: null,
    }),
    activityReader: async () => ({
      codex: {
        todayCostUSD: 1,
        recentTokens: 2,
        last30DaysCostUSD: 3,
        last30DaysTokens: 4,
      },
      claude: {
        todayCostUSD: 5,
        recentTokens: 6,
        last30DaysCostUSD: 7,
        last30DaysTokens: 8,
        costEstimateSupported: true,
      },
      antigravity: emptyActivityFixture(false),
    }),
    now: () => new Date("2026-08-12T00:00:00Z"),
  });

  const summary = await reader();

  assert.equal(summary.codexFiveHour, null);
  assert.equal(summary.codexLimitError, "codex unavailable");
  assert.equal(summary.claudeFiveHour, 80);
  assert.equal(summary.claudeLimitError, null);
  assert.equal(summary.codexActivity.todayCostUSD, 1);
});

test("서버는 읽기 전용 사용량 요약 GET 경로를 연결한다", () => {
  const source = readFileSync(
    new URL("../src/server.mjs", import.meta.url),
    "utf8",
  );
  assert.match(source, /url\.pathname === "\/api\/usage-summary"/);
  assert.match(source, /await usageSummary\(response, url\)/);
});
