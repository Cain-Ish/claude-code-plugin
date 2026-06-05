# SP-B — Opt-In Autonomous Consolidation (design)

- **Date:** 2026-06-05
- **Status:** spec → built (0.24.21)
- **Sub-project:** B of the autonomous-knowledge-loop roadmap (A deploy-bridge ✅ · B auto-consolidate · C dream-lifecycle · D retention · E project-continuity)
- **Grounded by:** the 2026-06-05 SP-B discovery sweep (consolidation surface · config.json status · containment-doctrine vs out-of-band precedent · nudge placement).

## Problem

SP-A made transcripts → per-transcript wiki/PROJECT deltas. But **no consolidation runs unattended** — only a deterministic reindex on each wiki write. Dedup, relate, enrich, and raw-inbox→node authoring are explicit `/second-brain:maintain` or a suggestion banner. A neglected KB silently accretes un-curated edges, an un-drained raw inbox, and blockless pages.

## The line (the crux)

The codebase already separates **content-free** consolidation (mutates state, *invents nothing*) from **LLM-driven** (authors prose / makes supersede judgements). Only the former is out-of-band-safe:

| Activity | Substrate | Out-of-band? |
|---|---|---|
| reindex, validate(+autofix), project-backfill | deterministic (local node) | ✅ yes — no creds |
| dedup, relate, enrich, ai-block + raw-node authoring | LLM (`claude` session) | 🔒 no — stays on `/maintain` |

The Anthropic containment doctrine forbids *the model deciding in-session* to fire side-effecting work — **not** an out-of-band job the user explicitly opted into (the `extract-drain.sh` timer is the blessed precedent). **Capture consent ≠ consolidation consent:** the job hard-gates on **both** an installed timer **and** `auto_improve:true`.

## Decision (user, 2026-06-05): **B — deterministic + nudge.** Full headless-LLM maintainer (C) is a deliberate, separately-consented future (and even then must stage→`dream_accept`, never write live).

## Build (0.24.21)

**B0 — config.json reader** (`lib.sh`). First config-file mechanism (everything else is env-only). `sb_config_get .path DEFAULT` (string) + `sb_config_bool .path on|off` (true→on · false→off · absent→default — a raw read, NOT jq `//`, so an explicit `false` is honoured). **Precedence: env overrides config** (`"${SB_FOO:-$(sb_config_get .foo HARD)}"`), preserving today's behaviour byte-for-byte when the file is absent. `ensure-dirs.sh` seeds `{"auto_improve": false}` (friendly to edit; opt-in preserved by the value; idempotent — never clobbers).

**B1 — self-install nudge** (`session-load.sh`). When `auto_improve` is OFF **and** the raw inbox is genuinely piling up (`RAW_N ≥ SB_NUDGE_RAW_THRESHOLD`, default 20), a SessionStart banner — *mutually exclusive* with the plain raw-inbox banner — offers the two honest remedies: `auto_improve:true` (auto-upkeeps **structure**) or `/second-brain:maintain` (**authors** the backlog). Kill switch `SB_AUTOCONSOLIDATE_NUDGE=off`.

**B2 — deterministic out-of-band consolidation** (`maintain-deterministic.sh`). validate(+autofix) → project-backfill → reindex; **no LLM, no credentials** → runs on the *hardened* drainer unit (no `~/.claude` grant). Called at the end of an `extract-drain.sh` cycle **when `auto_improve` is on**, so it inherits the drainer's CLAUDECODE-refuse / interactive-defer / single-flight guards — **no second timer**. Self-throttled to `SB_MAINTAIN_INTERVAL` (default 1h) so a 30-min drain cadence doesn't reindex every cycle; the `.last-maintain` marker doubles as the "last consolidated" timestamp. Never touches 4b/4c (LLM authoring).

## Non-goals / deferred

- **C — full headless LLM maintainer** (`claude -p` auto-authoring) → separate consent; must stage→`dream_accept`.
- Maintainer-cadence / retention TTLs in config.json → SP-D reads more keys.
- A first-class "last-maintain age" nudge predicate (the `.last-maintain` marker now exists to enable it) → future.

## Verification

- **Linux-CI:** config reader matrix (missing/partial/false/true/typo + the `//` false-trap), ensure-dirs seed/idempotency, the nudge fire/suppress matrix (threshold · auto-on · kill switch · mutual-exclusion), the deterministic job (marker, reindex, self-throttle), the extract-drain `auto_improve` gate (off→skip, on→run).
- **Operator (Pi):** flip `auto_improve:true`, confirm an idle-window drain leaves a fresh `.last-maintain` + a rebuilt `index.md`.

## Rollout

Additive; gated; version bump + migration row. No MCP change. With `auto_improve:false` (the seeded default) behaviour is unchanged.
