#!/bin/bash
# Mira release build script
# Usage: API_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx ./scripts/build_release.sh
#
# Prerequisites (all satisfied as of v1.0.0):
#   1. Developer ID Application cert in Keychain  ✓ (team 7FD7W8SX34)
#   2. DEVELOPMENT_TEAM set in project.yml (Release config)  ✓
#   3. Generate Sparkle keys once: ./Sparkle/bin/generate_keys
#      → paste public key into project.yml SUPublicEDKey  ✓
#      → keep private key safe (Sparkle stores it in the login keychain; never commit it)
#   4. App Store Connect API key (default ~/Downloads/AuthKey_44WN756492.p8;
#      override with API_KEY / API_KEY_ID / API_ISSUER env vars)
#      Find Issuer ID: App Store Connect → Users and Access → Integrations → App Store Connect API
#
# After running:
#   1. Upload Mira-X.Y.Z.zip to GitHub Releases
#   2. Run: ./Sparkle/bin/generate_appcast . to regenerate appcast.xml with signature
#   3. Commit and push appcast.xml (on main branch — that's what SUFeedURL points to)

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
SCHEME="Mira"
DERIVED="build_release"
API_KEY="${API_KEY:-$HOME/Downloads/AuthKey_44WN756492.p8}"
API_KEY_ID="${API_KEY_ID:-44WN756492}"
API_ISSUER="${API_ISSUER:-37bf5512-2ca0-470e-ac5f-cb5dca0a086d}"

# ── Version from Info.plist ──────────────────────────────────────────────────
# Read the version directly from Info.plist — the project sets
# CFBundleShortVersionString/CFBundleVersion there, not via the
# MARKETING_VERSION/CURRENT_PROJECT_VERSION build settings (which are empty).
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Mira/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Mira/Info.plist)
TEAM=$(xcodebuild -project Mira.xcodeproj -scheme $SCHEME -configuration Release \
  -showBuildSettings 2>/dev/null | grep ' DEVELOPMENT_TEAM' | awk '{print $3}')

if [[ -z "$TEAM" || "$TEAM" == "YOUR_TEAM_ID_HERE" ]]; then
  echo "ERROR: Fill in DEVELOPMENT_TEAM in project.yml (Release config) before releasing."
  exit 1
fi

# Fail early if the matching Developer ID cert isn't in the keychain — otherwise
# the build burns minutes before the re-sign step fails.
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM)"; then
  echo "ERROR: No 'Developer ID Application' cert for team $TEAM in the keychain."
  exit 1
fi

echo "▶ Building Mira $VERSION ($BUILD) for team $TEAM"

# ── Generate project ─────────────────────────────────────────────────────────
xcodegen generate

# ── Build Release ────────────────────────────────────────────────────────────
xcodebuild \
  -project Mira.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  clean build

APP="$DERIVED/Build/Products/Release/Mira.app"
ZIP="Mira-$VERSION.zip"
SIGN_ID="Developer ID Application: Trevon Barbour ($TEAM)"
ENTITLEMENTS="Mira/Mira.entitlements"

# ── Re-sign Sparkle nested binaries ──────────────────────────────────────────
# Sparkle ships pre-signed with its own cert from SPM; notarization requires
# every nested binary to be signed with YOUR Developer ID + secure timestamp.
# Sign innermost → outermost.
echo "▶ Re-signing Sparkle sub-components…"
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

# ── Embed the provisioning profile ───────────────────────────────────────────
# Authorizes restricted entitlements (Sign in with Apple) for this Developer ID
# app. The profile only carries the App ID; notarization validates the
# applesignin entitlement against the App ID's enabled capability. Verified
# Accepted by notarytool 2026-06-28.
PROFILE="Mira.provisionprofile"
if [ -f "$PROFILE" ]; then
  echo "▶ Embedding provisioning profile…"
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
else
  echo "WARNING: $PROFILE not found — Sign in with Apple will fail to notarize."
fi

# ── Re-sign main app with clean entitlements (strips injected get-task-allow) ─
echo "▶ Re-signing Mira.app…"
codesign --force --sign "$SIGN_ID" --timestamp --options=runtime \
  --entitlements "$ENTITLEMENTS" "$APP"

# ── Verify code signature (pre-notarization) ─────────────────────────────────
echo "▶ Verifying signature…"
codesign --verify --deep --strict "$APP" \
  || { echo "ERROR: Code signature verification failed."; exit 1; }

# ── Zip (for Sparkle appcast) ────────────────────────────────────────────────
echo "▶ Packaging $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# ── Notarize zip ──────────────────────────────────────────────────────────────
echo "▶ Notarizing zip (this takes 1–5 minutes)…"
xcrun notarytool submit "$ZIP" \
  --key "$API_KEY" \
  --key-id "$API_KEY_ID" \
  --issuer "$API_ISSUER" \
  --wait

# ── Staple app + repackage zip ────────────────────────────────────────────────
echo "▶ Stapling…"
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

# ── DMG (for website download) ───────────────────────────────────────────────
DMG="Mira-$VERSION.dmg"
echo "▶ Creating ${DMG}..."
create-dmg \
  --volname "Mira" \
  --volicon "$APP/Contents/Resources/AppIcon.icns" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 128 \
  --icon "Mira.app" 160 185 \
  --hide-extension "Mira.app" \
  --app-drop-link 440 185 \
  "$DMG" "$APP"

# Sign the DMG itself before notarizing. Without this the disk image has no code
# signature, so even after notarize+staple `spctl -a -t open` reports "no usable
# signature" and a downloaded .dmg can trip Gatekeeper. Sign → notarize → staple.
echo "▶ Signing $DMG…"
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"

echo "▶ Notarizing $DMG…"
xcrun notarytool submit "$DMG" \
  --key "$API_KEY" \
  --key-id "$API_KEY_ID" \
  --issuer "$API_ISSUER" \
  --wait

echo "▶ Stapling $DMG…"
xcrun stapler staple "$DMG"

echo ""
echo "✅  $ZIP (Sparkle) and $DMG (website) are ready."
echo ""
echo "Next steps:"
echo "  1. Upload $ZIP to GitHub → Releases → v$VERSION"
echo "  2. Run: ./Sparkle/bin/generate_appcast . > appcast.xml"
echo "     (needs the Sparkle private key in ~/.sparkle_private_key)"
echo "  3. git add appcast.xml && git commit -m 'chore: update appcast for $VERSION' && git push"
echo "  4. Create the GitHub Release tag v$VERSION"
