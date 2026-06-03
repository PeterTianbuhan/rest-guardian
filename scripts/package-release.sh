#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-v0.1.1-alpha}"
APP_DIR="$ROOT_DIR/build/Rest Guardian.app"
DIST_DIR="$ROOT_DIR/dist"
ZIP_PATH="$DIST_DIR/RestGuardian-macOS-arm64-${VERSION}.zip"

"$ROOT_DIR/build.sh" >/dev/null

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP_DIR" >/dev/null 2>&1 || true
fi

(
  cd "$ROOT_DIR/build"
  COPYFILE_DISABLE=1 zip -r -X "$ZIP_PATH" "Rest Guardian.app" >/dev/null
)
echo "$ZIP_PATH"
