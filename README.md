# OFFICESTRA

**한국어** | [English](README.en.md)

> Claude Code, Codex, Antigravity를 한 사무실에서 움직이세요.

**한 모델을 고르는 앱이 아닙니다. 서로 다른 AI 세션을 한 팀처럼 운영하는 앱입니다.**

OFFICESTRA는 Claude Code, Codex, Antigravity 같은 AI 코딩 에이전트를 직원처럼
배치하는 로컬 우선 멀티 AI 오케스트레이션 macOS 앱입니다. 각 직원은 자신만의
프로바이더, 모델, 역할과 대화 세션을 유지합니다. 사용자는 여러 터미널과 대화창을
오가는 대신 한 화면에서 일을 나누고, 진행 상황을 보고, 다음 직원을 이어서 투입할 수
있습니다.

<p align="center">
  <img src="docs/images/officestra-social-preview.png" alt="Claude Code, Codex, Antigravity를 한곳에서 운영하는 OFFICESTRA" width="100%">
</p>

<p align="center">
  <strong>세 개의 AI 프로바이더 · 다섯 개의 독립 세션 · 하나의 로컬 제어실</strong>
</p>

## 여러 AI를 쓰는 일이 왜 더 복잡해야 할까요?

Claude Code의 대화는 Claude Code에, Codex의 작업은 Codex에, Antigravity의 세션은
Antigravity에 남아 있습니다. OFFICESTRA는 이 세션들을 억지로 하나로 합치지 않습니다.
각 AI의 흐름은 그대로 살리고, 운영 화면만 하나로 모읍니다.

## 가장 강력한 기능

### 다섯 명의 AI, 다섯 개의 독립 세션

직원마다 Claude Code, Codex, Antigravity 중 하나를 선택하고 서로 다른 역할과 모델을
줄 수 있습니다. 각 대화는 섞이지 않으며, 나중에 돌아와도 자신의 세션에서 계속됩니다.

### 동시에 맡기고 한눈에 지켜보기

여러 직원에게 서로 다른 일을 맡기고 동시에 진행할 수 있습니다. 누가 생각 중인지,
어떤 명령과 도구를 쓰는지, 무엇을 바꿨고 어떤 답을 냈는지 한 화면에서 확인합니다.

### 결과를 다음 AI에게 이어주기

한 직원이 조사하고, 다른 직원이 검토하고, 또 다른 직원이 마무리하도록 업무를 나눌 수
있습니다. 각자의 대화는 독립적으로 유지하면서도 하나의 작업 흐름으로 운영할 수 있습니다.

### GUI와 실제 터미널을 오가기

필요할 때는 직원의 현재 세션을 실제 CLI 터미널로 열어 직접 대화할 수 있습니다. 다시
GUI로 돌아오면 터미널에서 진행한 내용도 같은 직원의 기록으로 이어집니다.

### 대화, 작업 기록, 한도를 한곳에

완료된 업무와 대화는 로컬에 쌓입니다. 직원별 기록을 다시 찾고, 각 CLI의 남은 한도와
컨텍스트 상태를 보며 다음에 어떤 AI를 투입할지 판단할 수 있습니다.

## GUI와 실제 터미널, 두 가지 작업 방식

<table>
  <tr>
    <td width="50%" align="center">
      <img src="docs/images/officestra-gui-mode.jpg" alt="OFFICESTRA GUI 모드" width="100%"><br>
      <strong>GUI 모드</strong><br>
      <sub>대화·작업 기록·직원 전환을 한 화면에서</sub>
    </td>
    <td width="50%" align="center">
      <img src="docs/images/officestra-terminal-mode.jpg" alt="OFFICESTRA 터미널 모드에서 실행 중인 Claude Code CLI" width="100%"><br>
      <strong>터미널 모드</strong><br>
      <sub>같은 직원의 실제 Claude Code CLI 세션을 그대로</sub>
    </td>
  </tr>
</table>

대화형 GUI와 실제 CLI 터미널을 오가고, 직원별 진행 상태·사용 한도·대화 기록을 같은
화면에서 관리합니다. 화면 스타일을 바꿔도 각 AI의 세션과 작업 흐름은 그대로 유지됩니다.

## 이런 분을 위한 앱입니다

- Claude Code, Codex, Antigravity를 함께 쓰지만 창과 세션 관리에 지친 사람
- 하나의 거대한 대화보다 역할별로 분리된 AI 세션을 선호하는 사람
- 복잡한 시스템을 직접 만들지 않고 멀티 AI 오케스트레이션을 경험하고 싶은 사람
- 여러 AI가 실제로 무엇을 하고 있는지 한눈에 보고 싶은 사람

## 지원하는 CLI

- OpenAI Codex CLI
- Anthropic Claude Code
- Google Antigravity CLI

사용 가능한 모델과 추론 단계, 한도 정보는 각 계정과 설치된 CLI 버전에 따라 달라집니다.

## 시작하기

### 가장 쉬운 방법: AI에게 맡기기

이미 사용 중인 Codex, Claude Code 또는 Antigravity에 아래 문장을 그대로 보내세요.

> “`https://github.com/neosp8888-design/office.git`을 이 Mac에 내려받고 OFFICESTRA를
> 실행해줘. 기존 AI CLI 로그인과 프로젝트는 건드리지 말고, 먼저 환경을 확인한 뒤 빠진
> 의존성만 설치해. 앱과 로컬 백엔드가 정상 실행되는 것까지 확인해줘.”

OFFICESTRA는 아직 최신 DMG를 제공하지 않습니다. 현재는 저장소를 내려받아 실행하는
방식이 기준입니다.

<details>
<summary><strong>직접 설치하기 — 숙련자용</strong></summary>

### 1. 준비할 것

- Apple silicon Mac과 macOS 14 이상
- Git과 Swift 5.10 이상을 포함한 Xcode Command Line Tools
- Node.js 20 이상과 npm
- Docker Desktop
- Codex, Claude Code, Antigravity 중 로그인된 CLI 하나 이상

Apple 개발 도구를 설치합니다.

```sh
xcode-select --install
```

[Homebrew](https://brew.sh/)가 준비돼 있다면 Node.js와 Docker Desktop을 설치하고
Docker를 실행합니다.

```sh
brew install node
brew install --cask docker
open -a Docker
```

### 2. 사용할 AI CLI 설치와 로그인

세 가지를 모두 설치할 필요는 없습니다. 사용할 CLI만 설치하고, 처음 실행할 때 각
서비스 계정으로 로그인하세요. 아래 명령 묶음 중 필요한 것만 실행합니다.

**OpenAI Codex CLI** — [공식 안내](https://developers.openai.com/codex/cli/)

```sh
curl -fsSL https://chatgpt.com/codex/install.sh | sh
codex
```

**Anthropic Claude Code** — [공식 안내](https://code.claude.com/docs/en/getting-started)

```sh
curl -fsSL https://claude.ai/install.sh | bash
claude
```

**Google Antigravity CLI** — [공식 안내](https://codelabs.developers.google.com/antigravity-cli-hands-on)

```sh
curl -fsSL https://antigravity.google/cli/install.sh | bash
agy
```

Docker 설치에 문제가 있으면 [Docker Desktop 공식 안내](https://docs.docker.com/desktop/setup/install/mac-install/)를
확인하세요.

### 3. 저장소 내려받기

```sh
git clone https://github.com/neosp8888-design/office.git "$HOME/OFFICESTRA"
cd "$HOME/OFFICESTRA"
```

같은 위치에 기존 설치가 있다면 덮어쓰거나 지우지 말고 먼저 상태를 확인하세요.

### 4. 백엔드와 앱 실행

첫 번째 터미널에서 로컬 데이터베이스와 백엔드를 시작합니다.

```sh
cd "$HOME/OFFICESTRA"
./scripts/start-backend.sh
```

첫 실행은 Docker 이미지와 패키지를 받아 시간이 걸릴 수 있습니다. 준비가 끝나면 두 번째
터미널에서 앱을 실행합니다.

```sh
cd "$HOME/OFFICESTRA"
swift run OfficeLLM
```

앱이 열리면 첫 실행 도우미에서 작업 폴더를 선택하고, 로그인해 둔 CLI를 직원에게
배정하면 됩니다.

</details>

> [!WARNING]
> OFFICESTRA는 아직 프리뷰입니다. 중요한 작업은 백업과 함께 진행하세요. 대화와 작업
> 기록을 외부에 공유하기 전에는 민감한 정보가 없는지 확인하세요.

[License](LICENSE)
