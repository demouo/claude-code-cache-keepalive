#!/usr/bin/env bash
# ============================================================
# cache-keepalive-ctl.sh  --  status | on | off | on-all | off-all
# ============================================================
# Manual control.
#
#   on / off    act on THIS session only (the default):
#                 off  stop this session's monitor and write
#                      ~/.claude/cache-keepalive/disabled.<session>
#                 on   clear this session's marker
#               Other running sessions and all future sessions are untouched.
#   on-all /    act on EVERY session:
#   off-all       off-all  stop every monitor and write the GLOBAL marker
#                          ~/.claude/cache-keepalive/disabled, so auto-start
#                          stays off across plugin reloads and new sessions
#                 on-all   clear the global marker and every per-session marker
#   status      monitors, which opt-out markers exist, effective config, and
#               this session's idle time
#
# A per-project file (<project>/.claude/cache-keepalive-off) is also honoured
# by the monitor but is managed by hand. "This session" is taken from
# CLAUDE_SESSION_ID (then CLAUDE_CODE_SESSION_ID, then the last session that
# stamped an activity).
#
# Usage:  bash cache-keepalive-ctl.sh [status|on|off|on-all|off-all]
# ============================================================
set -uo pipefail

STATE_DIR="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"
GLOBAL_OFF="$STATE_DIR/disabled"

# Which session are we acting on? Prefer the live env, then the last session
# that stamped activity (so a skill run from the Bash tool, which may not
# inherit the session env, still targets the right session).
key="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
if [ -z "$key" ] && [ -f "$STATE_DIR/last_session" ]; then
  key="$(cat "$STATE_DIR/last_session" 2>/dev/null || true)"
fi
safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$safe" ] || safe="default"

SESSION_OFF="$STATE_DIR/disabled.$safe"
SESSION_PIDFILE="$STATE_DIR/monitor.$safe.pid"

monitor_pids() { pgrep -f 'cache-keepalive-monitor\.sh' 2>/dev/null || true; }

# Kill only the process named by a pid file, and only if it really is our
# monitor (a reused pid must never be killed).
stop_pidfile() {
  local pf="$1" pid cmd
  [ -f "$pf" ] || return 0
  pid="$(cat "$pf" 2>/dev/null || true)"
  case "$pid" in
    ''|*[!0-9]*) rm -f "$pf"; return 0 ;;
  esac
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$cmd" in
    *cache-keepalive-monitor*)
      kill "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
      ;;
  esac
  rm -f "$pf"
}

arm_hint() {
  echo "  /reload-plugins   (the plugin monitor restarts automatically)"
  echo "  or the Monitor tool: Monitor(command=\"bash <plugin>/scripts/cache-keepalive-monitor.sh\", persistent=true)"
}

case "${1:-status}" in
  status)
    echo "state dir   : $STATE_DIR"
    echo "this session: $safe"
    if [ -f "$GLOBAL_OFF" ]; then
      echo "global off  : yes  ($GLOBAL_OFF present -> /cache-keepalive:on-all to re-arm)"
    else
      echo "global off  : no"
    fi
    if [ -f "$SESSION_OFF" ]; then
      echo "session off : yes  ($SESSION_OFF)"
    else
      echo "session off : no"
    fi
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.claude/cache-keepalive-off" ]; then
      echo "project off : yes  ($CLAUDE_PROJECT_DIR/.claude/cache-keepalive-off)"
    fi
    if [ -f "$SESSION_PIDFILE" ]; then
      echo "session mon : pid $(cat "$SESSION_PIDFILE" 2>/dev/null || echo '?')"
    fi
    pids="$(monitor_pids | tr '\n' ' ')"
    if [ -n "$pids" ]; then
      echo "monitors    : running (pid $pids)"
    else
      echo "monitors    : none running"
    fi
    hb="$STATE_DIR/last_stop.$safe"
    if [ -f "$hb" ]; then
      last="$(cat "$hb" 2>/dev/null || echo 0)"; now="$(date +%s)"
      case "$last" in ''|*[!0-9]*) last="$now" ;; esac
      echo "this idle   : $(( (now - last) / 60 )) min"
    fi
    if [ -f "$STATE_DIR/config" ]; then
      echo "config      :"; sed 's/^/  /' "$STATE_DIR/config"
    else
      echo "config      : (defaults: idle=3000s tick=300s max_idle=43200s)"
    fi
    ;;

  on|on-session|on-here|on-this)
    rm -f "$SESSION_OFF"
    echo "cache-keepalive: ON for this session (session=$safe)"
    if [ -f "$GLOBAL_OFF" ]; then
      echo "note: a GLOBAL disable marker is still present, so no monitor will"
      echo "      auto-start yet. Clear it with /cache-keepalive:on-all."
    elif [ -f "$SESSION_PIDFILE" ]; then
      echo "a monitor is already running (pid $(cat "$SESSION_PIDFILE" 2>/dev/null || echo '?'))"
    else
      echo "no monitor running yet. Re-arm with either:"
      arm_hint
    fi
    ;;

  off|off-session|off-here|off-this)
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    : > "$SESSION_OFF"
    stop_pidfile "$SESSION_PIDFILE"
    echo "cache-keepalive: OFF for this session only (session=$safe)"
    echo "other running sessions are untouched; only this session id will skip"
    echo "auto-start. Re-arm with /cache-keepalive:on (then /reload-plugins)."
    ;;

  on-all|on-everywhere|on-everything)
    rm -f "$GLOBAL_OFF" "$SESSION_OFF"
    rm -f "$STATE_DIR"/disabled.* 2>/dev/null || true
    echo "cache-keepalive: ON for ALL sessions (global + per-session markers cleared)"
    if [ -n "$(monitor_pids)" ]; then
      echo "a monitor is already running"
    else
      echo "no monitor running yet. Re-arm with either:"
      arm_hint
    fi
    ;;

  off-all|off-everywhere|off-everything)
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    : > "$GLOBAL_OFF"
    for pid in $(monitor_pids); do
      kill "$pid" 2>/dev/null || true
    done
    for _ in 1 2 3 4 5; do
      [ -z "$(monitor_pids)" ] && break
      sleep 0.2
    done
    for pid in $(monitor_pids); do
      kill -9 "$pid" 2>/dev/null || true
    done
    rm -f "$STATE_DIR"/monitor.*.pid 2>/dev/null || true
    echo "cache-keepalive: OFF for ALL sessions (global marker written, monitors stopped)"
    echo "it will not auto-start again until /cache-keepalive:on-all"
    ;;

  *)
    echo "usage: $0 [status|on|off|on-all|off-all]" >&2
    exit 2
    ;;
esac
