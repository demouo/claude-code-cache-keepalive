#!/usr/bin/env bash
# ============================================================
# cache-keepalive-reset.sh  --  UserPromptSubmit + SessionEnd hook
# ============================================================
# Clears the per-session keepalive counter so that:
#   * a real user prompt resets the loop budget, and
#   * a finished session leaves no stale state behind.
# ============================================================
set -uo pipefail

STATE_DIR="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"
[ -d "$STATE_DIR" ] || exit 0

input="$(cat 2>/dev/null || true)"

sid="$(printf '%s' "$input" \
  | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
[ -n "$sid" ] || sid="default"
safe_sid="$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '_')"

rm -f "$STATE_DIR/${safe_sid}.count"
exit 0
