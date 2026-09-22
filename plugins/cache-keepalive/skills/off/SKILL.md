---
name: off
description: Turn cache-keepalive off for THIS session only (the default), leaving other open sessions and all future sessions running. Use when the user wants to disable, close, or stop the prompt-cache keepalive monitor for the current session/task.
---

Turn the keepalive off for the current session only, then report the result.
For a blanket opt-out across every session, use `/cache-keepalive:off-all`
instead.

Run:

```bash
CTL="$(ls -1 "$HOME"/.claude/plugins/cache/*/cache-keepalive/*/scripts/cache-keepalive-ctl.sh 2>/dev/null | head -n1)"
if [ -n "$CTL" ]; then
  bash "$CTL" off
else
  STATE="${CCKA_STATE_DIR:-$HOME/.claude/cache-keepalive}"; mkdir -p "$STATE"
  key="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
  [ -n "$key" ] || key="$(cat "$STATE/last_session" 2>/dev/null || true)"
  safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"; [ -n "$safe" ] || safe="default"
  : > "$STATE/disabled.$safe"
  pf="$STATE/monitor.$safe.pid"
  if [ -f "$pf" ]; then
    pid="$(cat "$pf" 2>/dev/null || true)"
    case "$pid" in ''|*[!0-9]*) : ;; *)
      case "$(ps -p "$pid" -o command= 2>/dev/null || true)" in
        *cache-keepalive-monitor*) kill "$pid" 2>/dev/null || true ;;
      esac ;;
    esac
    rm -f "$pf"
  fi
  echo "cache-keepalive: OFF for this session only (session=$safe)"
fi
```

Then say briefly that **this** session's monitor is stopped and this session id
will not auto-start it again, while other/new sessions are unaffected.
`/cache-keepalive:on` re-arms this session; `/cache-keepalive:off-all` disables
every session.
