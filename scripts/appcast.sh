#!/bin/bash
# Regenerates appcast.xml — the Sparkle update feed — from the release archives
# in appcast-archives/. Each archive is signed with the EdDSA private key stored
# in your login Keychain (created once with Sparkle's `generate_keys`). The feed
# is copied to the repo root and, once committed + pushed to `main`, is served at
# the app's SUFeedURL (raw.githubusercontent.com/.../main/appcast.xml).
#
# Each version's DMG is hosted on its OWN normal GitHub release (tag vX.Y.Z) — so
# users get one-click "latest" downloads and changelog notes — and the feed points
# at those per-version assets. generate_appcast only accepts one constant
# --download-url-prefix, so we generate with a placeholder path segment and then
# rewrite each enclosure to its release URL using the version embedded in the
# filename (ClaudeBar-<version>.dmg). Signatures are over file content, not URLs,
# so the rewrite is safe.
#
# See RELEASING.md for the full per-release flow.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHIVES="${ARCHIVES:-appcast-archives}"
RELEASE_BASE="${RELEASE_BASE:-https://github.com/nerlichman/claudebar/releases/download}"
PLACEHOLDER="$RELEASE_BASE/_ver_/"

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

echo "generating appcast from $ARCHIVES/"
# --maximum-deltas 0: we don't ship delta updates (pointless for a ~2 MB app),
# and a .delta enclosure wouldn't match the vX.Y.Z rewrite below. Without this,
# generate_appcast emits a .delta between archive pairs once 2+ versions exist.
"$GEN" --maximum-deltas 0 --download-url-prefix "$PLACEHOLDER" "$ARCHIVES"

# Point each enclosure at its per-version release asset, normalizing whatever
# path segment generate_appcast emitted/preserved (the _ver_ placeholder, or an
# older one) to vX.Y.Z based on the version in the filename:
#   …/releases/download/<anything>/ClaudeBar-0.1.2.dmg
#   → …/releases/download/v0.1.2/ClaudeBar-0.1.2.dmg
sed -E "s#/releases/download/[^/]+/ClaudeBar-([0-9][0-9.]*)\.dmg#/releases/download/v\1/ClaudeBar-\1.dmg#g" \
  "$ARCHIVES/appcast.xml" > appcast.xml

# Sanity: every download URL must now be a per-version (vX.Y.Z) release asset.
if grep -oE 'https://[^"]*/releases/download/[^"]+' appcast.xml | grep -vqE '/releases/download/v[0-9]'; then
  echo "error: an enclosure URL isn't a vX.Y.Z release asset — archives must be named ClaudeBar-<version>.dmg" >&2
  rm -f appcast.xml
  exit 1
fi

echo "✓ wrote appcast.xml — commit + push to main to publish the update feed."
