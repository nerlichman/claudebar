#!/bin/bash
# ClaudeBar lifecycle hook — invoked by Claude Code hooks (SessionStart,
# UserPromptSubmit, Stop, Notification, SessionEnd) with the event name as
# $1 and the hook JSON on stdin. Records the last real interaction per
# session so the menu bar app can tell the working set from dormant
# background processes. Always exits 0 — never blocks Claude Code.
EVENT="${1:-unknown}"
input=$(cat)

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$sid" ] && exit 0

dir="$HOME/Library/Application Support/ClaudeBar/events"
mkdir -p "$dir"
tmp="$dir/$sid.json.tmp.$$"
if printf '{"event":"%s","ts":%s}' "$EVENT" "$(date +%s)" > "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$dir/$sid.json"
fi
exit 0
