#!/usr/bin/env bash
# ============================================================
# cache-keepalive-monitor.sh  --  Monitor tool / plugin monitor
# ============================================================
# Long-running background loop. It measures how long THIS session has
# been idle (now - last_stop) and, only once the idle window reaches
# CCKA_IDLE_SECONDS, prints ONE line. Claude Code delivers each stdout
# line to Claude as a notification, which starts a fresh turn -> a
# cache read -> the prompt-cache TTL is refreshed.
#
# Per-session: the heartbeat and log are keyed by the Claude Code
# session id (CLAUDE_SESSION_ID, falling back to CLAUDE_CODE_SESSION_ID),
# so concurrent sessions keep independent idle timers. If no session id
# is visible in the environment it falls back to the shared global file
# (any activity resets it, so it never spams).
#
# Config (env first, else ~/.claude/cache-keepalive/config, else default):
#   CCKA_IDLE_SECONDS   idle time before pinging        (default 3000 = 50 min)
#   CCKA_TICK_SECONDS   poll granularity                (default 300 = 5 min)
#   CCKA_PING_TEXT      stdout line delivered to Claude (default bland ping)
#   CCKA_STATE_DIR      state/log directory             (default ~/.claude/cache-keepalive)
#   CCKA_LOG            explicit log path override
#   CCKA_ENABLED        set 0/false/no/off to disable
#
# With a 1h TTL and idle=50min, a 5min tick means the ping fires somewhere
# in [50, 55] min after the last activity -- the extra tick of slack is
# deliberately kept below 60min. Keep TICK small relative to (TTL - IDLE).
# ============================================================
set -uo pipefail

STATE_DIR="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# optional KEY=VALUE config file (monitors do not receive plugin options)
CFG="$STATE_DIR/config"
if [ -f "$CFG" ]; then
  # shellcheck disable=SC1090
  . "$CFG" 2>/dev/null || true
fi

# master switch (default on); disable with CCKA_ENABLED=0 or plugin disable
case "$(printf '%s' "${CCKA_ENABLED:-1}" | tr '[:upper:]' '[:lower:]')" in
  0|false|no|off) exit 0 ;;
esac

# per-session key (must match cache-keepalive-stamp.sh)
key="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
if [ -n "$safe" ]; then
  HB="$STATE_DIR/last_stop.$safe"
  LOG="${CCKA_LOG:-$STATE_DIR/cache-keepalive.$safe.log}"
  SESSION_LABEL="$safe"
else
  HB="$STATE_DIR/last_stop"
  LOG="${CCKA_LOG:-$STATE_DIR/cache-keepalive.log}"
  SESSION_LABEL="global"
fi

IDLE="${CCKA_IDLE_SECONDS:-3000}"
TICK="${CCKA_TICK_SECONDS:-300}"
MESSAGE="${CCKA_PING_TEXT:-cache keepalive: this session has been idle; reply with a single word so the prompt cache stays warm.}"

case "$IDLE" in ''|*[!0-9]*) IDLE=3000 ;; esac
case "$TICK" in ''|*[!0-9]*) TICK=300 ;; esac
[ "$TICK" -lt 1 ] && TICK=300

log() { printf '[%s] [CACHE-KEEPALIVE-MONITOR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }

# bootstrap for this session: prefer the global heartbeat if we have none yet
if [ ! -f "$HB" ]; then
  if [ -f "$STATE_DIR/last_stop" ]; then
    cp "$STATE_DIR/last_stop" "$HB" 2>/dev/null || date +%s > "$HB" 2>/dev/null || true
  else
    date +%s > "$HB" 2>/dev/null || true
  fi
fi

log "monitor started (session=${SESSION_LABEL} idle=${IDLE}s tick=${TICK}s hb=$(basename "$HB"))"

while :; do
  sleep "$TICK" || exit 0

  now="$(date +%s)"
  last="$(cat "$HB" 2>/dev/null || echo "$now")"
  case "$last" in ''|*[!0-9]*) last="$now" ;; esac

  if [ $((now - last)) -ge "$IDLE" ]; then
    log "idle $(( (now - last) / 60 ))m >= $(( IDLE / 60 ))m -> emitting keepalive"
    printf '%s\n' "$MESSAGE"
    # avoid spamming if the notification never produces a Stop;
    # a real Stop/UserPromptSubmit will re-stamp anyway
    date +%s > "$HB" 2>/dev/null || true
  fi
done
