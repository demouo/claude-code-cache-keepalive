---
name: off
description: Stop cache-keepalive and keep it off. Use when the user wants to disable, close, or stop the prompt-cache keepalive monitor, or says this task does not need it.
---

Turn the keepalive off for good, then report the result to the user.

Run:

```bash
CTL="$(ls -1 "$HOME"/.claude/plugins/cache/*/cache-keepalive/*/scripts/cache-keepalive-ctl.sh 2>/dev/null | head -n1)"
if [ -n "$CTL" ]; then
  bash "$CTL" off
else
  STATE="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"; mkdir -p "$STATE"
  : > "$STATE/disabled"
  for p in $(pgrep -f 'cache-keepalive-monitor\.sh' 2>/dev/null); do kill "$p" 2>/dev/null; done
  rm -f "$STATE"/monitor.*.pid 2>/dev/null
  echo "cache-keepalive: OFF (global marker written, monitors stopped)"
fi
```

Then say briefly that the monitor is stopped and will not auto-start until `/cache-keepalive:on`.
