# claude-code-cache-keepalive

Keep Claude Code's prompt cache warm across idle pauses by injecting cheap
keepalive turns from a `Stop` hook. A cache **read** is far cheaper than a
cache **write**, so pinging just before the TTL expires avoids paying to
rebuild the whole prompt prefix every time you pause to think.

> ⚠️ **Read the caveats first.** This only saves money when you are billed
> **per token** (API key) *and* your provider refreshes the cache TTL on
> cache reads. On request-quota subscriptions (Claude Pro/Max, GLM Coding
> Plan, …) every ping **eats your quota** and makes things worse — keep it
> disabled there. See [Caveats](#caveats).

---

## How it works

When Claude finishes a turn, Claude Code fires the `Stop` hook. This tool's
hook sleeps for `interval_seconds` (default 240s, just under the 300s TTL)
and then writes this to stdout:

```json
{"decision":"block","reason":"got it, i need some time to think about the next move"}
```

Claude Code treats that as "the user sent a new instruction" and asks Claude
to respond. The response **reads the cached prompt prefix**, which refreshes
the TTL. Claude replies with one short line, `Stop` fires again, and the loop
continues — up to `max_loops_per_turn` times, or until you type.

```
Claude finishes a turn
   └─ Stop hook fires
        ├─ counter < max_loops ?  yes → sleep interval → emit {"decision":"block"}
        │                                              → Claude replies (cache READ → TTL refreshed) → ↻
        └─ counter >= max_loops ? no  → exit 0 (Stop proceeds, Claude stops)
```

A real user prompt (`UserPromptSubmit`) resets the counter; `SessionEnd`
clears the state.

At `interval=240`, `max_loops=15` one idle turn keeps the cache warm for
**~60 minutes**.

---

## Install

### Option A — installer script (works anywhere)

```bash
git clone https://github.com/<you>/claude-code-cache-keepalive.git
cd claude-code-cache-keepalive
./test.sh            # optional: verify the hooks
./install.sh         # install + enable
```

This copies the scripts to `~/.claude/hooks/`, wires them into
`~/.claude/settings.json`, and backs up the old settings file.

```bash
./install.sh --no-enable   # install but leave disabled (CCKA_ENABLED=0)
./install.sh --dir DIR     # custom Claude config dir
```

Restart Claude Code afterwards.

### Option B — as a Claude Code plugin

If your Claude Code supports the plugin marketplace:

```
/plugin marketplace add <you>/claude-code-cache-keepalive
/plugin install cache-keepalive@claude-cache-tools
```

Claude Code will prompt for the three config values. Verify with `/plugin`.

---

## Configuration

Settings are read in this order: **plugin option → environment variable →
default**.

| Plugin option | Env var | Default | Meaning |
| --- | --- | --- | --- |
| `interval_seconds` | `CCKA_INTERVAL` | `240` | Seconds slept before each ping (keep < TTL, 300s) |
| `max_loops_per_turn` | `CCKA_MAX_LOOPS` | `15` | Max consecutive pings per idle turn (`15 × 240s ≈ 60 min`) |
| `keepalive_message` | `CCKA_MESSAGE` | `got it, i need some time to think about the next move` | Text injected as the keepalive turn (keep it bland) |
| — | `CCKA_ENABLED` | `1` | Master switch; `0` / `false` / `no` / `off` disables |
| — | `CCKA_STATE_DIR` | `~/.claude/cache-keepalive` | State + log directory |
| — | `CCKA_LOG` | `$CCKA_STATE_DIR/cache-keepalive.log` | Log file |

Example — 30-minute coverage with a 3-minute interval:

```bash
export CCKA_INTERVAL=180
export CCKA_MAX_LOOPS=10
```

While a ping is sleeping the UI looks stuck — **press `Esc`** to break out.
Logs:

```bash
tail -f ~/.claude/cache-keepalive/cache-keepalive.log
```

---

## Verify / test

```bash
./test.sh
```

Runs the hooks against a throwaway state dir (1s interval) and checks:
budget enforcement, counter reset, and per-session isolation. No Claude Code
required.

---

## Uninstall

```bash
./uninstall.sh            # remove hooks + scripts, keep state/logs
./uninstall.sh --purge    # also delete ~/.claude/cache-keepalive
```

---

## Caveats

1. **API / token billing only.** On **Pro/Max** or **GLM Coding Plan** style
   subscriptions the quota is per request, so every keepalive turn burns
   quota. Keep `CCKA_ENABLED=0` there.
2. **Your provider must refresh the TTL on cache reads.** That is Anthropic's
   documented behaviour; third-party Anthropic-compatible gateways
   (e.g. `open.bigmodel.cn/api/anthropic`) may not do the same. Verify before
   relying on it.
3. **The keepalive turn is real.** It shows up in your transcript and token
   history. Keep `keepalive_message` bland so Claude doesn't start a tool call
   or write an essay.
4. **Anthropic can change the rules.** This depends on "a cache read refreshes
   the TTL", which is documented but not contractually guaranteed.
5. **Hook runtime.** The `Stop` hook sleeps up to 240s. The installer sets
   `timeout: 300` for it; if your install enforces a shorter limit, lower
   `CCKA_INTERVAL`.
6. **Press `Esc`** to interrupt a sleeping ping and get your prompt back.

---

## Repo layout

```
.
├── .claude-plugin/marketplace.json          # single-plugin marketplace
├── plugins/cache-keepalive/
│   ├── .claude-plugin/plugin.json           # plugin manifest + userConfig
│   ├── hooks/hooks.json                     # plugin hook wiring
│   └── scripts/
│       ├── cache-keepalive-stop.sh          # Stop: sleep + decision:block
│       └── cache-keepalive-reset.sh         # UserPromptSubmit + SessionEnd
├── install.sh
├── uninstall.sh
├── test.sh
└── README.md
```

## Differences from `yujiachen-y/claude-code-cache-keepalive`

Same mechanism and hook contract; this repo adds:

* a plain-`settings.json` installer (no plugin system needed),
* **per-session** counters (`<session_id>.count`) instead of one global
  `loop_counter`, so concurrent sessions/subagents don't fight over budget,
* a `CCKA_ENABLED` master switch,
* a merged reset/cleanup script and a `./test.sh` self-test.

## License

MIT — see [LICENSE](LICENSE).
