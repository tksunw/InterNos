#!/bin/zsh
# Assembles Internos.app from the SwiftPM build product.
# Usage: ./scripts/make-app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$DIR/build/Internos.app"

cd "$DIR"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Internos"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Internos"
cp "$DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Prefer a real identity (stable TCC grants across rebuilds); fall back to ad-hoc.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
    echo "warning: no signing identity found, using ad-hoc (TCC grants reset on each rebuild)" >&2
    codesign --force --sign - "$APP"
fi

echo "built: $APP"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Authority|Signature)" | head -3
