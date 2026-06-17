# Phase 1 — Restore the automation (design spec)

**Date:** 2026-06-17
**Status:** proposed (awaiting operator review)
**Scope:** Phase 1 of a 4-phase program. Phases 2–4 (slim persona, MCP hardening, debris cleanup) are out of scope here and have their own specs.

## The reframe (why this phase exists)

The plugin's hands-off pipeline (extract → consolidate → auto-accept) **is fully built and works under pure OAuth** — empirically confirmed on this Pi: an out-of-band extractor call returned valid JSON in ~15–20s with no `ANTHROPIC_API_KEY`. Config is already maxed (`auto_improve/auto_maintain: true`, `auto_accept: "all"`, timer installed + active).

So the "automated → manual" drift is **not** missing automation. It is **operational starvation + silent failure**:

1. The drainer **defers on any live interactive session** (`extract-drain.sh:42-63`). An always-on operator's 30-min timer almost always fires into a deferral → the drainer rarely runs.
2. The **120s extract timeout is marginal on a Pi 5** (`lib.sh:1237`) → `ec=124` → 3 strikes → quarantine.
3. Everything **fails soft** (`|| exit 0`, health written but never read) → the stall is invisible, so the operator reverts to manual.

Only **in-session real-time extraction** is *fundamentally* manual under OAuth (the recursive-claude lock). Everything else is fixable.

## Goals / success criteria

- The drainer makes **guaranteed forward progress** on an always-on machine (no indefinite deferral starvation).
- Extraction **succeeds on slow hardware** within the timeout under normal load.
- When automation **does** stall, the operator **sees it** (a loud, actionable SessionStart banner) instead of silently reverting to manual.
- The "stuck dream" concept has **one** definition, not four.
- The headless maintainer can **never** run unbounded, and a dead-on-arrival dream **self-heals** instead of wedging the pipeline.
- No regressions: every change ships with a test verifying against an **independent oracle** (filesystem fact / crafted fixture / round-trip), never re-asserting the implementation through its own reader.

## The six fixes

### 1.1 — Un-starve the drainer defer  *(root cause #1)*
**Current:** `sb_drain_should_defer` returns "defer" if ANY non-`-p` `claude` process is live.
**Risk/assumption:** the defer exists because the OAuth recursive-lock is claimed to be **global** (a live session would make `claude -p` hang). This premise is **unverified** and load-bearing.
**Design (safe under either premise):** keep the defer, but add a **bounded staleness-escape** — if the backlog has starved past a threshold (oldest pending transcript age and/or consecutive-defer count), do **one** drain attempt regardless. Worst case if the lock IS global: that one attempt is bounded by `SB_DRAIN_EXTRACT_TIMEOUT` and the poison-pill counter. If verification **disproves** the global lock, additionally relax the base defer to only defer on another live `claude -p`.
**Verify during impl:** does `claude -p` actually hang when a real interactive session is live? Resolve before finalizing the relaxation.
**Test:** `SB_INTERACTIVE_OVERRIDE=active` + a crafted starved backlog → asserts one attempt fires.

### 1.2 — Tune extract timeout for slow hardware  *(root cause)*
**Current:** `SB_DRAIN_EXTRACT_TIMEOUT:-120` (`lib.sh:1237`).
**Design:** raise the default to give Pi-class headroom (proposed **240s**), with a comment justifying it and confirming it stays well under the 7200s lock-staleness even fully degraded (`240 × BATCH × {direct,pty}`). Evaluate whether the drainer needs a tighter/chunked input cap than the shared `tail -c 200000` (`lib.sh:1281`) for the 2.9 MB backlog transcript. **No magic-number bump without rationale.**
**Test:** assert the new default + that a stubbed slow extractor inside the budget succeeds.

### 1.3 — Make failures loud  *(root cause #2)*
**Current:** drain timeouts/quarantine land in `error-log.jsonl`; nothing surfaces them. Existing banners key on counters, not the failure signature.
**Design:** a SessionStart banner (in `session-load.sh`, reusing the existing append plumbing) keyed on the **actual** signature — N consecutive `ec=124` drain failures, quarantine file present, or backlog starved past threshold — with concrete remedies (raise timeout / set `ANTHROPIC_API_KEY` / close session for a drain window). Kill-switch env, fail-open.
**Test:** crafted `error-log.jsonl` fixtures → banner fires / stays silent as expected.

### 1.4 — Unify the four dream-staleness definitions  *(Agent F #1, HIGH)*
**Current (4 disagreeing):** `dream-snapshot.sh:61` 6h mtime; `dream-autostage.sh:115` 24h created_at; `verify.sh:88` calendar-day; `maintain-llm-drain.sh` none. They produce contradictory health verdicts and a double-reclaim race.
**Design:** one helper `sb_dream_is_stale <status_file>` in `lib.sh` — **single policy**: status `pending|running` AND `status.json` mtime older than `SB_DREAM_RUN_TIMEOUT` (mtime is the right liveness signal; the runner heartbeats it between phases). **One terminal status:** `failed`. Migrate all four call sites to the helper (`dream-snapshot.sh` is already canonical).
**Test:** craft status.json fixtures at known mtimes; assert one consistent verdict across all callers.

### 1.5 — Headless maintainer: bounded timeout + pending self-heal  *(2 HIGH bugs)*
**B#1 (`maintain-llm-drain.sh:121,160`):** `${TBIN:+$TBIN "$TO"}` silently drops the timeout when no `timeout`/`gtimeout` exists → an unbounded `bwrap … claude -p --permission-mode bypassPermissions`. **Fix:** if `TBIN` empty, hard-fail (`_fail_step` + exit 0) — never run unbounded.
**B#2 (`maintain-llm-drain.sh:162-177`):** if the headless agent dies before writing `status=running`, the dream wedges `pending` (root cause of the 6h stall hit this session). **Fix:** after the run, if status is still `pending`, force `pending→failed` via the unified terminal status (1.4).
**Test:** stub the spawn → assert refusal when no timeout binary; assert `pending→failed` self-heal.

### 1.6 — Fix the stale "acceptance stays manual" banner
**Current:** `dream-autostage.sh` banners say "acceptance of the staged diff stays manual" even when `auto_accept: "all"` — training the operator to do it by hand.
**Design:** make the text conditional on `sb_config_get .auto_accept`: "will auto-accept (mode=X)" when not `off`. Low risk.
**Test:** both config states.

## Test strategy

TDD per fix; each test verifies against an **independent oracle** — crafted status.json/error-log fixtures, real filesystem state, or round-trip — never the implementation's own reader (per the standing convention that caught the "506 green tests, 14 bugs" gap).

## Release gate

- Feature branch (currently on `main` — branch first).
- Lockstep version bump: `plugin.json` + `marketplace.json` (+ `mcp/src/server.ts` only if MCP touched — Phase 1 is scripts-only, so likely no MCP bump) + `CHANGELOG.md`; `migrations/<v>.md` only if a real upgrade action is needed (1.4's status normalization may warrant one).
- Full test suite + smoke against `~/.second-brain/error-log.jsonl`.
- Clean `/second-brain:code-review-deep` before merge.

## Out of scope (later phases)
- Phase 2: slim persona (cut duplicate card → USER.md, drop catalog line, wire-or-cut `persona_dismiss`, re-cap/de-plumb `persona_think`).
- Phase 3: MCP hardening (`autofix:false` default, nested-spawn guard on destructive write-tools).
- Phase 4: debris (stranded migrations, MCP version-stamp gate, phantom config knobs, dead branches).
