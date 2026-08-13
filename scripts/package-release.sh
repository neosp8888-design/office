#!/bin/zsh
# 이 스크립트는 이미 빌드된 앱을 ZIP과 DMG 배포 산출물로 묶는다.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/OFFICESTRA.app"
RELEASE_DIR="$DIST_DIR/release"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/OfficeLLM"
STAGING_ROOT=""

cleanup() {
    if [[ -n "$STAGING_ROOT" && -d "$STAGING_ROOT" ]]; then
        rm -rf "$STAGING_ROOT"
    fi
}

trap cleanup EXIT

for required_path in "$APP_BUNDLE" "$INFO_PLIST" "$APP_EXECUTABLE"; do
    if [[ ! -e "$required_path" ]]; then
        print -u2 "필수 앱 산출물이 없습니다. $required_path"
        exit 1
    fi
done

print "입력 앱의 코드 서명을 검증합니다."
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
SIGNATURE_DETAILS="$(
    /usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1
)"

print "이 스크립트는 앱 자체를 새로 서명하거나 공증하지 않습니다. 공증된 앱의 최종 DMG만 별도로 서명·공증합니다."
RELEASE_FLAVOR="unnotarized"
if print -r -- "$SIGNATURE_DETAILS" | /usr/bin/grep -q '^Signature=adhoc$'; then
    RELEASE_FLAVOR="adhoc"
    print -u2 "경고: 입력 앱은 ad-hoc 서명이며 Apple 공증을 받지 않았습니다. 공개할 때는 Community Preview와 macOS의 앱별 '그래도 열기' 절차를 명시해야 합니다."
elif print -r -- "$SIGNATURE_DETAILS" \
    | /usr/bin/grep -q '^Authority=Developer ID Application:'; then
    SPCTL_OUTPUT=""
    if SPCTL_OUTPUT="$(
        /usr/sbin/spctl \
            --assess \
            --type execute \
            --verbose=4 \
            "$APP_BUNDLE" 2>&1
    )" && print -r -- "$SPCTL_OUTPUT" \
        | /usr/bin/grep -q 'source=Notarized Developer ID'; then
        RELEASE_FLAVOR="notarized"
        print "Developer ID 서명과 Apple 공증 승인을 확인했습니다."
    else
        RELEASE_FLAVOR="developer-id-unnotarized"
        print -u2 "경고: Developer ID 서명은 있지만 Apple 공증 승인을 확인하지 못했습니다."
        if [[ -n "$SPCTL_OUTPUT" ]]; then
            print -u2 -- "$SPCTL_OUTPUT"
        fi
    fi
else
    print -u2 "경고: Developer ID Application 서명을 확인하지 못했습니다. 공증된 정식 배포본으로 표시하지 않습니다."
fi

VERSION="$(
    /usr/libexec/PlistBuddy \
        -c 'Print :CFBundleShortVersionString' \
        "$INFO_PLIST"
)"
BUILD_NUMBER="$(
    /usr/libexec/PlistBuddy \
        -c 'Print :CFBundleVersion' \
        "$INFO_PLIST"
)"
SAFE_VERSION="${VERSION//[^A-Za-z0-9._-]/-}"
SAFE_BUILD_NUMBER="${BUILD_NUMBER//[^A-Za-z0-9._-]/-}"

ARCHITECTURES="$(/usr/bin/lipo -archs "$APP_EXECUTABLE")"
if [[ "$ARCHITECTURES" != "arm64" ]]; then
    print -u2 \
        "OFFICESTRA v1.3.2부터 Apple Silicon arm64 앱만 패키징합니다. 현재: ${ARCHITECTURES:-알 수 없음}"
    exit 1
fi
ARCH_LABEL="arm64"

ARTIFACT_BASENAME="OFFICESTRA-${SAFE_VERSION}-${SAFE_BUILD_NUMBER}-macOS-${ARCH_LABEL}-${RELEASE_FLAVOR}"
ZIP_NAME="$ARTIFACT_BASENAME.zip"
DMG_NAME="$ARTIFACT_BASENAME.dmg"
ZIP_PATH="$RELEASE_DIR/$ZIP_NAME"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
CHECKSUM_PATH="$RELEASE_DIR/SHA256SUMS"

mkdir -p "$RELEASE_DIR"
STAGING_ROOT="$(mktemp -d "$RELEASE_DIR/.officestra-release.XXXXXX")"
ZIP_TEMP="$STAGING_ROOT/$ZIP_NAME"
DMG_TEMP="$STAGING_ROOT/$DMG_NAME"

print "ZIP 산출물을 만듭니다."
/usr/bin/ditto \
    -c \
    -k \
    --sequesterRsrc \
    --keepParent \
    "$APP_BUNDLE" \
    "$ZIP_TEMP"

ZIP_VERIFY_ROOT="$STAGING_ROOT/zip-verify"
mkdir -p "$ZIP_VERIFY_ROOT"
/usr/bin/ditto -x -k "$ZIP_TEMP" "$ZIP_VERIFY_ROOT"
/usr/bin/codesign \
    --verify \
    --deep \
    --strict \
    --verbose=2 \
    "$ZIP_VERIFY_ROOT/OFFICESTRA.app"

DMG_ROOT="$STAGING_ROOT/OFFICESTRA"
mkdir -p "$DMG_ROOT"
/usr/bin/ditto "$APP_BUNDLE" "$DMG_ROOT/OFFICESTRA.app"
/bin/ln -s /Applications "$DMG_ROOT/Applications"

# 복사 과정에서 중첩 실행 파일이나 봉인된 리소스가 달라지지 않았는지 확인한다.
/usr/bin/codesign \
    --verify \
    --deep \
    --strict \
    --verbose=2 \
    "$DMG_ROOT/OFFICESTRA.app"

print "Applications 바로가기가 포함된 DMG 산출물을 만듭니다."
/usr/bin/hdiutil create \
    -ov \
    -format UDZO \
    -volname OFFICESTRA \
    -srcfolder "$DMG_ROOT" \
    "$DMG_TEMP"

if [[ "$RELEASE_FLAVOR" == "notarized" ]]; then
    print "최종 배포 컨테이너인 DMG를 서명하고 공증합니다."
    "$PROJECT_DIR/scripts/notarize-app.sh" "$DMG_TEMP"
fi

print "최종 DMG 무결성을 검증합니다."
/usr/bin/hdiutil verify "$DMG_TEMP"

# 검증을 통과한 완성본만 release 디렉터리에 노출한다.
/bin/mv -f "$ZIP_TEMP" "$ZIP_PATH"
/bin/mv -f "$DMG_TEMP" "$DMG_PATH"

CHECKSUM_TEMP="$STAGING_ROOT/SHA256SUMS"
(
    cd "$RELEASE_DIR"
    /usr/bin/shasum -a 256 "$ZIP_NAME" "$DMG_NAME"
) > "$CHECKSUM_TEMP"
/bin/mv "$CHECKSUM_TEMP" "$CHECKSUM_PATH"

print "배포 산출물 생성 완료"
print "서명 상태: $RELEASE_FLAVOR"
print "$ZIP_PATH"
print "$DMG_PATH"
print "$CHECKSUM_PATH"
