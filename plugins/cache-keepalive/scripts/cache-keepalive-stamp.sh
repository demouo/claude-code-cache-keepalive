#!/usr/bin/env bash
# ============================================================
# cache-keepalive-stamp.sh  --  Stop + UserPromptSubmit hook
# ============================================================
# Fast, non-blocking. It only records "the session was active now"
# so the background monitor can measure how long the session has been
# idle. It never sleeps and never blocks, so it does not stall the UI
# and is not subject to the Stop-hook 8-consecutive-block cap.
#
# Every Stop re-stamps, which is what makes the monitor's timer a
# resettable idle timer instead of a fixed cron interval.
# ============================================================
set -uo pipefail

STATE_DIR="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

input="$(cat 2>/dev/null || true)"
now="$(date +%s)"

# global activity heartbeat (what the monitor watches)
printf '%s' "$now" > "$STATE_DIR/last_stop" 2>/dev/null || true

# remember the session id for logging / debugging only
sid="$(printf '%s' "$input" \
  | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
[ -n "$sid" ] && printf '%s' "$sid" > "$STATE_DIR/last_session" 2>/dev/null || true

exit 0
