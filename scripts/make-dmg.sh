#!/bin/bash
# Assembles build/ClaudeBar.dmg (drag-to-Applications) from an already-built
# build/ClaudeBar.app. Run `make app` first.
#
# When CODESIGN_IDENTITY names a "Developer ID Application" identity, the disk
# image itself is signed (with a secure timestamp) so the download is trusted;
# `make dist` then notarizes and staples it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/ClaudeBar.app
DMG=build/ClaudeBar.dmg
TMP=build/ClaudeBar-tmp.dmg
STAGE=build/dmg

[ -d "$APP" ] || { echo "error: $APP not found — run 'make app' first" >&2; exit 1; }

rm -rf "$STAGE" "$DMG" "$TMP"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/ClaudeBar.app"
ln -s /Applications "$STAGE/Applications"
# Build the image directly from the staging folder, never mounting a volume.
# `hdiutil create -srcfolder` mounts /Volumes/ClaudeBar to copy files in, which
# macOS TCC blocks unless the invoking terminal has Full Disk Access. makehybrid
# writes the filesystem straight from the folder and convert compresses it —
# neither mounts, so no Full Disk Access is required.
hdiutil makehybrid -hfs -hfs-volume-name ClaudeBar -o "$TMP" "$STAGE"
hdiutil convert "$TMP" -format UDZO -o "$DMG"
rm -f "$TMP"
rm -rf "$STAGE"

if [[ "${CODESIGN_IDENTITY:-}" == "Developer ID"* ]]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
  echo "Signed $DMG ($CODESIGN_IDENTITY)"
fi
echo "Built $DMG"
