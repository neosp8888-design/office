-- 모델 카탈로그 저장소에 Claude Code 제공자를 추가한다.

ALTER TABLE agent_model_catalogs
DROP CONSTRAINT IF EXISTS agent_model_catalogs_provider_check;

ALTER TABLE agent_model_catalogs
ADD CONSTRAINT agent_model_catalogs_provider_check
CHECK (provider IN ('codex', 'antigravity', 'claude'));
