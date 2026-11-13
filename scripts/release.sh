#!/bin/bash
# Universal release build: Developer ID signature, notarization, stapling, zip.
# Usage: scripts/release.sh <version> [--publish]
# --publish tags the release and uploads it to GitHub (see scripts/publish-release.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--publish]}"
PUBLISH="${2:-}"
NOTARY_PROFILE="${DISKPIE_NOTARY_PROFILE:-diskpie-notary}"
IDENTITY="${DISKPIE_RELEASE_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
[[ -n "$IDENTITY" ]] || { echo "error: no Developer ID Application identity in the keychain" >&2; exit 1; }

if [[ "$PUBLISH" == "--publish" ]]; then
    [[ -z "$(git status --porcelain)" ]] || { echo "error: working tree is not clean" >&2; exit 1; }
    ! git rev-parse "v$VERSION" >/dev/null 2>&1 || { echo "error: tag v$VERSION already exists" >&2; exit 1; }
fi

OUT="build/release"
APP="$OUT/DiskPie.app"
ZIP="build/DiskPie-$VERSION.zip"
BUILD_NUMBER="$(git rev-list --count HEAD)"

swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
[[ -f Resources/AppIcon.icns ]] || ./scripts/make-icon.sh

rm -rf "$OUT" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DiskPie" "$APP/Contents/MacOS/DiskPie"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

lipo -info "$APP/Contents/MacOS/DiskPie"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "Built $ZIP ($VERSION, build $BUILD_NUMBER)"

if [[ "$PUBLISH" == "--publish" ]]; then
    ./scripts/publish-release.sh "$VERSION" "$ZIP" "$ZIP.sha256"
fi
