#!/bin/bash
# Assembles build/ClaudeBar.app from the SwiftPM release build and signs it.
# Signing with a real Apple Development identity keeps the app's code-signing
# identity stable across rebuilds (TCC/Keychain grants survive) and lets
# UNUserNotificationCenter deliver native banners. Falls back to ad-hoc when
# the identity isn't in the keychain. Override with CODESIGN_IDENTITY.
#
# When CODESIGN_IDENTITY names a "Developer ID Application" identity, the app
# is signed with the hardened runtime and a secure timestamp so it can be
# notarized — that's the distribution path driven by `make dist`.
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

# Embed Sparkle.framework. SwiftPM links Sparkle as a binary XCFramework but
# doesn't copy it into a hand-assembled .app, so we do it here — otherwise the
# app can't dynamically load Sparkle at launch. The framework lives in the SPM
# artifacts dir (path includes the macOS arch slice).
# Skip the transient */extract/* staging copy SwiftPM leaves behind; use the
# resolved artifact under .build/artifacts/sparkle/.
FRAMEWORK=$(find .build/artifacts -type d -name Sparkle.framework -path '*macos*' -not -path '*/extract/*' 2>/dev/null | head -1)
if [ -z "$FRAMEWORK" ]; then
  echo "error: Sparkle.framework not found under .build/artifacts — run 'swift build' first" >&2
  exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
# Teach the executable to find the embedded framework at runtime. SwiftPM links
# it as @rpath/Sparkle.framework/..., so the app needs this search path.
if ! otool -l "$APP/Contents/MacOS/ClaudeBar" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/ClaudeBar"
fi

# Sign inside-out. `codesign --deep` is discouraged and won't apply the
# hardened runtime to Sparkle's nested helpers the way notarization requires,
# so each component is signed bottom-up (nested code before its container).
# Distribution builds (Developer ID) add the hardened runtime + a secure
# timestamp; local dev/ad-hoc signing skips both (timestamping needs a real
# cert and network access).
SIGN_OPTS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" == "Developer ID"* ]]; then
  SIGN_OPTS+=(--options runtime --timestamp)
fi

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${SIGN_OPTS[@]}" "$SPARKLE/XPCServices/Downloader.xpc"
codesign "${SIGN_OPTS[@]}" "$SPARKLE/XPCServices/Installer.xpc"
codesign "${SIGN_OPTS[@]}" "$SPARKLE/Updater.app"
codesign "${SIGN_OPTS[@]}" "$SPARKLE/Autoupdate"
codesign "${SIGN_OPTS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
# App last; it carries the bundle identifier.
codesign "${SIGN_OPTS[@]}" --identifier "$BUNDLE_ID" "$APP"
echo "Built $APP (signed: $IDENTITY)"
