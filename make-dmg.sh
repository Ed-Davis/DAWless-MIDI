#!/bin/bash
# Builds an ad-hoc signed test DMG at "build/DAWless MIDI <version>.dmg".
# Not notarized: on first launch, right-click the app and choose Open
# (or allow it in System Settings ▸ Privacy & Security).
# For a signed, notarized release use ./release.sh instead.
set -euo pipefail
cd "$(dirname "$0")"

./make-app.sh
APP_NAME="DAWless MIDI"
VERSION="$(tr -d '[:space:]' < Packaging/VERSION)"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
DMG="build/${APP_NAME} ${VERSION} build ${BUILD} (test).dmg"

echo "▸ Creating DMG…"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "build/${APP_NAME}.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
echo "▸ Done: $DMG"
