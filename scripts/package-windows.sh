#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-v0.1.1-alpha}"
DIST_DIR="$ROOT_DIR/dist"
ZIP_PATH="$DIST_DIR/RestGuardian-Windows-PowerShell-${VERSION}.zip"

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"

(
  cd "$ROOT_DIR"
  COPYFILE_DISABLE=1 zip -r -X "$ZIP_PATH" \
    "windows" \
    "LICENSE" \
    >/dev/null
)

echo "$ZIP_PATH"
