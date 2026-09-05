# Antigravity 터미널 후속 응답 가져오기 수정

## 인계받은 문제와 실제 근거

- 마지막 미완료 작업은 2026-09-05 23:22의 `6490821e-e892-405b-8f45-7caad45c97f3` 턴이다. 첨부 보관함 화면에서 Antigravity 터미널의 응답과 저장된 응답이 다르다는 문제를 조사하다가 공급자 한도에 도달했다.
- 이전 Claude 중단 비용 작업은 이미 `e36f4bc`에 커밋돼 있다. 이번 작업에서는 수정하지 않았다.
- 원본 대화 DB: `/Users/neo/.gemini/antigravity-cli/conversations/88ee3317-726c-4b2d-90bc-9b6317cfaab9.db`.
- 원본 4329단계의 “테스트 결과를 확인하고 있습니다” 뒤에도 4335·4341단계의 대기 문구, 4343단계의 2,815자 최종 답변이 있다. 질문은 4319단계 이후 추가되지 않았다.
- 기존 워처는 첫 15단계 텍스트에서 완료하고 턴 연결을 지웠다. 이후 단계는 고아 상태로 대기열에 남아 누락되거나 다음 질문에 섞일 수 있었다.
- 요약 DB에는 이 대화의 현재 행이 없었다. `not_fully_idle`이나 미검증 executor 필드로 완료를 추정하는 방식은 쓰지 않았다.

## 수정한 동작

- 사용자 단계 인덱스를 다음 질문까지 턴 경계로 유지한다. 첫 응답 이후의 추가 메시지는 동일 턴의 마지막 응답을 갱신한다. 초기 대기 문구는 작업 내역의 중간 메시지로 남긴다.
- 중단 후 도착한 이전 응답, 이전 질문의 늦게 완료된 단계, 모드 진입 전 고아 단계는 새 질문에 붙이지 않는다. 실패/중단 도구 단계(상태 6·7)는 무한 재조회하지 않는다.
- 새 질문이 이전 응답보다 먼저 도착하면 이전 턴을 중단하고 새 질문을 기록한다. 질문을 대기열에 묶어 무한 대기시키지 않는다.
- 같은 질문의 단계별 토큰을 합산한 전체 스냅샷을 저장한다. 재조회나 저장 재시도에 토큰을 중복 합산하지 않는다.
- 후속 응답이 있는 동안 별도 근거 파일을 소비하지 않는다. 기존 근거와 추가 근거를 유지한다.
- 완료 턴 갱신은 Antigravity 터미널에만 허용한다. GUI·Claude·Codex·중단 턴을 임의로 되살리는 경로는 열지 않았다.
- 기존 완료 파이프라인을 통해 메시지·활동·사용량·근거·work_records·RAG를 함께 갱신한다. 활동은 기존 event key/sequence를 읽어 중복 삽입을 막고, 작업 기록의 변경 전 본문은 수정 이벤트에 보존한다.
- “첫 응답이 나왔다”와 “백그라운드 작업이 전부 끝났다”는 구분할 공식 신호가 없다. 기존 완료 표시 정책은 유지하며, 이후 오는 응답을 잃지 않는 방식이다. CPU/마우스·영문화·모델 선택 작업은 이번 범위가 아니다.

## 검증

- 실제 SQLite의 4278~4343 단계 66개를 읽기 전용으로 추출하고, 임시 SQLite와 메모리 런타임으로 순차 재생했다. 질문 3개, 각각 마지막 응답 원문 일치 3개. 마지막 질문에는 갱신 4회, 최종 2,815자, 작업 내역 12개(중간 안내 3개)가 남았다. 운영 대화 기록은 변경하지 않았다.
- 새 fixture는 실제 단계 인덱스·상태·대기 문구 순서를 보존하고 사용자 문구/최종 내용은 익명화했다.
- 백엔드 전체: `tests 513 / pass 508 / fail 0 / skipped 5 / cancelled 0`. 기존 격리 DB 검사 4개와 새 DB 검사 1개는 기본 실행에서 건너뛴다. 로그: `/tmp/officestra-antigravity-followups-tests.log`.
- 새 PostgreSQL 통합 검사만 별도로 실행: `tests 1 / pass 1 / fail 0 / skipped 0`. 새 UUID의 테스트 기록을 단일 트랜잭션에서 생성하고 전부 ROLLBACK했다. 메시지·활동·누적 토큰·작업 기록·RAG 일치 및 동일 스냅샷 재저장의 멱등성을 확인했다. 처음에는 테스트용 근거를 내부 정규화 없이 넘겨 실패했고, 실제 생산 경로와 같은 정규화를 적용한 뒤 통과했다. 로그: `/tmp/officestra-antigravity-followups-integration.log`.
- `npm run check`, `git diff --check` 통과. Swift 소스는 바꾸지 않아 Swift 단위 테스트는 이번에 재실행하지 않았다.
- 재생 결과 로그: `/tmp/officestra-antigravity-followups-replay.log`. 빌드 로그: `/tmp/officestra-antigravity-followups-build.log`.

## 적용 상태와 한계

- 앱 번들 재빌드·서명·내장 임베딩 smoke(1024차원, norm=1) 완료. 변경한 런타임 파일 4개와 번들 파일의 바이트 일치도 확인했다. 실행 중인 4317 백엔드 PID 7853은 유지했다. 사용자가 앱 버튼으로 백엔드를 재시작해야 새 워처가 적용된다.
- 기존 잘못 저장된 과거 턴을 자동 복구하거나 수정하지 않았다. 위의 원본 일치 검증은 오프라인 재생 결과다.
- 운영 앱에서 새 워처를 통한 실시간 입력 검증은 아직 하지 않았다. 유료 공급자 호출 없이 원본 재생과 실제 PostgreSQL 트랜잭션으로 검증했다.
- 커밋·푸시는 하지 않았다.

## 수정 파일

- `backend/src/terminal-sessions.mjs`
- `backend/src/agent-runtime.mjs`
- `backend/src/structured-turn-result.mjs`
- `backend/src/work-record-memory.mjs`
- `backend/test/terminal-sessions.test.mjs`
- `backend/test/agent-runtime.test.mjs`
- `backend/test/structured-turn-result.test.mjs`
- `backend/test/work-record-memory.integration.test.mjs`
- `backend/test/fixtures/antigravity-background-replies.json`
- `work/diagnostics/replay-antigravity-followups.mjs`
- `work/reports/antigravity-terminal-followups-2026-09-05.md`
