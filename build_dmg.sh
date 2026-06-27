#!/bin/bash
# Build a DMG installer for SingAR (drag-to-Applications, like real macOS apps).
# Usage: ./build_dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

# Ensure the .app is built first.
if [[ ! -d "build/SingAR.app" ]]; then
    echo "==> building .app first"
    ./build.sh release >/dev/null
fi

APP="build/SingAR.app"
DMG="dist/SingAR-Installer.dmg"
STAGING="build/dmg-staging"

echo "==> preparing DMG staging area"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> creating DMG"
rm -rf dist && mkdir -p dist
# Create a read-write DMG, then convert to compressed read-only.
hdiutil create -volname "SingAR" \
    -srcfolder "$STAGING" \
    -ov -format UDBZ \
    "$DMG" 2>&1 | tail -3

echo "==> verifying DMG"
hdiutil verify "$DMG" 2>&1 | tail -2

echo ""
echo "==> DMG ready: $DMG ($(du -sh "$DMG" | cut -f1))"
echo "    Mount: open $DMG"
echo "    Then drag SingAR to Applications."
