#!/bin/zsh
# Developer ID 앱을 Apple에 공증하고 티켓을 부착한다.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT="${1:-$PROJECT_DIR/dist/OFFICESTRA.app}"
NOTARY_PROFILE="${OFFICESTRA_NOTARY_PROFILE:-}"

if [[ ! -e "$ARTIFACT" ]]; then
    print -u2 "공증할 산출물이 없습니다. $ARTIFACT"
    exit 1
fi
if [[ -z "$NOTARY_PROFILE" ]]; then
    print -u2 "OFFICESTRA_NOTARY_PROFILE에 notarytool Keychain 프로필 이름을 지정하세요."
    print -u2 "인증값 자체를 환경 변수나 저장소에 넣지 마세요."
    exit 1
fi

TEMP_DIR=""
cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

if [[ "$ARTIFACT" != *.app || ! -d "$ARTIFACT" ]]; then
    print -u2 "공증할 산출물은 .app 번들이어야 합니다. $ARTIFACT"
    exit 1
fi

SIGNATURE_DETAILS="$(
    /usr/bin/codesign -dv --verbose=4 "$ARTIFACT" 2>&1
)"
if ! print -r -- "$SIGNATURE_DETAILS" \
    | /usr/bin/grep -q '^Authority=Developer ID Application:'; then
    print -u2 "Developer ID Application 서명이 필요합니다. ad-hoc 앱은 공증할 수 없습니다."
    exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$ARTIFACT"

TEMP_DIR="$(
    mktemp -d "${TMPDIR:-/tmp}/officestra-notary.XXXXXX"
)"
SUBMISSION_ZIP="$TEMP_DIR/OFFICESTRA.zip"
/usr/bin/ditto \
    -c \
    -k \
    --sequesterRsrc \
    --keepParent \
    "$ARTIFACT" \
    "$SUBMISSION_ZIP"

/usr/bin/xcrun notarytool submit \
    "$SUBMISSION_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
/usr/bin/xcrun stapler staple "$ARTIFACT"
/usr/bin/xcrun stapler validate "$ARTIFACT"
/usr/sbin/spctl \
    --assess \
    --type execute \
    --verbose=4 \
    "$ARTIFACT"

print "OFFICESTRA 앱 공증과 티켓 부착이 완료됐습니다."

print "$ARTIFACT"
