#!/bin/bash
# Builds SingAR.app (Release) and packages it into a drag-and-drop DMG
# at the repo root (e.g. "SingAR 2.2.4.dmg").
#
# GitHub ad-hoc distribution path (conscious decision, no Developer ID / notarization
# per owner condition):
#   - codesign --sign - (ad-hoc) with hardened runtime + entitlements, stable identifier.
#   - --timestamp is intentionally OMITTED: Apple timestamp server applies only to
#     Developer ID signatures; with ad-hoc (`-`) it is not applicable.
#   - Verify: codesign --verify --deep --strict (fatal) + spctl -a (informational only:
#     without notarization spctl reports rejection — expected for GitHub ad-hoc).
#   - SHA256 checksum is written next to the DMG for manual verification.
#   - Previous DMG (+ .sha256) is preserved as *.prev.dmg for rollback.
#
# Single source of truth for version: Sources/SingAR/Config/AppVersion.swift
#   (`static let current`). No hardcoded fallback — script FAILS if version is missing.
#   CFBundleShortVersionString / CFBundleVersion / DMG_PATH / DMG_TITLE are all
#   derived from that single VERSION variable.
#
# Usage:
#   ./scripts/build_dmg.sh [--dry-run] [--require-tag] [--help]
#     --dry-run      Validate version/entitlements/git-tag without building (for CI).
#     --require-tag  Fail if git tag v<VERSION> does not exist (CI release gate).
#     --help         Print this help.
set -euo pipefail

DRY_RUN=0
REQUIRE_TAG=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --require-tag) REQUIRE_TAG=1 ;;
        --help|-h)
            sed -n '1,30p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $arg (see --help)" >&2
            exit 1
            ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BIN_NAME="SingAR"
APPVERSION_FILE="$ROOT/Sources/SingAR/Config/AppVersion.swift"
ENTITLEMENTS="$ROOT/Resources/SingAR.entitlements"

# --- Single source of truth: AppVersion.current, no fallback ---
VERSION=$(grep 'static let current' "$APPVERSION_FILE" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/' || true)
if [ -z "${VERSION:-}" ]; then
    echo "ERROR: version not found in $APPVERSION_FILE (static let current). Refusing to use hardcoded fallback." >&2
    exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: version '$VERSION' from AppVersion.current is not SemVer X.Y.Z" >&2
    exit 1
fi
echo "==> Version source: AppVersion.current = $VERSION (single source of truth)"

APP_BUNDLE_NAME="SingAR $VERSION.app"
DMG_TITLE="SingAR $VERSION"
DMG_PATH="$ROOT/SingAR $VERSION.dmg"
SHA_PATH="$DMG_PATH.sha256"
BUILD_DIR="$ROOT/build"
APP_PATH="$BUILD_DIR/$APP_BUNDLE_NAME"
TEMP_STAGING=$(mktemp -d /tmp/singar-dmg-staging.XXXXXX)
trap 'rm -rf "${TEMP_STAGING}"' EXIT

# --- Git-tag check (release hygiene, non-fatal unless --require-tag) ---
if git rev-parse --git-dir >/dev/null 2>&1; then
    if git tag --list | grep -qx "v$VERSION"; then
        echo "==> Git tag check: v$VERSION exists."
    else
        MSG="WARNING: git tag v$VERSION not found (expected release tag for AppVersion.current=$VERSION). Create it with: git tag v$VERSION && git push origin v$VERSION"
        if [ "$REQUIRE_TAG" -eq 1 ]; then
            echo "ERROR: $MSG" >&2
            exit 1
        else
            echo "$MSG" >&2
        fi
    fi
else
    echo "WARNING: not a git checkout — skipping git-tag check." >&2
fi

if [ ! -f "$ENTITLEMENTS" ]; then
    echo "ERROR: entitlements not found: $ENTITLEMENTS" >&2
    exit 1
fi
echo "==> Entitlements: $ENTITLEMENTS (minimal set: audio-input, speech-recognition, network.client)"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "==> DRY-RUN OK: version=$VERSION, bundle=$APP_BUNDLE_NAME, dmg=$(basename "$DMG_PATH"), entitlements present, git-tag checked."
    echo "==> DRY-RUN: CFBundleShortVersionString=$VERSION, CFBundleVersion=$VERSION, DMG_PATH derived from single source."
    exit 0
fi

echo "==> Building Release configuration via Swift PM (v$VERSION)..."
swift build -c release

RELEASE_BIN=$(swift build -c release --show-bin-path)/$BIN_NAME

if [ ! -f "$RELEASE_BIN" ]; then
    echo "ERROR: Release binary $RELEASE_BIN not found" >&2
    exit 1
fi

echo "==> Assembling $APP_BUNDLE_NAME bundle (v$VERSION)..."
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

cp "$RELEASE_BIN" "$APP_PATH/Contents/MacOS/$BIN_NAME"
chmod +x "$APP_PATH/Contents/MacOS/$BIN_NAME"

# Create Info.plist with interpolated version (single source: $VERSION)
cat << EOF > "$APP_PATH/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$BIN_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.singar.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SingAR $VERSION</string>
    <key>CFBundleDisplayName</key>
    <string>SingAR $VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
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

echo "==> Signing the bundle (ad-hoc GitHub path: no Developer ID / notarization per owner)..."
echo "    NOTE: --timestamp omitted intentionally (Developer ID only, not applicable to ad-hoc '-')."
codesign --force --deep --sign - --identifier "com.singar.app" --requirement '=designated => identifier "com.singar.app"' --entitlements "$ENTITLEMENTS" --options runtime "$APP_PATH"

echo "==> Verifying signature (fatal)..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dv --verbose=4 "$APP_PATH" 2>&1 | head -20 || true

echo "==> spctl assessment (informational only — without notarization rejection is EXPECTED for ad-hoc)..."
spctl -a -t exec -vv "$APP_PATH" || echo "INFO: spctl rejected as expected for ad-hoc without notarization (see README Gatekeeper section)."

echo "==> App size:"
du -sh "$APP_PATH"

echo "==> Staging drag-and-drop folder in ${TEMP_STAGING}..."
cp -R "$APP_PATH" "${TEMP_STAGING}/"
ln -s /Applications "${TEMP_STAGING}/Applications"

# --- Preserve previous DMG for rollback ---
if [ -f "$DMG_PATH" ]; then
    PREV_DMG="${DMG_PATH%.dmg}.prev.dmg"
    echo "==> Preserving previous DMG for rollback: $PREV_DMG"
    mv -f "$DMG_PATH" "$PREV_DMG"
    if [ -f "$SHA_PATH" ]; then
        mv -f "$SHA_PATH" "${PREV_DMG}.sha256"
    fi
fi

echo "==> Creating DMG: $DMG_PATH..."
hdiutil create -volname "$DMG_TITLE" \
    -srcfolder "${TEMP_STAGING}" \
    -ov -format UDZO \
    "$DMG_PATH"

echo "==> Generating SHA256 checksum next to artifact..."
shasum -a 256 "$DMG_PATH" | tee "$SHA_PATH"

echo "==> Done: $DMG_PATH"
ls -lh "$DMG_PATH" "$SHA_PATH"
echo "==> Rollback: previous DMG (if any) kept as '${DMG_PATH%.dmg}.prev.dmg'. Revert via: mv -f '${DMG_PATH%.dmg}.prev.dmg' '$DMG_PATH'"
