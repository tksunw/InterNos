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

codesign "${FLAGS[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
# Downloader.xpc carries sandbox entitlements Sparkle needs preserved.
codesign "${FLAGS[@]}" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
codesign "${FLAGS[@]}" "$FW/Versions/B/Autoupdate"
codesign "${FLAGS[@]}" "$FW/Versions/B/Updater.app"
codesign "${FLAGS[@]}" "$FW"
