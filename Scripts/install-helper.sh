#!/bin/sh
# Builds the ScreenBridge Mac helper (Release), installs it to ~/Applications and
# launches it. On launch the helper installs the `screenbridge` and
# `screenbridge-mcp` commands into ~/Library/Application Support/ScreenBridge/bin.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${SCREENBRIDGE_APP_DIR:-$HOME/Applications}"

command -v xcodegen >/dev/null || { echo "error: xcodegen is required (brew install xcodegen)"; exit 1; }
cd "$ROOT/Mac/App"
xcodegen generate --quiet
xcodebuild -project ScreenBridgeHelper.xcodeproj -scheme ScreenBridgeHelper -configuration Release \
  -derivedDataPath "$ROOT/.build/helper-release" build -quiet

mkdir -p "$DEST"
pkill -x ScreenBridge 2>/dev/null || true
rm -rf "$DEST/ScreenBridge.app"
cp -R "$ROOT/.build/helper-release/Build/Products/Release/ScreenBridge.app" "$DEST/"
open "$DEST/ScreenBridge.app"
sleep 2
"$HOME/Library/Application Support/ScreenBridge/bin/screenbridge" doctor || true
echo "Installed $DEST/ScreenBridge.app"
