# Releasing ClaudeBar

ClaudeBar ships as a Developer ID-signed, notarized DMG, with in-app auto-updates via [Sparkle](https://sparkle-project.org). Each version is a normal GitHub release (`vX.Y.Z`) carrying the DMG and changelog, and the Sparkle feed (`appcast.xml`, served from `main`) points at those per-version release assets.

## One-time setup (already done)

Three credentials have to exist before any of the steps below work:

- **Developer ID identity** in the login Keychain (`Developer ID Application: …`).
- **Notary profile** for `notarytool`:
  ```sh
  xcrun notarytool store-credentials claudebar-notary \
    --apple-id your_apple_id_here --team-id your_team_id_here --password your_app_specific_password_here
  ```
- **Sparkle EdDSA signing key** in the login Keychain, created by `generate_keys` from Sparkle. Its public half is `SUPublicEDKey` in `Resources/Info.plist`.

No Full Disk Access is required, because the DMG is built with `hdiutil makehybrid`, which never mounts a volume.

## Per-release steps

Releasing `0.1.3`, for example. The version bump and the feed belong in **one commit**, so the tag points at a commit that already describes its own release. Don't commit until step 4.

1. **Bump the version** in three places, with no commit yet:
   - `Resources/Info.plist` → `CFBundleShortVersionString` (`0.1.3`) **and** `CFBundleVersion`, which must strictly increase because Sparkle keys on it.
   - `Sources/ClaudeBar/ClaudeBarApp.swift` → the `"ClaudeBar launched (version …)"` log line.

2. **Build the signed, notarized DMG and stage it** for the feed. The name must be `ClaudeBar-<version>.dmg`:
   ```sh
   CODESIGN_IDENTITY="Developer ID Application: GoGrow, Inc (92DJTUUM2X)" make dist
   cp build/ClaudeBar.dmg appcast-archives/ClaudeBar-0.1.3.dmg
   ```
   Check the DMG is what you think it is before it goes public:
   ```sh
   spctl -a -t open --context context:primary-signature -v appcast-archives/ClaudeBar-0.1.3.dmg
   ```

3. **Regenerate the feed.** `make appcast` works entirely off the local archives, signing file content and deriving each URL from the filename, so it does not need the GitHub release to exist yet. That is what lets this be one commit.
   ```sh
   make appcast
   ```

4. **Commit the bump and the feed together, and push:**
   ```sh
   git commit -am "Release 0.1.3" && git push
   ```
   Push *before* step 5. `gh release create` tags whatever the remote's `main` points at, so an unpushed bump puts the tag on the previous commit and ships the old version under the new label.

5. **Publish the GitHub release**, which serves as both the human download and the Sparkle asset host. Do this right after the push (see the gotcha below):
   ```sh
   gh release create v0.1.3 appcast-archives/ClaudeBar-0.1.3.dmg \
     --title "ClaudeBar v0.1.3" \
     --notes "What changed in this release…" \
     --latest
   ```

6. **Verify** the tag, the asset, and that Sparkle's feed and the release agree:
   ```sh
   git ls-remote --tags origin v0.1.3
   gh api repos/nerlichman/claudebar/releases/latest -q .tag_name
   ```

## Notes and gotchas

Six things that have bitten this flow before:

- **`CFBundleVersion` must increase every release**, because it's the version Sparkle compares.
- **Pushing the feed makes it live before the release asset exists**, for the few seconds between steps 4 and 5. A Sparkle client that checks in that window gets a 404 on the download and retries on its next check, so the cost is one missed check rather than a broken install. Keep the two steps back to back and it stays a non-event. The older flow published the release first and the feed second, which closed that window but cost an extra commit and left the tag pointing at a commit whose `appcast.xml` didn't yet mention the release.
- **`appcast-archives/` is local-only (gitignored).** `make appcast` signs and sizes the DMGs from this folder, so keep recent versions in it. On a fresh checkout, repopulate from the releases:
  ```sh
  gh release download v0.1.2 -p 'ClaudeBar-*.dmg' -D appcast-archives
  ```
- **The feed must reference real `vX.Y.Z` release assets.** `make appcast` rewrites each enclosure URL to `…/releases/download/v<version>/ClaudeBar-<version>.dmg`, so the archive filenames must be `ClaudeBar-<version>.dmg`. It errors out if any URL is left unrewritten.
- **Delta updates** aren't used, since they're pointless for a 2 MB app. Every update is a full download.
- Releases before `0.1.2` predate Sparkle, so those users have no updater and must download `0.1.2` or later manually once.
