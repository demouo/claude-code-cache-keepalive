---
name: on
description: Re-enable cache-keepalive after it was turned off. Use when the user wants the prompt-cache keepalive monitor back.
---

Re-enable the keepalive, then report the result to the user.

Run:

```bash
CTL="$(ls -1 "$HOME"/.claude/plugins/cache/*/cache-keepalive/*/scripts/cache-keepalive-ctl.sh 2>/dev/null | head -n1)"
if [ -n "$CTL" ]; then
  bash "$CTL" on
else
  STATE="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"
  rm -f "$STATE/disabled" "$STATE"/disabled.* 2>/dev/null
  echo "cache-keepalive: ON (disable markers cleared)"
  echo "no monitor running yet. Re-arm with /reload-plugins, or the Monitor tool:"
  echo "  Monitor(command=\"bash <plugin>/scripts/cache-keepalive-monitor.sh\", persistent=true)"
fi
```

If no monitor is running, tell the user to run `/reload-plugins` (the plugin monitor
restarts automatically) or to start it with the Monitor tool as printed above.
