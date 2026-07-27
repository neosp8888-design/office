# OFFICESTRA

OFFICESTRA는 다섯 명의 가상 직원을 선택해 로컬 Codex CLI와 Claude Code
CLI에 업무를 맡기고, 진행 상황·응답·대화 기록·사용량을 한 화면에서
확인하는 macOS 앱이다.

SwiftUI와 SpriteKit으로 만든 오피스 화면은 단순한 장식이 아니라 실제
에이전트 선택과 업무 상태를 보여주는 인터페이스다. Node.js 백엔드는 CLI
프로세스와 세션을 관리하고, 모든 업무 기록은 로컬 PostgreSQL에 저장한다.

## 화면 구성

| 영역 | 역할 |
| --- | --- |
| 왼쪽 위 | 다섯 직원을 선택하고 상태를 확인하는 실시간 오피스 |
| 왼쪽 아래 | 전체 대화 보관함과 Codex·Claude 사용량 보드 |
| 오른쪽 전체 | 모든 직원의 요청·진행 단계·응답을 섞어 보여주는 실시간 업무실 |
| 화면 아래 | 직원·CLI·모델·추론 단계를 선택하고 파일과 함께 업무를 전달하는 입력창 |

오피스는 상단의 여성 보스 1명과 좌우 두 명씩의 실무자 4명으로 구성된다.
모던 낮·밤 테마, 실제 시각과 동기화된 시계, 눈·입·손 애니메이션과 야간
조명 효과를 제공한다.

## 주요 기능

### 직원과 CLI

- 직원별 이름과 역할 지침 설정
- Codex 또는 Claude Code 선택
- 직원별 모델·추론 단계·파일 접근 권한 설정
- 설정 메뉴와 입력창에서 같은 실행 설정 사용
- 직원별 외부 CLI 세션을 PostgreSQL에 저장하고 앱 재실행 뒤 복구
- 역할·CLI·모델·추론·권한이 바뀌면 기존 세션을 종료하고 새 세션 시작
- 사용자 판단이 필요한 질문을 표시하고 같은 세션으로 답변 재개
- 비정상 종료는 `업무 중단`, 모델 한도 소진은 `퇴근` 상태로 구분

현재 선택할 수 있는 모델은 다음과 같다.

| CLI | 모델 | 추론 단계 |
| --- | --- | --- |
| Codex | 5.6 Sol, 5.6 Terra, 5.6 Luna | high, xhigh, max |
| Claude Code | Opus 5, Fable, Sonnet 5 | high, xhigh, max |

권한은 `읽기 전용`, `작업 폴더 쓰기`, `전체 허용`의 공통 3단계로 표시하고
각 CLI가 이해하는 실제 권한 값으로 변환한다.

### 실시간 업무

- 백엔드가 Codex·Claude Code CLI 프로세스를 실행하고 중단
- PostgreSQL에 업무와 공개 진행 이벤트를 먼저 저장한 뒤 WebSocket으로 전달
- 앱 재실행 시 REST 스냅샷을 읽고 진행 중 업무에 다시 연결
- 실행 중 응답의 타자 효과와 완료 시 자동 최신 위치 이동
- 과거 기록을 읽는 동안 자동 스크롤을 멈추고 창 크기 변경 뒤 읽던 위치 복원
- GitHub Flavored Markdown 표·코드·목록·제목·링크 렌더링
- 응답 원문 복사와 로컬 생성 이미지 미리보기
- 업무당 최대 20개 파일 첨부와 실행 중 업무 중단
- 업무 중인 캐릭터의 짧은 상태 말풍선 순환

### 기록과 사용량

- 직원명·업무·응답·세션 ID·모델·추론 단계를 한 번에 검색
- 대화별 외부 세션 ID와 실행 당시 CLI·모델·추론 정보 보존
- 업무와 응답 원문을 함께 보는 상세 화면과 복사 기능
- 보관함을 최근 12건부터 필요한 만큼 추가 로딩
- Codex·Claude의 5시간·7일 잔여량과 요금제 표시
- CodexBar가 제공하는 오늘·최근 30일 비용과 토큰 통계 표시
- pgvector 벡터 검색과 PostgreSQL 전문 검색을 위한 RAG 저장·검색 API

## 동작 구조

```mermaid
flowchart LR
    A["OFFICESTRA macOS 앱"] <-->|"REST · WebSocket"| B["Node.js 백엔드"]
    B --> C["Codex CLI"]
    B --> D["Claude Code CLI"]
    B <-->|"세션 · 업무 · 진행 · 응답"| E["PostgreSQL<br/>pgvector · pgcrypto"]
    B --> F["로컬 첨부 파일"]
```

앱은 CLI 프로세스를 직접 실행하지 않는다. 백엔드가 실행을 소유하며, 앱은
업무를 요청하고 저장된 상태와 실시간 이벤트를 표시한다. 백엔드가 계속
실행 중이면 앱을 다시 열어도 진행 중 업무와 기존 세션을 이어서 볼 수 있다.

## 요구 사항

- macOS 14 이상
- Swift 5.10 이상
- Docker와 Docker Compose
- Node.js와 npm
- 사용할 Codex CLI 또는 Claude Code CLI의 설치 및 로그인
- 선택 사항으로 사용량 통계를 표시할 CodexBar CLI

OFFICESTRA는 API 키를 직접 저장하지 않는다. Codex와 Claude Code는 각 CLI의
기존 로컬 로그인을 사용한다.

## 빠른 시작

먼저
`Sources/OfficeCore/Resources/characters.json`의 최상위 `workdir`를
에이전트가 실제로 작업할 절대경로로 변경한다.

```json
{
  "workdir": "/absolute/path/to/workspace"
}
```

터미널 1에서 PostgreSQL과 백엔드를 실행한다.

```sh
./scripts/start-backend.sh
```

이 스크립트는 pgvector PostgreSQL 컨테이너를 시작하고, 필요한 경우 Node
패키지를 설치한 뒤 마이그레이션과 백엔드를 실행한다. 앱을 사용하는 동안
이 터미널을 계속 열어둔다.

터미널 2에서 앱을 실행한다.

```sh
swift run OfficeLLM
```

사용자에게 보이는 이름은 `OFFICESTRA`지만 기존 호환성을 위해 SwiftPM 제품과
내부 실행 파일 이름은 `OfficeLLM`을 유지한다.

## 백엔드 설정

기본 백엔드 주소는 `http://127.0.0.1:4317`이고 PostgreSQL은 로컬 포트
`54329`를 사용한다. 기본 데이터베이스는 Docker 볼륨
`office-postgres-data`에 보존된다.

환경값을 바꿀 때는 현재 셸에서 지정한 뒤 백엔드를 시작한다.

```sh
DATABASE_URL="postgres://office:office-local@127.0.0.1:54329/office" \
OFFICE_BACKEND_PORT=4317 \
CHARACTER_CONFIG_PATH="Sources/OfficeCore/Resources/characters.json" \
./scripts/start-backend.sh
```

`backend/.env.example`은 변수 목록 참고용이다. 현재 시작 스크립트는
`backend/.env` 파일을 자동으로 불러오지 않는다. 백엔드 포트를 변경하면
`characters.json`의 `databaseBaseURL`도 같은 주소로 맞춰야 한다.

## 데이터와 RAG

PostgreSQL에는 캐릭터 설정, 대화, CLI 세션, 업무 상태, 공개 진행 이벤트와
응답이 저장된다. 초기 스키마에는 토큰과 비용 정보를 기록할 필드도 준비되어
있다. 파일 첨부 원본은 작업 폴더의 `.office-attachments`에 보관되며 Git에서
제외된다.

초기 스키마는 `pgcrypto`와 `vector` 확장을 활성화하고 다음 두 검색 방식을
준비한다.

- `vector(1536)`과 HNSW 코사인 검색
- `tsvector`와 GIN 인덱스를 이용한 전문 검색

`POST /api/rag/documents`로 문서와 선택적인 임베딩을 저장하고
`POST /api/rag/search`로 벡터 또는 텍스트 검색을 수행할 수 있다. 임베딩 생성과
검색 결과의 자동 프롬프트 주입은 아직 별도 오케스트레이션 단계가 필요하다.

## 테스트

```sh
npm --prefix backend run check
npm --prefix backend test
swift test -Xswiftc -warnings-as-errors
```

## 앱 번들 만들기

```sh
./scripts/build-app.sh
open dist/OFFICESTRA.app
```

생성되는 앱 번들은 로컬 실행용 ad-hoc 서명을 사용한다. 번들로 실행할 때도
백엔드는 별도 터미널에서 실행 중이어야 한다.

## 프로젝트 구조

```text
Sources/OfficeCore/       공통 설정·모델·오피스 리소스
Sources/OfficeGame/       SwiftUI·SpriteKit 앱과 실시간 업무 UI
backend/                  REST·WebSocket 서버와 CLI 실행 런타임
database/migrations/      PostgreSQL·pgvector 스키마
infra/                    로컬 PostgreSQL Docker Compose 설정
scripts/                  백엔드 시작과 macOS 앱 번들 빌드
Tests/                    Swift 단위 테스트
backend/test/             Node.js 백엔드 단위 테스트
```
