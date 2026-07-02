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
ZIP="$DIR/build/Internos-$VERSION.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-internos}"

"$DIR/scripts/make-app.sh" release

# Re-sign with Developer ID if available (make-app.sh may have used a dev identity).
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')"
if [[ -n "$DEV_ID" ]]; then
    echo "signing with: $DEV_ID"
    codesign --force --options runtime --timestamp --sign "$DEV_ID" "$APP"
else
    echo "NOTE: no Developer ID Application certificate found — artifact is development-signed." >&2
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "artifact: $ZIP"

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "submitting for notarization…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    # Re-zip so the download carries the stapled ticket.
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "notarized and stapled: $ZIP"
else
    echo "NOTE: no notarytool profile '$NOTARY_PROFILE' — skipping notarization." >&2
fi

shasum -a 256 "$ZIP"
