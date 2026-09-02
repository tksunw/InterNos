#!/bin/zsh
# Re-signs the embedded Sparkle.framework with our identity, deepest-first.
#
# Two reasons this is required, not optional:
#   1. Library validation (hardened runtime) rejects a framework signed by a
#      different team — Sparkle ships signed by the Sparkle project.
#   2. Notarization requires hardened runtime on every nested executable
#      (XPC services, Autoupdate, Updater.app), which re-signing applies.
#
# Usage: sign-sparkle-framework.sh <app-bundle> <identity> [--timestamp]
set -euo pipefail

APP="$1"
IDENTITY="$2"
TS="${3:-}"

FW="$APP/Contents/Frameworks/Sparkle.framework"
FLAGS=(--force --options runtime --sign "$IDENTITY")
[[ "$TS" == "--timestamp" ]] && FLAGS+=(--timestamp)

# Resolve the framework's current version instead of hardcoding a letter, and
# enumerate the nested executables instead of pinning today's roster — both have
# changed across Sparkle majors. --preserve-metadata=entitlements only on the XPC
# services (Downloader.xpc's sandbox entitlements must survive); Autoupdate
# carries Sparkle's own team-less application-identifier, which must not be
# stamped into our Developer ID signature.
VERSION_DIR="$FW/Versions/$(readlink "$FW/Versions/Current" 2>/dev/null || echo Current)"
NESTED=("$VERSION_DIR"/XPCServices/*.xpc(N) "$VERSION_DIR"/Autoupdate(N) "$VERSION_DIR"/Updater.app(N))
if (( ${#NESTED} == 0 )); then
    echo "error: no nested Sparkle executables under $VERSION_DIR — framework layout changed?" >&2
    exit 1
fi

# The zero-count check above catches a totally empty roster, but not a partial
# one — assert the two items we actually depend on resolved.
MISSING=()
[[ -e "$VERSION_DIR/Autoupdate" ]] || MISSING+=("Autoupdate")
[[ -e "$VERSION_DIR/XPCServices/Downloader.xpc" ]] || MISSING+=("XPCServices/Downloader.xpc")
if (( ${#MISSING} > 0 )); then
    echo "error: missing required Sparkle nested executable(s) under $VERSION_DIR: ${MISSING[*]}" >&2
    exit 1
fi
for ITEM in "${NESTED[@]}"; do
    if [[ "$ITEM" == *.xpc ]]; then
        codesign "${FLAGS[@]}" --preserve-metadata=entitlements "$ITEM"
    else
        codesign "${FLAGS[@]}" "$ITEM"
    fi
done
codesign "${FLAGS[@]}" "$FW"
