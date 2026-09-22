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
CTL="$HERE/plugins/cache-keepalive/scripts/cache-keepalive-ctl.sh"
HOUSEKEEP="$HERE/plugins/cache-keepalive/scripts/cache-keepalive-housekeep.sh"

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

echo "-- default ping text: bland, short, one-word reply --"
: > "$TMP/out.def"
printf '%s' "$(date +%s)" > "$TMP/last_stop.DEF"
CLAUDE_SESSION_ID=DEF CCKA_IDLE_SECONDS=1 CCKA_TICK_SECONDS=1 bash "$MONITOR" >"$TMP/out.def" 2>/dev/null &
PIDS+=($!)
sleep 3
first="$(head -n1 "$TMP/out.def")"
check "$( [ -n "$first" ] && echo yes || echo no )" "yes" "default ping text fires with no CCKA_PING_TEXT"
case "$first" in *cache*|*Cache*|*keepalive*) leaked=yes ;; *) leaked=no ;; esac
check "$leaked" "no" "default ping text does not name the cache-keepalive mechanism"
check "$( [ "${#first}" -le 60 ] && echo yes || echo no )" "yes" "default ping text stays short (${#first} chars)"
case "$first" in *ok*) asks_ok=yes ;; *) asks_ok=no ;; esac
check "$asks_ok" "yes" "default ping text pins the answer to one-word \"ok\""

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

echo "-- resume after a long gap: stale heartbeat must not fire on startup --"
printf '%s' "$(( $(date +%s) - 100000 ))" > "$TMP/last_stop.R"   # days-old heartbeat
CLAUDE_SESSION_ID=R CCKA_IDLE_SECONDS=3 CCKA_TICK_SECONDS=1 CCKA_PING_TEXT=PING_R bash "$MONITOR" >"$TMP/out.R" 2>/dev/null &
PIDS+=($!)
sleep 2
check "$(wc -l < "$TMP/out.R" | tr -d ' ')" "0" "stale heartbeat does not ping immediately on startup"
sleep 4
check "$( [ "$(wc -l < "$TMP/out.R" | tr -d ' ')" -ge 1 ] && echo yes || echo no )" "yes" "pings only after a fresh idle window"

echo "-- cleanup must not kill a reused pid --"
sleep 60 &
DUMMY=$!; PIDS+=("$DUMMY")
printf '%s' "$DUMMY" > "$TMP/monitor.Z.pid"
printf '%s' '{"session_id":"Z"}' | CLAUDE_SESSION_ID=Z bash "$CLEANUP"
check "$(kill -0 "$DUMMY" 2>/dev/null && echo alive || echo dead)" "alive" "non-matching pid is left alone"
check "$( [ -f "$TMP/monitor.Z.pid" ] && echo yes || echo no )" "no" "stale pid file removed"
kill "$DUMMY" 2>/dev/null || true

echo "-- housekeeping: archive stale state by date, drop dead pid files --"
HK="$TMP/hk"; mkdir -p "$HK"
printf 'x' > "$HK/last_stop.OLD"
printf 'x' > "$HK/cache-keepalive.OLD.log"
printf 'x' > "$HK/last_stop.NEW"
printf 'x' > "$HK/last_stop.CUR"
printf 'cfg' > "$HK/config"
printf '999999' > "$HK/monitor.DEAD.pid"        # dead pid
touch -t 202001010000 "$HK/last_stop.OLD" "$HK/cache-keepalive.OLD.log" "$HK/last_stop.CUR"
CLAUDE_SESSION_ID=CUR CCKA_STATE_DIR="$HK" CCKA_RETENTION_DAYS=7 CCKA_HOUSEKEEP_INTERVAL=0 bash "$HOUSEKEEP"
check "$( [ -f "$HK/last_stop.OLD" ] && echo yes || echo no )" "no" "old heartbeat archived away"
check "$( [ -f "$HK/cache-keepalive.OLD.log" ] && echo yes || echo no )" "no" "old log archived away"
check "$( [ -f "$HK/last_stop.NEW" ] && echo yes || echo no )" "yes" "recent file kept"
check "$( [ -f "$HK/last_stop.CUR" ] && echo yes || echo no )" "yes" "current session's file kept"
check "$( [ -f "$HK/config" ] && echo yes || echo no )" "yes" "config kept"
check "$( [ -f "$HK/monitor.DEAD.pid" ] && echo yes || echo no )" "no" "dead pid file removed"
arch="$HK/archive/cache-keepalive-2020-01-01.tar.gz"
check "$( [ -f "$arch" ] && echo yes || echo no )" "yes" "dated archive created"
check "$(tar -tzf "$arch" 2>/dev/null | grep -c -E 'last_stop.OLD|cache-keepalive.OLD.log')" "2" "archive contains the old files"

echo "-- max idle cap: pinging stops on an abandoned session --"
: > "$TMP/out.CAP"
CLAUDE_SESSION_ID=CAP CCKA_IDLE_SECONDS=1 CCKA_TICK_SECONDS=1 CCKA_MAX_IDLE_SECONDS=3 CCKA_PING_TEXT=PING_CAP bash "$MONITOR" >"$TMP/out.CAP" 2>/dev/null &
PIDS+=($!)
sleep 8
n="$(wc -l < "$TMP/out.CAP" | tr -d ' ')"
check "$( [ "$n" -ge 1 ] && [ "$n" -le 3 ] && echo yes || echo no )" "yes" "pings stop after max idle ($n pings, not ~8)"
stamp CAP
sleep 3
m="$(wc -l < "$TMP/out.CAP" | tr -d ' ')"
check "$( [ "$m" -gt "$n" ] && echo yes || echo no )" "yes" "new activity resumes pinging"

echo "-- opt-out markers prevent the monitor from starting --"
: > "$TMP/disabled"
CLAUDE_SESSION_ID=G1 CCKA_IDLE_SECONDS=1 CCKA_TICK_SECONDS=1 bash "$MONITOR" >"$TMP/out.G1" 2>/dev/null &
PIDS+=($!); sleep 2
check "$(wc -l < "$TMP/out.G1" | tr -d ' ')" "0" "global disabled marker -> no ping"
rm -f "$TMP/disabled"

: > "$TMP/disabled.G2"
CLAUDE_SESSION_ID=G2 CCKA_IDLE_SECONDS=1 CCKA_TICK_SECONDS=1 bash "$MONITOR" >"$TMP/out.G2" 2>/dev/null &
PIDS+=($!); sleep 2
check "$(wc -l < "$TMP/out.G2" | tr -d ' ')" "0" "per-session disabled marker -> no ping"
rm -f "$TMP/disabled.G2"

mkdir -p "$TMP/proj/.claude"; : > "$TMP/proj/.claude/cache-keepalive-off"
CLAUDE_PROJECT_DIR="$TMP/proj" CLAUDE_SESSION_ID=G3 CCKA_IDLE_SECONDS=1 CCKA_TICK_SECONDS=1 bash "$MONITOR" >"$TMP/out.G3" 2>/dev/null &
PIDS+=($!); sleep 2
check "$(wc -l < "$TMP/out.G3" | tr -d ' ')" "0" "project opt-out file -> no ping"
rm -f "$TMP/proj/.claude/cache-keepalive-off"

echo "-- monitor --session <id>: explicit session (env is not exported) --"
printf '%s' "$(date +%s)" > "$TMP/last_stop.S9"
CLAUDE_SESSION_ID= CLAUDE_CODE_SESSION_ID= CCKA_IDLE_SECONDS=2 CCKA_TICK_SECONDS=1 CCKA_PING_TEXT=PING_S9 bash "$MONITOR" --session S9 >"$TMP/out.S9" 2>/dev/null &
PIDS+=($!)
sleep 1
check "$( [ -f "$TMP/monitor.S9.pid" ] && echo yes || echo no )" "yes" "--session writes monitor.S9.pid"
check "$( [ -f "$TMP/cache-keepalive.S9.log" ] && echo yes || echo no )" "yes" "--session logs to cache-keepalive.S9.log"
sleep 3
check "$( [ "$(wc -l < "$TMP/out.S9" | tr -d ' ')" -ge 1 ] && echo yes || echo no )" "yes" "--session pings from its own heartbeat"

echo "-- ctl off-all/on-all (every session) --"
# a decoy whose command line merely mentions the script name
bash -c 'sleep 30 # cache-keepalive-monitor.sh' &
DECOY=$!; PIDS+=("$DECOY")
CLAUDE_SESSION_ID=H CCKA_IDLE_SECONDS=300 CCKA_TICK_SECONDS=300 bash "$MONITOR" >"$TMP/out.H" 2>/dev/null &
HPID=$!; PIDS+=("$HPID"); sleep 1
check "$( [ -f "$TMP/monitor.H.pid" ] && echo yes || echo no )" "yes" "monitor H is running"
case "$(bash "$CTL" status 2>/dev/null)" in
  *"$DECOY "*|*"$DECOY)"*) decoy_listed=yes ;;
  *) decoy_listed=no ;;
esac
check "$decoy_listed" "no" "status does not list a decoy that merely mentions the script name"
CLAUDE_SESSION_ID=H bash "$CTL" off-all >/dev/null
hgone=no
for _ in 1 2 3 4 5 6 7 8 9 10; do
  s="$(awk '{print $3}' /proc/$HPID/stat 2>/dev/null)"
  if [ -z "$s" ] || [ "$s" = "Z" ]; then hgone=yes; break; fi
  sleep 0.2
done
check "$hgone" "yes" "ctl off-all stops the monitor"
check "$(kill -0 "$DECOY" 2>/dev/null && echo alive || echo dead)" "alive" "off-all does not kill an unrelated process"
kill "$DECOY" 2>/dev/null || true
check "$( [ -f "$TMP/disabled" ] && echo yes || echo no )" "yes" "ctl off-all writes the global marker"
CLAUDE_SESSION_ID=H bash "$CTL" on-all >/dev/null
check "$( [ -f "$TMP/disabled" ] && echo yes || echo no )" "no" "ctl on-all clears the global marker"

echo "-- ctl off/on: this session only --"
CLAUDE_SESSION_ID=S1 CCKA_IDLE_SECONDS=300 CCKA_TICK_SECONDS=300 bash "$MONITOR" >"$TMP/out.S1" 2>/dev/null &
S1PID=$!; PIDS+=("$S1PID")
CLAUDE_SESSION_ID=S2 CCKA_IDLE_SECONDS=300 CCKA_TICK_SECONDS=300 bash "$MONITOR" >"$TMP/out.S2" 2>/dev/null &
S2PID=$!; PIDS+=("$S2PID")
sleep 1
check "$( [ -f "$TMP/monitor.S1.pid" ] && echo yes || echo no )" "yes" "S1 monitor is running"
CLAUDE_SESSION_ID=S1 bash "$CTL" off >/dev/null
s1gone=no
for _ in 1 2 3 4 5 6 7 8 9 10; do
  s="$(awk '{print $3}' /proc/$S1PID/stat 2>/dev/null)"
  if [ -z "$s" ] || [ "$s" = "Z" ]; then s1gone=yes; break; fi
  sleep 0.2
done
check "$s1gone" "yes" "off stops this session's monitor"
check "$(kill -0 "$S2PID" 2>/dev/null && echo alive || echo dead)" "alive" "off leaves other sessions running"
check "$( [ -f "$TMP/disabled.S1" ] && echo yes || echo no )" "yes" "off writes the per-session marker"
check "$( [ -f "$TMP/disabled" ] && echo yes || echo no )" "no" "off does NOT write the global marker"

# a session carrying the marker must not auto-start on a later (re)launch
CLAUDE_SESSION_ID=S1 CCKA_IDLE_SECONDS=1 CCKA_TICK_SECONDS=1 bash "$MONITOR" >"$TMP/out.S1b" 2>/dev/null &
PIDS+=($!); sleep 2
check "$(wc -l < "$TMP/out.S1b" | tr -d ' ')" "0" "per-session marker keeps that session's monitor from starting"

# without any session env, target the last session that stamped activity
printf '%s' S1 > "$TMP/last_session"
status_out="$(CLAUDE_SESSION_ID= CLAUDE_CODE_SESSION_ID= bash "$CTL" status 2>/dev/null || true)"
case "$status_out" in *"this session: S1"*) got=0 ;; *) got=1 ;; esac
check "$got" "0" "status resolves the session from last_session when no env is set"
CLAUDE_SESSION_ID= CLAUDE_CODE_SESSION_ID= bash "$CTL" off >/dev/null
check "$( [ -f "$TMP/disabled.S1" ] && echo yes || echo no )" "yes" "off falls back to last_session"

# `on` is session-scoped; `on-all` clears everything
printf 'x' > "$TMP/disabled"
printf 'x' > "$TMP/disabled.OTHER"
CLAUDE_SESSION_ID=S1 bash "$CTL" on >/dev/null
check "$( [ -f "$TMP/disabled.S1" ] && echo yes || echo no )" "no" "on clears this session's marker"
check "$( [ -f "$TMP/disabled" ] && echo yes || echo no )" "yes" "on leaves the global marker alone"
bash "$CTL" on-all >/dev/null
check "$( [ -f "$TMP/disabled" ] && echo yes || echo no )" "no" "on-all clears the global marker"
check "$( [ -f "$TMP/disabled.OTHER" ] && echo yes || echo no )" "no" "on-all clears other sessions' markers"

echo "-- shipped skills stay out of Claude's context --"
missing=""
for f in "$HERE"/plugins/cache-keepalive/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  grep -q '^disable-model-invocation: true' "$f" || missing="$missing $(basename "$(dirname "$f")")"
done
check "$missing" "" "every skill sets disable-model-invocation: true"
check "$(ls -1 "$HERE"/plugins/cache-keepalive/skills | sort | tr '\n' ' ')" "off status " "only the manual off/status controls ship"

echo "-- ctl messages never point at removed slash commands --"
TMP2="$TMP/ctlmessages"; mkdir -p "$TMP2"
ctlout=""
for c in status on off on-all off-all; do
  ctlout="$ctlout$(CCKA_STATE_DIR="$TMP2" CLAUDE_SESSION_ID=Q bash "$CTL" "$c" 2>&1)"
done
case "$ctlout" in *"/cache-keepalive:"*) stale=yes ;; *) stale=no ;; esac
check "$stale" "no" "ctl output never advertises a removed /cache-keepalive: command"

printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
