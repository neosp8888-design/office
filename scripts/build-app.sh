#!/bin/zsh
# 이 스크립트는 Swift 패키지를 빌드해 실행 가능한 macOS 앱 번들로 묶는다.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/OFFICESTRA.app"

cd "$PROJECT_DIR"
swift build -c release --product OfficeLLM
BIN_DIR="$(swift build -c release --show-bin-path)"
CORE_RESOURCE_BUNDLE="$BIN_DIR/OfficeLLM_OfficeCore.bundle"
GAME_RESOURCE_BUNDLE="$BIN_DIR/OfficeLLM_OfficeGame.bundle"

for required_path in \
    "$BIN_DIR/OfficeLLM" \
    "$CORE_RESOURCE_BUNDLE/Info.plist" \
    "$CORE_RESOURCE_BUNDLE/characters.json" \
    "$CORE_RESOURCE_BUNDLE/office-retina-v1" \
    "$CORE_RESOURCE_BUNDLE/avatars" \
    "$CORE_RESOURCE_BUNDLE/profiles" \
    "$GAME_RESOURCE_BUNDLE/Info.plist" \
    "$GAME_RESOURCE_BUNDLE/en.lproj/Localizable.strings" \
    "$GAME_RESOURCE_BUNDLE/ko.lproj/Localizable.strings"; do
    if [[ ! -e "$required_path" ]]; then
        print -u2 "필수 빌드 결과가 없습니다. $required_path"
        exit 1
    fi
done

mkdir -p "$DIST_DIR"
STAGING_ROOT="$(mktemp -d "$DIST_DIR/.officestra-build.XXXXXX")"
STAGED_APP="$STAGING_ROOT/OFFICESTRA.app"
CONTENTS_DIR="$STAGED_APP/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cleanup() {
    if [[ -d "$STAGING_ROOT" ]]; then
        rm -rf "$STAGING_ROOT"
    fi
}

trap cleanup EXIT

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/OfficeLLM" "$MACOS_DIR/OfficeLLM"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

# SwiftUI의 고정 문구는 앱 주 번들의 Localizable.strings를 조회하므로,
# 패키지 리소스의 언어 디렉터리도 최종 앱 번들에 넣는다.
/usr/bin/rsync \
    -a \
    --delete \
    "$PROJECT_DIR/Sources/OfficeGame/Resources/" \
    "$RESOURCES_DIR/"

cp "$PROJECT_DIR/Resources/OFFICESTRA.icns" "$RESOURCES_DIR/OFFICESTRA.icns"

/usr/bin/rsync \
    -a \
    --delete \
    "$CORE_RESOURCE_BUNDLE/" \
    "$RESOURCES_DIR/OfficeLLM_OfficeCore.bundle/"

/usr/bin/rsync \
    -a \
    --delete \
    "$GAME_RESOURCE_BUNDLE/" \
    "$RESOURCES_DIR/OfficeLLM_OfficeGame.bundle/"

RUNTIME_CONFIG="$RESOURCES_DIR/OfficeLLM_OfficeCore.bundle/characters.json"
OFFICESTRA_PROJECT_DIR="$PROJECT_DIR" \
OFFICESTRA_RUNTIME_CONFIG="$RUNTIME_CONFIG" \
OFFICESTRA_CONFIGURED_WORKDIR="${OFFICESTRA_WORKDIR:-}" \
/usr/bin/env node <<'NODE'
const fs = require("node:fs");
const nodePath = require("node:path");

const configPath = process.env.OFFICESTRA_RUNTIME_CONFIG;
const configuration = JSON.parse(fs.readFileSync(configPath, "utf8"));
const configuredWorkdir = process.env.OFFICESTRA_CONFIGURED_WORKDIR?.trim();

if (configuredWorkdir) {
  configuration.workdir = configuredWorkdir;
} else if (configuration.workdir === "/Users/your-name/Projects") {
  configuration.workdir = process.env.OFFICESTRA_PROJECT_DIR;
}

if (
  !nodePath.isAbsolute(configuration.workdir) ||
  !fs.statSync(configuration.workdir).isDirectory()
) {
  throw new Error(`업무 폴더가 올바른 디렉터리가 아닙니다. ${configuration.workdir}`);
}

fs.writeFileSync(configPath, `${JSON.stringify(configuration, null, 2)}\n`);
NODE

chmod 755 "$MACOS_DIR/OfficeLLM"
codesign --force --deep --sign - "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

if [[ -e "$APP_BUNDLE" ]]; then
    /usr/bin/swift -e '
        import Darwin

        let installedApp = CommandLine.arguments[1]
        let stagedApp = CommandLine.arguments[2]
        guard renamex_np(
            installedApp,
            stagedApp,
            UInt32(RENAME_SWAP)
        ) == 0 else {
            perror("OFFICESTRA.app 원자적 교체")
            exit(1)
        }
    ' "$APP_BUNDLE" "$STAGED_APP"
else
    mv "$STAGED_APP" "$APP_BUNDLE"
fi

echo "$APP_BUNDLE"
