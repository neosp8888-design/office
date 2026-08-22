# Stellar Blade 메시 모딩 환경

설치 루트: `G:\StellarBladeModding`

## 실행

- `Launch-FModel.cmd`: 게임 메시·텍스처 탐색 및 `.uemodel` 추출
- `Launch-Blender-4.4.cmd`: Stellar Blade 전용 Blender 4.4.3
- `Open-Workspace.cmd`: 작업 폴더 열기

시스템의 Blender 5.1은 변경하지 않았습니다. FBX 뼈 반전 수정 플러그인이 Blender 4.4용이므로 G 드라이브의 포터블 4.4.3만 모딩에 사용합니다.

## FModel 최초 설정

- Archive Directory: `H:\SteamLibrary\steamapps\common\StellarBlade`
- UE Version: `GAME_UE_4_26`
- Local Mapping: 켜기
- Mapping 우선 시도: `G:\StellarBladeModding\Mappings\StellarBlade_1.4.1.usmap`
- 호환 문제가 있으면 공식 가이드본: `G:\StellarBladeModding\Mappings\StellarBlade_1.1.0.usmap`
- Output Directory: `G:\StellarBladeModding\Workspace\FModel-Output`
- Mesh Format: `.uemodel`
- Texture Format: `TGA`
- Import Sockets: 끄기

## Blender 설정

- UEFormat general scale: `1`
- UEFormat Import Sockets: 끄기
- Scene Unit Scale: `0.01`
- FBX 내보내기: `Inverted Bones Fix` 켜기
- FBX 내보내기: `Add Leaf Bones` 끄기

설치된 애드온:

- UEFormat Blender v10
- PSK/PSA 7.1.0
- Stellar Blade FBX Exporter Fixes

## Unreal Engine

Epic Games Launcher에서 Unreal Engine `4.26`을 다음 위치에 설치해야 합니다.

`G:\StellarBladeModding\UnrealEngine\UE_4.26`

새 Blank Games 프로젝트는 아래 위치를 사용합니다.

`G:\StellarBladeModding\Workspace\UnrealProjects`

프로젝트 설정에서는 Generate Chunks, Use IoStore, Cook Everything을 켜고 SteamVR·OculusVR을 끕니다.

## 안전 규칙

- 기존 게임 파일과 `~mods`의 78개 파일은 이번 설치에서 수정하지 않습니다.
- 첫 테스트 전 `~mods`를 별도 백업하고, 새 모드는 하나씩만 추가합니다.
- 기존 모드 목록은 `Backups\existing-mods-manifest.csv`에 기록됩니다.
