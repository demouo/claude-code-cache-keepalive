---
name: status
description: Show whether cache-keepalive is running and how it is configured. Use when the user asks about the prompt-cache keepalive status, whether it is on, or when it will ping.
disable-model-invocation: true
---

Report the keepalive status. Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/cache-keepalive-ctl.sh" status
```

Then summarise: whether it is on, how many monitors are running, and the config
(idle threshold and tick).
