-- 이 파일은 완료 턴의 캐시 생성 토큰을 비용 추정 근거로 함께 저장한다.

ALTER TABLE usage_records
ADD COLUMN IF NOT EXISTS cache_write_input_tokens bigint,
ADD COLUMN IF NOT EXISTS cache_write_5m_input_tokens bigint,
ADD COLUMN IF NOT EXISTS cache_write_1h_input_tokens bigint;
