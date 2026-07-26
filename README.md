# 사무실 실시간 2D 도트 프로토타입

SwiftUI 명령 UI와 SpriteKit 실시간 오피스를 결합한 macOS 프로토타입이다.

## 현재 구현

- 상단 꼭짓점의 보스 단상과 보스 책상
- 좌우 벽과 평행한 실무 책상 2개씩
- 실무 책상마다 모니터 1대
- 사람 없이 비워 둔 의자와 중앙 작업 공간
- V4 배치를 공유하는 모던 낮·밤, 우드 낮·밤 테마
- 창문, 화이트보드, 책장, 시계, 액자, 화분
- 도트 배율을 유지하는 비보간 이미지 표시
- 60fps SpriteKit 장면과 향후 캐릭터용 실시간 레이어
- 밤 창밖 불빛 점멸, 단상 간접조명 호흡, 실제 시각 초침
- 오른쪽 위 테마 선택기와 선택값 저장
- 하단 명령 입력창

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

현재 앱 배경은 `Sources/OfficeCore/Resources/office-theme-*-v4.png` 네 장이다. 배경 위의 실시간 요소는 `Sources/OfficeGame/OfficeRealtimeScene.swift`에서 갱신한다. 모니터와 화분은 정적인 배경 요소로 유지한다. 이전 도트 시안과 제외한 화분 애니메이션 실험은 `artifacts/2d-archive`에 보관한다. Blender 원본과 USDZ는 `blender`, `Models`, `artifacts/3d-archive`에 보관하지만 앱 번들에는 포함하지 않는다.
