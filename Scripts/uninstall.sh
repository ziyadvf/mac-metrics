#!/usr/bin/env bash
set -euo pipefail
APP="$HOME/Applications/MacMetrics.app"
pkill -x MacMetrics 2>/dev/null || true
rm -rf "$APP"
echo "Removed $APP"
