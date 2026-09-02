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

# Embed Sparkle.framework: SwiftPM links against the xcframework but doesn't
# bundle it; the binary's rpath (@executable_path/../Frameworks) expects it here.
# The artifact path is SwiftPM-internal and has changed across toolchains, so
# demand exactly one match instead of silently taking whatever sorts first.
SPARKLE_SLICES=("$DIR"/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework(N))
if (( ${#SPARKLE_SLICES} != 1 )); then
    echo "error: expected exactly one macOS Sparkle.framework slice, found ${#SPARKLE_SLICES}" >&2
    echo "       under $DIR/.build/artifacts. SwiftPM artifact layout changed?" >&2
    exit 1
fi
SPARKLE_FW="${SPARKLE_SLICES[1]}"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"

# Debug builds get a distinct bundle ID + name so they never collide with an
# installed release app's TCC (mic/Input Monitoring/Accessibility) or LaunchServices
# identity. Release builds keep the real net.timkennedy.internos.
if [[ "$CONFIG" == "debug" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier net.timkennedy.internos.debug" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Internos Dev" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Internos Dev" "$APP/Contents/Info.plist"
    # A dev build must never be a live Sparkle client on the production feed: an
    # accepted update would install release Internos over this path and corrupt
    # the debug bundle's separate TCC identity. UpdateController treats a missing
    # feed as "updater disabled" (no start, no prompt, no menu item).
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# Prefer a real identity (stable TCC grants across rebuilds); fall back to ad-hoc.
# The entitlements file is required: hardened runtime blocks mic access without it.
ENTITLEMENTS="$DIR/Resources/Internos.entitlements"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')"
if [[ -z "$IDENTITY" ]]; then
    echo "warning: no signing identity found, using ad-hoc (TCC grants reset on each rebuild)" >&2
    IDENTITY="-"
fi
"$DIR/scripts/sign-sparkle-framework.sh" "$APP" "$IDENTITY"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

echo "built: $APP"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Authority|Signature)" | head -3
