#!/usr/bin/env bash
# One-shot installer for CopilotMeter.
#
# Downloads the latest CopilotMeter.dmg from GitHub Releases, strips the
# macOS quarantine attribute (the one that makes Gatekeeper say
# "Apple cannot verify..."), mounts it, copies the app to /Applications,
# and detaches the DMG.
#
# Usage (from any Terminal):
#   curl -fsSL https://raw.githubusercontent.com/zhongjiechen/CopilotMeter/main/Scripts/install.sh | bash
#
# Or with a pinned version:
#   VERSION=v0.1.1 bash <(curl -fsSL https://raw.githubusercontent.com/zhongjiechen/CopilotMeter/main/Scripts/install.sh)
set -euo pipefail

REPO="zhongjiechen/CopilotMeter"
VERSION="${VERSION:-latest}"

if [[ "$VERSION" == "latest" ]]; then
    DMG_URL="https://github.com/${REPO}/releases/latest/download/CopilotMeter.dmg"
else
    DMG_URL="https://github.com/${REPO}/releases/download/${VERSION}/CopilotMeter.dmg"
fi

TMP_DIR="$(mktemp -d -t copilotmeter-install)"
trap 'rm -rf "$TMP_DIR"' EXIT

DMG_PATH="$TMP_DIR/CopilotMeter.dmg"
MOUNT_POINT="$TMP_DIR/mnt"
mkdir -p "$MOUNT_POINT"

echo "==> Downloading $DMG_URL"
curl -fsSL -o "$DMG_PATH" "$DMG_URL"

echo "==> Stripping macOS quarantine attribute"
# Quietly ignore "No such xattr" — the attribute may not be set when running
# this script through certain shells.
xattr -d com.apple.quarantine "$DMG_PATH" 2>/dev/null || true

echo "==> Mounting $DMG_PATH"
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -nobrowse -quiet

echo "==> Copying CopilotMeter.app to /Applications"
rm -rf "/Applications/CopilotMeter.app"
cp -R "$MOUNT_POINT/CopilotMeter.app" "/Applications/"

# Strip quarantine from the installed app too so first launch doesn't prompt.
xattr -dr com.apple.quarantine "/Applications/CopilotMeter.app" 2>/dev/null || true

echo "==> Detaching DMG"
hdiutil detach "$MOUNT_POINT" -quiet

echo
echo "✅ CopilotMeter installed."
echo
echo "   Launch:           open -a CopilotMeter"
echo "   Open at login:    System Settings → General → Login Items → +"
echo "   Uninstall later:  rm -rf /Applications/CopilotMeter.app"
