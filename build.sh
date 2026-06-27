#!/bin/bash
# Build SingAR into a runnable .app bundle.
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
EXEC="$BUILD_DIR/singar"   # SwiftPM lowercases the executable name
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
    echo "    bundled model (turbo)"
elif [[ -f "models/ggml-large-v3.bin" ]]; then
    mkdir -p "$APP/Contents/Resources/models"
    cp "models/ggml-large-v3.bin" "$APP/Contents/Resources/models/"
    echo "    bundled model (large-v3)"
fi

# Optional: ad-hoc code sign so the bundle is recognised locally.
codesign --force --sign - --entitlements - "$APP/Contents/MacOS/SingAR" 2>/dev/null || true

echo "==> built $APP"
echo "Run with: open $APP"
echo ""
echo "Note: first run requires granting permissions in System Settings:"
echo "  - Privacy & Security → Microphone"
echo "  - Privacy & Security → Accessibility"
echo "  - Privacy & Security → Input Monitoring"
echo "And disable Apple dictation: System Settings → Keyboard → Dictation → Off"
