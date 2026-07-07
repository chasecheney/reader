#!/bin/bash
# make_dmg.sh — package the notarized Story Reader.app into a distributable DMG.
#
# Usage:  ./make_dmg.sh "/path/to/Story Reader.app" 1.0
#
# Prereqs (one time):
#   brew install create-dmg
#   A notarytool keychain profile. Credentials are ACCOUNT-level, not
#   per-app — if you already stored one for another app (e.g. MP4ToolsPlus),
#   reuse it:   NOTARY_PROFILE=yourprofile ./make_dmg.sh ...
#   Otherwise create one:
#   xcrun notarytool store-credentials storyreader \
#       --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
#   (password = an app-specific password from account.apple.com)
#
# The .app must already be Developer ID-signed and notarized
# (Xcode Organizer -> Distribute App -> Direct Distribution).

set -euo pipefail

APP="${1:?usage: make_dmg.sh /path/to/Story\ Reader.app VERSION}"
VER="${2:?usage: make_dmg.sh /path/to/Story\ Reader.app VERSION}"
NAME="StoryReader-${VER}"
DMG="${NAME}.dmg"
IDENTITY="Developer ID Application"   # narrows to your single Developer ID cert
PROFILE="${NOTARY_PROFILE:-storyreader}"   # notarytool keychain profile (override via env)

echo "==> Verifying the app is notarized..."
xcrun stapler validate "$APP" || {
  echo "App is not stapled/notarized. Export it via Organizer -> Direct Distribution first."
  exit 1
}

echo "==> Building ${DMG}..."
rm -f "$DMG"
create-dmg \
  --volname "Story Reader" \
  --window-size 560 380 \
  --icon-size 128 \
  --icon "$(basename "$APP")" 140 180 \
  --app-drop-link 420 180 \
  --hide-extension "$(basename "$APP")" \
  "$DMG" "$APP"

echo "==> Signing the DMG..."
codesign --force --sign "$IDENTITY" "$DMG"

echo "==> Notarizing the DMG (waits for Apple)..."
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> Stapling the ticket..."
xcrun stapler staple "$DMG"

echo "==> Verifying..."
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"

shasum -a 256 "$DMG" | tee "${DMG}.sha256"
echo "==> Done: ${DMG} (checksum in ${DMG}.sha256)"
