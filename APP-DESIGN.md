# 사무실 — Codex ↔ Claude Code 통합 macOS 앱 설계

> **⚠️ 릴레이 전제로 쓴 옛 문서다. 상호작용 설계는 [LLM-WIRING.md](LLM-WIRING.md) 로 대체됐다.**
>
> 이 문서는 두 에이전트가 서로 주고받는 **릴레이**를 전제한다.
> 확정된 모델은 릴레이가 아니라 **동시 실행(fan-out)** 이고, 인원도 2명 고정이 아니라 캐릭터 5명 전원이다.
> CLI 옵션 표와 실측 함정 목록은 여전히 유효하지만, 상호작용·세션 구조는 LLM-WIRING.md 를 따른다.

Codex 앱과 Claude Code 앱을 도트 오피스 UI 하나로 합친 macOS 전용 앱.
두 CLI를 감싸는 GUI 프런트엔드이며, 자율 실행 도구가 아니라 **사람이 지시하고 보는 도구**다.

시안: [office-app.png](office-app.png) · 렌더 스크립트: [render_app.py](render_app.py)

## 요구사항

1. Codex / Claude Code 둘 다 인증 및 사용 가능
2. 둘이 서로 대화 가능
3. 세션에 저장된 대화를 나중에 조회 가능
4. macOS 전용 앱
5. 화면 캐릭터 5명 — 여성 보스 1명과 실무자 4명. 실제 CLI·역할 연결은 추후 확정
6. 호출 시 모델·추론 레벨 선택 가능
7. 그 외 필요한 것도 전부 옵션으로 선택 가능

---

## 1. 실측으로 확인된 것

문서의 모든 플래그는 이 머신에서 실제로 실행해 확인했다. 추측한 값은 없다.

### Codex — `codex-cli 0.146.0-alpha.3.1`

```
codex exec --json --skip-git-repo-check "<prompt>" < /dev/null
```

- `--skip-git-repo-check` 없이 git 저장소 밖에서 실행하면 거부된다.
- stdin을 읽으려 대기하므로 `< /dev/null`이 필요하다.
- 이벤트 JSONL — `thread.started`(`thread_id`) → `turn.started` →
  `item.completed`(`item.type="agent_message"`, `text`) → `turn.completed`(`usage`)
- `usage` 필드 — `input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`,
  `output_tokens`, `reasoning_output_tokens`. **금액은 주지 않는다.**
- 인증 — `~/.codex/auth.json`. `codex login status` → `Logged in using ChatGPT`
- 현재 설정(`~/.codex/config.toml`) — `model = "gpt-5.6-sol"`, `model_reasoning_effort = "xhigh"`

### Claude Code — `2.1.205`

```
claude -p "<prompt>" --output-format stream-json --verbose
```

- 이벤트 JSONL — `system`(`subtype:"init"`, `session_id`, `model`, `apiKeySource`) →
  `assistant` → `result`(`total_cost_usd`, `usage`, `is_error`, `api_error_status`)
- **금액을 직접 준다**(`total_cost_usd`). Codex와 비대칭이다.
- 인증 — `~/.claude/.credentials.json`이 없다. macOS 키체인에 있다.
- 실측 — 기본 모델 `claude-fable-5`는 크레딧 소진으로 **429 `credits_required`**.
  `--model claude-sonnet-5`는 정상. 사소한 호출 하나에 `total_cost_usd = 0.206`.

### 공통

- 두 CLI 모두 **네이티브 Mach-O arm64 바이너리**다. 런타임 Node 의존이 없다.
- **GUI 최소 PATH(`/usr/bin:/bin:/usr/sbin:/sbin`)에서 둘 다 찾을 수 없다.**
  `codex`는 `~/.local/bin`, `claude`는 nvm 경로에 있다. → §3 참조
- 빌드 환경 — Swift 6.3.3 / Xcode 26.6 / `arm64-apple-macosx26.0`

---

## 2. 옵션 명세

전부 UI에서 선택 가능해야 한다. 적용 범위가 다르므로 배치도 다르다.

### 에이전트별 (상단 카드)

| 옵션 | Codex | Claude Code | 기본값 |
|---|---|---|---|
| 모델 | `-m <model>` | `--model <model>` | 각 CLI 설정 승계 |
| 추론 레벨 | `-c model_reasoning_effort="…"` | `--effort <level>` | `medium` |
| 권한 | `-s <mode>` | `--permission-mode <mode>` | 작업 폴더 쓰기 |
| 역할 프롬프트 | 프롬프트 앞에 삽입 | `--append-system-prompt` | 비어 있음 |
| 폴백 모델 | 없음 | `--fallback-model a,b` | 비어 있음 |
| 실행 파일 경로 | — | — | 자동 탐색 결과 |

**추론 레벨은 반드시 에이전트별 독립 선택기여야 한다.** 두 체계가 완전히 같지 않다.

| | 값 |
|---|---|
| Codex | `none` · `minimal` · low · medium · high · xhigh · max |
| Claude | low · medium · high · xhigh · max |

겹치는 5단계를 하나의 슬라이더로 묶고 싶은 유혹이 있지만, `none`/`minimal`이
Codex 전용이라 공유 컨트롤로 만들면 Codex의 가장 싼 두 단계를 영영 쓸 수 없게 된다.

**권한은 이름도 단계 수도 달라서 앱 공통 3단계로 추상화한다.**

| 앱 단계 | Codex `-s` | Claude `--permission-mode` |
|---|---|---|
| 읽기 전용 | `read-only` | `plan` |
| 작업 폴더 쓰기 (기본) | `workspace-write` | `auto` |
| 전체 허용 | `danger-full-access` | `bypassPermissions` |

Claude의 `acceptEdits`는 비대화형 실행에서 Bash 승인을 기다리므로 사용하지 않는다.
`manual` · `dontAsk`는 공통 3단계에 매핑하지 않는다.

### 릴레이 (하단 바)

| 옵션 | 기본값 | 이유 |
|---|---|---|
| 턴 상한 | 6 | 왕복 3회면 대개 결론이 난다. **상한 없는 릴레이는 과금 사고다.** |
| 시작자 | Codex | 임의. 바꿀 수 있으면 된다. |
| 종료 조건 | 턴 상한 도달 | "합의 시 종료" 같은 판정은 또 다른 LLM 호출이라 기본에서 뺀다. |
| 비용 상한 | 세션당 $2 | 턴 상한과 짝. 도달 시 자동 중단. |

### 전역

| 옵션 | 비고 |
|---|---|
| 작업 디렉터리 | 오피스 하나 = 폴더 하나. Codex의 git 저장소 검사 대상. |
| CLI 실행 경로 | §3 때문에 필수. 자동 탐색 + 수동 지정. |

---

## 3. 아키텍처

### 인증 — 앱이 구현하지 않는다

두 CLI가 각자 자격증명을 이미 보유한다(Codex는 `auth.json`, Claude는 키체인).
앱은 **상태를 감지해 표시하고, 없으면 로그인 명령을 안내**할 뿐이다.
OAuth도 API 키 보관도 앱의 일이 아니다. 이것이 이 설계에서 가장 큰 단순화다.

- Codex — `codex login status` 출력 파싱
- Claude — `init` 이벤트의 `apiKeySource`, 그리고 `result.api_error_status`로 판정

### CLI 실행 — PATH에 의존하면 안 된다

GUI 앱은 Finder에서 실행될 때 셸 프로파일을 읽지 않아 PATH가 최소치다.
실측 결과 그 PATH로는 두 CLI 모두 찾을 수 없다. 세 가지를 순서대로 시도한다.

1. 사용자가 설정에서 지정한 절대 경로
2. 알려진 위치 탐색 — `~/.local/bin`, `~/.nvm/versions/node/*/bin`, `/opt/homebrew/bin`, `/usr/local/bin`
3. 로그인 셸 경유 — `/bin/zsh -lc 'command -v codex'`

찾지 못하면 캐릭터를 회색 처리하고 카드에 경로 지정 버튼을 띄운다. 조용히 실패하면 안 된다.

**App Sandbox를 켜면 임의 경로의 외부 바이너리 실행이 막힌다.** 이 앱은
Mac App Store 배포가 아니라 Developer ID 서명 + 공증으로 직접 배포하고
샌드박스를 끄는 쪽이 현실적이다. 배포 경로를 먼저 정해야 한다. → §6

### 프로세스와 스트리밍

`Process` + `Pipe`로 띄우고 stdout을 줄 단위로 읽어 JSONL을 파싱한다.
줄 하나 = 이벤트 하나이므로 별도 프레이밍이 필요 없다.
stdin은 즉시 닫는다(Codex가 대기하지 않도록).

이벤트를 캐릭터 상태로 매핑한다.

| 캐릭터 상태 | Codex | Claude |
|---|---|---|
| 대기 | 프로세스 없음 | 프로세스 없음 |
| 생각중 | `turn.started` 이후 | `init` 이후 |
| 말하는중 | `item.completed`(agent_message) | `assistant` |
| 완료 | `turn.completed` | `result`(`is_error:false`) |
| 에러 | 비정상 종료 | `result`(`is_error:true`) |

**말풍선은 도착하는 대로 흘려야 한다.** 완료 후 한 번에 뿌리면 화면이 죽는다.

### 릴레이

A의 최종 메시지를 B의 프롬프트로 넣고 턴 상한까지 반복한다. 그게 전부다.

주의할 것이 하나 있다. **역할을 주지 않으면 둘이 서로 동의만 하다 끝난다.**
"너는 구현, 너는 검토" 같은 대립 구도를 역할 프롬프트로 넣어야 대화가 생산적이 된다.
이것이 릴레이 품질을 가르는 가장 큰 변수이고, 그래서 역할 프롬프트를 옵션 표 맨 위쪽에 뒀다.

중단 버튼은 프로세스를 즉시 종료하고, 그때까지의 대화는 저장한다.

### 에러

- Claude 429 `credits_required` → 폴백 모델이 지정돼 있으면 재시도, 없으면 카드를 빨간 상태로 바꾸고 릴레이 중단
- Codex는 금액을 주지 않으므로 토큰 수만 누적하고, 합계 비용은 Claude 몫만 정확하다.
  **UI에서 이 비대칭을 숨기지 말 것.** Codex는 토큰, Claude는 금액으로 따로 표기한다.

---

## 4. 세션 저장과 조회

### 앱이 대화를 직접 저장해야 하는 이유

두 CLI는 각자 세션을 이미 저장한다(`~/.claude/projects/*.jsonl`, `~/.codex/sessions/`).
그런데 **두 에이전트가 주고받은 대화는 어느 쪽에도 온전히 없다.**
Codex의 세션에는 Claude가 뭐라고 했는지가 사용자 입력으로만 남고, 반대도 마찬가지다.
대화 자체가 앱에만 존재하는 1급 객체이므로 앱이 저장해야 한다.

### 데이터 모델

필드는 실제 이벤트에서 유도했다.

```
conversation(id, title, workdir, created_at, turn_limit, cost_cap)
turn(id, conversation_id, seq, agent, prompt, started_at, ended_at)
message(id, turn_id, role, text, received_at)
usage(turn_id, input_tokens, output_tokens, cached_input_tokens,
      reasoning_output_tokens, cost_usd)          -- cost_usd 는 Claude 만 채워짐
cli_session(turn_id, agent, external_id)          -- codex thread_id / claude session_id
option_snapshot(turn_id, model, effort, permission, role_prompt)
```

`cli_session.external_id`를 보관하는 이유는 나중에 **원본 CLI 세션을 이어갈 수 있게**
하기 위해서다(`codex exec resume <id>`, `claude --resume <id>`).
이게 없으면 앱을 벗어나는 순간 맥락이 끊긴다.

`option_snapshot`은 "그때 어떤 설정으로 불렀는지"를 남긴다.
설정을 옵션으로 다 열어줄수록 이 기록이 없으면 나중에 결과를 재현할 수 없다.

### 저장소

SQLite 파일 하나. 이유는 세 가지다 — 대화 목록 정렬·검색이 쿼리 한 줄이고,
비용 집계가 `SUM()`이면 끝나고, 파일 하나라 백업과 이동이 쉽다.
JSONL로 쌓으면 조회할 때마다 전량을 읽어야 한다.

위치 — `~/Library/Application Support/<앱>/sessions.db`

### 조회 UI

좌측 책장이 보관함이다. 책등 하나 = 대화 하나이고 색으로 어느 에이전트가 주도했는지 구분한다.
클릭하면 대화가 열리고, 말풍선이 순서대로 재생된다.

필요한 기능은 목록·검색(본문 전문 검색)·비용 집계·삭제·보관이다.
그 이상은 넣지 않는다.

---

## 5. 화면

| 영역 | 내용 |
|---|---|
| 타이틀바 | 앱 이름, 작업 디렉터리 |
| 에이전트 카드 ×2 | 인증 상태 · 모델 · 추론 레벨 · 누적 비용. 클릭하면 고급 옵션(권한·역할·폴백·경로) |
| 오피스 | 여성 보스 1명, 대각선 2인조 두 쌍, 중앙 여백, 좌측 책장 |
| 하단 바 | 입력창 · 대상 선택 · 릴레이 턴 카운터 · 중단 · 합계 |

---

## 6. 결정이 필요한 것

1. **배포 방식** — Mac App Store(샌드박스 필수, 외부 CLI 실행 불가)냐
   Developer ID 직접 배포(샌드박스 해제 가능)냐. 후자가 아니면 이 앱은 성립하지 않는다.
   가장 먼저 확정해야 할 항목이다.
2. **Codex 비용 표시** — 금액을 안 주므로 토큰만 표시할지, 모델별 단가표를 앱에 넣어 추정할지.
   추정치를 실제 금액처럼 보여주면 안 된다.
3. **작업 디렉터리를 대화별로 둘지 앱 전역으로 둘지** — 전역이 단순하지만
   여러 프로젝트를 오가면 불편하다.
4. **역할 프롬프트 프리셋** — 매번 쓰기 번거로우니 몇 개 기본 제공할지.

## 7. 하지 않을 것

사용자가 명시적으로 선을 그었다 — "너무 자동화로 몰아가는 게 별로임".

- 자율 실행, 스케줄러, 나이틀리
- 자동 재시도 루프(폴백 모델 1회 재시도는 예외)
- 에이전트가 스스로 다음 할 일을 정하는 구조
- 결과를 외부(이슈 트래커 등)로 자동 전송

사람이 버튼을 누르고, 둘이 정해진 횟수만큼 말하고, 결과가 남는다. 그게 전부다.
