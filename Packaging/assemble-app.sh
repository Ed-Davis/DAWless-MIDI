#!/bin/bash
# Shared by make-app.sh and release.sh: builds the release binary and assembles
# an unsigned "build/DAWless MIDI.app". Source this file; it sets APP_NAME,
# EXEC, BUNDLE_ID, VERSION, BUILD and APP.
set -euo pipefail

APP_NAME="DAWless MIDI"
EXEC="DAWlessMIDI"
BUNDLE_ID="com.ed1t.dawlessmidi"
VERSION="$(tr -d '[:space:]' < Packaging/VERSION)"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/${APP_NAME}.app"

echo "▸ Building ${APP_NAME} ${VERSION} (${BUILD}, release)…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/$EXEC" "$APP/Contents/MacOS/$EXEC"
[[ -x "$APP/Contents/MacOS/$EXEC" ]] || { echo "✗ executable missing"; exit 1; }
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Apple privacy manifest (App Store requirement).
cp Packaging/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
if command -v plutil >/dev/null; then plutil -lint "$APP/Contents/Resources/PrivacyInfo.xcprivacy"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>      <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>       <string>${EXEC}</string>
    <key>CFBundleIdentifier</key>       <string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>          <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.music</string>
    <key>NSHumanReadableCopyright</key> <string>Copyright © 2026 Ed Davis. All rights reserved.</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>NSPrincipalClass</key>         <string>NSApplication</string>
</dict>
</plist>
PLIST

xattr -cr "$APP" 2>/dev/null || true
