#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/build/Rest Guardian.app"

if [[ ! -x "$APP_DIR/Contents/MacOS/RestGuardian" ]]; then
  "$ROOT_DIR/build.sh" >/dev/null
fi

open "$APP_DIR" --args "$@"
