// 이 파일은 공급자 직접 한도와 PostgreSQL 사용량 집계 계약을 검증한다.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  createUsageSummaryReader,
  parseClaudeRateLimits,
  parseCodexRateLimits,
  readClaudeRateLimits,
  readUsageActivity,
} from "../src/usage-summary.mjs";

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
      plan: "Pro",
    },
  );
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
  });
  assert.deepEqual(activity.claude, {
    todayCostUSD: 0,
    recentTokens: 0,
    last30DaysCostUSD: 0,
    last30DaysTokens: 0,
  });
  assert.match(query.text, /usage_records AS usage/);
  assert.match(query.text, /WHEN[\s\S]*= 'claude'/);
  assert.equal(query.values.length, 2);
});

test("한도는 짧게 캐시하고 DB 통계는 매 요청 최신값을 읽는다", async () => {
  let codexReads = 0;
  let claudeReads = 0;
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
        },
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
  assert.equal(claudeReads, 2);
  assert.equal(activityReads, 3);
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
      },
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
