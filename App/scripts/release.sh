#!/bin/zsh
# Builds a distributable Internos release artifact.
#
# Full pipeline (needs one-time setup, see README "Releasing"):
#   1. Developer ID Application certificate in the keychain
#   2. notarytool credentials: xcrun notarytool store-credentials internos \
#        --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
#
# Degrades gracefully: without a Developer ID cert it signs with the available
# development identity (fine for personal installs; Gatekeeper will warn others);
# without notary credentials it skips notarization.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$DIR/build/Internos.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DIR/Resources/Info.plist")"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DIR/Resources/Info.plist")"
ZIP="$DIR/build/Internos-$VERSION.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-internos}"
REPO="$(cd "$DIR/.." && pwd)"
# Derived from Resources/Info.plist (SUFeedURL), a raw.githubusercontent.com URL
# of the form https://raw.githubusercontent.com/<owner>/<repo>/main/appcast.xml.
SUFEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$DIR/Resources/Info.plist")"
REPO_SLUG="$(sed -E 's#^https://raw\.githubusercontent\.com/([^/]+/[^/]+)/.*$#\1#' <<< "$SUFEED_URL")"
# A bogus/unrecognized URL passes through the sed unchanged, and an unmatched
# URL still contains slashes (e.g. "https://example.com/x"), so require the
# result to look like a bare owner/repo slug, not just contain a slash anywhere.
if [[ "$REPO_SLUG" != */* || "$REPO_SLUG" == */*/* || "$REPO_SLUG" == *:* ]]; then
    echo "error: could not derive owner/repo from SUFeedURL '$SUFEED_URL' in Resources/Info.plist" >&2
    exit 1
fi

SPARKLE_BIN="$DIR/.build/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
    echo "error: $SPARKLE_BIN/generate_appcast not found. Run 'swift build' first (SPM fetches the Sparkle artifact)" >&2
    exit 1
fi

# Sparkle compares sparkle:version (CFBundleVersion), not the marketing version.
# A release that bumps only CFBundleShortVersionString would be invisible to
# every installed copy, so refuse to build one. Rebuilding the same marketing
# version with the same build number is allowed (generate_appcast updates the
# existing item).
if [[ "$BUILD_NUM" != <-> ]]; then
    echo "error: CFBundleVersion must be an integer for Sparkle ordering, got '$BUILD_NUM'" >&2
    exit 1
fi
if [[ -f "$REPO/appcast.xml" ]]; then
    # Highest sparkle:version across all items (not the first item: the file may
    # be hand-edited or reordered), plus that item's marketing version.
    read -r LAST_BUILD LAST_MARKETING < <(awk -F'[<>]' '
        /<sparkle:version>/ { b = $3 }
        /<sparkle:shortVersionString>/ { m = $3 }
        /<\/item>/ { if (b ~ /^[0-9]+$/ && b + 0 > max + 0) { max = b; mm = m }; b = ""; m = "" }
        END { print max, mm }' "$REPO/appcast.xml")
    if [[ "$LAST_BUILD" != <-> ]]; then
        echo "error: appcast.xml exists but no integer <sparkle:version> parsed; refusing to guess" >&2
        exit 1
    fi
    if (( BUILD_NUM < LAST_BUILD )) || { (( BUILD_NUM == LAST_BUILD )) && [[ "${LAST_MARKETING:-$VERSION}" != "$VERSION" ]]; }; then
        echo "error: CFBundleVersion ($BUILD_NUM) must exceed the newest appcast sparkle:version ($LAST_BUILD)" >&2
        echo "       or Sparkle clients will never see this release. Bump CFBundleVersion in Resources/Info.plist." >&2
        exit 1
    fi
fi

"$DIR/scripts/make-app.sh" release

# Re-sign with Developer ID if available (make-app.sh may have used a dev identity).
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')"
if [[ -n "$DEV_ID" ]]; then
    echo "signing with: $DEV_ID"
    "$DIR/scripts/sign-sparkle-framework.sh" "$APP" "$DEV_ID" --timestamp
    codesign --force --options runtime --timestamp \
        --entitlements "$DIR/Resources/Internos.entitlements" --sign "$DEV_ID" "$APP"
else
    echo "NOTE: no Developer ID Application certificate found — artifact is development-signed." >&2
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "artifact: $ZIP"

HAVE_NOTARY=0
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    HAVE_NOTARY=1
    echo "submitting app for notarization…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    # Re-zip so the download carries the stapled ticket.
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "notarized and stapled: $ZIP"
else
    echo "NOTE: no notarytool profile '$NOTARY_PROFILE' — skipping notarization." >&2
fi

# Build the drag-to-Applications installer from the (now stapled) app.
DMG="$DIR/build/Internos-$VERSION.dmg"
"$DIR/scripts/make-dmg.sh"
if [[ "$HAVE_NOTARY" == "1" ]]; then
    echo "submitting DMG for notarization…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "notarized and stapled: $DMG"
fi

# Sparkle appcast: EdDSA-sign the DMG (key lives in the login keychain, created
# once with generate_keys) and write appcast.xml at the repo root. Sparkle
# clients read it from raw.githubusercontent.com (SUFeedURL), so the release
# isn't visible to updaters until appcast.xml is committed and pushed.
APPCAST_STAGE="$DIR/build/appcast-stage"
rm -rf "$APPCAST_STAGE"
mkdir -p "$APPCAST_STAGE"
cp "$DMG" "$APPCAST_STAGE/"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO_SLUG/releases/download/v$VERSION/" \
    --link "https://github.com/$REPO_SLUG/releases" \
    -o "$REPO/appcast.xml" "$APPCAST_STAGE"
echo "appcast written: $REPO/appcast.xml"
echo "REMINDER: upload the DMG to the v$VERSION GitHub release, then commit and push appcast.xml."

echo "--- artifacts ---"
shasum -a 256 "$ZIP" "$DMG"
