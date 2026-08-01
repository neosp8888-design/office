# OFFICESTRA 저장소 작업 지침

- `checklist.md`와 `context-notes.md`는 v1.0 이전 작업 기록의 동결본이다. 읽을 수 있지만 새 내용을 추가하거나 수정·재생성하지 않는다.
- 비자명한 업무의 계획과 결과는 대화에 간결하게 보고한다. 완료 턴은 백엔드가 PostgreSQL `work_records`에 자동 저장한다.
- 현재 작업 기록은 읽기 전용 `GET /api/work-records`로 조회하고, 필요하면 `state`, `kind`, `q` 필터를 사용한다.
