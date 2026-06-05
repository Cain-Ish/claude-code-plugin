# SP-C — Dream Lifecycle Truth (design)

- **Date:** 2026-06-05
- **Status:** spec → built (0.24.22)
- **Sub-project:** C of the autonomous-knowledge-loop roadmap (A ✅ · B ✅ · C dream-lifecycle · D retention · E project-continuity)
- **Grounded by:** the 2026-06-05 SP-C discovery (state machine · banner predicate · retention · the live dream store).

## Verdict — it was a banner bug, not lost knowledge

All dreams on the dogfood machine are `status:"completed"` **and** `archived_at`-stamped (terminal — their pages were applied minutes after the run). `drm_20260517T152815Z` (the one that "nagged for 19 days") was archived 45 min after it ended. The nag came from `session-load.sh:531` keying the banner on `status=="completed"` **alone** — no `archived_at` guard — then `break`-ing on the oldest, so it re-fired forever. Every other consumer (`dream_list` `dream.ts:226`, review, status, `verify.sh`) honours `archived_at`; the banner alone forgot. The user's earlier "two stale dreams" / "actually archived" confusion was exactly this.

## State model (unchanged — SP-C reads it, doesn't extend it)

`DreamStatus.status` is a 5-value union (`pending|running|completed|failed|canceled`). **accepted/discarded/archived are NOT status values** — they are modelled by stamping `archived_at` (and reclaiming staging) while `status` stays `completed`. The canonical "awaiting review" predicate is therefore **`status=="completed" && archived_at==null`**. SP-C adopts this predicate; it deliberately does **not** add a status enum value (a larger model change, deferred).

## Build (0.24.22)

**C1 — Terminal-state guard (the bug fix).** `session-load.sh` dream nudge now skips any dream with a non-null `archived_at` (`continue`), so the banner goes **silent** once a dream is accepted/discarded. This is the whole fix for the reported nag.

**C2 — Stale escalation.** A completed-unarchived dream older than `SB_DREAM_STALE_DAYS` (default 7) gets a louder, distinctly-tagged banner (`dream-stale-nudge`): *"finished ~Nd ago and is still UNREVIEWED … these changes are NOT in your wiki yet"* — encoding the user's rule that an unaccepted dream is unpopulated knowledge. Age = `status.json` mtime (≈ completion time until archived; portable `stat -c||-f`, no `date -d`).

**C3 — Iterate-all.** Dropped the `break`; all non-archived completed dreams are counted and the oldest surfaced with a `(+N more)` tail, so a second pending dream is never silently dropped.

**C5 — Running-reclaim (a separate, serious bug the discovery surfaced).** `dream-snapshot.sh:49` refuses to create a dream while one is `pending`/`running` — so a crash mid-run would **deadlock every future dream forever**. Now a pending/running dream whose `status.json` hasn't advanced in `SB_DREAM_RUN_TIMEOUT` (default **3h**, well beyond a healthy consolidation) is treated as crashed: marked `failed` (recoverable — its staging is kept) and the new dream proceeds. A *fresh* running dream still blocks (no concurrent runs).

## C4 — Retention → SP-D (no code in SP-C)

SP-C performs **no disk deletion**. The existing prune in `dream-snapshot.sh:56-67` is fragile (hardcoded count-cap of 5, only fires on create, oldest-by-name not by-age, skips canceled/failed staging). That, plus a new `archived_at`-based TTL and reclaim of canceled/failed staging, is **SP-D's `sb_prune_archives`** — config-driven, runnable standalone on maintainer cadence. SP-C leaves the accept/discard staging-reclaim where it is (correct + cheap).

## Decision (user, 2026-06-05): **signal-only, louder** — never auto-resolve. SP-C never drops unpopulated knowledge (no auto-discard, no silent auto-archive); it only tells the truth (silent when terminal, loud when genuinely stale) and unblocks a crashed run.

## Verification

- **Linux-CI:** `test-dream-nudge.sh` — archived→silent, fresh→nudge, stale→escalated, multiple→count, running→no-nudge. `test-dream-lifecycle.sh` subtests 8/9 — fresh running blocks, stale running reclaimed→failed + new dream proceeds.
- **Operator (Pi):** next SessionStart, the 19-day `drm_20260517` nag is gone (it's archived); a genuinely-stale unaccepted dream would escalate.

## Rollout

Additive; gated; version bump + migration row. No MCP change. Reads existing `archived_at`/mtime; with no dreams, behaviour unchanged.
