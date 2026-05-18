#!/usr/bin/env bash
# Build a distributable CopilotMeter.dmg from the assembled .app bundle.
#
# The resulting DMG opens to show CopilotMeter.app next to an "Applications"
# alias, so the user just drags the app onto Applications to install — the
# standard macOS convention.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="CopilotMeter"
APP_BUNDLE="$ROOT/build/$APP_NAME.app"
DMG_PATH="$ROOT/build/$APP_NAME.dmg"
STAGING="$ROOT/build/dmg-staging"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "==> $APP_BUNDLE not found — running Scripts/build-app.sh first"
    bash "$ROOT/Scripts/build-app.sh"
fi

echo "==> Staging contents in $STAGING"
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

VOLNAME="$APP_NAME"

echo "==> hdiutil create $DMG_PATH"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH" >/dev/null

echo "==> Ad-hoc codesign DMG"
codesign --force --sign - "$DMG_PATH" >/dev/null

rm -rf "$STAGING"

echo "==> Done"
ls -lh "$DMG_PATH"
shasum -a 256 "$DMG_PATH"
