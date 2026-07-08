#!/bin/zsh
# Assembles Internos.app from the SwiftPM build product.
# Usage: ./scripts/make-app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Debug and release must NOT share an output path: TCC ties grants to bundle ID +
# path + signature, and one path alternating between two identities corrupts the
# permission panes (toggles that don't stick / attach to the wrong binary).
if [[ "$CONFIG" == "debug" ]]; then
    APP="$DIR/build/debug/Internos Dev.app"
else
    APP="$DIR/build/Internos.app"
fi

cd "$DIR"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Internos"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Internos"
cp "$DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Debug builds get a distinct bundle ID + name so they never collide with an
# installed release app's TCC (mic/Input Monitoring/Accessibility) or LaunchServices
# identity. Release builds keep the real net.timkennedy.internos.
if [[ "$CONFIG" == "debug" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier net.timkennedy.internos.debug" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Internos Dev" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Internos Dev" "$APP/Contents/Info.plist"
fi

# Prefer a real identity (stable TCC grants across rebuilds); fall back to ad-hoc.
# The entitlements file is required: hardened runtime blocks mic access without it.
ENTITLEMENTS="$DIR/Resources/Internos.entitlements"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
else
    echo "warning: no signing identity found, using ad-hoc (TCC grants reset on each rebuild)" >&2
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi

echo "built: $APP"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Authority|Signature)" | head -3
