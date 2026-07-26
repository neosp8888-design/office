-- 이 파일은 Claude 비대화형 세션의 기본 권한을 승인 대기가 없는 자동 모드로 전환한다.

UPDATE characters
SET
    permission = 'auto',
    updated_at = now()
WHERE backend = 'claude'
  AND permission = 'acceptEdits';
