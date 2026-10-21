#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/MacMetrics.app"
DEST="$HOME/Applications/MacMetrics.app"
if [[ ! -d "$APP" ]]; then
  "$ROOT/Scripts/build.sh"
fi
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP" "$DEST"
open "$DEST"
echo "Installed and launched $DEST"
