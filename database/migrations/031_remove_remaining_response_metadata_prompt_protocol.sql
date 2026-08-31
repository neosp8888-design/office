-- 030 적용 뒤 문구가 조금 달랐던 기존 직원 지침도 마커 기준으로 정리한다.

UPDATE characters
SET identity_prompt = rtrim(
  substring(
    identity_prompt
    FROM 1 FOR strpos(identity_prompt, E'\n근거를 쓴 응답') - 1
  )
)
WHERE strpos(identity_prompt, E'\n근거를 쓴 응답') > 0
  AND (
    strpos(identity_prompt, E'\n[OFFICE_SOURCES]') > 0
    OR strpos(identity_prompt, E'\n[OFFICE_WIKI_PROPOSALS]') > 0
  );
