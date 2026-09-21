#!/usr/bin/env bash
# ============================================================
# test.sh  --  self-test for the cache-keepalive scripts
# ============================================================
# Exercises the stamp hook and the per-session idle monitor against a
# throwaway state dir with a tiny idle window. No Claude Code needed.
# ============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$HERE/plugins/cache-keepalive/scripts/cache-keepalive-stamp.sh"
MONITOR="$HERE/plugins/cache-keepalive/scripts/cache-keepalive-monitor.sh"
CLEANUP="$HERE/plugins/cache-keepalive/scripts/cache-keepalive-cleanup.sh"

TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; sleep 0.2; rm -rf "$TMP"; }
trap cleanup EXIT

export CCKA_STATE_DIR="$TMP"

pass=0; fail=0
check() { # got want label
  if [ "$1" = "$2" ]; then pass=$((pass + 1)); printf '  ok   %s\n' "$3"
  else fail=$((fail + 1)); printf '  FAIL %s\n       got:  %s\n       want: %s\n' "$3" "$1" "$2"; fi
}
lines() { wc -l < "$1" 2>/dev/null | tr -d ' '; }
stamp() { # sid  [envsid]
  if [ -n "${2:-}" ]; then printf '%s' "{\"session_id\":\"$1\"}" | CLAUDE_SESSION_ID="$2" bash "$STAMP"
  else printf '%s' "{\"session_id\":\"$1\"}" | bash "$STAMP"; fi
}

echo "cache-keepalive self-test"

echo "-- stamp hook (per-session) --"
stamp A
stamp B
check "$( [ -f "$TMP/last_stop.A" ] && echo yes || echo no )" "yes" "writes per-session heartbeat last_stop.A"
check "$( [ -f "$TMP/last_stop.B" ] && echo yes || echo no )" "yes" "writes per-session heartbeat last_stop.B"
check "$( [ -f "$TMP/last_stop" ] && echo yes || echo no )"   "yes" "also writes the global fallback heartbeat"
t1="$(cat "$TMP/last_stop.A")"; sleep 1; stamp A; t2="$(cat "$TMP/last_stop.A")"
check "$( [ "$t2" -ge "$t1" ] && echo yes || echo no )" "yes" "A heartbeat advances on each Stop"

echo "-- two sessions, independent idle timers (idle=3s tick=1s) --"
: > "$TMP/out.A"; : > "$TMP/out.B"
CLAUDE_SESSION_ID=A CCKA_IDLE_SECONDS=3 CCKA_TICK_SECONDS=1 CCKA_PING_TEXT=PING_A bash "$MONITOR" >"$TMP/out.A" 2>/dev/null &
PIDS+=($!)
CLAUDE_SESSION_ID=B CCKA_IDLE_SECONDS=3 CCKA_TICK_SECONDS=1 CCKA_PING_TEXT=PING_B bash "$MONITOR" >"$TMP/out.B" 2>/dev/null &
PIDS+=($!)
sleep 1
stamp A; stamp B
for _ in 1 2 3 4 5; do sleep 1; stamp B; done   # keep B active, let A go idle
check "$( [ "$(lines "$TMP/out.A")" -ge 1 ] && echo yes || echo no )" "yes" "A pings after its own idle window"
check "$(lines "$TMP/out.B")" "0" "B stays silent while it keeps re-stamping (independent of A)"
check "$(grep -c '^PING_A$' "$TMP/out.A")" "$(lines "$TMP/out.A")" "A only emits its own ping text"
check "$( [ -f "$TMP/cache-keepalive.A.log" ] && echo yes || echo no )" "yes" "A logs to its own file"

echo "-- global fallback (no session id visible) --"
stamp G                              # stdin session_id, no env -> global monitor watches last_stop
tA="$(cat "$TMP/last_stop")"
sleep 1; stamp G
check "$( [ "$(cat "$TMP/last_stop")" -ge "$tA" ] && echo yes || echo no )" "yes" "global heartbeat advances without a session env"
CLAUDE_SESSION_ID= CLAUDE_CODE_SESSION_ID= CCKA_IDLE_SECONDS=1 CCKA_TICK_SECONDS=1 bash "$MONITOR" >"$TMP/out.global" 2>/dev/null &
PIDS+=($!)
sleep 3
check "$( [ "$(lines "$TMP/out.global")" -ge 1 ] && echo yes || echo no )" "yes" "keyless monitor uses the shared global heartbeat"
check "$( [ -f "$TMP/cache-keepalive.log" ] && echo yes || echo no )" "yes" "keyless monitor logs to the shared log"

echo "-- disabled --"
CCKA_ENABLED=0 CCKA_IDLE_SECONDS=1 CCKA_TICK_SECONDS=1 bash "$MONITOR" >"$TMP/off" 2>/dev/null &
PIDS+=($!)
sleep 2
check "$(wc -l < "$TMP/off" | tr -d ' ')" "0" "CCKA_ENABLED=0 is a no-op"

echo "-- SessionEnd cleanup stops this session's monitor --"
CLAUDE_SESSION_ID=C CCKA_IDLE_SECONDS=300 CCKA_TICK_SECONDS=300 bash "$MONITOR" >"$TMP/out.C" 2>/dev/null &
MPID=$!; PIDS+=("$MPID")
sleep 1
check "$( [ -f "$TMP/monitor.C.pid" ] && echo yes || echo no )" "yes" "monitor writes its pid file"
printf '%s' '{"session_id":"C"}' | CLAUDE_SESSION_ID=C bash "$CLEANUP"
gone=no
for _ in 1 2 3 4 5 6 7 8 9 10; do
  s="$(awk '{print $3}' /proc/$MPID/stat 2>/dev/null)"
  if [ -z "$s" ] || [ "$s" = "Z" ]; then gone=yes; break; fi
  sleep 0.2
done
check "$gone" "yes" "cleanup stops the monitor process"
check "$( [ -f "$TMP/monitor.C.pid" ] && echo yes || echo no )" "no" "pid file removed"

printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
