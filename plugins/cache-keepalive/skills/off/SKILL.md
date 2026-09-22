---
name: off
description: Turn cache-keepalive off for THIS session only, leaving other open sessions and all future sessions running. Use when the user wants to disable, close, or stop the prompt-cache keepalive monitor for the current session/task.
disable-model-invocation: true
---

Turn the keepalive off for the current session only, then report the result.

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/cache-keepalive-ctl.sh" off
```

Then say briefly that **this** session's monitor is stopped and this session id
will not auto-start it again, while other and new sessions are unaffected. To
re-arm, run the same script with `on`. For a global opt-out use `off-all`; for
a per-project opt-out create `<project>/.claude/cache-keepalive-off`.
