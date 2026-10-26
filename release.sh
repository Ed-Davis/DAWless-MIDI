#!/bin/bash
# Build, sign, notarize, and staple a release DMG for DAWless MIDI
set -euo pipefail
cd "$(dirname "$0")"
DEV_ID="${SIGN_IDENTITY:-Developer ID Application: Edward Davis (NCLS6DFRQ6)}"
KEYCHAIN_PROFILE="AC_PASSWORD"

# Notarize with an App Store Connect API key when one is given (CI sets
# NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID), otherwise with the
# "AC_PASSWORD" profile in your keychain.
if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  NOTARY_ARGS=(--keychain-profile "$KEYCHAIN_PROFILE")
fi

# Checks the API key works before building. A Team key needs the issuer ID;
# an Individual key must be used without one, so try that if the first fails.
if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  echo "=== Checking the notary API key ==="
  if xcrun notarytool history "${NOTARY_ARGS[@]}" >/dev/null 2>notary-check.log; then
    echo "Team key accepted."
  elif xcrun notarytool history --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" >/dev/null 2>>notary-check.log; then
    echo "Individual key accepted (no issuer ID)."
    NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID")
  else
    cat notary-check.log
    echo "✗ ERROR: Apple's notary service didn't accept the API key, with or without the issuer ID."
    exit 1
  fi
  rm -f notary-check.log
fi

echo "=== Building release and assembling .app ==="
source Packaging/assemble-app.sh

echo "=== Codesigning ==="
codesign --force --options runtime \
  --sign "$DEV_ID" \
  --entitlements entitlements.plist \
  --timestamp \
  "$APP"

echo "=== Verifying signature ==="
codesign --verify --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>&1)"
[[ "$SIGNED_ENTITLEMENTS" == *"com.apple.security.app-sandbox"* ]] \
  || { echo "✗ ERROR: App Sandbox entitlement missing"; exit 1; }
# Not notarized yet, so Gatekeeper is expected to reject it here.
spctl --assess --type execute -vv "$APP" 2>&1 || echo "  (expected before notarization)"

echo "=== Creating zip for notarization ==="
ditto -c -k --keepParent "$APP" "build/${APP_NAME}.app.zip"

echo "=== Submitting for notarization ==="
xcrun notarytool submit "build/${APP_NAME}.app.zip" "${NOTARY_ARGS[@]}" --wait 2>&1

echo "=== Stapling ==="
xcrun stapler staple "$APP"

echo "=== Verifying notarization ==="
spctl --assess --type execute -vv "$APP" 2>&1

echo "=== Creating DMG ==="
rm -rf dmg_staging "build/${APP_NAME}.dmg"
mkdir dmg_staging
cp -R "$APP" dmg_staging/
ln -s /Applications dmg_staging/Applications
hdiutil create -volname "$APP_NAME" -srcfolder dmg_staging -ov -format UDRO "build/${APP_NAME}.dmg"
rm -rf dmg_staging

echo "=== Notarizing DMG ==="
xcrun notarytool submit "build/${APP_NAME}.dmg" "${NOTARY_ARGS[@]}" --wait 2>&1

echo "=== Stapling DMG ==="
xcrun stapler staple "build/${APP_NAME}.dmg"

echo "=== Verifying DMG ==="
xcrun stapler validate "build/${APP_NAME}.dmg" 2>&1

echo "=== Done: build/${APP_NAME}.dmg ==="
ls -la "build/${APP_NAME}.dmg"
