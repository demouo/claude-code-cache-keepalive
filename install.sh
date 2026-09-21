#!/usr/bin/env bash
# ============================================================
# install.sh  --  install the cache-keepalive hook + monitor
# ============================================================
# Copies the scripts into $CLAUDE_DIR/hooks and wires the stamp hook
# into settings.json (Stop + UserPromptSubmit). Idempotent: re-running
# replaces any previous cache-keepalive wiring instead of duplicating.
#
# NOTE: settings.json cannot auto-start the background Monitor. Use the
# plugin install (see README) for that, or start it once per session:
#   Monitor(command="bash ~/.claude/hooks/cache-keepalive-monitor.sh", persistent=true)
#
# Usage:
#   ./install.sh              # install and ENABLE
#   ./install.sh --no-enable  # install but set CCKA_ENABLED=0
#   ./install.sh --dir DIR    # use a custom Claude config dir
# ============================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$REPO_DIR/plugins/cache-keepalive/scripts"

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
ENABLE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-enable) ENABLE=0 ;;
    --enable)    ENABLE=1 ;;
    --dir)       shift; CLAUDE_DIR="$1"; HOOKS_DIR="$CLAUDE_DIR/hooks"; SETTINGS="$CLAUDE_DIR/settings.json" ;;
    -h|--help)   sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

export CLAUDE_DIR HOOKS_DIR

merge_json() {
  local settings="$1" enable="$2"
  if command -v node >/dev/null 2>&1; then
    SETTINGS="$settings" ENABLE="$enable" HOOKS_DIR="$HOOKS_DIR" node - <<'NODE'
const fs = require('fs');
const p = process.env.SETTINGS, enable = process.env.ENABLE === '1', hooksDir = process.env.HOOKS_DIR;
let cfg = {};
if (fs.existsSync(p)) {
  try { cfg = JSON.parse(fs.readFileSync(p, 'utf8') || '{}'); }
  catch (e) { console.error('  ! settings.json is not valid JSON: ' + e.message); process.exit(1); }
}
cfg.env = cfg.env || {};
cfg.env.CCKA_ENABLED = enable ? '1' : '0';
cfg.hooks = cfg.hooks || {};
// migration: drop any previous cache-keepalive wiring (old sleep-based hooks included)
for (const ev of Object.keys(cfg.hooks)) {
  cfg.hooks[ev] = (cfg.hooks[ev] || []).filter(
    g => !(g.hooks || []).some(h => (h.command || '').includes('cache-keepalive-')));
  if (cfg.hooks[ev].length === 0) delete cfg.hooks[ev];
}
const wire = (ev, cmd, timeout) => {
  (cfg.hooks[ev] = cfg.hooks[ev] || []).push({ hooks: [{ type: 'command', command: cmd, timeout }] });
};
wire('Stop', `bash "${hooksDir}/cache-keepalive-stamp.sh"`, 10);
wire('UserPromptSubmit', `bash "${hooksDir}/cache-keepalive-stamp.sh"`, 10);
fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + '\n');
NODE
  elif command -v python3 >/dev/null 2>&1; then
    SETTINGS="$settings" ENABLE="$enable" HOOKS_DIR="$HOOKS_DIR" python3 - <<'PY'
import json, os
p = os.environ['SETTINGS']; enable = os.environ['ENABLE'] == '1'; hooks = os.environ['HOOKS_DIR']
try:
    cfg = json.load(open(p)) if os.path.exists(p) else {}
except Exception as e:
    print('  ! settings.json is not valid JSON:', e); raise SystemExit(1)
cfg.setdefault('env', {})['CCKA_ENABLED'] = '1' if enable else '0'
hk = cfg.get('hooks', {})
for ev in list(hk):
    hk[ev] = [g for g in hk[ev]
              if not any('cache-keepalive-' in (h.get('command', '')) for h in g.get('hooks', []))]
    if not hk[ev]:
        del hk[ev]
def wire(ev, cmd, timeout):
    hk.setdefault(ev, []).append({'hooks': [{'type': 'command', 'command': cmd, 'timeout': timeout}]})
wire('Stop', f'bash "{hooks}/cache-keepalive-stamp.sh"', 10)
wire('UserPromptSubmit', f'bash "{hooks}/cache-keepalive-stamp.sh"', 10)
if hk:
    cfg['hooks'] = hk
else:
    cfg.pop('hooks', None)
with open(p, 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False); f.write('\n')
PY
  else
    echo "  ! need 'node' or 'python3' to edit settings.json" >&2
    return 1
  fi
}

echo "cache-keepalive -> $CLAUDE_DIR"
mkdir -p "$HOOKS_DIR"

# remove scripts from the previous (sleep-based) design
rm -f "$HOOKS_DIR/cache-keepalive-stop.sh" "$HOOKS_DIR/cache-keepalive-reset.sh"

cp "$SRC_DIR/cache-keepalive-stamp.sh"   "$HOOKS_DIR/cache-keepalive-stamp.sh"
cp "$SRC_DIR/cache-keepalive-monitor.sh" "$HOOKS_DIR/cache-keepalive-monitor.sh"
chmod 0755 "$HOOKS_DIR/cache-keepalive-stamp.sh" "$HOOKS_DIR/cache-keepalive-monitor.sh"

if [ -f "$SETTINGS" ]; then
  BAK="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS" "$BAK"
  echo "  backed up settings.json -> $BAK"
fi

merge_json "$SETTINGS" "$ENABLE"

echo "  wired Stop + UserPromptSubmit -> cache-keepalive-stamp.sh"
if [ "$ENABLE" = "1" ]; then echo "  CCKA_ENABLED=1"; else echo "  CCKA_ENABLED=0 (monitor will no-op)"; fi
echo
echo "Restart Claude Code to pick up the hooks."
echo "The background monitor is NOT auto-started from settings.json. Either:"
echo "  a) install as a plugin (auto-starts the monitor), or"
echo "  b) ask Claude once per session to run:"
echo "     Monitor(command=\"bash $HOOKS_DIR/cache-keepalive-monitor.sh\", persistent=true)"
echo
echo "  log: tail -f \"$CLAUDE_DIR/cache-keepalive/cache-keepalive.log\""
echo "  cfg: ~/.claude/cache-keepalive/config   (CCKA_IDLE_SECONDS=3000, CCKA_TICK_SECONDS=300, ...)"
