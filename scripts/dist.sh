#!/bin/bash
# Produces a signed, notarized, stapled build/ClaudeBar.dmg ready to ship.
#
# Requires:
#   CODESIGN_IDENTITY  a "Developer ID Application: …" identity in your keychain
#                      (Apple Development certs cannot be notarized).
#   NOTARY_PROFILE     a notarytool keychain profile (default: claudebar-notary),
#                      created once with:
#                        xcrun notarytool store-credentials claudebar-notary \
#                          --apple-id <id> --team-id <team> --password <app-specific-pw>
#
# Usage:
#   CODESIGN_IDENTITY="Developer ID Application: Your Co (TEAMID)" make dist
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/ClaudeBar.app
DMG=build/ClaudeBar.dmg
ZIP=build/ClaudeBar.zip
NOTARY_PROFILE="${NOTARY_PROFILE:-claudebar-notary}"

# --- preflight ---------------------------------------------------------------
: "${CODESIGN_IDENTITY:?set CODESIGN_IDENTITY to your 'Developer ID Application: …' identity}"
case "$CODESIGN_IDENTITY" in
  "Developer ID"*) ;;
  *) echo "error: dist needs a Developer ID identity, got: $CODESIGN_IDENTITY" >&2; exit 1 ;;
esac
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CODESIGN_IDENTITY"; then
  echo "error: identity not in keychain: $CODESIGN_IDENTITY" >&2; exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "error: notary profile '$NOTARY_PROFILE' not found or invalid. Create it with:" >&2
  echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <id> --team-id <team> --password <app-specific-pw>" >&2
  exit 1
fi

# notarytool needs an archive: zip a .app, submit a .dmg as-is. Staple the
# original target so the ticket travels with it (offline-robust first launch).
notarize_and_staple() {
  local target="$1" submission="$1"
  if [[ "$target" == *.app ]]; then
    rm -f "$ZIP"
    ditto -c -k --keepParent "$target" "$ZIP"
    submission="$ZIP"
  fi
  echo "notarizing $submission …"
  xcrun notarytool submit "$submission" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$target"
}

# --- pipeline ----------------------------------------------------------------
# 1. Build + sign the app (make-app.sh adds hardened runtime + timestamp for a
#    Developer ID identity), then sanity-check the signature.
export CODESIGN_IDENTITY
./scripts/make-app.sh
codesign --verify --deep --strict --verbose=2 "$APP"

# 2. Notarize + staple the app.
notarize_and_staple "$APP"

# 3. Assemble + sign the DMG from the stapled app.
./scripts/make-dmg.sh

# 4. Notarize + staple the DMG.
notarize_and_staple "$DMG"

# 5. Verify exactly what a user's Mac will check.
echo "=== verification ==="
spctl -a -vvv "$APP"
spctl -a -t open --context context:primary-signature -vvv "$DMG"
echo ""
echo "✓ $DMG is signed, notarized, and stapled."
echo "  sha256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
