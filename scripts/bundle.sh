#!/bin/bash
# Usage: scripts/bundle.sh <Squats|PoseSpike>
# Builds the target and wraps it in a signed build/<name>.app.
set -euo pipefail

NAME="${1:-}"
case "$NAME" in
  Squats)    ID=local.squats;       UIELEMENT=true ;;
  PoseSpike) ID=local.squats.spike; UIELEMENT=false ;;
  *) echo "usage: scripts/bundle.sh <Squats|PoseSpike>" >&2; exit 1 ;;
esac

cd "$(dirname "$0")/.."
swift build -c release --product "$NAME"

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/$NAME" "$APP/Contents/MacOS/$NAME"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><$UIELEMENT/>
  <key>NSCameraUsageDescription</key><string>Squats uses the camera only while you are doing a set, to count your squats. Nothing is recorded or sent.</string>
</dict>
</plist>
EOF

codesign --force --sign "Apple Development" "$APP"
echo "$APP"
