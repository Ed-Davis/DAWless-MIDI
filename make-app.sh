#!/bin/bash
# Builds "DAWless MIDI.app" into ./build
#
# Usage:
#   ./make-app.sh                # Ad-hoc signed dev build (drag to Applications)
#   ./make-app.sh --app-store    # App Store build (sandboxed, Mac Developer signed)
#
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
source Packaging/assemble-app.sh

# Sign — NO --deep (app has no nested executables; --deep corrupts signature)
echo "▸ Signing app…"
if [[ "$MODE" == "--app-store" ]]; then
  codesign --force --options runtime \
    --sign "Mac Developer: Edward Davis (NCLS6DFRQ6)" \
    --entitlements entitlements.plist \
    "$APP"
else
  # Ad-hoc, but sandboxed exactly like the App Store build, so testing
  # shows any sandbox problem before submission.
  codesign --force --options runtime --entitlements entitlements.plist --sign - "$APP"
fi

echo "▸ Verifying signature…"
codesign --verify --strict "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q app-sandbox || { echo "✗ sandbox entitlement missing"; exit 1; }
# Gatekeeper always rejects ad-hoc and unnotarized builds; this is informational.
spctl --assess --type execute -vv "$APP" 2>&1 || true

echo "▸ Done: $APP"
if [[ "$MODE" == "--app-store" ]]; then
  echo "  App Store build (sandboxed). Upload via Xcode or Transporter."
else
  echo "  Drag to Applications to install."
  if [[ -z "${CI:-}" ]]; then open -R "$APP" || true; fi
fi
