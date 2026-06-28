#!/bin/bash
# Local test build: signed Release (Developer ID, hardened runtime) installed to
# /Applications WITHOUT notarization/DMG. For verifying behavior locally before
# cutting the real notarized release with build_release.sh.
set -euo pipefail

SCHEME="Mira"
DERIVED="build_run"
TEAM="7FD7W8SX34"
SIGN_ID="Developer ID Application: Trevon Barbour ($TEAM)"
ENTITLEMENTS="Mira/Mira.entitlements"
APP="$DERIVED/Build/Products/Release/Mira.app"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Mira/Info.plist)
echo "▶ Building Mira $VERSION (Release, local install) for team $TEAM"

xcodegen generate
xcodebuild \
  -project Mira.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  clean build

echo "▶ Re-signing Sparkle sub-components..."
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for bin in \
  "$SPARKLE/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
  "$SPARKLE/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
  "$SPARKLE/XPCServices/Downloader.xpc" \
  "$SPARKLE/XPCServices/Installer.xpc" \
  "$SPARKLE/Updater.app/Contents/MacOS/Updater" \
  "$SPARKLE/Updater.app" \
  "$SPARKLE/Autoupdate" \
  "$SPARKLE/Sparkle" \
  "$APP/Contents/Frameworks/Sparkle.framework"; do
  if [ -e "$bin" ]; then
    codesign --force --sign "$SIGN_ID" --timestamp --options=runtime "$bin"
  fi
done

echo "▶ Re-signing Mira.app..."
codesign --force --sign "$SIGN_ID" --timestamp --options=runtime \
  --entitlements "$ENTITLEMENTS" "$APP"

echo "▶ Verifying signature..."
codesign --verify --deep --strict "$APP"

echo "▶ Installing to /Applications..."
osascript -e 'tell application "Mira" to quit' 2>/dev/null || true
pkill -x Mira 2>/dev/null || true
sleep 1
rm -rf /Applications/Mira.app
ditto "$APP" /Applications/Mira.app

echo "✅ Installed /Applications/Mira.app ($VERSION)"
