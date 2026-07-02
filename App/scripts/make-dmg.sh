#!/bin/zsh
# Builds Internos-<version>.dmg: a drag-to-Applications installer window.
# Expects build/Internos.app to already exist and be Developer ID signed (release.sh does that).
# Self-contained: uses hdiutil + Finder AppleScript, no external tools.
# Degrades gracefully — if the Finder layout step fails (e.g. no GUI session), it still
# produces a functional DMG with the app + Applications symlink, just without the pretty layout.
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

# Stage contents: app, Applications symlink, hidden background.
cp -R "$APP" "$STAGE/Internos.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
[[ -f "$BG" ]] && cp "$BG" "$STAGE/.background/background.tiff"

# Read-write image we can lay out, then compress.
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
    -format UDRW -ov "$TMPDMG" >/dev/null

MOUNT_OUTPUT="$(hdiutil attach "$TMPDMG" -readwrite -noverify -noautoopen)"
MOUNT_DIR="$(echo "$MOUNT_OUTPUT" | grep -o '/Volumes/.*' | head -1)"

# Finder layout: icon view, background image, window size, icon positions. Best-effort.
if [[ -n "$MOUNT_DIR" ]]; then
    osascript <<EOF 2>/dev/null || echo "note: Finder layout skipped (DMG still valid)" >&2
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 520}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        try
            set background picture of opts to file ".background:background.tiff"
        end try
        set position of item "Internos.app" of container window to {170, 200}
        set position of item "Applications" of container window to {490, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
    sync
    hdiutil detach "$MOUNT_DIR" >/dev/null
fi

rm -f "$DMG"
hdiutil convert "$TMPDMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

# Sign the DMG itself with Developer ID (so the download is signed end to end).
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')"
if [[ -n "$DEV_ID" ]]; then
    codesign --force --sign "$DEV_ID" "$DMG"
fi

echo "built: $DMG"
