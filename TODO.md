# ClaudeBar — next steps

## Pending

1. **Test click-to-open on a terminal session** — the iTerm tab-jump (tty match) hasn't been exercised; first click triggers the Automation permission prompt. Note: the app was re-signed with a real identity on 2026-06-11, so the prompt will appear once more, then stick.
2. **Verify launch-at-login toggle** — new in the gear menu (SMAppService); flip it on from the installed copy and confirm ClaudeBar appears in System Settings → Login Items.
3. **Close the konvoy-mobile session** — `claude -r` (pid 30807) idle on iTerm ttys004 since June 8; close it from that tab (Ctrl+C or `/exit`).

## Deferred

4. **Keychain hybrid vs manual token** — decided 2026-06-11 to keep the manual paste flow for now; revisit if re-pasting becomes annoying. The Keychain fetcher path remains a ~20 min swap.

## Watchlist / ideas

5. **Desktop session deep link** — check if the desktop app ever offers "Copy link" on a session (or ships a `claude://` session route); if so, wire it into `SessionFocus` for exact-chat focus.
6. **Usage history sparkline** — we now persist API readings; a small 24h/weekly chart in the dropdown would be cheap to add.
7. **Burn-rate hint** — "at this pace you hit 100% in ~40m" next to the 5-hour gauge.

## Done (2026-06-11)

- First git commit.
- Signed with Apple Development certificate (`CODESIGN_IDENTITY` override, ad-hoc fallback) — native notifications + stable TCC identity.
- Launch-at-login toggle in the gear menu.
- README + verify.sh updated (signing/icon checks added; all checks pass).
