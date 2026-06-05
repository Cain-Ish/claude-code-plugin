# Cross-OS Schedulers (SP-A.3/.4) — design

- **Date:** 2026-06-05
- **Status:** spec → build
- **Motivation:** the plugin ships to every OS, but the out-of-band drainer (the only autonomous-capture path for OAuth-subscription users) is **Linux/systemd-only**. macOS + Windows subscription users get no autonomous capture. The frictionless workaround (`export ANTHROPIC_API_KEY` → in-session, any OS) already works; this closes the *subscription* gap on non-Linux.
- **Grounded by:** the 2026-06-05 Claude-first-universal-engine discovery (§4 cross-OS scheduler plan).

## Problem

`scripts/extract-drain.sh` and `scripts/install-extract-timer.sh` assume Linux:
- the drainer uses `flock` (no `flock(1)` on stock macOS) and reads `/proc/$PID/cmdline` (no `/proc` on macOS) — so on macOS the single-flight lock and the interactive-`claude` defer-guard both break.
- the installer only writes systemd user units.
- the capture banner probes `systemctl --user is-active`, so off Linux it always reports "no timer" → false "capture not running" forever.

## Non-goals / honest caveats (documented, not solved)

- **No off-Linux sandbox.** systemd's `ProtectHome`/`ReadWritePaths` hardening + the `--oauth` credential-scoping have **no portable equivalent**. On macOS/Windows the scheduled job runs **as the user with full access** (it can read `~/.claude` inherently). The `--oauth` flag is therefore a **Linux-only distinction**; on mac/Windows it is accepted but a no-op (the job is unsandboxed regardless). This is stated in the installer output and the README.
- **macOS has no `linger`.** A launchd LaunchAgent runs **only during an active GUI login session**; there is no clean per-user "run while logged out" (a LaunchDaemon would run as root with no `$HOME`, breaking the per-user OAuth/`~/.claude` model — explicitly rejected). `RunAtLoad=true` gives a fast catch-up at next login. Documented.
- **Scheduled jobs get a minimal environment.** launchd/Task Scheduler do not inherit the user's shell env. The OAuth path needs only `PATH` (to find `claude`/`node`/`jq`) + `HOME`; the installer sets those. Optional engine knobs the user set in their shell (`SB_EXTRACTOR_LOCAL_URL`, `ANTHROPIC_BASE_URL`, `SB_EXTRACTOR_MODEL`) are **snapshotted into the unit at `--apply` time** so the scheduled job sees them.

## SP-3 — Portable drainer (`scripts/extract-drain.sh`)

1. **Single-flight lock** — `flock` if the binary exists (Linux/brew); else a portable `mkdir`-lock with a staleness steal: `mkdir "$BRAIN_DIR/.extract-drain.lock.d"` is atomic everywhere; on collision, steal it if its mtime is older than `SB_DRAIN_LOCK_STALE` (default 1800s, ≥ the timer interval) — covers a crashed run that left the lock; `trap rmdir EXIT` releases it on normal/most-signal exit.
2. **Interactive-`claude` defer-guard** — replace the `/proc/$PID/cmdline` read with `ps -p "$p" -o args=` (portable: Linux, macOS, Git-Bash). Keep `pgrep` (present on Linux + macOS; degrade to a `ps`-scan when `pgrep` is absent). `SB_INTERACTIVE_OVERRIDE` still forces the verdict for tests. Fail-closed: if process detection is unavailable, defer (don't risk the recursive lock).

## SP-4 — Cross-OS installer (`scripts/install-extract-timer.sh`)

OS switch at the top (preserving the print / `--apply` / `--uninstall` tri-state + `--oauth`):
```
case "$(uname -s)" in
  Linux)               os=systemd ;;
  Darwin)              os=launchd ;;
  MINGW*|MSYS*|CYGWIN*) os=windows ;;
  *)                   os=unsupported ;;
esac
```
- **systemd (unchanged):** the current behaviour. `--oauth` selects the creds-granting unit; linger printed.
- **launchd (macOS):** write `~/Library/LaunchAgents/sb-extract-drain.plist` — `Label`, `ProgramArguments=[/bin/bash, <drainer>]`, `StartInterval 1800`, `RunAtLoad true`, `EnvironmentVariables` = `PATH` (the installer's `$PATH`) + `HOME` + the snapshotted `SB_*`/`ANTHROPIC_BASE_URL`. Install: `launchctl bootstrap gui/$(id -u) <plist>` (fallback `launchctl load -w`); uninstall: `launchctl bootout gui/$(id -u)/sb-extract-drain` (fallback `unload -w`) + `rm`. Print the no-linger caveat.
- **windows (Git Bash):** a Scheduled Task running the drainer via the bash that's running the installer. Find bash: `BASH_W=$(cygpath -w "$(command -v bash)")`. Create: `schtasks /Create /TN sb-extract-drain /SC MINUTE /MO 30 /TR "\"$BASH_W\" -lc 'exec \"$DRAINER\"'" /F`. Uninstall: `schtasks /Delete /TN sb-extract-drain /F`. Print the no-sandbox caveat.
- **unsupported:** print a clear message + the manual fallback (`export ANTHROPIC_API_KEY` for in-session, or run `extract-drain.sh` from cron yourself).

`--oauth` on launchd/windows is accepted (so the docs are uniform) but only affects the systemd variant; off Linux the job is unsandboxed regardless (printed).

## Banner probe (`scripts/session-load.sh`)

The OAuth-branch `CAP_TIMER` probe must branch per-OS so it doesn't false-alarm off Linux:
- Linux: `systemctl --user is-active sb-extract-drain.timer`.
- macOS: `launchctl print gui/$(id -u)/sb-extract-drain` (or `launchctl list | grep`).
- Windows: `schtasks /Query /TN sb-extract-drain`.
- unknown: treat as unknown (don't shout "no timer" — the timer state is just unobservable).

## Verification

- **Linux-runnable (CI/TDD):** the portable lock (collision → no-op; stale → steal), the `ps`-based defer-guard, the installer OS-detection + the **rendered** launchd plist / Windows task content (structural: correct Label/interval/ProgramArguments/env, the `--oauth` no-op note, the caveats printed), the Linux path unchanged, the banner probe branching.
- **Per-OS real-run (operator — I cannot run launchd/Task Scheduler on this Pi):** `--apply` on a Mac → the LaunchAgent fires + a real drain writes a delta during a logged-in idle window; `--apply` on Windows (Git Bash) → the Scheduled Task fires + drains. Documented in the migration row as the verification the user performs.

## Rollout

Additive; gated; version bump + migration row. No MCP change. Reversible (`--uninstall` per OS). With no install, behaviour unchanged on every OS.
