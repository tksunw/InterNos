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
# changed across Sparkle majors. --preserve-metadata=entitlements is applied
# uniformly: a no-op where there are none, required for Downloader.xpc's sandbox
# entitlements.
VERSION_DIR="$FW/Versions/$(readlink "$FW/Versions/Current" 2>/dev/null || echo Current)"
NESTED=("$VERSION_DIR"/XPCServices/*.xpc(N) "$VERSION_DIR"/Autoupdate(N) "$VERSION_DIR"/Updater.app(N))
if (( ${#NESTED} == 0 )); then
    echo "error: no nested Sparkle executables under $VERSION_DIR — framework layout changed?" >&2
    exit 1
fi
for ITEM in "${NESTED[@]}"; do
    codesign "${FLAGS[@]}" --preserve-metadata=entitlements "$ITEM"
done
codesign "${FLAGS[@]}" "$FW"
