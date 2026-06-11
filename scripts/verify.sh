#!/bin/bash
# End-to-end smoke test for ClaudeBar. Builds the app, launches it, and
# exercises the session monitor with synthetic session files. Only writes
# test files it creates itself and removes them on exit.
set -uo pipefail
cd "$(dirname "$0")/.."

APP=build/ClaudeBar.app
LOG="$HOME/Library/Logs/ClaudeBar/claudebar.log"
TEST_FILE="$HOME/.claude/sessions/claudebar-verify-$$.json"
STALE_FILE="$HOME/.claude/sessions/claudebar-verify-stale-$$.json"
FAILURES=0

cleanup() { rm -f "$TEST_FILE" "$STALE_FILE"; }
trap cleanup EXIT

pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# Waits up to $1 seconds for a log line written after $START_MARK matching $2.
wait_for_log() {
    local timeout=$1 pattern=$2 i=0
    while [ "$i" -lt "$((timeout * 2))" ]; do
        if tail -c +"$START_OFFSET" "$LOG" 2>/dev/null | grep -q "$pattern"; then
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
    done
    return 1
}

echo "== 1. Build & bundle"
./scripts/make-app.sh >/dev/null || { fail "build"; exit 1; }
[ -x "$APP/Contents/MacOS/ClaudeBar" ] && pass "binary present" || fail "binary missing"
codesign --verify "$APP" 2>/dev/null && pass "codesign verifies" || fail "codesign"
plutil -lint "$APP/Contents/Info.plist" >/dev/null && pass "Info.plist valid" || fail "Info.plist"

echo "== 2. Launch"
pkill -x ClaudeBar 2>/dev/null
sleep 1
START_OFFSET=$(($(stat -f %z "$LOG" 2>/dev/null || echo 0) + 1))
open "$APP" || { sleep 3; open "$APP"; } || { fail "open"; exit 1; }
sleep 2
pgrep -x ClaudeBar >/dev/null && pass "process running" || fail "process not running"

echo "== 3. Monitor loop"
wait_for_log 10 "state: sessions=" && pass "state summary logged" || fail "no state summary"

echo "== 4. Waiting session detection"
LSTART=$(ps -p $$ -o lstart= | tr -s ' ' | sed 's/^ *//;s/ *$//')
STARTED_MS=$(($(date -j -f "%a %b %e %T %Y" "$LSTART" +%s) * 1000))
cat > "$TEST_FILE" <<JSON
{"pid":$$,"sessionId":"claudebar-verify-$$","cwd":"$PWD","startedAt":$STARTED_MS,"entrypoint":"cli","kind":"interactive","status":"waiting","waitingFor":"permission prompt"}
JSON
wait_for_log 8 "$$:Terminal:waiting" && pass "fake waiting session detected" || fail "waiting session not detected"
wait_for_log 8 "notify: Claude is waiting for you" && pass "waiting notification fired" || fail "no waiting notification"

rm -f "$TEST_FILE"
START_OFFSET=$(($(stat -f %z "$LOG") + 1))
DISAPPEARED=1
for _ in $(seq 1 16); do
    LINE=$(tail -c +"$START_OFFSET" "$LOG" 2>/dev/null | grep "state: sessions=" | tail -1)
    if [ -n "$LINE" ] && ! echo "$LINE" | grep -q "$$:Terminal"; then
        DISAPPEARED=0
        break
    fi
    sleep 0.5
done
[ "$DISAPPEARED" -eq 0 ] && pass "removed session disappears" || fail "session lingered after removal"

echo "== 5. Stale (dead pid) session rejection"
START_OFFSET=$(($(stat -f %z "$LOG") + 1))
cat > "$STALE_FILE" <<JSON
{"pid":99999998,"sessionId":"claudebar-verify-stale-$$","cwd":"$PWD","startedAt":$STARTED_MS,"entrypoint":"cli","kind":"interactive"}
JSON
sleep 5
if tail -c +"$START_OFFSET" "$LOG" | grep "state: sessions=" | grep -q "99999998:"; then
    fail "dead pid appeared in session list"
else
    pass "dead pid filtered out"
fi
rm -f "$STALE_FILE"

echo "== 6. Usage source"
if grep -q "usage: source=statusline" "$LOG"; then
    pass "statusline usage data read"
else
    echo "  skip: no statusline capture yet (interact with a Claude session first)"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
else
    echo "$FAILURES CHECK(S) FAILED"
    exit 1
fi
