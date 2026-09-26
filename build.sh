#!/bin/zsh
# 编译 WorkBuddyTouchBar.app
set -e
cd "$(dirname "$0")"

APP_NAME="WorkBuddyTouchBar"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

mkdir -p "$APP_DIR/Contents/MacOS"

swiftc -O -swift-version 5 Sources/main.swift \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
  -framework AppKit -framework ServiceManagement

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>local.user.workbuddy-touchbar</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true
echo "Build OK: $APP_DIR"
