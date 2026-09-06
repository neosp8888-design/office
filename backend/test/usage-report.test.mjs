// 이 파일은 화이트보드 상세 사용 현황 집계의 입력 검증과 SQL 계약을 검증한다.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  USAGE_REPORT_DAY_SPAN,
  USAGE_REPORT_MONTH_SPAN,
  UsageReportError,
  normalizeUsageReportOptions,
  readUsageReport,
  usageReportQuery,
} from "../src/usage-report.mjs";

test("백엔드·집계 단위·시간대는 허용 값만 받는다", () => {
  assert.deepEqual(
    normalizeUsageReportOptions({
      backend: "claude",
      granularity: "month",
      timeZone: " Asia/Seoul ",
    }),
    { backend: "claude", granularity: "month", timeZone: "Asia/Seoul" },
  );
  assert.deepEqual(
    normalizeUsageReportOptions({ backend: "codex" }),
    { backend: "codex", granularity: "day", timeZone: "UTC" },
  );
  for (const options of [
    { backend: "gemini" },
    { backend: null },
    { backend: "codex", granularity: "week" },
    { backend: "codex", timeZone: "Asia/Seoul; DROP TABLE turns" },
    { backend: "codex", timeZone: "" },
  ]) {
    assert.throws(
      () => normalizeUsageReportOptions(options),
      (error) => error instanceof UsageReportError && error.statusCode === 400,
    );
  }
});

test("집계 SQL은 단위별 기간 라벨과 조회 범위를 쓰고 값은 파라미터로만 넣는다", () => {
  const day = usageReportQuery("day");
  assert.match(day, /date_trunc\('day', turn\.started_at AT TIME ZONE \$2\)/);
  assert.match(day, /'YYYY-MM-DD'/);
  assert.match(day, new RegExp(`interval '${USAGE_REPORT_DAY_SPAN - 1} days'`));
  assert.match(day, /turn\.backend = \$1/);
  // 직원별 평가율이 핵심이므로 세션의 직원 ID를 함께 집계한다.
  assert.match(day, /LEFT JOIN cli_sessions AS session/);
  assert.match(day, /session\.character_id/);
  assert.match(day, /FILTER \(WHERE feedback\.feedback = 'liked'\)/);
  assert.match(day, /FILTER \(WHERE feedback\.feedback = 'disliked'\)/);

  const month = usageReportQuery("month");
  assert.match(month, /date_trunc\('month'/);
  assert.match(month, /'YYYY-MM'/);
  assert.match(
    month,
    new RegExp(`interval '${USAGE_REPORT_MONTH_SPAN - 1} months'`),
  );
});

test("응답 행은 숫자로 정규화되고 빈 모델·추론은 빈 문자열이다", async () => {
  const calls = [];
  const client = {
    async query(text, params) {
      calls.push({ text, params });
      return {
        rows: [
          {
            period: "2026-09",
            characterId: "boss",
            model: "gpt-5.6-sol",
            effort: "max",
            turns: "3",
            costUSD: "1.25",
            inputTokens: "1000",
            cachedInputTokens: "200",
            outputTokens: "50",
            liked: "2",
            disliked: "0",
          },
        ],
      };
    },
  };
  const report = await readUsageReport(client, {
    backend: "codex",
    granularity: "month",
    timeZone: "Asia/Seoul",
  });
  assert.deepEqual(calls[0].params, ["codex", "Asia/Seoul"]);
  assert.equal(report.backend, "codex");
  assert.equal(report.granularity, "month");
  assert.deepEqual(report.rows, [
    {
      period: "2026-09",
      characterId: "boss",
      model: "gpt-5.6-sol",
      effort: "max",
      turns: 3,
      costUSD: 1.25,
      inputTokens: 1000,
      cachedInputTokens: 200,
      outputTokens: 50,
      liked: 2,
      disliked: 0,
    },
  ]);
});

test("서버는 /api/usage-report GET을 집계로 연결하고 검증 오류를 상태 코드로 돌려준다", () => {
  const serverSource = readFileSync(
    new URL("../src/server.mjs", import.meta.url),
    "utf8",
  );
  assert.match(
    serverSource,
    /request\.method === "GET" &&\s*url\.pathname === "\/api\/usage-report"/,
  );
  assert.match(serverSource, /readUsageReport\(pool, \{/);
  assert.match(serverSource, /error instanceof UsageReportError/);
});
