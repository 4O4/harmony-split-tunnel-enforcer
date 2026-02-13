#!/bin/bash
set -euo pipefail

APP_NAME="Harmony Split Tunnel Enforcer"
BUNDLE_ID="net.rawbytes.harmony-split-tunnel-enforcer"
EXECUTABLE="HarmonySplitTunnelEnforcer"

# Set APP_VERSION env var to override CFBundleShortVersionString (default: 1.0.0)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building release..."
swift build -c release

BUILD_DIR=".build/release"
APP_DIR="${SCRIPT_DIR}/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "${BUILD_DIR}/${EXECUTABLE}" "${MACOS}/${EXECUTABLE}"

if [ -f "${SCRIPT_DIR}/AppIcon.icns" ]; then
    cp "${SCRIPT_DIR}/AppIcon.icns" "${RESOURCES}/AppIcon.icns"
    echo "Bundled AppIcon.icns"
fi

cat > "${CONTENTS}/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION:-1.0.0}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

echo "Done: ${APP_DIR}"
echo "To run: open '${APP_DIR}'"
echo "Or: '${MACOS}/${EXECUTABLE}'"
