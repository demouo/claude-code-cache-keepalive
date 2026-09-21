#!/usr/bin/env bash
# ============================================================
# install.sh  --  install the cache-keepalive hooks into Claude Code
# ============================================================
# Copies the hook scripts into $CLAUDE_DIR/hooks and wires them into
# $CLAUDE_DIR/settings.json (Stop / UserPromptSubmit / SessionEnd).
# Idempotent: re-running will not duplicate hook entries.
#
# Usage:
#   ./install.sh              # install and ENABLE
#   ./install.sh --no-enable  # install but stay disabled (CCKA_ENABLED=0)
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
    -h|--help)   sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
const wire = (ev, cmd, timeout) => {
  const arr = (cfg.hooks[ev] = cfg.hooks[ev] || []);
  const present = arr.some(g => (g.hooks || []).some(h => (h.command || '').includes('cache-keepalive-')));
  if (!present) arr.push({ hooks: [{ type: 'command', command: cmd, timeout }] });
};
wire('Stop', `bash "${hooksDir}/cache-keepalive-stop.sh"`, 300);
wire('UserPromptSubmit', `bash "${hooksDir}/cache-keepalive-reset.sh"`, 10);
wire('SessionEnd', `bash "${hooksDir}/cache-keepalive-reset.sh"`, 10);
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
hk = cfg.setdefault('hooks', {})
def wire(ev, cmd, timeout):
    arr = hk.setdefault(ev, [])
    if not any('cache-keepalive-' in (h.get('command', '')) for g in arr for h in g.get('hooks', [])):
        arr.append({'hooks': [{'type': 'command', 'command': cmd, 'timeout': timeout}]})
wire('Stop', f'bash "{hooks}/cache-keepalive-stop.sh"', 300)
wire('UserPromptSubmit', f'bash "{hooks}/cache-keepalive-reset.sh"', 10)
wire('SessionEnd', f'bash "{hooks}/cache-keepalive-reset.sh"', 10)
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
cp "$SRC_DIR/cache-keepalive-stop.sh"  "$HOOKS_DIR/cache-keepalive-stop.sh"
cp "$SRC_DIR/cache-keepalive-reset.sh" "$HOOKS_DIR/cache-keepalive-reset.sh"
chmod 0755 "$HOOKS_DIR/cache-keepalive-stop.sh" "$HOOKS_DIR/cache-keepalive-reset.sh"

if [ -f "$SETTINGS" ]; then
  BAK="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS" "$BAK"
  echo "  backed up settings.json -> $BAK"
fi

merge_json "$SETTINGS" "$ENABLE"

if [ "$ENABLE" = "1" ]; then
  echo "  installed and ENABLED (CCKA_ENABLED=1)"
else
  echo "  installed but DISABLED (CCKA_ENABLED=0)"
fi
echo
echo "Restart Claude Code to pick up the hooks."
echo "  log:   tail -f \"$CLAUDE_DIR/cache-keepalive/cache-keepalive.log\""
echo "  pause: set CCKA_ENABLED=0 in $SETTINGS (or export it) and restart"
echo "  note:  while a ping is sleeping the UI looks stuck - press Esc to break out"
