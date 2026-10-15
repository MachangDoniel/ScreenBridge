#!/bin/sh
# Runs every automated check that doesn't need a physical device.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="${SIMULATOR:-iPhone 17}"

echo "== Shared package (macOS): protocol, transport, registry"
(cd "$ROOT" && swift test)

echo "== Mac core: store, git consistency, path confinement, receiver, MCP"
(cd "$ROOT/Mac" && swift build && swift test)

echo "== iOS framework on simulator ($SIM): UIKit cell reuse + registry"
(cd "$ROOT" && xcodebuild test -scheme ScreenBridge-Package -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath .build/xcode -only-testing:ScreenBridgeTests -quiet)

# Release-archive verification lives in the demo repo (Scripts/verify-release.sh):
# https://github.com/MachangDoniel/ScreenBridgeDemo
