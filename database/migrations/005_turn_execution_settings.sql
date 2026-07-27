-- 이 파일은 각 대화 턴이 실제 실행에 사용한 CLI와 모델 및 추론 설정을 보존한다.

ALTER TABLE turns
ADD COLUMN IF NOT EXISTS backend text
    CHECK (backend IN ('codex', 'claude'));

ALTER TABLE turns
ADD COLUMN IF NOT EXISTS model text;

ALTER TABLE turns
ADD COLUMN IF NOT EXISTS effort text
    CHECK (effort IN ('high', 'xhigh', 'max'));
