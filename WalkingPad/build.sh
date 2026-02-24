#!/bin/bash
set -e

APP_NAME="WalkingPad"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

rm -rf "$BUILD_DIR"

mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp Info.plist "$APP_DIR/Contents/Info.plist"
cp AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

swiftc \
    -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
    -target arm64-apple-macosx13.0 \
    -parse-as-library \
    Sources/WalkingPad/App.swift \
    Sources/WalkingPad/BLEManager.swift \
    Sources/WalkingPad/Views.swift \
    -framework SwiftUI \
    -framework AppKit \
    -framework CoreBluetooth

# Codesign so macOS remembers Bluetooth permission
codesign --force --sign - "$APP_DIR"

echo "Built: $APP_DIR"
echo "Run with: open \"$APP_DIR\""
