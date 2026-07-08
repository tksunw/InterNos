#!/bin/zsh
# Builds Internos-<version>.dmg: a drag-to-Applications installer window.
# Expects build/Internos.app to already exist and be Developer ID signed (release.sh does that).
# The window layout (background, icon positions, view options) comes from the pre-baked
# Resources/dmg-DS_Store — deterministic and headless-safe. The previous approach (live
# Finder AppleScript) failed silently in sandboxed/headless shells and shipped ugly DMGs.
# To regenerate the layout: mount a UDRW copy, arrange the window in Finder by hand
# (Cmd-J: background .background/background.tiff, icon size 112, app at 170,200,
# Applications at 490,200, window 660x400), then copy the volume's .DS_Store back to
# Resources/dmg-DS_Store.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$DIR/build/Internos.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DIR/Resources/Info.plist")"
VOLNAME="Internos"
DMG="$DIR/build/Internos-$VERSION.dmg"
BG="$DIR/Resources/dmg-background.tiff"

[[ -d "$APP" ]] || { echo "error: $APP not found — build it first" >&2; exit 1 }

STAGE="$(mktemp -d)"
TMPDMG="$(mktemp -u).dmg"
trap 'rm -rf "$STAGE" "$TMPDMG"' EXIT

# Stage contents: app, Applications symlink, hidden background, pre-baked Finder layout.
cp -R "$APP" "$STAGE/Internos.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
[[ -f "$BG" ]] && cp "$BG" "$STAGE/.background/background.tiff"
DS="$DIR/Resources/dmg-DS_Store"
if [[ -f "$DS" ]]; then
    cp "$DS" "$STAGE/.DS_Store"
else
    echo "warning: $DS missing — DMG will have no window layout" >&2
fi

hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
    -format UDRW -ov "$TMPDMG" >/dev/null

rm -f "$DMG"
hdiutil convert "$TMPDMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

# Sign the DMG itself with Developer ID (so the download is signed end to end).
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')"
if [[ -n "$DEV_ID" ]]; then
    codesign --force --sign "$DEV_ID" "$DMG"
fi

echo "built: $DMG"
