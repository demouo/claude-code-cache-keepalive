#!/usr/bin/env bash
# ============================================================
# test.sh  --  self-test for the cache-keepalive hook scripts
# ============================================================
# Runs the Stop / reset hooks against a throwaway state dir with a
# 1-second interval so it finishes fast. No Claude Code required.
# ============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STOP="$HERE/plugins/cache-keepalive/scripts/cache-keepalive-stop.sh"
RESET="$HERE/plugins/cache-keepalive/scripts/cache-keepalive-reset.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CCKA_STATE_DIR="$TMP" CCKA_ENABLED=1 CCKA_INTERVAL=1 CCKA_MAX_LOOPS=2
MSG='got it, i need some time to think about the next move'
BLOCK="{\"decision\":\"block\",\"reason\":\"$MSG\"}"

pass=0; fail=0
check() { # got want label
  if [ "$1" = "$2" ]; then pass=$((pass + 1)); printf '  ok   %s\n' "$3"
  else fail=$((fail + 1)); printf '  FAIL %s\n       got:  %s\n       want: %s\n' "$3" "$1" "$2"; fi
}

ping() { printf '%s' "$1" | bash "$STOP"; }

A='{"session_id":"A"}'

echo "cache-keepalive self-test (interval=1s, max=2)"
check "$(ping "$A")" "$BLOCK" "ping 1/2 emits decision:block"
check "$(ping "$A")" "$BLOCK" "ping 2/2 emits decision:block"
check "$(ping "$A")" ""       "ping 3/2 over budget emits nothing"

printf '%s' "$A" | bash "$RESET"
check "$(ping "$A")" "$BLOCK" "UserPromptSubmit/SessionEnd reset restores budget"

B='{"session_id":"B"}'
check "$(ping "$B")" "$BLOCK" "second session has its own counter"

check "$(CCKA_ENABLED=0 bash "$STOP" < /dev/null)" "" "CCKA_ENABLED=0 is a no-op"
check "$(CCKA_ENABLED=false bash "$STOP" <<<"$A")"  "" "CCKA_ENABLED=false is a no-op"

[ -f "$TMP/cache-keepalive.log" ] && check "yes" "yes" "log file written" || check "no" "yes" "log file written"

printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
