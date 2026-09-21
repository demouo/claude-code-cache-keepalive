# claude-code-cache-keepalive

<p>
<a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
<a href="test.sh"><img alt="tests: 29 passing" src="https://img.shields.io/badge/tests-29%20passing-brightgreen"></a>
<img alt="Claude Code plugin" src="https://img.shields.io/badge/Claude%20Code-plugin-6E56CF">
<img alt="Requires the Monitor tool" src="https://img.shields.io/badge/requires-Monitor%20tool-orange">
</p>

**Keep Claude Code's prompt cache warm across idle pauses — without freezing your terminal.**

A `Stop` hook stamps "the session was active just now"; a background
**Monitor** watches that timestamp and, only once the session has been idle
long enough (default **50 min**), emits one line. That line is delivered to
Claude as a notification, which starts a fresh turn → a cache **read** →
the prompt-cache TTL is refreshed. One cheap read instead of an expensive
full cache rewrite.

Built for a **1 hour** cache TTL. On a 5-minute TTL you would set
`CCKA_IDLE_SECONDS=240`.

## Cost at a glance

10 warm pings (cache **reads**) vs. one cold start (a 1-hour cache **rewrite**), USD:

| Model | 100K ctx | 1M ctx | Savings |
| --- | ---: | ---: | ---: |
| Opus 5 / 4.8 / 4.7 / 4.6 | $0.50 → $1.00 | $5.00 → $10.00 | **2×** |
| Sonnet 5 | $0.20 → $0.40 | $2.00 → $4.00 | **2×** |
| Sonnet 4.6 / 4.5 | $0.30 → $0.60 | $3.00 → $6.00 | **2×** |
| Haiku 4.5 | $0.10 → $0.20 | $1.00 → $2.00 | **2×** |
| Fable 5.1 | $0.25 → $2.00 | $2.50 → $20.00 | **8×** |

`warm ×10 → cold ×1`. 10 pings ≈ **8 hours** of warmth; pinging stops after
12 h idle, which keeps it under the **20-ping** break-even for a 1-hour rewrite.
Full table (20K–1M, all models, break-even) and the generator:
**[docs/COST.md](docs/COST.md)**.

## Who this is for

✅ **For: Claude Code on official Anthropic** — both a **Claude Pro/Max
subscription** and a **Console API key**. On a subscription the main
conversation gets a **1-hour** prompt-cache TTL (within your plan's included
usage); leave a session idle longer than that and your next message
re-processes the whole prefix — slower, and far more usage than a cache read.
This keeps the prefix warm so you come back to a cheap cache **read**. The
defaults (50 min) are tuned for that 1-hour TTL.

On an **API key** the default TTL is 5 minutes, so lower the numbers or set a
1-hour TTL yourself — see [Timing rule](#timing-rule).

❌ **Not for:** third-party Anthropic-compatible gateways (DeepSeek, GLM,
OpenRouter, …) and Bedrock / Vertex / Foundry — the **Monitor tool is
first-party only**, so the monitor is skipped there, and their cache semantics
differ anyway.

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

**Per-session:** each session starts its own monitor, and the heartbeat/log
are keyed by the Claude Code session id (`CLAUDE_SESSION_ID`), so concurrent
sessions keep **independent** idle timers — activity in session A does not
postpone the ping for an idle session B. If no session id is visible to the
monitor it falls back to the shared `last_stop` file (any activity resets it,
so it never spams).

### Resuming a session later

The heartbeat is per session and persists on disk. When you resume a session
after a long gap, the stored heartbeat is already older than the idle window,
so the monitor **resets it to "now" on startup** instead of firing an
immediate ping against a cold cache. It then behaves normally and pings only
after a fresh idle window. (The cache is cold anyway after a few hours.)

Stale `monitor.<session>.pid` files are harmless: the `SessionEnd` cleanup
only kills a pid whose command line actually matches the monitor, so a
reused pid is left alone.

### Housekeeping

Per-session state would otherwise accumulate forever. At session start (at
most once per `CCKA_HOUSEKEEP_INTERVAL`), the monitor runs a housekeeping
pass that:

* deletes `monitor.<session>.pid` files whose process is gone;
* bundles `last_stop.<session>` / `cache-keepalive.<session>.log` older than
  `CCKA_RETENTION_DAYS` (default 7) into
  `archive/cache-keepalive-<date>.tar.gz`, bucketed by the file's
  last-modified **date**, then removes the originals;
* optionally prunes archives older than `CCKA_ARCHIVE_KEEP_DAYS`.

The current session's files, `config`, and the housekeeping logs are never
touched. Archives are ordinary tarballs:

```bash
ls  ~/.claude/cache-keepalive/archive/
tar -tzf ~/.claude/cache-keepalive/archive/cache-keepalive-2026-09-21.tar.gz
```

### Why a Monitor and not a sleeping Stop hook

| | Stop hook that sleeps | **Monitor** (this repo) |
|---|---|---|
| Blocks the UI while waiting | yes (press Esc) | **no** |
| Limited by the 8-consecutive-block cap | yes | **no** |
| Can wait ~50 min in one shot | no (hook timeout) | **yes** |
| Cost while idle | — | one local `sleep`, 0 tokens |
| When it pings | after *every* turn | only after real idle |

---

## What it saves

Anthropic prices a **cache read** at ~0.1× base input, a **5-minute cache
write** at ~1.25×, and a **1-hour cache write** at ~2×. When an idle gap lets
the cache expire, the next turn re-processes the whole prefix at 1.25–2×
instead of reading it at 0.1×. On an API key that is a direct bill; on a
Pro/Max subscription it is what drains your plan usage faster.

At a 20K-token cached prefix (Sonnet-class, per million tokens):

| | multiplier | cost of one idle refresh |
| --- | --- | --- |
| keepalive ping (cache **read**) | 0.1× | ~$0.006 |
| forced rewrite (cache expired) | 1.25× | ~$0.075 |

That is ~**20 keepalive pings for the price of one forced 1-hour rewrite** (12
on a 5-minute TTL). Covering a full 1 h TTL costs a handful of cache reads, so a
couple of long breaks a day already pays for it. If your pauses are always
shorter than the TTL, this does nothing for you — leave it off.

Full per-model tables (Opus / Sonnet / Haiku / Fable × 20K–1M context) and the
break-even math: [docs/COST.md](docs/COST.md).

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
| `CCKA_MAX_IDLE_SECONDS` | `43200` | Stop pinging once idle exceeds this (12 h; `0` = never) |
| `CCKA_PING_TEXT` | bland text | The line delivered to Claude |
| `CCKA_STATE_DIR` | `~/.claude/cache-keepalive` | State + log directory |
| `CCKA_LOG` | `$CCKA_STATE_DIR/cache-keepalive.<session>.log` | Explicit log path override |
| `CCKA_ENABLED` | `1` | `0` / `false` / `no` / `off` disables the monitor |
| `CCKA_RETENTION_DAYS` | `7` | Age before per-session state is archived |
| `CCKA_ARCHIVE_KEEP_DAYS` | `0` | Prune archives older than this (`0` = keep forever) |
| `CCKA_ARCHIVE_DIR` | `$CCKA_STATE_DIR/archive` | Where dated archives go |
| `CCKA_HOUSEKEEP_INTERVAL` | `21600` | Min seconds between housekeeping runs (`0` = every start) |

### Timing rule

```
worst-case ping time = IDLE_SECONDS + (TICK_SECONDS - 1)
```

Keep that **below the cache TTL**:

| TTL | where | `CCKA_IDLE_SECONDS` | `CCKA_TICK_SECONDS` | worst case |
| --- | --- | --- | --- | --- |
| 1 h (3600 s) | Claude Pro/Max within plan, or `CLAUDE_CODE_PROMPT_CACHE_TTL=1h` | 3000 (50 min) | 300 (5 min) | **55 min** ✅ |
| 5 min (300 s) | API key default | 240 | 15 | 254 s ✅ |

A 5-minute tick is fine for a 1 h TTL, but **not** for a 5-minute TTL —
lower the tick if you lower the TTL.

Log (per session):

```bash
tail -f ~/.claude/cache-keepalive/cache-keepalive.<session-id>.log
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
2. **Usage.** Works on both a Pro/Max subscription and API billing. On a
   subscription the point is to avoid a full prefix re-processing (which drains
   plan usage) after an idle gap longer than the 1-hour TTL, not to cut a
   per-token bill. Pinging stops after `CCKA_MAX_IDLE_SECONDS` (default 12 h)
   so an abandoned session does not keep pinging.
3. **Multi-session.** Each session runs its own monitor and heartbeat
   (`last_stop.<session_id>`), so timers are independent. The only shared
   case is a monitor that cannot see `CLAUDE_SESSION_ID`, which falls back
   to the global `last_stop`.
4. **The ping is a real turn.** It appears in the transcript and costs one
   cache read + a short reply. Keep `CCKA_PING_TEXT` bland.
5. **Experimental.** Plugin monitors are an experimental component and run
   unsandboxed at hook trust level.
6. **Provider.** "A cache read refreshes the TTL" is Anthropic's documented
   behaviour; third-party Anthropic-compatible gateways may differ.
7. **Exit confirmation.** Claude Code shows a *"Background work is running …
   Exit anyway?"* prompt whenever a session-scoped monitor is active
   (anthropics/claude-code#58852, closed as not planned — there is no
   `silentExit` opt-out). This plugin ships a `SessionEnd` hook that stops the
   monitor during teardown; whether that removes the prompt depends on the
   exit ordering, so you may still see it. The default selection is
   *Exit anyway*, so a plain Enter dismisses it.

---

## Repo layout

```
.
├── .claude-plugin/marketplace.json                       # single-plugin marketplace
├── plugins/cache-keepalive/
│   ├── .claude-plugin/plugin.json                        # plugin manifest
│   ├── hooks/hooks.json                                  # Stop + UserPromptSubmit -> stamp, SessionEnd -> cleanup
│   ├── monitors/monitors.json                            # auto-start idle monitor
│   └── scripts/
│       ├── cache-keepalive-stamp.sh                      # record last_stop
│       ├── cache-keepalive-monitor.sh                    # idle timer -> ping
│       ├── cache-keepalive-cleanup.sh                    # SessionEnd: stop the monitor
│       └── cache-keepalive-housekeep.sh                  # archive stale state
├── install.sh / uninstall.sh / test.sh
└── README.md
```

## Related / prior art

* **[yujiachen-y/claude-code-cache-keepalive](https://github.com/yujiachen-y/claude-code-cache-keepalive)** —
  same goal, built as a `Stop` hook that **sleeps** before pinging. It runs on
  any provider, but it blocks the terminal while waiting and is capped at 8
  consecutive blocks, so it can only cover ~30 min at a time. This repo uses
  the **Monitor** tool instead: no UI block, no block cap, and a real 50-min
  idle timer. Trade-off: it requires the Monitor tool (official Anthropic only).
* **Aider `--cache-keepalive-pings`**, **Cache-Refresh-SillyTavern**, and
  **cline/cline#414** — the same "a cache read refreshes the TTL" trick, in
  other tools.

## License

MIT — see [LICENSE](LICENSE).
