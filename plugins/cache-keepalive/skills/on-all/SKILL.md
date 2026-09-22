---
name: on-all
description: Re-enable cache-keepalive for EVERY session after a global off-all, clearing the global marker and all per-session markers. Use when the user wants the prompt-cache keepalive back everywhere.
---

Globally re-enable the keepalive, then report the result.

Run:

```bash
CTL="$(ls -1 "$HOME"/.claude/plugins/cache/*/cache-keepalive/*/scripts/cache-keepalive-ctl.sh 2>/dev/null | head -n1)"
if [ -n "$CTL" ]; then
  bash "$CTL" on-all
else
  STATE="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"
  rm -f "$STATE/disabled" "$STATE"/disabled.* 2>/dev/null
  echo "cache-keepalive: ON for ALL sessions (disable markers cleared)"
fi
```

If no monitor is running, tell the user to run `/reload-plugins` (the plugin
monitor restarts automatically) or to start it with the Monitor tool:

```
Monitor(command="bash <plugin>/scripts/cache-keepalive-monitor.sh", persistent=true)
```
