#!/bin/bash
# Regenerates appcast.xml — the Sparkle update feed — from the release archives
# in appcast-archives/. Each archive is signed with the EdDSA private key stored
# in your login Keychain (created once with Sparkle's `generate_keys`). The feed
# is copied to the repo root and, once committed + pushed to `main`, is served at
# the app's SUFeedURL (raw.githubusercontent.com/.../main/appcast.xml).
#
# Per-release flow:
#   1. bump the version (Info.plist CFBundleShortVersionString + CFBundleVersion,
#      and the log line in ClaudeBarApp.swift). CFBundleVersion MUST increase.
#   2. CODESIGN_IDENTITY="Developer ID Application: …" make dist   # build/ClaudeBar.dmg
#   3. cp build/ClaudeBar.dmg appcast-archives/ClaudeBar-<version>.dmg
#   4. upload that DMG to the GitHub release it will be downloaded from
#      (see DOWNLOAD_URL_PREFIX below), e.g.:
#        gh release upload appcast appcast-archives/ClaudeBar-<version>.dmg
#   5. make appcast                                               # regenerate appcast.xml
#   6. git add appcast.xml && git commit -m "Release <version>" && git push   # go live
#
# generate_appcast builds each enclosure URL as <DOWNLOAD_URL_PREFIX><filename>,
# so every DMG must be downloadable from that one stable base. Hosting all
# versions under a single GitHub release (tag `appcast`) keeps the prefix
# constant and lets Sparkle compute delta updates. Override the base or archive
# dir via env vars if you host elsewhere.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHIVES="${ARCHIVES:-appcast-archives}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/nerlichman/claudebar/releases/download/appcast/}"

GEN=$(find .build/artifacts -type f -name generate_appcast -not -path '*/extract/*' 2>/dev/null | head -1)
if [ -z "$GEN" ]; then
  echo "error: generate_appcast not found under .build/artifacts — run 'swift build' first" >&2
  exit 1
fi
if [ -z "$(find "$ARCHIVES" \( -name '*.dmg' -o -name '*.zip' \) 2>/dev/null)" ]; then
  echo "error: no .dmg/.zip archives in $ARCHIVES/ — stage your release DMG there first:" >&2
  echo "  cp build/ClaudeBar.dmg $ARCHIVES/ClaudeBar-<version>.dmg" >&2
  exit 1
fi

echo "generating appcast from $ARCHIVES/ (download prefix: $DOWNLOAD_URL_PREFIX)"
"$GEN" --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$ARCHIVES"

cp "$ARCHIVES/appcast.xml" appcast.xml
echo "✓ wrote appcast.xml — commit + push to main to publish the update feed."
