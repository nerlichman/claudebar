# ClaudeBar

A native macOS menu bar app that tracks your Claude Code **usage windows** and **running sessions** across all surfaces — the desktop app, terminal (iTerm), and the VS Code extension.

## What it shows

- **Menu bar**: your 5-hour window utilization (e.g. `42%`), with a ✋ icon when any session is waiting for your input and a ⚠️ icon above 90%. The label style is configurable (Icon + %, % only, Icon only) via the gear menu; compact styles expand back to the full label whenever something needs attention.
- **Dropdown**:
  - 5-hour and weekly usage windows with progress bars and reset countdowns.
  - Every running Claude Code session with its title, project name (worktrees displayed nicely), git branch, surface icon (terminal / desktop / VS Code), and live state — **Active** (generating), **Waiting** (blocked on a permission prompt or your input), or **Idle**.
  - **Click a session to jump to it**: terminal sessions select the exact iTerm tab (matched by the claude process's controlling tty), desktop sessions deep-link to the exact session view (`claude://claude.ai/claude-code-desktop/<id>`, falling back to activating the app), VS Code sessions open the workspace window. The first terminal jump triggers a one-time Automation permission prompt.
  - **Expandable rows**: each session shows its token count and API-equivalent cost inline; expanding reveals today vs lifetime breakdowns.
  - Sessions idle for 60+ minutes collapse into a **dormant** group; sessions that ended collapse into an **earlier today** group.
  - Today's token totals and the API-equivalent cost (informational for subscription plans).
- **Notifications**: when a session starts waiting for your input, and when the 5-hour or weekly window crosses 75% / 90% (once per window). Native banners with the ClaudeBar name and icon when the app is signed with a real identity (see below), `osascript` banners otherwise.

## How it works — no credentials, no network

ClaudeBar reads only local files that Claude Code already writes:

| Data | Source |
|---|---|
| Running sessions + waiting state | `~/.claude/sessions/{pid}.json` (PID liveness validated via the kernel to filter stale files) |
| Working set vs dormant | Claude Code lifecycle hooks (`SessionStart`/`UserPromptSubmit`/`Stop`/`Notification`/`SessionEnd` → `claudebar-hook.sh` → `events/{session_id}.json`) plus transcript activity; idle sessions untouched for 60+ min collapse into a "dormant" group, and `SessionEnd` hides a session even if its process lingers |
| Session titles | Desktop app session metadata, falling back to the transcript slug |
| Activity (generating vs idle) | mtime of `~/.claude/projects/*/{sessionId}.jsonl` |
| Usage windows (5h / weekly) | Two sources, freshest wins: (a) an optional **user-pasted access token** polling `api.anthropic.com/api/oauth/usage` every 60s — exact data, but the token rotates within hours and must be re-pasted; (b) a statusline hook capturing the `rate_limits` JSON Claude Code pushes to statusline scripts (credential-free fallback, only refreshes on terminal interactions — the desktop app does not invoke statuslines) |
| Token/cost stats (per session and per day) | Incremental tail-parsing of the transcript `.jsonl` files |

It never touches the Keychain and never writes to or deletes anything inside `~/.claude` (the statusline/hooks config in `~/.claude/settings.json` was added with consent). The only network call is the optional usage poll to `api.anthropic.com`, authenticated with a token you paste yourself:

```sh
security find-generic-password -s "Claude Code-credentials" -w | jq -r '.claudeAiOauth.accessToken' | pbcopy
```

then click **Paste usage token…** in the gear menu. When the token rotates, the dropdown shows "usage token expired" and falls back to statusline data until you re-paste. The last good API reading is cached across relaunches, and 429 responses trigger an exponential cooldown (5 min doubling up to 30 min, surfaced in the dropdown). (A hybrid Keychain-read mode that removes the re-paste chore is a possible future switch — deliberately deferred for now.)

## Build & run

Requires Xcode command line tools (Swift 5.10+). No other dependencies.

```sh
make run          # build, bundle, sign, launch from build/
make install      # build + install to ~/Applications and launch
make install-hook # (re)install the statusline capture hook
make verify       # end-to-end smoke test
make logs         # tail ~/Library/Logs/ClaudeBar/claudebar.log
make stop         # quit the app
```

The statusline hook is registered in `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "bash \"$HOME/Library/Application Support/ClaudeBar/statusline-hook.sh\""
}
```

The hook delegates to `~/.claude/statusline.sh` (your original statusline), so the terminal statusline looks exactly as before.

## Signing

`scripts/make-app.sh` signs with an Apple Development certificate by default (override with `CODESIGN_IDENTITY=...`, falls back to ad-hoc if the identity isn't in the keychain). A real signature keeps the app's code-signing identity stable across rebuilds — TCC Automation grants and notification permission survive — and enables native `UNUserNotificationCenter` banners instead of the `osascript` fallback.

## Notes

- **Launch at login**: toggle in the gear menu (SMAppService). Flip it from the installed copy (`make install`), so the login item points at `~/Applications/ClaudeBar.app` rather than a build directory.
- Threshold testing: `defaults write dev.gogrow.claudebar debugThresholds -array 1` makes the next evaluation fire at any usage level; `defaults delete dev.gogrow.claudebar debugThresholds` restores 75/90.
- Cost figures use current Claude API per-MTok prices (cache reads at 0.1×, cache writes at 1.25×/2×) — they show what your usage *would* cost at API rates, which is informational if you're on a subscription plan.
