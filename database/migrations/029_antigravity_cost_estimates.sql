-- 기존 Antigravity 턴에도 직접 API 기준의 환산 추정 비용을 채운다.
-- agy는 캐시 미스 입력과 캐시 읽기를 분리하고 output_tokens에 추론을 포함한다.

UPDATE usage_records AS usage
SET cost_usd = ROUND(
    (
        COALESCE(usage.input_tokens, 0) *
        CASE
            WHEN turn_record.model IN ('gemini-3.7-flash', 'gemini-3.6-flash')
                AND turn_record.started_at < TIMESTAMPTZ '2027-01-01 00:00:00+00'
                THEN 0.75
            WHEN turn_record.model IN ('gemini-3.7-flash', 'gemini-3.6-flash', 'gemini-3.5-flash')
                THEN 1.50
            WHEN turn_record.model IN ('gemini-3.1-pro', 'gemini-3.1-pro-preview')
                AND COALESCE(usage.input_tokens, 0)
                    + COALESCE(usage.cached_input_tokens, 0) > 200000
                THEN 4.00
            WHEN turn_record.model IN ('gemini-3.1-pro', 'gemini-3.1-pro-preview')
                THEN 2.00
        END
        + COALESCE(usage.cached_input_tokens, 0) *
        CASE
            WHEN turn_record.model IN ('gemini-3.7-flash', 'gemini-3.6-flash')
                AND turn_record.started_at < TIMESTAMPTZ '2027-01-01 00:00:00+00'
                THEN 0.075
            WHEN turn_record.model IN ('gemini-3.7-flash', 'gemini-3.6-flash', 'gemini-3.5-flash')
                THEN 0.15
            WHEN turn_record.model IN ('gemini-3.1-pro', 'gemini-3.1-pro-preview')
                AND COALESCE(usage.input_tokens, 0)
                    + COALESCE(usage.cached_input_tokens, 0) > 200000
                THEN 0.40
            WHEN turn_record.model IN ('gemini-3.1-pro', 'gemini-3.1-pro-preview')
                THEN 0.20
        END
        + COALESCE(usage.output_tokens, 0) *
        CASE
            WHEN turn_record.model IN ('gemini-3.7-flash', 'gemini-3.6-flash')
                AND turn_record.started_at < TIMESTAMPTZ '2027-01-01 00:00:00+00'
                THEN 3.75
            WHEN turn_record.model IN ('gemini-3.7-flash', 'gemini-3.6-flash')
                THEN 7.50
            WHEN turn_record.model = 'gemini-3.5-flash'
                THEN 9.00
            WHEN turn_record.model IN ('gemini-3.1-pro', 'gemini-3.1-pro-preview')
                AND COALESCE(usage.input_tokens, 0)
                    + COALESCE(usage.cached_input_tokens, 0) > 200000
                THEN 18.00
            WHEN turn_record.model IN ('gemini-3.1-pro', 'gemini-3.1-pro-preview')
                THEN 12.00
        END
    ) / 1000000.0,
    8
)
FROM turns AS turn_record
WHERE usage.turn_id = turn_record.id
  AND turn_record.backend = 'antigravity'
  AND turn_record.model IN (
      'gemini-3.7-flash',
      'gemini-3.6-flash',
      'gemini-3.5-flash',
      'gemini-3.1-pro',
      'gemini-3.1-pro-preview'
  )
  AND usage.cost_usd IS NULL;
