# 사무실 CLI 에이전트 앱

SwiftUI·SpriteKit 사무실에서 캐릭터를 선택해 Codex CLI와 Claude Code CLI에
업무를 전달하는 macOS 앱이다.

## 현재 구현

- 상단 꼭짓점의 보스 단상과 보스 책상
- 좌우 벽과 평행한 실무 책상 2개씩
- 실무 책상마다 모니터 1대
- 여성 보스 1명과 실무자 4명의 선택 영역
- 캐릭터 이름과 응답을 표시하는 말풍선
- 설정 메뉴의 직원별 이름·역할 지침 변경
- 설정 메뉴와 입력바의 캐릭터별 CLI·모델·추론 선택
- V4 배치를 공유하는 모던 낮·밤 테마
- 창문, 화이트보드, 책장, 시계, 액자, 화분
- 60fps SpriteKit 장면과 캐릭터 눈·입·손 애니메이션
- 밤 창밖 불빛 점멸, 단상 간접조명 호흡, 실제 시각 초침
- 해·달 아이콘으로 낮·밤 전환
- 선택 캐릭터 이름이 표시되는 하단 명령 입력창
- Codex·Claude Code JSONL 실행과 캐릭터별 세션 유지
- PostgreSQL 대화 저장과 pgvector RAG 스키마

## 캐릭터 설정

기본 이름, 자리, 역할 지침, CLI 종류, 작업 폴더는
`Sources/OfficeCore/Resources/characters.json`에서 관리한다. 백엔드가 처음
시작될 때 PostgreSQL에 없는 직원만 기본값으로 등록한다. 이후 설정 메뉴에서
바꾼 이름과 역할 지침은 DB 값을 유지한다. 역할 지침을 바꾸면 해당 직원의
다음 업무는 새 CLI 세션으로 시작한다.

## PostgreSQL 백엔드

Docker와 Node.js가 설치된 상태에서 다음 명령을 실행한다.

```sh
./scripts/start-backend.sh
```

기본 주소는 `http://127.0.0.1:4317`이고 PostgreSQL은 로컬 포트 `54329`를
사용한다. 환경값 예시는 `backend/.env.example`에 있다.

## 캐릭터별 모델

- Codex는 `5.6 Sol`, `5.6 Terra`, `5.6 Luna`와 `high`, `xhigh`, `max`
- Claude Code는 `Opus 5`, `Fable`, `Sonnet 5`와 `high`, `xhigh`, `max`
- 기본값은 Codex `5.6 Sol + high`, Claude Code `Opus 5 + high`

CLI를 변경하면 해당 CLI의 기본 모델과 `high`가 자동으로 선택된다. 설정은
PostgreSQL에 저장되며 입력바와 전체 설정 메뉴가 같은 값을 사용한다.

## 실행

```sh
swift run OfficeGame
```

## 테스트

```sh
swift test -Xswiftc -warnings-as-errors
```

## 앱 번들 만들기

```sh
./scripts/build-app.sh
open dist/OfficeGame.app
```

현재 앱 메뉴에는 모던 낮·밤만 노출한다. CLI 호출은 앱에서 직접 수행하며
인증은 각 CLI의 기존 로그인을 사용한다. 앱은 API 키를 저장하지 않는다.
