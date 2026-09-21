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

# App Intents metadata: Shortcuts, Spotlight and Siri discover the intents through
# Contents/Resources/Metadata.appintents. Xcode generates it for app targets; for a
# SwiftPM executable we run the same processor over the compiler's const-values
# output. The intermediates path is SwiftPM-internal (same caveat as the Sparkle
# artifact above), so fail loud if it moves rather than ship an app with no intents.
CONSTVALS=("$DIR"/.build/out/Intermediates.noindex/Internos.build/${(C)CONFIG}/Internos-p.build/Objects-normal/arm64/*.swiftconstvalues(N))
if (( ${#CONSTVALS} == 0 )); then
    echo "error: no .swiftconstvalues for Internos ($CONFIG). SwiftPM intermediates layout changed?" >&2
    exit 1
fi
INTENTS_TMP="$(mktemp -d)"
print -l "${CONSTVALS[@]}" > "$INTENTS_TMP/constvals.list"
print -l "$DIR"/Sources/*.swift > "$INTENTS_TMP/sources.list"
xcrun appintentsmetadataprocessor \
    --output "$APP/Contents/Resources" \
    --toolchain-dir "${$(xcrun --find swiftc):h:h:h}" \
    --module-name Internos \
    --sdk-root "$(xcrun --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
    --platform-family macOS \
    --deployment-target "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$DIR/Resources/Info.plist")" \
    --target-triple arm64-apple-macos \
    --source-file-list "$INTENTS_TMP/sources.list" \
    --swift-const-vals-list "$INTENTS_TMP/constvals.list" \
    --force --quiet-warnings >"$INTENTS_TMP/log" 2>&1 || true
# The processor logs chattily even on success, so its output is shown only on failure.
if ! grep -q ToggleDictationIntent "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" 2>/dev/null; then
    cat "$INTENTS_TMP/log" >&2
    echo "error: Metadata.appintents missing or has no intents (processor output above)" >&2
    exit 1
fi
rm -rf "$INTENTS_TMP"

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
