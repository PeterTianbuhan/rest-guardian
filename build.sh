#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/build/Rest Guardian.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
MODULE_CACHE_DIR="$ROOT_DIR/build/module-cache"

SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ ! -d "$SDK_PATH" ]]; then
  SDK_PATH="$(xcrun --show-sdk-path)"
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE_DIR"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
MODULE_CACHE_DIR="$MODULE_CACHE_DIR" \
swiftc "$ROOT_DIR/Sources/RestGuardian.swift" \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macosx13.0 \
  -framework Cocoa \
  -o "$MACOS_DIR/RestGuardian"

chmod +x "$MACOS_DIR/RestGuardian"
echo "$APP_DIR"
