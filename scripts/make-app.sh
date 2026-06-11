#!/bin/bash
# Assembles build/ClaudeBar.app from the SwiftPM release build and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/ClaudeBar.app
BUNDLE_ID=dev.gogrow.claudebar

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeBar "$APP/Contents/MacOS/ClaudeBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
echo "Built $APP"
