#!/bin/bash
# ClaudeBar statusline hook — installed by `make install-hook` or the app's
# gear menu. Claude Code pipes its statusline JSON (including rate_limits)
# to this script. We atomically save a copy for the ClaudeBar menu bar app
# to read, then delegate to the user's original statusline so the terminal
# looks unchanged. No dependencies beyond stock macOS.
set -u

input=$(cat)

dir="$HOME/Library/Application Support/ClaudeBar"
mkdir -p "$dir"
tmp="$dir/usage.json.tmp.$$"
if printf '%s' "$input" > "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$dir/usage.json"
fi

# Delegate: a statusline command captured at install time, then the
# conventional ~/.claude/statusline.sh, then a minimal model-name line.
if [ -f "$dir/original-statusline-command" ]; then
  printf '%s' "$input" | eval "$(cat "$dir/original-statusline-command")"
elif [ -f "$HOME/.claude/statusline.sh" ]; then
  printf '%s' "$input" | bash "$HOME/.claude/statusline.sh"
else
  printf '%s' "$input" \
    | sed -n 's/.*"display_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1
fi
