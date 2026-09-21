#!/usr/bin/env bash
# ============================================================
# cache-keepalive-stop.sh  --  Claude Code Stop hook
# ============================================================
# When Claude finishes a turn, sleep INTERVAL seconds (just under the
# prompt-cache TTL) and then emit {"decision":"block","reason":"..."}.
# The block forces a new turn; that turn READS the cached prompt prefix,
# which refreshes the TTL. Cache reads are far cheaper than cache writes.
#
# ONLY useful when you are billed per token (API key) AND your provider
# refreshes the TTL on cache reads. On request-quota subscriptions
# (Claude Pro/Max, GLM Coding Plan, ...) every ping eats your quota,
# so disable it:  CCKA_ENABLED=0
#
# Config precedence: plugin option -> env var -> default
#
#   enabled      CLAUDE_PLUGIN_OPTION_ENABLED          | CCKA_ENABLED      | 1
#   interval     CLAUDE_PLUGIN_OPTION_INTERVAL_SECONDS | CCKA_INTERVAL     | 240
#   max loops    CLAUDE_PLUGIN_OPTION_MAX_LOOPS_PER_TURN| CCKA_MAX_LOOPS   | 15
#   message      CLAUDE_PLUGIN_OPTION_KEEPALIVE_MESSAGE| CCKA_MESSAGE      | (bland text)
#   state dir                                                CCKA_STATE_DIR| ~/.claude/cache-keepalive
#
# Break out of a sleeping ping by pressing Esc in Claude Code.
# ============================================================
set -uo pipefail

STATE_DIR="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"
LOG_FILE="${CCKA_LOG:-$STATE_DIR/cache-keepalive.log}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

log() { printf '[%s] [CACHE-KEEPALIVE] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true; }

# Hook stdin is JSON: {"session_id":"...","transcript_path":"...",...}
input="$(cat 2>/dev/null || true)"

# --- master switch (default ON; disable with CCKA_ENABLED=0) -------------
_enabled="${CLAUDE_PLUGIN_OPTION_ENABLED:-${CCKA_ENABLED:-1}}"
case "$(printf '%s' "$_enabled" | tr '[:upper:]' '[:lower:]')" in
  0|false|no|off) exit 0 ;;
esac

INTERVAL="${CLAUDE_PLUGIN_OPTION_INTERVAL_SECONDS:-${CCKA_INTERVAL:-240}}"
MAX_LOOPS="${CLAUDE_PLUGIN_OPTION_MAX_LOOPS_PER_TURN:-${CCKA_MAX_LOOPS:-15}}"
MESSAGE="${CLAUDE_PLUGIN_OPTION_KEEPALIVE_MESSAGE:-${CCKA_MESSAGE:-got it, i need some time to think about the next move}}"

case "$INTERVAL"  in ''|*[!0-9]*) INTERVAL=240 ;; esac
case "$MAX_LOOPS" in ''|*[!0-9]*) MAX_LOOPS=15 ;; esac

# --- per-session state ---------------------------------------------------
sid="$(printf '%s' "$input" \
  | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
[ -n "$sid" ] || sid="default"
safe_sid="$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '_')"
COUNTER_FILE="$STATE_DIR/${safe_sid}.count"

trap 'log "interrupted by signal, letting Stop proceed"; exit 0' INT TERM

count=0
[ -f "$COUNTER_FILE" ] && count="$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)"
case "$count" in ''|*[!0-9]*) count=0 ;; esac

if [ "$count" -ge "$MAX_LOOPS" ]; then
  log "max loops reached ($count/$MAX_LOOPS), letting Stop proceed"
  rm -f "$COUNTER_FILE"
  exit 0
fi

next=$((count + 1))
log "stop fired, sleeping ${INTERVAL}s before keepalive ping $next/$MAX_LOOPS"
sleep "$INTERVAL" || { log "sleep interrupted, letting Stop proceed"; exit 0; }

printf '%s' "$next" > "$COUNTER_FILE"
log "ping $next/$MAX_LOOPS -> decision:block"

escaped="${MESSAGE//\\/\\\\}"
escaped="${escaped//\"/\\\"}"
escaped="${escaped//$'\n'/ }"
printf '{"decision":"block","reason":"%s"}\n' "$escaped"
exit 0
