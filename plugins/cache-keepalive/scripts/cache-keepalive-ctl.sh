#!/usr/bin/env bash
# ============================================================
# cache-keepalive-ctl.sh  --  status | on | off
# ============================================================
# Manual control.
#
#   status  whether monitors are running, which opt-out markers exist,
#           the effective config, and this session's idle time
#   off     stop every keepalive monitor and write a GLOBAL disable marker
#           so auto-start stays off (survives plugin reloads and new sessions)
#   on      remove the disable markers so it may run again
#
# The global marker is ~/.claude/cache-keepalive/disabled. A per-session
# marker (disabled.<session>) and a per-project file
# (<project>/.claude/cache-keepalive-off) are also honoured by the monitor.
#
# Usage:  bash cache-keepalive-ctl.sh [status|on|off]
# ============================================================
set -uo pipefail

STATE_DIR="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"
GLOBAL_OFF="$STATE_DIR/disabled"

key="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$safe" ] || safe="default"
SESSION_OFF="$STATE_DIR/disabled.$safe"

monitor_pids() { pgrep -f 'cache-keepalive-monitor\.sh' 2>/dev/null || true; }

case "${1:-status}" in
  status)
    echo "state dir  : $STATE_DIR"
    if [ -f "$GLOBAL_OFF" ]; then
      echo "global off : yes  ($GLOBAL_OFF present -> /cache-keepalive:on to re-arm)"
    else
      echo "global off : no"
    fi
    [ -f "$SESSION_OFF" ] && echo "session off: yes  ($SESSION_OFF)"
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.claude/cache-keepalive-off" ]; then
      echo "project off: yes  ($CLAUDE_PROJECT_DIR/.claude/cache-keepalive-off)"
    fi
    pids="$(monitor_pids | tr '\n' ' ')"
    if [ -n "$pids" ]; then
      echo "monitors   : running (pid $pids)"
    else
      echo "monitors   : none running"
    fi
    hb="$STATE_DIR/last_stop.$safe"
    if [ -f "$hb" ]; then
      last="$(cat "$hb" 2>/dev/null || echo 0)"; now="$(date +%s)"
      case "$last" in ''|*[!0-9]*) last="$now" ;; esac
      echo "this idle  : $(( (now - last) / 60 )) min"
    fi
    if [ -f "$STATE_DIR/config" ]; then
      echo "config     :"; sed 's/^/  /' "$STATE_DIR/config"
    else
      echo "config     : (defaults: idle=3000s tick=300s max_idle=43200s)"
    fi
    ;;

  off)
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
    echo "cache-keepalive: OFF (global marker written, monitors stopped)"
    echo "it will not auto-start again until /cache-keepalive:on"
    ;;

  on)
    rm -f "$GLOBAL_OFF" "$SESSION_OFF"
    echo "cache-keepalive: ON (disable markers cleared)"
    if [ -n "$(monitor_pids)" ]; then
      echo "a monitor is already running"
    else
      echo "no monitor running yet. Re-arm with either:"
      echo "  /reload-plugins   (the plugin monitor restarts automatically)"
      echo "  or the Monitor tool: Monitor(command=\"bash <plugin>/scripts/cache-keepalive-monitor.sh\", persistent=true)"
    fi
    ;;

  *)
    echo "usage: $0 [status|on|off]" >&2
    exit 2
    ;;
esac
