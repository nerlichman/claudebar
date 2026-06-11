# ClaudeBar — next steps

## Pending

1. **Test click-to-open on a terminal session** — the iTerm tab-jump (tty match) hasn't been exercised; first click triggers the Automation permission prompt. Note: the app was re-signed with a real identity on 2026-06-11, so the prompt will appear once more, then stick.
2. **Verify launch-at-login toggle** — new in the gear menu (SMAppService); flip it on from the installed copy and confirm ClaudeBar appears in System Settings → Login Items.
3. **Close the konvoy-mobile session** — `claude -r` (pid 30807) idle on iTerm ttys004 since June 8; close it from that tab (Ctrl+C or `/exit`).

## Deferred

4. **Keychain hybrid vs manual token** — decided 2026-06-11 to keep the manual paste flow for now; revisit if re-pasting becomes annoying. The Keychain fetcher path remains a ~20 min swap.

## Watchlist / ideas

5. **Usage history sparkline** — we now persist API readings; a small 24h/weekly chart in the dropdown would be cheap to add.
6. **Burn-rate hint** — "at this pace you hit 100% in ~40m" next to the 5-hour gauge.
7. **Watch the `/claude-code-desktop/` deep-link route across desktop app updates** — the route is whitelisted in the app's claude:// URL handler (verified on Claude 1.11847.5); if it breaks, clicking falls back to just activating the app.

## Done (2026-06-11)

- First git commit.
- Signed with Apple Development certificate (`CODESIGN_IDENTITY` override, ad-hoc fallback) — native notifications + stable TCC identity.
- Launch-at-login toggle in the gear menu.
- README + verify.sh updated (signing/icon checks added; all checks pass).
- Desktop session deep link: clicking a desktop session now focuses the exact session via `claude://claude.ai/claude-code-desktop/<local id>` (cliSessionId → local id mapped from the desktop app's session metadata).
