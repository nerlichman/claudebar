# ClaudeBar — next steps

## Priority
1. **First git commit** — the repo has the full working app but zero commits. Commit, then iterate safely.
2. **Decide: Keychain hybrid vs manual token** — the pasted token rotates within hours; first time it shows "usage token expired", decide whether to switch to the Keychain read (fetcher already built, ~20 min swap) or keep re-pasting.
3. **Sign with an Apple Development certificate** (free Apple ID via Xcode) — unlocks native notifications (ClaudeBar name + icon instead of "Script Editor" osascript banners) and stops the per-rebuild identity churn in TCC/Keychain.

## Worth doing
4. **Update `scripts/verify.sh` + README** — both predate: manual token + rate-limit backoff, session titles, dormant/“earlier today” tiers, click-to-open, per-session costs, expandable rows, app icon, `make install`.
5. **Test click-to-open on a terminal session** — the iTerm tab-jump (tty match) hasn't been exercised; first click triggers the Automation permission prompt.
6. **Launch at login** — descoped from v1; now that `~/Applications/ClaudeBar.app` exists, add an SMAppService login-item toggle in the gear menu.

## Watchlist / ideas
7. **Desktop session deep link** — check if the desktop app ever offers "Copy link" on a session (or ships a `claude://` session route); if so, wire it into `SessionFocus` for exact-chat focus.
8. **Usage history sparkline** — we now persist API readings; a small 24h/weekly chart in the dropdown would be cheap to add.
9. **Burn-rate hint** — "at this pace you hit 100% in ~40m" next to the 5-hour gauge.
10. Close the konvoy-mobile session that's been waiting since June 8. 🙂
