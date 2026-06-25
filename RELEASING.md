# Releasing ClaudeBar

ClaudeBar ships as a Developer ID–signed, notarized DMG, with in-app auto-updates
via [Sparkle](https://sparkle-project.org). Each version is a normal GitHub
release (`vX.Y.Z`) carrying the DMG + changelog; the Sparkle feed (`appcast.xml`,
served from `main`) points at those per-version release assets.

## One-time setup (already done)

- **Developer ID identity** in the login Keychain (`Developer ID Application: …`).
- **Notary profile** for `notarytool`:
  ```sh
  xcrun notarytool store-credentials claudebar-notary \
    --apple-id <id> --team-id <team> --password <app-specific-password>
  ```
- **Sparkle EdDSA signing key** in the login Keychain (`generate_keys` from
  Sparkle); its public half is `SUPublicEDKey` in `Resources/Info.plist`.

No Full Disk Access is required — the DMG is built with `hdiutil makehybrid`,
which never mounts a volume.

## Per-release steps

Releasing, e.g., `0.1.3`:

1. **Bump the version** in three places, then commit:
   - `Resources/Info.plist` → `CFBundleShortVersionString` (`0.1.3`) **and**
     `CFBundleVersion` (must strictly increase — Sparkle keys on it).
   - `Sources/ClaudeBar/ClaudeBarApp.swift` → the `"ClaudeBar launched (version …)"`
     log line.
   ```sh
   git commit -am "Bump version to 0.1.3"
   ```

2. **Build the signed + notarized DMG:**
   ```sh
   CODESIGN_IDENTITY="Developer ID Application: GoGrow, Inc (92DJTUUM2X)" make dist
   ```

3. **Stage the DMG locally** for the feed (the name must be `ClaudeBar-<version>.dmg`):
   ```sh
   cp build/ClaudeBar.dmg appcast-archives/ClaudeBar-0.1.3.dmg
   ```

4. **Publish the GitHub release** (this is both the human download and the Sparkle
   asset host):
   ```sh
   gh release create v0.1.3 appcast-archives/ClaudeBar-0.1.3.dmg \
     --title "ClaudeBar v0.1.3" \
     --notes "What changed in this release…" \
     --latest
   ```

5. **Regenerate and publish the feed:**
   ```sh
   make appcast
   git add appcast.xml && git commit -m "Release 0.1.3" && git push
   ```
   Pushing `appcast.xml` to `main` is what makes the update go live; Sparkle reads
   it from `SUFeedURL`.

## Notes & gotchas

- **`CFBundleVersion` must increase every release** — it's the version Sparkle
  compares.
- **`appcast-archives/` is local-only (gitignored).** `make appcast` signs and
  sizes the DMGs from this folder, so keep recent versions in it. On a fresh
  checkout, repopulate from the releases:
  ```sh
  gh release download v0.1.2 -p 'ClaudeBar-*.dmg' -D appcast-archives
  ```
- **The feed must reference real `vX.Y.Z` release assets.** `make appcast` rewrites
  each enclosure URL to `…/releases/download/v<version>/ClaudeBar-<version>.dmg`,
  so the archive filenames must be `ClaudeBar-<version>.dmg` (it errors out if any
  URL is left unrewritten).
- **Delta updates** aren't used (pointless for a ~2 MB app); every update is a full
  download.
- Releases before `0.1.2` predate Sparkle, so those users have no updater and must
  download `0.1.2`+ manually once.
