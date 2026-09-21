#!/usr/bin/env bash
# ============================================================
# uninstall.sh  --  remove the cache-keepalive hooks
# ============================================================
# Removes the hook wiring from settings.json and deletes the installed
# scripts. Runtime state (logs, counters) is kept unless --purge.
#
# Usage:
#   ./uninstall.sh            # remove hooks + scripts (keep state)
#   ./uninstall.sh --purge    # also delete ~/.claude/cache-keepalive
#   ./uninstall.sh --dir DIR  # use a custom Claude config dir
# ============================================================
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
STATE_DIR="${CCKA_STATE_DIR:-$CLAUDE_DIR/cache-keepalive}"
PURGE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1 ;;
    --dir)   shift; CLAUDE_DIR="$1"; HOOKS_DIR="$CLAUDE_DIR/hooks"; SETTINGS="$CLAUDE_DIR/settings.json"; STATE_DIR="$CLAUDE_DIR/cache-keepalive" ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

export HOOKS_DIR

remove_json() {
  [ -f "$SETTINGS" ] || return 0
  if command -v node >/dev/null 2>&1; then
    SETTINGS="$SETTINGS" node - <<'NODE'
const fs = require('fs');
const p = process.env.SETTINGS;
let cfg;
try { cfg = JSON.parse(fs.readFileSync(p, 'utf8') || '{}'); }
catch (e) { console.error('  ! settings.json is not valid JSON: ' + e.message); process.exit(1); }
if (cfg.env) delete cfg.env.CCKA_ENABLED;
if (cfg.hooks) {
  for (const ev of Object.keys(cfg.hooks)) {
    cfg.hooks[ev] = (cfg.hooks[ev] || []).filter(
      g => !(g.hooks || []).some(h => (h.command || '').includes('cache-keepalive-')));
    if (cfg.hooks[ev].length === 0) delete cfg.hooks[ev];
  }
  if (Object.keys(cfg.hooks).length === 0) delete cfg.hooks;
}
fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + '\n');
NODE
  elif command -v python3 >/dev/null 2>&1; then
    SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os
p = os.environ['SETTINGS']
try:
    cfg = json.load(open(p))
except Exception as e:
    print('  ! settings.json is not valid JSON:', e); raise SystemExit(1)
cfg.get('env', {}).pop('CCKA_ENABLED', None)
if not cfg.get('env'):
    cfg.pop('env', None)
if 'hooks' in cfg:
    for ev in list(cfg['hooks']):
        cfg['hooks'][ev] = [g for g in cfg['hooks'][ev]
                            if not any('cache-keepalive-' in (h.get('command', '')) for h in g.get('hooks', []))]
        if not cfg['hooks'][ev]:
            del cfg['hooks'][ev]
    if not cfg['hooks']:
        del cfg['hooks']
with open(p, 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False); f.write('\n')
PY
  else
    echo "  ! need 'node' or 'python3' to edit settings.json" >&2
    return 1
  fi
}

echo "cache-keepalive <- $CLAUDE_DIR"
if [ -f "$SETTINGS" ]; then
  BAK="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS" "$BAK"
  echo "  backed up settings.json -> $BAK"
fi
remove_json

rm -f "$HOOKS_DIR/cache-keepalive-stop.sh" "$HOOKS_DIR/cache-keepalive-reset.sh"
echo "  removed hook scripts"

if [ "$PURGE" = "1" ]; then
  rm -rf "$STATE_DIR"
  echo "  purged state: $STATE_DIR"
else
  echo "  kept state:   $STATE_DIR  (use --purge to delete)"
fi
echo
echo "Restart Claude Code to apply."
