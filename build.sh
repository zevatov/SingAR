#!/bin/bash
# Build SingAR into a signed .app bundle.
# Usage: ./build.sh [release]
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="debug"
if [[ "${1:-}" == "release" ]]; then
    CONFIG="release"
fi

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BUILD_DIR=".build/$CONFIG"
EXEC="$BUILD_DIR/singar"
[[ -x "$EXEC" ]] || EXEC="$BUILD_DIR/SingAR"

APP="build/SingAR.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$EXEC" "$APP/Contents/MacOS/SingAR"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

# Whisper model: bundle if present so the app works standalone.
if [[ -f "models/ggml-large-v3-turbo.bin" ]]; then
    mkdir -p "$APP/Contents/Resources/models"
    cp "models/ggml-large-v3-turbo.bin" "$APP/Contents/Resources/models/"
    echo "    bundled model (turbo, 1.5GB)"
elif [[ -f "models/ggml-large-v3.bin" ]]; then
    mkdir -p "$APP/Contents/Resources/models"
    cp "models/ggml-large-v3.bin" "$APP/Contents/Resources/models/"
    echo "    bundled model (large-v3)"
fi

# Sign with a STABLE identifier so TCC permissions persist. Clear xattr first
# (resource forks break code signing). Ad-hoc signing keys TCC to cdhash, so
# the app must be installed in a stable path (/Applications) and not rebuilt
# after permissions are granted.
echo "==> clearing xattr + code signing (identifier: app.singar)"
xattr -cr "$APP"
codesign --force --sign - --identifier app.singar "$APP"

echo "==> verifying signature"
codesign --verify --verbose "$APP" 2>&1 | head -1
codesign -dv "$APP" 2>&1 | grep -iE "identifier|sealed" | head -2

echo "==> built $APP ($(du -sh "$APP" | cut -f1))"
echo ""
if [[ "$CONFIG" == "release" ]]; then
    echo "Run: open $APP"
    echo "Or install to /Applications: cp -R $APP /Applications/"
fi
