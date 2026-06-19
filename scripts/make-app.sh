#!/bin/bash
# Assembles build/ClaudeBar.app from the SwiftPM release build and signs it.
# Signing with a real Apple Development identity keeps the app's code-signing
# identity stable across rebuilds (TCC/Keychain grants survive) and lets
# UNUserNotificationCenter deliver native banners. Falls back to ad-hoc when
# the identity isn't in the keychain. Override with CODESIGN_IDENTITY.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/ClaudeBar.app
BUNDLE_ID=com.nerlichman.claudebar
IDENTITY="${CODESIGN_IDENTITY:-Apple Development: nicolaserlichman@gmail.com (V5A2LD3ZA4)}"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  echo "warning: identity '$IDENTITY' not found, ad-hoc signing instead" >&2
  IDENTITY="-"
fi

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
# Bundle the Claude Code hook scripts so the app can install them itself
# (gear menu) — keeps a shared .dmg fully functional without the repo.
cp scripts/statusline-hook.sh scripts/claudebar-hook.sh "$APP/Contents/Resources/"

codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
echo "Built $APP (signed: $IDENTITY)"
