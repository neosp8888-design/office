# 컨텍스트 노트

## 확인된 요구

- macOS 전용 앱
- 실제 실행 도구는 Codex와 Claude Code
- 두 에이전트의 대화와 세션 조회
- 모델, 추론 수준, 권한 등 호출 옵션 선택
- 사람이 지시하고 지켜보는 도구
- 기능보다 디자인 완성도가 우선

## 현재 디자인 결정

- 현재 앱 화면은 `exec-fa8167ee-12a6-45d9-8b63-7d00f8cbb91e`에서 생성된 3D V4 정적 배경
- 좌우 실무 책상은 두 개의 깊이와 앞·뒷선이 일치하는 2인용 연속 배치
- 여성 보스 1명과 남녀 실무자 4명은 배경 이미지에 포함
- 상단 꼭짓점에 보스 단상과 책상 배치
- 왼쪽 벽과 오른쪽 벽에 평행한 책상 2개씩 배치
- 실무 책상마다 모니터 1대
- 중앙 바닥은 이동과 상태 연출을 위해 비움
- 하단 명령 입력창은 SwiftUI로 유지
- 모든 새 배경은 넓은 책상, 보이는 키보드, 뒤쪽 의자 배치의 V4를 기준으로 고정
- 테마는 모던 낮, 모던 밤, 우드 낮, 우드 밤의 네 종류
- 배경은 정적 PNG로 유지하고 창문, 단상 조명, 시계만 코드 오버레이로 애니메이션
- 모니터는 원근상 코드와 커서를 읽을 수 없으므로 배경의 정적인 주변광만 사용
- 화분은 별도 애니메이션 없이 배경에 고정
- 여성 보스는 비대칭 다크 브라운 단발, 네이비 재킷, 아이보리 블라우스, 틸 포인트를 사용
- 여성 보스 하의는 차콜 팬츠 대신 무릎길이 차콜 스커트로 확정
- 여성 보스는 좌우로 틀지 않고 책상 중앙축에 맞추되 V4의 위에서 내려다보는 시점을 적용
- 여성 보스의 6프레임은 업무 3장과 대화 3장으로 명확히 분리
- 업무 상태는 양손 타이핑과 눈 깜빡임, 대화 상태는 한 손 제스처와 눈 깜빡임으로 표현
- 업무 중에는 고개와 시선을 모니터 쪽으로 숙이고 대화 중에는 고개를 들어 사용자를 바라봄
- 도트 배경과 도트 눈 깜빡임 오버레이는 현재 앱에서 사용하지 않음
- 3D V4 배경은 1536×1024 원본을 선형 보간으로 표시
- 3D 인물 애니메이션은 전체 이미지를 다시 생성하지 않고 눈·입·손의 작은 영역만 원본 위에 교체
- 다섯 인물의 눈 깜빡임·말하기·타이핑은 서로 독립적인 간격으로 랜덤 조합
- 낮·밤은 각 재질 원본의 색온도·명암·야간 조명만 변경하고, 모던과 우드는 별도 재질 원본을 사용
- 모던 테마는 우드의 단순 탈채도가 아니라 이전 픽셀 모던을 재질 참고로 삼은 별도 3D 원본
- 모던은 회색 포세린 타일, 무광 흰색 책상, 차콜 금속 프레임, 흰색·회색 보스 단상을 사용
- 현재 사용자 메뉴에는 모던 낮·밤만 표시하고 우드 낮·밤 리소스는 향후 확장을 위해 보존
- 왼쪽 남성과 오른쪽 여성의 타이핑은 키보드를 마스크에서 제외하고 손가락 변화량을 절반 이하로 제한
- 모던 조명은 천장 펜던트가 아니라 왼쪽 화이트보드 위와 오른쪽 시계 위의 가로형 벽부착 조명 두 개로 확정
- 벽부착 조명은 낮 렌더에서 꺼져 있고 밤 렌더에서 주 조명으로 켜짐
- 모던 밤은 낮 이미지의 단순 채도 조절이 아니라 창밖 야경, 모니터 주변광, 단상 간접조명을 포함한 별도 3D 원본
- 모니터 주변광, 창밖 불빛, 보스 단상 조명은 야간에만 SpriteKit 오버레이로 매우 약하게 변화
- 현재 빌드에 필요하지 않은 구형 자산과 실험 파일은 `/Users/neo/office-unused-archive-20260726`에 삭제 없이 보관
- 활성 프로젝트에는 앱 소스, 테스트, 네 테마, 60개 모션과 현재 3D 모션 재생성 원본만 유지
- 벽시계는 배경 PNG의 프레임과 바깥 눈금을 그대로 사용하고 정적 바늘 영역만 작은 시계판 오버레이로 가림
- 모던 낮·밤에서는 시스템 현지 시각에 맞춰 시침·분침·초침을 매초 갱신
- 실시간 아날로그 시계 오버레이는 우드 테마에는 적용하지 않음
- 이미지 구조 비교 결과 모던 낮 원본이 모던 밤보다 수직으로 7px 아래여서 낮의 배경·인물 모션·시계를 함께 7px 위로 보정
- 모던 낮의 아날로그 시계 바늘 오버레이는 공통 아트워크 보정량을 상쇄하도록 로컬 y를 7px 낮춰 밤과 같은 화면 좌표에 배치
- 오른쪽 여성 직원의 재킷은 모던 낮·밤에서 의자보다 밝고 붉은 기가 도는 플럼 퍼플로 확정
- 오른쪽 여성 직원의 말하기·타이핑 원본도 플럼 퍼플 전용 소스를 사용해 동작 중 파란 재킷이 노출되지 않게 함
- 오른쪽 여성의 눈 깜빡임은 다른 인물과 분리된 퍼플 전용 소스를 사용해 얼굴·어깨의 파란색 노출을 차단

## 아직 확정하지 않은 것

- 다섯 캐릭터의 최종 도트 외형과 애니메이션 프레임
- 캐릭터와 Codex·Claude Code 세션 또는 역할의 연결 방식
- 긴 대화를 읽는 패널과 상태 말풍선의 위치
- 앱 배포 방식과 Codex 비용 표시 정책

## 구현 결정

- 네이티브 UI는 SwiftUI
- 배경은 1536×1024 PNG
- 확대와 축소 시 픽셀 보간을 사용하지 않음
- Blender 원본과 USDZ는 보관하지만 앱 리소스에는 포함하지 않음
- 앱 번들은 ad-hoc 코드 서명으로 로컬 실행 가능
- V4 PNG는 정적 배경으로 유지하고 오피스 장면은 SpriteKit 게임 루프로 전환
- SpriteKit 렌더링은 60fps로 유지하고 향후 도트 캐릭터 프레임은 8~12fps로 재생
- 창밖 불빛과 단상 조명, 초침은 SKScene에서 실시간 갱신
- 앱이 비활성화되면 장면을 일시정지
- 여성 보스는 책상 아래를 마스킹하고 모니터를 전경으로 다시 덮어 보스 의자에 착석
- 여성 보스의 기본 상태는 손가락 타이핑과 간헐적인 눈 깜빡임으로 구성
- 명령 전송 시 여성 보스는 3.2초 동안 대화 동작을 재생한 뒤 업무 동작으로 복귀

## 기준 파일

- 기능 요구사항은 `APP-DESIGN.md`
- 기존 기능 시안은 `office-app.png`
- 도트 스타일 기준은 `reference-office-game.png`
- 현재 앱 배경은 `Sources/OfficeCore/Resources/office-background-3d-v4.png`
- 여성 보스 디자인은 `artifacts/character-concepts/boss-female-concept-v3-horizontal-desk.png`
- 여성 보스 원본 시트는 `artifacts/character-sprites/boss-female-sheet-v5-perspective-mouths-alpha.png`
- 실제 앱 실행 화면은 `artifacts/office-app-pixel-v1.png`
- 최종 SpriteKit 실시간 화면은 `artifacts/office-realtime-final-b.jpg`
- 현재 3D 배경 원본은 `artifacts/office-3d-v4-layout-concept-v3.png`
- 앱 리소스는 `Sources/OfficeCore/Resources/office-background-3d-v4.png`
- 인물 포함 도트 배경 원본은 `artifacts/office-pixel-v5-with-characters.png`
- 인물 포함 도트 앱 리소스는 `Sources/OfficeCore/Resources/office-background-pixel-v5.png`
- 고밀도 실제 도트 원본은 `Sources/OfficeCore/Resources/office-true-pixel-v2.png`
- 눈 깜빡임 스프라이트는 `Sources/OfficeCore/Resources/office-true-pixel-blink-v2`
- 눈 깜빡임 확대 검수본은 `artifacts/office-true-pixel-blink-v2-contact-sheet.png`
- 3D 인물 동작 패치는 `Sources/OfficeCore/Resources/office-3d-motion-v1`
- 3D 동작 검수본은 `artifacts/office-3d-motion-v1-contact-sheet.png`
- 3D 네 테마 검수본은 `artifacts/office-3d-themes-v1-contact-sheet.png`
- 모던 3D 원본은 `artifacts/office-3d-modern-v1.png`
- 벽부착 조명 모던 낮 원본은 `artifacts/office-3d-modern-v2-wall-lights.png`
- 벽부착 조명 모던 밤 원본은 `artifacts/office-3d-modern-night-v2-wall-lights.png`
- 모던 동작 검수본은 `artifacts/office-3d-modern-motion-v1-contact-sheet.png`
