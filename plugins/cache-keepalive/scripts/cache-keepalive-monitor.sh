#!/usr/bin/env bash
# ============================================================
# cache-keepalive-monitor.sh  --  Monitor tool / plugin monitor
# ============================================================
# Long-running background loop. It measures how long THIS session has
# been idle (now - last_stop, where last_stop is written by real activity
# only) and, once the idle window reaches CCKA_IDLE_SECONDS, prints ONE
# line. Claude Code delivers each stdout line to Claude as a notification,
# which starts a fresh turn -> a cache read -> the prompt-cache TTL is
# refreshed.
#
# It starts only when the user wants it:
#   * CCKA_ENABLED=0                            -> never
#   * ~/.claude/cache-keepalive/disabled.<sid>  -> not for this session
#     (created by /cache-keepalive:off, removed by :on)
#   * <project>/.claude/cache-keepalive-off     -> not for this project
# and it stops pinging once the session has been idle for
# CCKA_MAX_IDLE_SECONDS (default 12h); real activity resets that.
#
# Per-session: heartbeat, ping marker and log are keyed by the Claude Code
# session id (CLAUDE_SESSION_ID), so concurrent sessions keep independent
# idle timers. With no session id visible it falls back to shared global files.
#
# Config (env first, else ~/.claude/cache-keepalive/config, else default):
#   CCKA_IDLE_SECONDS       idle before pinging        (default 3000 = 50 min)
#   CCKA_TICK_SECONDS       poll granularity           (default 300 = 5 min)
#   CCKA_MAX_IDLE_SECONDS   stop pinging past this idle (default 43200 = 12h; 0 = never)
#   CCKA_PING_TEXT          stdout line delivered to Claude
#                           (default: asks for a one-word "ok" reply)
#                           (default: a bland "reply with a single word")
#   CCKA_STATE_DIR          state/log directory        (default ~/.claude/cache-keepalive)
#   CCKA_LOG                explicit log path override
#   CCKA_ENABLED            set 0/false/no/off to disable
#
# With a 1h TTL (Claude Pro/Max default) and idle=50min, a 5min tick means
# the ping fires somewhere in [50, 55] min after the last activity -- the
# extra tick of slack is deliberately kept below 60min.
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

# --session "<id>": Claude Code substitutes ${CLAUDE_SESSION_ID} inside the
# configured monitor command, but the variable is NOT exported to the process
# environment, so we must be told explicitly. Falls back to the env if present.
SESSION_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session)   shift; SESSION_ARG="${1:-}" ;;
    --session=*) SESSION_ARG="${1#--session=}" ;;
  esac
  shift || true
done

# per-session key (must match cache-keepalive-stamp.sh)
key="${SESSION_ARG:-${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"
safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
if [ -n "$safe" ]; then
  HB="$STATE_DIR/last_stop.$safe"
  PINGFILE="$STATE_DIR/last_ping.$safe"
  DISABLED="$STATE_DIR/disabled.$safe"
  LOG="${CCKA_LOG:-$STATE_DIR/cache-keepalive.$safe.log}"
  SESSION_LABEL="$safe"
else
  HB="$STATE_DIR/last_stop"
  PINGFILE="$STATE_DIR/last_ping"
  DISABLED="$STATE_DIR/disabled"
  LOG="${CCKA_LOG:-$STATE_DIR/cache-keepalive.log}"
  SESSION_LABEL="global"
fi

log() { printf '[%s] [CACHE-KEEPALIVE-MONITOR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }

# --- start-up gates ------------------------------------------------------
# master switch (default on)
case "$(printf '%s' "${CCKA_ENABLED:-1}" | tr '[:upper:]' '[:lower:]')" in
  0|false|no|off) log "CCKA_ENABLED=off; not starting"; exit 0 ;;
esac

# opt-out markers (created by /cache-keepalive:off, removed by :on). The global
# one disables every session; the per-session one only this session. Checked on
# every start, so turning it off also survives a plugin reload.
if [ -f "$STATE_DIR/disabled" ] || [ -f "$DISABLED" ]; then
  log "disabled marker present; not starting (use /cache-keepalive:on to re-arm)"
  exit 0
fi

# per-project opt-out: <project>/.claude/cache-keepalive-off
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.claude/cache-keepalive-off" ]; then
  log "project opt-out at $CLAUDE_PROJECT_DIR/.claude/cache-keepalive-off; not starting"
  exit 0
fi

IDLE="${CCKA_IDLE_SECONDS:-3000}"
TICK="${CCKA_TICK_SECONDS:-300}"
MAX_IDLE="${CCKA_MAX_IDLE_SECONDS:-43200}"
MESSAGE="${CCKA_PING_TEXT:-Reply with \"ok\" and nothing else.}"

case "$IDLE"     in ''|*[!0-9]*) IDLE=3000 ;; esac
case "$TICK"     in ''|*[!0-9]*) TICK=300 ;; esac
case "$MAX_IDLE" in ''|*[!0-9]*) MAX_IDLE=43200 ;; esac
[ "$TICK" -lt 1 ] && TICK=300

# record our pid so a SessionEnd hook / the ctl script can stop us
PIDFILE="$STATE_DIR/monitor.$SESSION_LABEL.pid"
printf '%s' "$$" > "$PIDFILE" 2>/dev/null || true
_cleanup() { rm -f "$PIDFILE" 2>/dev/null || true; }
trap _cleanup EXIT
trap '_cleanup; exit 0' INT TERM

# bootstrap for this session: prefer the global heartbeat if we have none yet
if [ ! -f "$HB" ]; then
  if [ -f "$STATE_DIR/last_stop" ]; then
    cp "$STATE_DIR/last_stop" "$HB" 2>/dev/null || date +%s > "$HB" 2>/dev/null || true
  else
    date +%s > "$HB" 2>/dev/null || true
  fi
fi

# A session that is just starting/resuming is "active now". If the stored
# heartbeat is already older than the idle window (e.g. a session resumed
# days later, or a monitor restarted long after the last activity), reset it
# to now so we do not fire a pointless ping with a cold cache on startup.
_now="$(date +%s)"
_last="$(cat "$HB" 2>/dev/null || echo "$_now")"
case "$_last" in ''|*[!0-9]*) _last="$_now" ;; esac
if [ $((_now - _last)) -ge "$IDLE" ]; then
  printf '%s' "$_now" > "$HB" 2>/dev/null || true
fi

log "monitor started (session=${SESSION_LABEL} idle=${IDLE}s tick=${TICK}s max_idle=${MAX_IDLE}s hb=$(basename "$HB"))"

# opportunistic housekeeping (throttled inside); stdout is redirected so it
# can never leak into the monitor's notification stream
HK="$(dirname "$0")/cache-keepalive-housekeep.sh"
if [ -f "$HK" ]; then
  ( bash "$HK" >/dev/null 2>&1 & ) 2>/dev/null || true
fi

capped=0
while :; do
  # background sleep + wait: `wait` is interrupted immediately by trap
  # signals, so the SessionEnd cleanup can stop us promptly (a foreground
  # `sleep` would defer the trap until the sleep finished).
  sleep "$TICK" &
  wait $! 2>/dev/null || true

  now="$(date +%s)"
  last="$(cat "$HB" 2>/dev/null || echo "$now")"
  case "$last" in ''|*[!0-9]*) last="$now" ;; esac
  since_ping_last="$(cat "$PINGFILE" 2>/dev/null || echo 0)"
  case "$since_ping_last" in ''|*[!0-9]*) since_ping_last=0 ;; esac

  idle=$((now - last))
  since_ping=$((now - since_ping_last))

  # ping only when idle enough AND we have not pinged in the last window
  # (the second condition is a guard for when a ping produced no Stop)
  if [ "$idle" -ge "$IDLE" ] && [ "$since_ping" -ge "$IDLE" ]; then
    if [ "$MAX_IDLE" -gt 0 ] && [ "$idle" -ge "$MAX_IDLE" ]; then
      if [ "$capped" = 0 ]; then
        log "idle $((idle / 3600))h exceeds max_idle; pausing pings until activity resumes"
        capped=1
      fi
    else
      capped=0
      log "idle $((idle / 60))m >= $((IDLE / 60))m -> emitting keepalive"
      printf '%s\n' "$MESSAGE"
      printf '%s' "$now" > "$PINGFILE" 2>/dev/null || true
    fi
  fi
done
