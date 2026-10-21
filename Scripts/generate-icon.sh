#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/Resources"
ICONSET="$ASSETS/AppIcon.iconset"
mkdir -p "$ICONSET"
swift "$ROOT/Scripts/draw-app-icon.swift" "$ASSETS/AppIcon.png"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ASSETS/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$ASSETS/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ASSETS/AppIcon.icns"
