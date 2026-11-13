#!/bin/bash
# Builds build/DiskPie.app and signs it with a stable Apple Development identity,
# so Full Disk Access granted once survives rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/DiskPie.app"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

if [[ ! -f Resources/AppIcon.icns ]]; then
    ./scripts/make-icon.sh || echo "warning: icon generation failed"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DiskPie" "$APP/Contents/MacOS/DiskPie"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

IDENTITY_FILE=".signing-identity"
if [[ -n "${DISKPIE_SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$DISKPIE_SIGN_IDENTITY"
elif [[ -f "$IDENTITY_FILE" ]]; then
    IDENTITY="$(cat "$IDENTITY_FILE")"
else
    IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')"
    IDENTITY="${IDENTITY:--}"
    echo "$IDENTITY" > "$IDENTITY_FILE"
fi

codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
echo "Built $APP (signed with $IDENTITY)"
