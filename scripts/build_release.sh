#!/bin/bash
# Mira release build script
# Usage: APPLE_ID=you@email.com NOTARIZATION_PASSWORD=xxxx-xxxx-xxxx-xxxx ./scripts/build_release.sh
#
# Prerequisites:
#   1. Developer ID Application cert in Keychain
#   2. Fill in DEVELOPMENT_TEAM in project.yml (Release config)
#   3. Generate Sparkle keys once: ./Sparkle/bin/generate_keys
#      → paste public key into project.yml SUPublicEDKey
#      → keep private key safe (never commit it)
#
# After running:
#   1. Upload Mira-X.Y.Z.zip to GitHub Releases
#   2. Run: ./Sparkle/bin/generate_appcast . to regenerate appcast.xml with signature
#   3. Commit and push appcast.xml (on main branch — that's what SUFeedURL points to)

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
SCHEME="Mira"
DERIVED="build_release"
APPLE_ID="${APPLE_ID:?Set APPLE_ID env var}"
NOTARIZATION_PASSWORD="${NOTARIZATION_PASSWORD:?Set NOTARIZATION_PASSWORD env var}"

# ── Version from Info.plist ──────────────────────────────────────────────────
VERSION=$(xcodebuild -project Mira.xcodeproj -scheme $SCHEME -configuration Release \
  -showBuildSettings 2>/dev/null | grep 'MARKETING_VERSION' | awk '{print $3}')
BUILD=$(xcodebuild -project Mira.xcodeproj -scheme $SCHEME -configuration Release \
  -showBuildSettings 2>/dev/null | grep 'CURRENT_PROJECT_VERSION' | awk '{print $3}')
TEAM=$(xcodebuild -project Mira.xcodeproj -scheme $SCHEME -configuration Release \
  -showBuildSettings 2>/dev/null | grep 'DEVELOPMENT_TEAM' | awk '{print $3}')

if [[ "$TEAM" == "YOUR_TEAM_ID_HERE" ]]; then
  echo "ERROR: Fill in DEVELOPMENT_TEAM in project.yml (Release config) before releasing."
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

# ── Zip ───────────────────────────────────────────────────────────────────────
echo "▶ Packaging $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# ── Notarize ──────────────────────────────────────────────────────────────────
echo "▶ Notarizing (this takes 1–5 minutes)…"
xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_ID" \
  --password "$NOTARIZATION_PASSWORD" \
  --team-id "$TEAM" \
  --wait

# ── Staple ────────────────────────────────────────────────────────────────────
echo "▶ Stapling…"
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo ""
echo "✅  $ZIP is ready."
echo ""
echo "Next steps:"
echo "  1. Upload $ZIP to GitHub → Releases → v$VERSION"
echo "  2. Run: ./Sparkle/bin/generate_appcast . > appcast.xml"
echo "     (needs the Sparkle private key in ~/.sparkle_private_key)"
echo "  3. git add appcast.xml && git commit -m 'chore: update appcast for $VERSION' && git push"
echo "  4. Create the GitHub Release tag v$VERSION"
