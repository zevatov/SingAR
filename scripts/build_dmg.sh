#!/bin/bash
# Builds SingAR.app (Release) and packages it into a drag-and-drop DMG
# ("SingAR 2.1 beta.dmg") at the repo root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="SingAR"
VERSION="2.1-beta"
DMG_TITLE="SingAR 2.1 beta"
DMG_PATH="$ROOT/SingAR 2.1 beta.dmg"
BUILD_DIR="$ROOT/build"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
TEMP_STAGING=$(mktemp -d /tmp/singar-dmg-staging.XXXXXX)

echo "==> Building Release configuration via Swift PM..."
swift build -c release

RELEASE_BIN=$(swift build -c release --show-bin-path)/$APP_NAME

if [ ! -f "$RELEASE_BIN" ]; then
    echo "ERROR: Release binary $RELEASE_BIN not found" >&2
    exit 1
fi

echo "==> Assembling $APP_NAME.app bundle..."
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

cp "$RELEASE_BIN" "$APP_PATH/Contents/MacOS/$APP_NAME"
chmod +x "$APP_PATH/Contents/MacOS/$APP_NAME"

# Create Info.plist
cat << 'EOF' > "$APP_PATH/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>SingAR</string>
    <key>CFBundleIdentifier</key>
    <string>com.singar.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SingAR</string>
    <key>CFBundleDisplayName</key>
    <string>SingAR</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.1-beta</string>
    <key>CFBundleVersion</key>
    <string>2.1-beta</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>SingAR требует доступ к микрофону для записи речи и голосовой диктовки.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>SingAR использует распознавание речи для транскрипции вашего голоса в текст.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>SingAR требует доступ для автоматической вставки распознанного текста.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "==> Cleaning extended attributes..."
xattr -cr "$APP_PATH" 2>/dev/null || true

echo "==> Signing the bundle (ad-hoc, hardened runtime with entitlements and stable identifier)..."
codesign --force --deep --sign - --identifier "com.singar.app" --requirement '=designated => identifier "com.singar.app"' --entitlements "$ROOT/Resources/SingAR.entitlements" --options runtime "$APP_PATH"

echo "==> Verifying signature..."
codesign --verify --deep --strict "$APP_PATH"

echo "==> App size:"
du -sh "$APP_PATH"

echo "==> Staging drag-and-drop folder in ${TEMP_STAGING}..."
cp -R "$APP_PATH" "${TEMP_STAGING}/"
ln -s /Applications "${TEMP_STAGING}/Applications"

echo "==> Creating DMG: $DMG_PATH..."
rm -f "$DMG_PATH"
hdiutil create -volname "$DMG_TITLE" \
    -srcfolder "${TEMP_STAGING}" \
    -ov -format UDZO \
    "$DMG_PATH"

echo "==> Cleaning temporary staging folder..."
rm -rf "${TEMP_STAGING}"

echo "==> Done: $DMG_PATH"
ls -lh "$DMG_PATH"
