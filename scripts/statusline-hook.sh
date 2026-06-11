#!/bin/bash
# ClaudeBar statusline hook — installed by claude-macos-bar (make install-hook).
# Claude Code pipes its statusline JSON (including rate_limits) to this script.
# We atomically save a copy for the ClaudeBar menu bar app to read, then
# delegate to the user's original statusline script unchanged.
set -u

input=$(cat)

dir="$HOME/Library/Application Support/ClaudeBar"
mkdir -p "$dir"
tmp="$dir/usage.json.tmp.$$"
if printf '%s' "$input" > "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$dir/usage.json"
fi

printf '%s' "$input" | bash "$HOME/.claude/statusline.sh"
