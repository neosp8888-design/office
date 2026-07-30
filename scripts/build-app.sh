#!/bin/zsh
# 이 스크립트는 Swift 패키지를 빌드해 실행 가능한 macOS 앱 번들로 묶는다.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$PROJECT_DIR/dist/OFFICESTRA.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$PROJECT_DIR"
swift build -c release --product OfficeLLM
BIN_DIR="$(swift build -c release --show-bin-path)"
RESOURCE_STAGE_DIR="$(mktemp -d /tmp/officellm-resources.XXXXXX)"
RESOURCE_STAGE_BUNDLE="$RESOURCE_STAGE_DIR/OfficeLLM_OfficeCore.bundle"

trap 'rm -rf "$RESOURCE_STAGE_DIR"' EXIT

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
mkdir -p "$RESOURCE_STAGE_BUNDLE"
cp "$BIN_DIR/OfficeLLM" "$MACOS_DIR/OfficeLLM"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/OFFICESTRA.icns" "$RESOURCES_DIR/OFFICESTRA.icns"

cp \
    "$PROJECT_DIR/Sources/OfficeCore/Resources/characters.json" \
    "$RESOURCE_STAGE_BUNDLE/characters.json"

mkdir -p "$RESOURCE_STAGE_BUNDLE/office-retina-v1"
/usr/bin/rsync \
    -a \
    --delete \
    "$PROJECT_DIR/Sources/OfficeCore/Resources/office-retina-v1/" \
    "$RESOURCE_STAGE_BUNDLE/office-retina-v1/"

mkdir -p "$RESOURCE_STAGE_BUNDLE/avatars"
/usr/bin/rsync \
    -a \
    --delete \
    "$PROJECT_DIR/Sources/OfficeCore/Resources/avatars/" \
    "$RESOURCE_STAGE_BUNDLE/avatars/"

/usr/bin/rsync \
    -a \
    --delete \
    "$RESOURCE_STAGE_BUNDLE/" \
    "$RESOURCES_DIR/OfficeLLM_OfficeCore.bundle/"
chmod 755 "$MACOS_DIR/OfficeLLM"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "$APP_BUNDLE"
