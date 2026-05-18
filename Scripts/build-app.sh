#!/usr/bin/env bash
# Build CopilotMeter as a native arm64 macOS .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
ARCH="${ARCH:-arm64}"
APP_NAME="CopilotMeter"
APP_BUNDLE="$ROOT/build/$APP_NAME.app"

echo "==> Building Swift package (config=$CONFIG, arch=$ARCH)"
# Use arch -arm64 to force arm64 build even when launched under Rosetta terminal.
if [[ "$(uname -m)" == "x86_64" && -n "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" ]] && \
   sysctl -n sysctl.proc_translated 2>/dev/null | grep -q 1; then
  PREFIX=(arch -arm64)
else
  PREFIX=()
fi

"${PREFIX[@]}" swift build -c "$CONFIG" --arch "$ARCH"

BIN_PATH="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)"
EXE="$BIN_PATH/$APP_NAME"
if [[ ! -x "$EXE" ]]; then
    echo "error: built executable not found at $EXE" >&2
    exit 1
fi

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$EXE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Ensure icon exists; regenerate if missing.
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
    echo "==> AppIcon.icns missing — running generate-icon.sh"
    bash "$ROOT/Scripts/generate-icon.sh"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Ad-hoc codesign so macOS lets us launch it.
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

echo "==> Built $APP_BUNDLE"
echo "Launch with:  open '$APP_BUNDLE'"
