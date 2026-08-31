-- 근거·위키 JSON 계약은 직원 시스템 지침이 아니라 백엔드의 별도 결과 통로가 담당한다.

UPDATE characters
SET identity_prompt = rtrim(
  substring(
    identity_prompt
    FROM 1 FOR strpos(
      identity_prompt,
      E'\n근거를 쓴 응답 끝에는 실제 쓴 근거만 남긴다.'
    ) - 1
  )
)
WHERE strpos(
  identity_prompt,
  E'\n근거를 쓴 응답 끝에는 실제 쓴 근거만 남긴다.'
) > 0;
