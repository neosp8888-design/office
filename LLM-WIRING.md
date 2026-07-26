# 사무실 앱 — LLM 연결 설계

도트 사무실 화면에 Codex / Claude Code 를 물리는 설계.
이 문서의 모든 CLI 명령·플래그·값은 이 머신에서 **실제로 실행해 확인**했다. 추측한 것은 없다.

작성 2026-07-26.

---

## 1. 상호작용 모델

사용자가 캐릭터를 지목해 일을 시킨다. 릴레이(둘이 주고받기)가 아니라 **동시 실행**이다.

1. 캐릭터를 클릭해 선택한다. 여러 명 선택할 수 있다.
2. 입력바 위에 선택된 캐릭터가 칩으로 뜨고, **칩마다 모델·추론 레벨을 따로** 고른다.
3. 질문을 보내면 선택된 전원에게 동시에 나간다.
4. 각 캐릭터는 **자기만의 세션**을 계속 유지한다.

---

## 2. 검증된 CLI 인터페이스

### 실행

```
# codex 첫 턴
codex exec --json --skip-git-repo-check \
  -c model="…" -c model_reasoning_effort="…" -s <sandbox> "<프롬프트>"

# codex 이어가기
codex exec resume <thread_id> --json \
  -c model="…" -c model_reasoning_effort="…" "<프롬프트>"

# claude 첫 턴
claude -p "<프롬프트>" --output-format stream-json --verbose \
  --model … --effort … --permission-mode … \
  --append-system-prompt "<정체성>" --fallback-model <백업>

# claude 이어가기
claude -p "<프롬프트>" --resume <session_id> \
  --output-format stream-json --verbose --model … --effort …
```

`codex exec resume` 는 `-c key=value` 오버라이드를 받는다. **세션을 유지한 채 모델·추론을 턴마다 바꿀 수 있다.**

### 옵션 값

| 항목 | Codex | Claude Code |
|---|---|---|
| 모델 | `-m` / `-c model="…"` | `--model` |
| 추론 | `-c model_reasoning_effort="…"` | `--effort` |
| 추론 값 | `none` `minimal` low medium high xhigh max | low medium high xhigh max |
| 권한 | `-s` = read-only / workspace-write / danger-full-access | `--permission-mode` = acceptEdits / auto / bypassPermissions / manual / dontAsk / plan |
| 폴백 | 없음 | `--fallback-model` (콤마 목록) |

**추론 레벨은 반드시 에이전트별 독립 선택기여야 한다.** `none` 과 `minimal` 은 Codex 에만 있어서,
겹치는 5단계로 공용 컨트롤을 만들면 Codex 의 가장 싼 두 단계를 영영 못 쓴다.

권한은 이름도 단계 수도 달라 앱 공통 3단계로 추상화한다.

| 앱 단계 | Codex | Claude |
|---|---|---|
| 읽기 전용 | `read-only` | `plan` |
| 작업 폴더 쓰기 (기본) | `workspace-write` | `acceptEdits` |
| 전체 허용 | `danger-full-access` | `bypassPermissions` |

Claude 에만 있는 `auto` · `manual` · `dontAsk` 는 3단계에 억지로 끼우지 말고 고급 설정에서 원시 값으로 노출한다.

### 이벤트 정규화

두 CLI 의 JSONL 을 하나의 `AgentEvent` 로 접는다.

| AgentEvent | Codex | Claude |
|---|---|---|
| `started(sessionID)` | `thread.started` → `thread_id` | `system`/`init` → `session_id` |
| `thinking` | `turn.started` | `init` 직후 |
| `message(text)` | `item.completed` → `item.text` (`type=agent_message`) | `assistant` |
| `finished(usage)` | `turn.completed` → `usage` | `result` → `usage`, `total_cost_usd` |
| `failed(reason)` | 비정상 종료 | `result.is_error`, `api_error_status` |

---

## 3. 계층

```
OfficeRealtimeScene        상태만 받아 그린다. LLM 을 모른다.
      ↑ CharacterState
AgentDirector (actor)      선택 관리 · 동시 발송 · 비용 집계 · 중단
      ↑ AgentEvent
CLIRunner (actor) × N      Process + JSONL 파싱
      ↑
   codex / claude
```

캐릭터 상태는 넷이면 충분하다 — `idle` / `thinking` / `speaking` / `organizing`.
에러는 상태가 아니라 말풍선 내용으로 처리하는 편이 화면이 덜 복잡하다.

---

## 4. 캐릭터 = 세션의 주인

| 필드 | 언제 정해지나 |
|---|---|
| `backend` (codex / claude) | 캐릭터 생성 시 고정 |
| `sessionID` | 첫 턴 응답에서 획득 |
| `model` · `effort` · `permission` | **턴마다 변경 가능** |
| 정체성 프롬프트 | 첫 턴에 1회만 |
| 직전 `input_tokens` | 매 턴 갱신 — 압축 판단에 쓴다 |

캐릭터 5명 전부 에이전트로 둔다. 보통 둘만 쓰더라도 나머지가 놀 뿐 구조는 같다.

---

## 5. 정체성 — 두 층으로 나눈다

### 고정 정체성 (첫 턴 1회)

```
너는 이 사무실의 <이름>이다. <자리>에 앉아 있다.
동료: <나머지 캐릭터 이름 전원>.
사용자는 사장이며, 사무실 화면에서 너를 지목해 말을 건다.
```

세션이 유지되므로 **매 턴 붙이면 안 된다.** 낭비이고 프롬프트 캐시도 깨진다.

동료 명단은 **5명 전원**을 넣는다. 나중에 세 번째를 불렀을 때 서로 처음 보는 사이가 되지 않는다.

### 턴 맥락 (동시 발송일 때만)

```
[이 질문은 너와 <동료>에게 동시에 갔다.
 겹치는 답을 피하고 네 관점에서 답하라.]
```

동시 실행에는 조율 수단이 이 한 줄뿐이다. 서로 동시에 받았다는 걸 모르면 같은 답을 중복으로 낸다.

---

## 6. 동시 실행

`withTaskGroup` 으로 선택된 N명에게 병렬 발송한다. 각자 독립 프로세스, 독립 세션.
응답은 도착하는 대로 각자 말풍선에 흘린다. 서로 기다리지 않는다.

### 서로의 답은 안 보인다

각자 자기 컨텍스트만 갖는다. Codex 는 Claude 가 뭐라 했는지 모르고 반대도 같다.
공유하려면 앱이 다음 턴 프롬프트에 명시적으로 넣어야 한다.

```
[직전 질문에 <동료>는 이렇게 답했다]
…동료 답변…
```

**항상 넣으면 토큰이 두 배가 되고 컨텍스트가 두 배로 빨리 찬다.**
"서로 답 공유" 를 토글로 두고 필요할 때만 켜는 편이 낫다. → §12 미결정

---

## 7. 생각정리 (압축)

두 CLI 모두 헤드리스 모드에 압축 플래그가 없다. 앱이 직접 한다.

### 동작

1. 현재 세션에 인수인계 메모를 요청한다 (한 턴)
2. 메모를 받아 저장한다
3. 세션을 버리고 새 세션을 시작한다
4. 새 세션 첫 프롬프트 = 정체성 + 인수인계 메모

캐릭터는 그동안 `organizing` 상태로 둔다.

### 요청 문구

"요약해라" 로 하면 서사만 남고 실행 정보가 빠진다. **인수인계로 요청해야** 다음 세션이 이어서 일한다.

```
지금까지의 작업을 다음 세션으로 넘길 인수인계 메모로 정리하라.
- 무엇을 하고 있었는지
- 확정된 결정과 그 이유
- 진행 중인 것과 바로 다음에 할 일
- 사용자가 명시한 선호나 제약
사족 없이 메모만 쓸 것.
```

### 임계치 — 누적하지 않는다

두 CLI 모두 매 턴 `usage.input_tokens` 를 준다.
**직전 턴의 `input_tokens` 가 곧 현재 컨텍스트 크기다.** 따로 누적할 필요가 없다.

실측 — codex 에 `"Reply with exactly: PONG"` 한 줄만 보냈는데 `input_tokens = 22,050` 이었다.
시스템 프롬프트와 툴 정의만으로 **시작부터 22k 를 깔고 간다.** 임계치를 잡을 때 이 바닥값을 감안한다.

권장 임계치는 컨텍스트의 **60~70%**. 꽉 차서 하면 인수인계 메모 자체가 잘린다.

---

## 8. 세션 모델 — 층이 셋이다

```
앱의 대화 (보관함에 한 줄로 보이는 단위)
├─ 캐릭터 A ─ CLI 세션 #1 ─(압축)─ #2 ─(압축)─ #3
├─ 캐릭터 B ─ CLI 세션 #1 ─(압축)─ #2
└─ 캐릭터 C ─ CLI 세션 #1
```

- **CLI 세션** — 캐릭터 한 명당 하나. 5명이면 5개가 따로 돈다.
- **앱의 대화** — 여러 캐릭터의 세션을 묶은 작업 단위. 보관함에 뜨는 건 이 단위다.
- **압축 체인** — 캐릭터가 생각정리를 할 때마다 그 캐릭터의 CLI 세션이 갈아탄다.

**압축 후에도 원본 세션 ID 를 버리지 않는다.** 보관해두면 나중에
`codex exec resume` / `claude --resume` 으로 원본을 되짚을 수 있다.
메모만 남기면 압축에서 잃은 디테일을 영영 못 찾는다.

---

## 9. 데이터 모델

```
conversation(id, title, workdir, created_at)
character(id, name, seat, backend, identity_prompt)
cli_session(id, conversation_id, character_id, external_id,
            started_at, ended_at, handoff_note, prev_session_id)
turn(id, cli_session_id, seq, prompt, started_at, ended_at)
message(id, turn_id, role, text, received_at)
usage(turn_id, input_tokens, output_tokens,
      cached_input_tokens, reasoning_output_tokens, cost_usd)
turn_options(turn_id, model, effort, permission)
```

- `cli_session.external_id` — `thread_id` / `session_id`
- `cli_session.prev_session_id` — 압축 체인을 잇는다
- `turn_options` — 설정을 턴마다 바꿀 수 있으므로 그때 무엇으로 불렀는지 남겨야 재현이 된다
- `usage.cost_usd` — Claude 만 채워진다. §11 참조

저장소는 SQLite 파일 하나. `~/Library/Application Support/<앱>/sessions.db`

---

## 10. 화면

| 영역 | 내용 |
|---|---|
| 사무실 | 캐릭터 5명. 클릭으로 선택 토글, 선택 시 커서 표시 |
| 입력바 위 | 선택된 캐릭터 칩. **칩마다 모델·추론 드롭다운**, 컨텍스트 게이지, 생각정리 버튼 |
| 입력바 | 질문 입력. 아무도 선택 안 하면 전송 비활성 |
| 말풍선 | 캐릭터 머리 위. 스트리밍으로 흘린다 |

**말풍선은 도착하는 대로 흘려야 한다.** 완료 후 한 번에 뿌리면 화면이 죽는다.

---

## 11. 실측으로 확인된 함정

1. **PATH** — GUI 앱은 Finder 실행 시 셸 프로파일을 안 읽어 PATH 가 최소치다.
   그 PATH 로는 `codex`(`~/.local/bin`)도 `claude`(nvm 경로)도 **찾을 수 없다.**
   절대경로를 설정으로 두거나 `/bin/zsh -lc` 를 경유해야 한다. 놓치면 앱이 아예 동작하지 않는다.
   두 CLI 모두 네이티브 Mach-O arm64 라 런타임 Node 의존은 없다.

2. **codex stdin** — 닫지 않으면 입력 대기로 멈춘다. `< /dev/null`.

3. **codex git 검사** — 저장소 밖이면 `--skip-git-repo-check` 없이 거부한다.

4. **Claude 크레딧** — 기본 모델이 크레딧 소진이면 `429 credits_required` 로 거절된다.
   실측 당시 `claude-fable-5` 가 그랬고 `--model claude-sonnet-5` 는 정상이었다.
   `--fallback-model` 을 지정해두는 편이 안전하다.

5. **비용 비대칭** — Claude 는 `total_cost_usd` 를 주고 Codex 는 토큰만 준다.
   합쳐서 "합계 $" 로 보여주면 거짓말이 된다. Codex 는 토큰, Claude 는 금액으로 따로 표기한다.

6. **App Sandbox** — 켜면 임의 경로의 외부 바이너리 실행이 막힌다.
   Mac App Store 배포가 아니라 Developer ID 서명 + 공증으로 직접 배포하고 샌드박스를 끄는 쪽이어야 성립한다.

---

## 12. 미결정

1. **답변 공유를 자동으로 할지 토글로 둘지** — 자동이면 토큰이 두 배, 컨텍스트가 두 배로 빨리 찬다.
2. **보스 자리를 사용자 자리로 비울지** — 5명 전부 에이전트로 쓰기로 했으므로 지금은 전원 에이전트.
3. **작업 디렉터리를 대화별로 둘지 앱 전역으로 둘지** — 전역이 단순하지만 여러 프로젝트를 오가면 불편하다.
4. **모델 변경 시 캐시가 깨지는 것** — 어쩔 수 없는 것으로 정리했다. 표시만 할지 여부는 남아 있다.

---

## 13. 하지 않을 것

- 자율 실행, 스케줄러, 나이틀리
- 에이전트가 스스로 다음 할 일을 정하는 구조
- 결과를 외부로 자동 전송

사람이 캐릭터를 고르고, 질문하고, 답이 돌아온다. 그게 전부다.
