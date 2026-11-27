#!/bin/bash
# Usage: scripts/bundle.sh
# Builds Squats and wraps it in a signed build/Squats.app.
set -euo pipefail

NAME=Squats
cd "$(dirname "$0")/.."
# UNIVERSAL=1 also builds for Intel Macs. Slower; used for the release download.
ARCHS=${UNIVERSAL:+--arch arm64 --arch x86_64}
swift build -c release --product "$NAME" $ARCHS

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release $ARCHS --show-bin-path)/$NAME" "$APP/Contents/MacOS/$NAME"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # redraw with: swift scripts/make-icon.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.fakhrillo.squats</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCameraUsageDescription</key><string>Squats uses the camera only while you are doing a set, to count your squats. Nothing is recorded or sent.</string>
</dict>
</plist>
PLIST

# Sign with a development certificate so camera and notification permissions survive rebuilds.
# Without one: SIGN_IDENTITY=- scripts/bundle.sh (ad hoc).
codesign --force --sign "${SIGN_IDENTITY:-Apple Development}" "$APP"
echo "$APP"
