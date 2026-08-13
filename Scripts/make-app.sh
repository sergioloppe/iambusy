#!/bin/bash
# Build IAmBusy.app and a distributable zip. No Developer ID signing --
# the bundle gets an ad-hoc signature only, so recipients must approve it
# once (right-click -> Open) or strip quarantine. See README.
#
# Usage: Scripts/make-app.sh [version]        (default: 0.1.0)

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
APP_NAME="IAmBusy"
EXECUTABLE="Busy"
BUNDLE_ID="io.kadmos.iambusy"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building release binary (universal)"
if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
    BINARY=".build/apple/Products/Release/$EXECUTABLE"
else
    echo "    universal build unavailable, falling back to native arch"
    swift build -c release
    BINARY=".build/release/$EXECUTABLE"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$EXECUTABLE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" > /dev/null

echo "==> Ad-hoc signing (no Developer ID)"
codesign --force --sign - "$APP"

echo "==> Zipping"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Done"
echo "    app: $APP"
echo "    zip: $ZIP"
