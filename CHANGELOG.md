# Changelog

All notable changes to this project are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [2.7.2] — find monitor processes by argv, not by substring

### Fixed
- `cache-keepalive-ctl.sh` located running monitors with `pgrep -f
  cache-keepalive-monitor.sh`, which matches the whole command line. Any
  unrelated process that merely *mentions* the script name (an editor open on
  it, a shell running a command containing the path) was matched: `status`
  showed false positives and `off-all` would **kill** them. It now matches
  argv precisely (a shell whose argument is the script; `/proc` on Linux, a
  `ps` pattern elsewhere). Tests add a decoy that mentions the name.

## [2.7.1] — pass the session id to the monitor explicitly

### Fixed
- The plugin monitor relied on `CLAUDE_SESSION_ID` being present in its
  process environment. It is not: Claude Code only substitutes
  `${CLAUDE_SESSION_ID}` **inside configured command strings**; it is not
  exported to subprocesses (anthropics/claude-code#47018, #25642). Every
  monitor therefore fell back to the shared `global` heartbeat and the
  per-session timers were inert. `monitors.json` now passes
  `--session "${CLAUDE_SESSION_ID}"`, and the monitor accepts `--session <id>`
  (still falling back to the environment).

## [2.7.0] — session-scoped opt-out

### Changed
- `on` / `off` are now **session-scoped** by default: `/cache-keepalive:off`
  stops only the current session's monitor and writes
  `disabled.<session>`, leaving other open sessions and every future session
  alone. `/cache-keepalive:on` clears it.
- The previous global behaviour moved to new `/cache-keepalive:on-all` /
  `/cache-keepalive:off-all` skills and `cache-keepalive-ctl.sh on-all |
  off-all`. `off-all` writes the global `disabled` marker; `on-all` clears the
  global marker and every per-session marker.
- `cache-keepalive-ctl.sh status` now always prints `this session` and
  `session off`, plus the session's monitor pid when one is running.

### Added
- The ctl/status scripts resolve "this session" from `CLAUDE_SESSION_ID`, then
  `CLAUDE_CODE_SESSION_ID`, then `~/.claude/cache-keepalive/last_session`
  (written by the stamp hook), so a session-scoped command targets the right
  session even when the Bash tool does not inherit the session env.

## [2.6.0] — explicit on/off control

### Added
- `/cache-keepalive:off` (and `:on`, `:status`) skills, plus
  `scripts/cache-keepalive-ctl.sh status|on|off`.
- The monitor now honours opt-out markers on every start: a global
  `disabled` file, a per-session `disabled.<session>` file, and a per-project
  `<project>/.claude/cache-keepalive-off`. Together with `CCKA_ENABLED=0` this
  means a manual stop is remembered instead of being silently undone by a
  plugin reload or the next session.

### Why
- Deleting the monitor from Claude Code's task list used to be a one-way door,
  and `/reload-plugins` would quietly bring it back. State was consistent
  either way, but the user's intent was not respected.

## [2.5.0] — idle cap + correct subscription positioning

### Added
- `CCKA_MAX_IDLE_SECONDS` (default 43200 = 12 h): the monitor stops pinging
  once a session has been idle that long, so an abandoned session no longer
  pings every idle window and burns usage. Real activity resumes pinging.
- A separate `last_ping.<session>` marker distinguishes "last real activity"
  from "last ping", so the cap is measured from genuine activity.

### Changed
- Docs: corrected positioning. Claude Pro/Max subscriptions get a **1-hour**
  prompt-cache TTL for the main conversation (within plan usage), so the
  defaults are aimed at subscribers; API keys default to a 5-minute TTL. The
  plugin is for **official Anthropic only** (Monitor is first-party).

## [2.4.0] — housekeeping

### Added
- `cache-keepalive-housekeep.sh`: at session start (throttled by
  `CCKA_HOUSEKEEP_INTERVAL`, default 6h), delete dead `monitor.*.pid` files and
  bundle per-session heartbeats/logs older than `CCKA_RETENTION_DAYS`
  (default 7) into `archive/cache-keepalive-<date>.tar.gz`, bucketed by the
  file's last-modified date. Optional `CCKA_ARCHIVE_KEEP_DAYS` pruning.
- Config: `CCKA_RETENTION_DAYS`, `CCKA_ARCHIVE_KEEP_DAYS`, `CCKA_ARCHIVE_DIR`,
  `CCKA_HOUSEKEEP_INTERVAL`.

## [2.3.0] — robust resume

### Fixed
- On startup the monitor resets an already-expired heartbeat to "now", so
  resuming a session days later no longer fires an immediate, pointless ping
  against a cold cache.
- SessionEnd cleanup now kills a pid only if its command line matches the
  monitor, so a stale `monitor.*.pid` pointing at a reused pid cannot kill an
  unrelated process.

## [2.2.0] — clean exit

### Added
- `cache-keepalive-cleanup.sh` (`SessionEnd`): stop this session's monitor
  during teardown.

### Fixed
- The monitor's wait is now a background `sleep` + `wait`, so a `SIGTERM`
  from the cleanup hook is handled immediately instead of being deferred until
  the foreground `sleep` returned.

## [2.1.0] — per-session timers

### Changed
- Heartbeat and log are keyed by `CLAUDE_SESSION_ID`
  (`last_stop.<session>`, `cache-keepalive.<session>.log`), so concurrent
  sessions keep independent idle timers instead of sharing one global clock.
- Falls back to the shared `last_stop` when no session id is visible.

## [2.0.0] — Monitor-based idle timer

### Changed (breaking)
- Replaced the sleeping `Stop` hook with a resettable idle timer: the hook only
  stamps activity, and a background **Monitor** pings once the session has been
  idle for `CCKA_IDLE_SECONDS`.
- No UI blocking, no 8-consecutive-block cap, supports ~50-minute waits.
- Removed the old `cache-keepalive-stop.sh` / `cache-keepalive-reset.sh` and
  the stale plugin `userConfig`.
- `install.sh` migrates old wiring; `uninstall.sh` removes the new scripts.

## [1.0.0] — initial

- `Stop` hook that sleeps and returns `decision: "block"` to keep the prompt
  cache warm; per-session counters; installer, uninstaller and tests.
