// 이 파일은 화이트보드 상세용 백엔드별 일·월 사용 현황(모델·추론·평가)을 집계한다.

export const USAGE_REPORT_BACKENDS = ["codex", "claude", "antigravity"];
export const USAGE_REPORT_GRANULARITIES = ["day", "month"];

export class UsageReportError extends Error {
  constructor(message, statusCode = 400) {
    super(message);
    this.name = "UsageReportError";
    this.statusCode = statusCode;
  }
}

/// 일별은 최근 30일, 월별은 최근 12개월을 본다.
export const USAGE_REPORT_DAY_SPAN = 30;
export const USAGE_REPORT_MONTH_SPAN = 12;

const TIME_ZONE_PATTERN = /^[A-Za-z0-9_+\-/]{1,64}$/;

export function normalizeUsageReportOptions({
  backend,
  granularity = "day",
  timeZone = "UTC",
} = {}) {
  if (!USAGE_REPORT_BACKENDS.includes(backend)) {
    throw new UsageReportError(`알 수 없는 백엔드입니다. ${backend}`);
  }
  if (!USAGE_REPORT_GRANULARITIES.includes(granularity)) {
    throw new UsageReportError(`알 수 없는 집계 단위입니다. ${granularity}`);
  }
  const zone = String(timeZone ?? "").trim();
  if (!TIME_ZONE_PATTERN.test(zone)) {
    throw new UsageReportError(`올바르지 않은 시간대입니다. ${timeZone}`);
  }
  return { backend, granularity, timeZone: zone };
}

/// 기간 라벨은 시간대를 적용한 뒤 자른다. 일별은 YYYY-MM-DD, 월별은 YYYY-MM.
export function usageReportQuery(granularity) {
  const periodFormat = granularity === "day" ? "YYYY-MM-DD" : "YYYY-MM";
  const span = granularity === "day"
    ? `${USAGE_REPORT_DAY_SPAN - 1} days`
    : `${USAGE_REPORT_MONTH_SPAN - 1} months`;
  return `
    WITH local_turn AS (
      SELECT
        turn.id,
        session.character_id,
        turn.model,
        turn.effort,
        date_trunc('${granularity}', turn.started_at AT TIME ZONE $2) AS bucket
      FROM turns AS turn
      LEFT JOIN cli_sessions AS session ON session.id = turn.cli_session_id
      WHERE turn.backend = $1
        AND turn.started_at IS NOT NULL
        AND turn.started_at AT TIME ZONE $2
          >= date_trunc('${granularity}', now() AT TIME ZONE $2)
            - interval '${span}'
    )
    SELECT
      to_char(local_turn.bucket, '${periodFormat}') AS period,
      COALESCE(local_turn.character_id, '') AS "characterId",
      COALESCE(local_turn.model, '') AS model,
      COALESCE(local_turn.effort, '') AS effort,
      COUNT(*)::int AS turns,
      COALESCE(SUM(usage.cost_usd), 0)::float8 AS "costUSD",
      COALESCE(SUM(usage.input_tokens), 0)::bigint AS "inputTokens",
      COALESCE(SUM(usage.cached_input_tokens), 0)::bigint AS "cachedInputTokens",
      COALESCE(SUM(usage.output_tokens), 0)::bigint AS "outputTokens",
      COUNT(*) FILTER (WHERE feedback.feedback = 'liked')::int AS liked,
      COUNT(*) FILTER (WHERE feedback.feedback = 'disliked')::int AS disliked
    FROM local_turn
    LEFT JOIN usage_records AS usage ON usage.turn_id = local_turn.id
    LEFT JOIN turn_response_feedback AS feedback
      ON feedback.turn_id = local_turn.id
    GROUP BY 1, 2, 3, 4
    ORDER BY 1, 2, 3, 4
  `;
}

export async function readUsageReport(client, options) {
  const { backend, granularity, timeZone } = normalizeUsageReportOptions(
    options,
  );
  const result = await client.query(usageReportQuery(granularity), [
    backend,
    timeZone,
  ]);
  return {
    backend,
    granularity,
    timeZone,
    generatedAt: new Date().toISOString(),
    rows: result.rows.map((row) => ({
      period: row.period,
      characterId: row.characterId,
      model: row.model,
      effort: row.effort,
      turns: Number(row.turns),
      costUSD: Number(row.costUSD),
      inputTokens: Number(row.inputTokens),
      cachedInputTokens: Number(row.cachedInputTokens),
      outputTokens: Number(row.outputTokens),
      liked: Number(row.liked),
      disliked: Number(row.disliked),
    })),
  };
}
