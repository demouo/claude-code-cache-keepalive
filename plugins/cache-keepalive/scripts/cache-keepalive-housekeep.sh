#!/usr/bin/env bash
# ============================================================
# cache-keepalive-housekeep.sh  --  archive stale per-session state
# ============================================================
# Per-session state (last_stop.<session>, cache-keepalive.<session>.log,
# monitor.<session>.pid) accumulates forever. This prunes it:
#
#   * dead pid files are removed;
#   * per-session heartbeats/logs older than CCKA_RETENTION_DAYS are
#     bundled into archive/cache-keepalive-<date>.tar.gz, bucketed by the
#     file's last-modified date, then removed from the state dir;
#   * archives older than CCKA_ARCHIVE_KEEP_DAYS are pruned (0 = keep).
#
# It never touches the current session's files, config, or its own logs.
# Run from the monitor at session start; throttled by CCKA_HOUSEKEEP_INTERVAL.
#
# Config (env first, then ~/.claude/cache-keepalive/config):
#   CCKA_RETENTION_DAYS        age before archiving       (default 7)
#   CCKA_ARCHIVE_KEEP_DAYS     age to keep archives       (default 0 = forever)
#   CCKA_ARCHIVE_DIR           archive directory          (default <state>/archive)
#   CCKA_HOUSEKEEP_INTERVAL    min seconds between runs   (default 21600 = 6h)
# ============================================================
set -uo pipefail

STATE_DIR="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"
[ -d "$STATE_DIR" ] || exit 0

CFG="$STATE_DIR/config"
if [ -f "$CFG" ]; then
  # shellcheck disable=SC1090
  . "$CFG" 2>/dev/null || true
fi

RETENTION_DAYS="${CCKA_RETENTION_DAYS:-7}"
ARCHIVE_KEEP_DAYS="${CCKA_ARCHIVE_KEEP_DAYS:-0}"
ARCHIVE_DIR="${CCKA_ARCHIVE_DIR:-$STATE_DIR/archive}"
INTERVAL="${CCKA_HOUSEKEEP_INTERVAL:-21600}"

case "$RETENTION_DAYS"   in ''|*[!0-9]*) RETENTION_DAYS=7 ;; esac
case "$ARCHIVE_KEEP_DAYS" in ''|*[!0-9]*) ARCHIVE_KEEP_DAYS=0 ;; esac
case "$INTERVAL"         in ''|*[!0-9]*) INTERVAL=21600 ;; esac

LOG="$STATE_DIR/housekeep.log"
STAMP="$STATE_DIR/housekeep.last"
mkdir -p "$ARCHIVE_DIR" 2>/dev/null || true

log() { printf '[%s] [HOUSEKEEP] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }

# throttle (set CCKA_HOUSEKEEP_INTERVAL=0 to force)
now="$(date +%s)"
if [ "$INTERVAL" -gt 0 ] && [ -f "$STAMP" ]; then
  last="$(cat "$STAMP" 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -lt "$INTERVAL" ] && exit 0
fi
printf '%s' "$now" > "$STAMP" 2>/dev/null || true

# current session's files must never be archived
key="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"

ret_secs=$((RETENTION_DAYS * 86400))

# portable mtime helpers (GNU vs BSD/macOS)
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
mdate_of() { date -d "@$1" '+%Y-%m-%d' 2>/dev/null || date -r "$1" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d'; }

# ---- 1) remove dead/stale pid files -------------------------------------
for pf in "$STATE_DIR"/monitor.*.pid; do
  [ -f "$pf" ] || continue
  pid="$(cat "$pf" 2>/dev/null || true)"
  case "$pid" in
    ''|*[!0-9]*) rm -f "$pf"; continue ;;
  esac
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$cmd" in
    *cache-keepalive-monitor*) : ;;   # a live monitor owns this pid -> keep
    *) rm -f "$pf" ;;
  esac
done

# ---- 2) archive old per-session files, bucketed by mtime date -----------
stage_root="$(mktemp -d)"
trap 'rm -rf "$stage_root"' EXIT

found=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base="$(basename "$f")"
  case "$base" in
    config|housekeep.log|housekeep.last) continue ;;
  esac
  # never archive the current session's files
  [ -n "$safe" ] && case "$base" in
    "last_stop.$safe"|"last_ping.$safe"|"cache-keepalive.$safe.log"|"monitor.$safe.pid") continue ;;
  esac

  m="$(mtime_of "$f")"
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  [ $((now - m)) -lt "$ret_secs" ] && continue

  d="$(mdate_of "$m")"
  mkdir -p "$stage_root/$d" 2>/dev/null || continue
  if cp -p "$f" "$stage_root/$d/" 2>/dev/null; then
    rm -f "$f"
    found=$((found + 1))
  fi
done < <(find "$STATE_DIR" -maxdepth 1 -type f \
           \( -name 'last_stop' -o -name 'last_stop.*' \
              -o -name 'last_ping' -o -name 'last_ping.*' \
              -o -name 'cache-keepalive.log' -o -name 'cache-keepalive.*.log' \
              -o -name '*.count' \) 2>/dev/null)

if [ "$found" -gt 0 ]; then
  for dd in "$stage_root"/*/; do
    [ -d "$dd" ] || continue
    d="$(basename "$dd")"
    arch="$ARCHIVE_DIR/cache-keepalive-$d.tar.gz"
    # merge into an existing bucket archive, if any
    [ -f "$arch" ] && tar -xzf "$arch" -C "$dd" 2>/dev/null || true
    if tar -czf "$arch" -C "$dd" . 2>/dev/null; then
      log "archived $d -> $arch"
    else
      log "ERROR: failed to write $arch"
    fi
  done
  log "housekeep done: archived $found file(s), retention=${RETENTION_DAYS}d"
fi

# ---- 3) prune old archives ---------------------------------------------
if [ "$ARCHIVE_KEEP_DAYS" -gt 0 ]; then
  find "$ARCHIVE_DIR" -maxdepth 1 -type f -name 'cache-keepalive-*.tar.gz' \
    -mtime +"$ARCHIVE_KEEP_DAYS" -delete 2>/dev/null || true
fi

exit 0
