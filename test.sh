#!/usr/bin/env bash
# ============================================================
# test.sh  --  self-test for the cache-keepalive scripts
# ============================================================
# Exercises the stamp hook and the idle-timer monitor against a
# throwaway state dir with a tiny idle window. No Claude Code needed.
# ============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$HERE/plugins/cache-keepalive/scripts/cache-keepalive-stamp.sh"
MONITOR="$HERE/plugins/cache-keepalive/scripts/cache-keepalive-monitor.sh"

TMP="$(mktemp -d)"
MON_PID=""
cleanup() { [ -n "$MON_PID" ] && kill "$MON_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

export CCKA_STATE_DIR="$TMP"
HB="$TMP/last_stop"
OUT="$TMP/events"

pass=0; fail=0
check() { # got want label
  if [ "$1" = "$2" ]; then pass=$((pass + 1)); printf '  ok   %s\n' "$3"
  else fail=$((fail + 1)); printf '  FAIL %s\n       got:  %s\n       want: %s\n' "$3" "$1" "$2"; fi
}
lines() { wc -l < "$OUT" 2>/dev/null | tr -d ' '; }
stamp() { printf '%s' "$1" | bash "$STAMP"; }

# ---------------------------------------------------------------
echo "cache-keepalive self-test"

echo "-- stamp hook --"
out="$(stamp '{"session_id":"S1"}')"
check "$out" "" "prints nothing (non-blocking)"
check "$( [ -f "$HB" ] && echo yes || echo no )" "yes" "writes last_stop"
check "$(cat "$TMP/last_session" 2>/dev/null)" "S1" "records session_id"
t1="$(cat "$HB")"; sleep 1; stamp '{"session_id":"S1"}'; t2="$(cat "$HB")"
check "$( [ "$t2" -ge "$t1" ] && echo yes || echo no )" "yes" "timestamp advances on each Stop"

echo "-- monitor idle timer (idle=2s tick=1s) --"
CCKA_IDLE_SECONDS=2 CCKA_TICK_SECONDS=1 CCKA_PING_TEXT=PING bash "$MONITOR" >"$OUT" 2>"$TMP/err" &
MON_PID=$!
sleep 1
check "$(lines)" "0" "no ping before the idle window"

stamp '{"session_id":"S1"}'
for _ in 1 2 3; do sleep 1; stamp '{"session_id":"S1"}'; done
check "$(lines)" "0" "no ping while the session keeps re-stamping (reset-on-Stop)"

sleep 4
n="$(lines)"
check "$( [ "${n:-0}" -ge 1 ] && echo yes || echo no )" "yes" "ping fires after the session goes idle"

check "$(grep -c '^PING$' "$OUT")" "$n" "every emitted line is the configured ping text"

before="$(lines)"
stamp '{"session_id":"S1"}'      # simulate a Stop right after the ping
sleep 1                           # < idle window
check "$(lines)" "$before" "a fresh Stop postpones the next ping"

echo "-- disabled --"
CCKA_ENABLED=0 CCKA_IDLE_SECONDS=1 CCKA_TICK_SECONDS=1 bash "$MONITOR" >"$TMP/off" 2>/dev/null &
OFF_PID=$!
sleep 2; kill "$OFF_PID" 2>/dev/null
check "$(wc -l < "$TMP/off" | tr -d ' ')" "0" "CCKA_ENABLED=0 is a no-op"

printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
