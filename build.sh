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
# Fall back to the target name casing if the lowercase isn't present.
[[ -x "$EXEC" ]] || EXEC="$BUILD_DIR/SingAR"

APP="build/SingAR.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$EXEC" "$APP/Contents/MacOS/SingAR"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> built $APP"
echo "Run with: open $APP"
