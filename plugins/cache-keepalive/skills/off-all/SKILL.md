---
name: off-all
description: Turn cache-keepalive off for EVERY session (global opt-out) and keep it off across plugin reloads and new sessions. Use when the user wants to disable the prompt-cache keepalive everywhere, not just the current session.
---

Globally disable the keepalive, then report the result. Use this (not
`/cache-keepalive:off`) when the intent is "stop it everywhere / for good".

Run:

```bash
CTL="$(ls -1 "$HOME"/.claude/plugins/cache/*/cache-keepalive/*/scripts/cache-keepalive-ctl.sh 2>/dev/null | head -n1)"
if [ -n "$CTL" ]; then
  bash "$CTL" off-all
else
  STATE="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"; mkdir -p "$STATE"
  : > "$STATE/disabled"
  for p in $(pgrep -f 'cache-keepalive-monitor\.sh' 2>/dev/null); do kill "$p" 2>/dev/null; done
  rm -f "$STATE"/monitor.*.pid 2>/dev/null
  echo "cache-keepalive: OFF for ALL sessions (global marker written, monitors stopped)"
fi
```

Then say briefly that every monitor is stopped and nothing will auto-start
until `/cache-keepalive:on-all`.
