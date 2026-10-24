#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_ROOT="$APP_ROOT/native"
SPM_ROOT="$NATIVE_ROOT/app/MeetingTranscriber"
if [ "$#" -gt 1 ]; then echo 'Usage: build-native.sh [baseline|pip|baseline-enhanced|pip-enhanced|upstream]' >&2; exit 2; fi
if [ "$#" -gt 0 ]; then
    EDITION="$1"
elif [ -f "$APP_ROOT/distribution.json" ]; then
    EDITION="$(python3 "$APP_ROOT/scripts/release_integrity.py" distribution-default "$APP_ROOT")"
else
    EDITION='pip'
fi
python3 "$APP_ROOT/scripts/release_integrity.py" distribution-check "$APP_ROOT" "$EDITION"
SCRATCH="$NATIVE_ROOT/.build-$EDITION"
OUT="$APP_ROOT/dist/$EDITION"
unset PIP_EDITION PIP_NEUTRAL MEETINGS_ENHANCEMENTS MEETINGS_REPLICA
case "$EDITION" in
    pip)
        export PIP_EDITION=1
        APP_NAME='Pip Meetings'
        BUNDLE_ID='uk.pipreps.meetings'
        APP_VERSION='0.1.0-alpha.1' ;;
    pip-enhanced)
        export PIP_EDITION=1 MEETINGS_ENHANCEMENTS=1
        APP_NAME='Pip Meetings Enhanced'
        BUNDLE_ID='uk.pipreps.meetings.enhanced'
        APP_VERSION='0.1.0-alpha.2' ;;
    baseline)
        export PIP_EDITION=1 PIP_NEUTRAL=1 MEETINGS_REPLICA=1
        APP_NAME='Meetings Replica'
        BUNDLE_ID='uk.pipreps.meetings.replica'
        APP_VERSION='0.1.0-alpha.1' ;;
    baseline-enhanced)
        export PIP_EDITION=1 PIP_NEUTRAL=1 MEETINGS_ENHANCEMENTS=1
        APP_NAME='Meetings Baseline Enhanced'
        BUNDLE_ID='uk.pipreps.meetings.neutral.enhanced'
        APP_VERSION='0.1.0-alpha.2' ;;
    upstream)
        APP_NAME='Meeting Transcriber Upstream'
        BUNDLE_ID='uk.pipreps.meetings.baseline'
        APP_VERSION='0.8.1-baseline.1' ;;
esac
mkdir -p "$OUT"
if [ -L "$OUT" ]; then echo 'Refusing a symlinked build output directory' >&2; exit 2; fi
SOURCE_MANIFEST="$(mktemp "${TMPDIR:-/tmp}/meetings-source-manifest.XXXXXX")"
BUILD_STAGE=''
FINAL_BUNDLE="$OUT/$APP_NAME.app"
PREVIOUS_BUNDLE=''
cleanup_bundle_stage() {
    if [ -n "$FINAL_BUNDLE" ] && [ ! -e "$FINAL_BUNDLE" ] && [ -n "$PREVIOUS_BUNDLE" ] && [ -e "$PREVIOUS_BUNDLE" ]; then
        mv "$PREVIOUS_BUNDLE" "$FINAL_BUNDLE"
    fi
    if [ -n "$BUILD_STAGE" ] && [ -d "$BUILD_STAGE" ]; then rm -rf "$BUILD_STAGE"; fi
    if [ -n "$SOURCE_MANIFEST" ] && [ -f "$SOURCE_MANIFEST" ]; then rm -f "$SOURCE_MANIFEST"; fi
}
trap cleanup_bundle_stage EXIT
SOURCE_DIGEST="$(python3 "$APP_ROOT/scripts/release_integrity.py" manifest "$APP_ROOT" "$SOURCE_MANIFEST")"
swift build --package-path "$SPM_ROOT" --scratch-path "$SCRATCH" -c release --jobs 2
BINARY_DIR="$(swift build --package-path "$SPM_ROOT" --scratch-path "$SCRATCH" -c release --show-bin-path)"
BUILD_STAGE="$(mktemp -d "$OUT/.bundle-stage.XXXXXX")"
PREVIOUS_BUNDLE="$BUILD_STAGE/previous.app"
APP_BUNDLE="$BUILD_STAGE/$APP_NAME.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY_DIR/MeetingTranscriber" "$APP_BUNDLE/Contents/MacOS/MeetingTranscriber"
cp "$SPM_ROOT/Sources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 14.2' "$APP_BUNDLE/Contents/Info.plist"
if [ "$EDITION" != upstream ]; then
    /usr/libexec/PlistBuddy -c 'Set :LSUIElement false' "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :NSMicrophoneUsageDescription $APP_NAME records microphone audio only when you start a recording." "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :NSAudioCaptureUsageDescription $APP_NAME records the app audio you choose for your meeting." "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :NSScreenCaptureUsageDescription $APP_NAME needs permission to capture the app audio you choose." "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :NSAccessibilityUsageDescription $APP_NAME does not use automatic meeting detection." "$APP_BUNDLE/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c 'Add :UpstreamRevision string a4f6af6df2674bc4e18097084a128af469823fab' "$APP_BUNDLE/Contents/Info.plist"
source "$NATIVE_ROOT/scripts/lib/bundle-licenses.sh"
install_third_party_licenses "$APP_BUNDLE/Contents/Resources"
cp "$NATIVE_ROOT/LICENSE" "$APP_BUNDLE/Contents/Resources/licenses/MeetingTranscriber-LICENSE.txt"
source "$NATIVE_ROOT/scripts/lib/localvqe-resources.sh"
install_localvqe_resources "$APP_BUNDLE/Contents/Resources"
if [ "$EDITION" = upstream ]; then
    ICONSET="$BUILD_STAGE/AppIcon.iconset"
    mkdir -p "$ICONSET"
    cp "$SPM_ROOT/Sources/Assets.xcassets/AppIcon.appiconset/"*.png "$ICONSET/"
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
    # Pip uses an original native character in-app; do not reuse the upstream icon.
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$APP_BUNDLE/Contents/Info.plist"
fi
python3 "$APP_ROOT/scripts/release_integrity.py" receipt "$APP_ROOT" "$APP_BUNDLE" "$EDITION" "$SOURCE_MANIFEST" "$SOURCE_DIGEST"
codesign --force --sign - --entitlements "$SPM_ROOT/Entitlements/Homebrew.entitlements" "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"
python3 "$APP_ROOT/scripts/release-info.py" "$APP_ROOT" "$APP_BUNDLE" "$EDITION" "$BUILD_STAGE/release-info.json" --reported-bundle-path "dist/$EDITION/$APP_NAME.app"
shasum -a 256 "$APP_BUNDLE/Contents/MacOS/MeetingTranscriber" > "$BUILD_STAGE/binary-sha256.txt"
# Replace only this script's generated app after successful assembly/signature
# verification. No source or user-data directory is removed.
if [ -e "$FINAL_BUNDLE" ] || [ -L "$FINAL_BUNDLE" ]; then
    mv "$FINAL_BUNDLE" "$PREVIOUS_BUNDLE"
fi
mv "$APP_BUNDLE" "$FINAL_BUNDLE"
mv "$BUILD_STAGE/release-info.json" "$OUT/release-info.json"
mv "$BUILD_STAGE/binary-sha256.txt" "$OUT/binary-sha256.txt"
echo "Built $FINAL_BUNDLE (ad-hoc signed; not notarised)"
