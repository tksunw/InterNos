#!/bin/zsh
# Builds Internos-<version>.dmg: a drag-to-Applications installer window.
# Expects build/Internos.app to already exist and be Developer ID signed (release.sh does that).
# Layout is done by dmgbuild (pipx install dmgbuild), which writes the Finder .DS_Store
# programmatically — deterministic and headless-safe. Earlier approaches both failed:
# live Finder AppleScript needs a GUI session + automation TCC, and reusing a baked
# .DS_Store breaks because its background reference is an alias tied to the original
# volume's identity. Window/icon settings live in dmg-settings.py.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$DIR/build/Internos.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DIR/Resources/Info.plist")"
DMG="$DIR/build/Internos-$VERSION.dmg"
BG="$DIR/Resources/dmg-background.tiff"

[[ -d "$APP" ]] || { echo "error: $APP not found — build it first" >&2; exit 1 }
command -v dmgbuild >/dev/null || { echo "error: dmgbuild not found — pipx install dmgbuild" >&2; exit 1 }

rm -f "$DMG"
dmgbuild -s "$DIR/scripts/dmg-settings.py" \
    -D app="$APP" -D background="$BG" \
    "Internos" "$DMG"

# Sign the DMG itself with Developer ID (so the download is signed end to end).
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')"
if [[ -n "$DEV_ID" ]]; then
    codesign --force --sign "$DEV_ID" "$DMG"
fi

echo "built: $DMG"
