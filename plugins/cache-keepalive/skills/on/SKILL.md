---
name: on
description: Re-enable cache-keepalive for THIS session after it was turned off (the default). Use when the user wants the prompt-cache keepalive monitor back for the current session. For all sessions use on-all.
---

Re-enable the keepalive for the current session, then report the result.

Run:

```bash
CTL="$(ls -1 "$HOME"/.claude/plugins/cache/*/cache-keepalive/*/scripts/cache-keepalive-ctl.sh 2>/dev/null | head -n1)"
if [ -n "$CTL" ]; then
  bash "$CTL" on
else
  STATE="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"
  key="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
  [ -n "$key" ] || key="$(cat "$STATE/last_session" 2>/dev/null || true)"
  safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"; [ -n "$safe" ] || safe="default"
  rm -f "$STATE/disabled.$safe" 2>/dev/null
  echo "cache-keepalive: ON for this session (session=$safe)"
fi
```

If the global marker is still set (a previous `/cache-keepalive:off-all`), say
that no monitor can auto-start until `/cache-keepalive:on-all` is run. If no
monitor is running, tell the user to run `/reload-plugins` (the plugin monitor
restarts automatically) or to start it with the Monitor tool:

```
Monitor(command="bash <plugin>/scripts/cache-keepalive-monitor.sh", persistent=true)
```
