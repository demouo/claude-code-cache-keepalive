#!/usr/bin/env bash
# ============================================================
# cache-keepalive-cleanup.sh  --  SessionEnd hook
# ============================================================
# Stops this session's background monitor as part of session teardown,
# so it is not counted as "background work still running" at exit.
# Best-effort: reads the pid file the monitor wrote on startup.
# ============================================================
set -uo pipefail

STATE_DIR="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"
[ -d "$STATE_DIR" ] || exit 0

input="$(cat 2>/dev/null || true)"

key="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
if [ -z "$key" ]; then
  key="$(printf '%s' "$input" \
    | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
fi
[ -n "$key" ] || key="default"
safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"

PIDFILE="$STATE_DIR/monitor.$safe.pid"
[ -f "$PIDFILE" ] || exit 0

pid="$(cat "$PIDFILE" 2>/dev/null || true)"
case "$pid" in
  ''|*[!0-9]*) : ;;
  *)
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    ;;
esac
rm -f "$PIDFILE"
exit 0
