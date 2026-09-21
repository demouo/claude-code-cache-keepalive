# claude-code-cache-keepalive

Keep Claude Code's **prompt cache warm across idle pauses**.

A `Stop` hook stamps "the session was active just now"; a background
**Monitor** watches that timestamp and, only once the session has been idle
long enough (default **50 min**), emits one line. That line is delivered to
Claude as a notification, which starts a fresh turn → a cache **read** →
the prompt-cache TTL is refreshed. One cheap read instead of an expensive
full cache rewrite.

Built for a **1 hour** cache TTL. On a 5-minute TTL you would set
`CCKA_IDLE_SECONDS=240`.

> ⚠️ **Billing matters.** This only pays off when you are billed **per
> token** (API key) *and* your provider refreshes the TTL on cache reads.
> On request-quota subscriptions (Claude Pro/Max, GLM Coding Plan, …) every
> ping **eats your quota** — disable it there.

---

## How it works

```
turn ends (Stop) ─────────────► stamp hook: last_stop = now   (instant, non-blocking)
you submit (UserPromptSubmit) ─► stamp hook: last_stop = now

background Monitor loop (dies with the session):
  every TICK (default 300s):
    idle = now - last_stop
    if idle < IDLE_SECONDS:  do nothing
    else:                    echo "<ping>"   ─► Claude Code delivers it as a notification
                                                 └► new turn → cache READ → TTL refreshed
                                                    └► turn ends → Stop → last_stop = now → ↻
```

Because the timer is `now - last_stop`, it is a **resettable idle timer**:
every Stop restarts the 50-minute window. An actively used session is never
pinged; only a genuinely idle one is.

### Why a Monitor and not a sleeping Stop hook

| | Stop hook that sleeps | **Monitor** (this repo) |
|---|---|---|
| Blocks the UI while waiting | yes (press Esc) | **no** |
| Limited by the 8-consecutive-block cap | yes | **no** |
| Can wait ~50 min in one shot | no (hook timeout) | **yes** |
| Cost while idle | — | one local `sleep`, 0 tokens |
| When it pings | after *every* turn | only after real idle |

---

## Install

### Recommended — as a plugin (auto-starts the Monitor)

```
/plugin marketplace add demouo/claude-code-cache-keepalive
/plugin install cache-keepalive@claude-cache-tools
```

Non-interactively:

```bash
git clone https://github.com/demouo/claude-code-cache-keepalive.git
claude plugin marketplace add ./claude-code-cache-keepalive
claude plugin install cache-keepalive@claude-cache-tools
claude plugin list
```

The plugin ships a `monitors/monitors.json` with `"when": "always"`, so the
idle monitor starts automatically with the session.

### Alternative — plain `settings.json`

```bash
git clone https://github.com/demouo/claude-code-cache-keepalive.git
cd claude-code-cache-keepalive
./test.sh          # optional self-test
./install.sh       # copies scripts, wires Stop + UserPromptSubmit -> stamp
```

This route **cannot auto-start the Monitor**. Start it once per session:

```
Monitor(command="bash ~/.claude/hooks/cache-keepalive-monitor.sh", persistent=true)
```

---

## Configuration

The Monitor reads **env vars first**, then `~/.claude/cache-keepalive/config`
(`KEY=VALUE` lines), then defaults. (Plugin `userConfig` values are not
visible to monitors, so use the config file or environment.)

| Env var | Default | Meaning |
| --- | --- | --- |
| `CCKA_IDLE_SECONDS` | `3000` | Idle time before pinging (50 min) |
| `CCKA_TICK_SECONDS` | `300` | Poll granularity (5 min) |
| `CCKA_PING_TEXT` | bland text | The line delivered to Claude |
| `CCKA_STATE_DIR` | `~/.claude/cache-keepalive` | State + log directory |
| `CCKA_ENABLED` | `1` | `0` / `false` / `no` / `off` disables the monitor |

### Timing rule

```
worst-case ping time = IDLE_SECONDS + (TICK_SECONDS - 1)
```

Keep that **below the cache TTL**:

| TTL | `CCKA_IDLE_SECONDS` | `CCKA_TICK_SECONDS` | worst case |
| --- | --- | --- | --- |
| 1 h (3600 s) | 3000 (50 min) | 300 (5 min) | **55 min** ✅ |
| 5 min (300 s) | 240 | 15 | 254 s ✅ |

A 5-minute tick is fine for a 1 h TTL, but **not** for a 5-minute TTL —
lower the tick if you lower the TTL.

Log:

```bash
tail -f ~/.claude/cache-keepalive/cache-keepalive.log
```

---

## Verify / test

```bash
./test.sh
```

Checks the stamp hook (writes `last_stop`, records session id, non-blocking)
and the idle timer (no ping while re-stamped, ping after idle, fresh Stop
postpones the next ping, `CCKA_ENABLED=0` is a no-op). No Claude Code
required.

---

## Uninstall

```bash
# plugin route
claude plugin uninstall cache-keepalive

# settings route
./uninstall.sh            # remove hooks + scripts, keep state/logs
./uninstall.sh --purge    # also delete ~/.claude/cache-keepalive
```

---

## Caveats

1. **Monitor availability.** The Monitor tool needs a recent Claude Code and
   is **not available** when `DISABLE_TELEMETRY` or
   `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is set, nor on Amazon Bedrock,
   Google Cloud's Agent Platform, or Microsoft Foundry. Plugin monitors run
   only in **interactive CLI** sessions.
2. **Billing.** API/token billing only; disable on request-quota
   subscriptions.
3. **Multi-session heartbeat.** `last_stop` is a single file, so concurrent
   interactive sessions share the timer — activity in any session postpones
   the ping for all. Key the file by `session_id` if you need strict
   per-session timers.
4. **The ping is a real turn.** It appears in the transcript and costs one
   cache read + a short reply. Keep `CCKA_PING_TEXT` bland.
5. **Experimental.** Plugin monitors are an experimental component and run
   unsandboxed at hook trust level.
6. **Provider.** "A cache read refreshes the TTL" is Anthropic's documented
   behaviour; third-party Anthropic-compatible gateways may differ.

---

## Repo layout

```
.
├── .claude-plugin/marketplace.json                       # single-plugin marketplace
├── plugins/cache-keepalive/
│   ├── .claude-plugin/plugin.json                        # plugin manifest
│   ├── hooks/hooks.json                                  # Stop + UserPromptSubmit -> stamp
│   ├── monitors/monitors.json                            # auto-start idle monitor
│   └── scripts/
│       ├── cache-keepalive-stamp.sh                      # record last_stop
│       └── cache-keepalive-monitor.sh                    # idle timer -> ping
├── install.sh / uninstall.sh / test.sh
└── README.md
```

## License

MIT — see [LICENSE](LICENSE).
