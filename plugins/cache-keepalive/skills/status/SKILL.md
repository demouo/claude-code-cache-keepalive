---
name: status
description: Show whether cache-keepalive is running and how it is configured. Use when the user asks about the prompt-cache keepalive status, whether it is on, or when it will ping.
---

Report the keepalive status. Run:

```bash
CTL="$(ls -1 "$HOME"/.claude/plugins/cache/*/cache-keepalive/*/scripts/cache-keepalive-ctl.sh 2>/dev/null | head -n1)"
if [ -n "$CTL" ]; then
  bash "$CTL" status
else
  STATE="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"
  [ -f "$STATE/disabled" ] && echo "global off : yes" || echo "global off : no"
  pids="$(pgrep -f 'cache-keepalive-monitor\.sh' 2>/dev/null | tr '\n' ' ')"
  [ -n "$pids" ] && echo "monitors   : $pids" || echo "monitors   : none running"
  [ -f "$STATE/config" ] && { echo "config:"; sed 's/^/  /' "$STATE/config"; } || echo "config     : (defaults)"
fi
```

Then summarise: whether it is on, how many monitors are running, and the config
(idle threshold and tick).
