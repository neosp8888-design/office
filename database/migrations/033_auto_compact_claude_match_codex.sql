-- 032 적용 뒤 앱의 저장 클램프가 Claude 기준을 다시 50%로 되돌렸다.
-- 클램프를 고쳤으므로 Codex 최대 맥락(약 27만 토큰)에 해당하는 25%로 다시 맞춘다.

UPDATE characters
SET auto_compact_percent = 25, updated_at = now()
WHERE backend = 'claude' AND auto_compact_percent = 50;
