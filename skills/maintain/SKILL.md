---
name: maintain
description: Run the knowledge-maintainer on the second-brain wiki — audit, dedup, relate, enrich, author ai-blocks — then drain the raw inbox to completion via a looped drain worker. An explicit full maintenance run.
user-invocable: true
disable-model-invocation: true
allowed-tools: Agent Read mcp__plugin_second-brain_knowledge-base__knowledge_reindex
---

# /second-brain:maintain — full maintenance run

An **explicit** full maintenance pass over the knowledge base, in three stages. Unlike an
auto-dispatched run (which the plugin triggers after extraction or a reindex and which performs
only the consolidation phases), this also performs the two **bulk-authoring** phases that
auto-runs deliberately skip: **Phase 4b** (author/backfill the machine-first `ai-block`) and the
**raw-inbox drain** (turn `/second-brain:capture` + setup-deep-scan material into wiki nodes,
conservative create/update, never auto-discard, with provenance).

## Stage 1 — consolidation (one dispatch)

Dispatch the **knowledge-maintainer** with the `Agent` tool, `subagent_type:
"second-brain:knowledge-maintainer"`. Tell it:

> This is an **explicit** `/second-brain:maintain` run. Perform phases 0–4, **4b** (ai-block
> authoring/backfill), the opt-in **project backfill**, and **5** (reindex). **Do NOT drain the
> raw inbox in-context** — the raw-inbox drain (Phase 4c) is handled separately by this skill's
> drain loop after you finish. Report what you audited / merged / related / enriched, ai-blocks
> authored, and the reindex result.

Relay its report.

## Stage 2 — drain the raw inbox to completion (loop the drain worker)

This is the truncation-safe drain: instead of draining every item in one context (which truncates
after a few large documents), dispatch a **fresh-context worker per batch** and loop until the
inbox makes no further progress.

Loop, up to a hard cap of **30 iterations**:

1. Dispatch **`second-brain:raw-drainer`** with the `Agent` tool (a fresh context each time). It
   reconciles, drains up to `SB_DRAIN_BATCH` (default 5) items with full provenance, reconciles
   again, and ends its report with a line `DRAINED: <n>  REMAINING: <m>`.
2. Parse that final line.
   - **`<n>` (DRAINED) is 0** → a full pass drained nothing new (only deliberately-skipped
     low-value items remain). **Stop the loop.**
   - **`<m>` (REMAINING) is 0** → the inbox is empty. **Stop the loop.**
   - otherwise → dispatch the worker again (more items to drain).
3. If you reach the 30-iteration cap with `<m>` still > 0, **stop and report a possible stall**
   (fail loud) — name the remaining count so the user can inspect with
   `/second-brain:capture --list`. (A healthy drain terminates on `DRAINED: 0` long before the
   cap.)

If a worker dispatch returns no parseable `DRAINED:`/`REMAINING:` line (e.g. it died), treat it
as progress-unknown: dispatch once more; if the second consecutive dispatch also returns no line,
stop and report it rather than looping blind.

After the loop, summarize: total items created / updated across all batches, and any items left
unprocessed. Items remain only because a worker judged them obvious low-value (boilerplate / stubs)
on a full scan — tell the user to **inspect them with `/second-brain:capture --list` before
discarding**, and prune only confirmed noise with `/second-brain:capture --discard <id>` (pruning is
always the user's call, never automatic).

## Stage 3 — final reindex

The drain loop added/updated pages after Stage 1's reindex, so regenerate the catalog once more:
call the `knowledge_reindex` MCP tool. Relay the result.

---

**Notes**
- The maintainer's consolidation is bounded by its 50-change/run cap; if it reports work left over
  the cap, re-run `/second-brain:maintain`.
- The drain targets the **active project**'s inbox by default. The whole drain is resumable and
  idempotent (reconcile-backed), so re-running `/second-brain:maintain` is always safe.
- **Transient inbox (opt-in):** processed raw `.md` files are kept in `raw/` as an audit trail by
  default (never searched — search is scoped to `~/knowledge/wiki/`). Set `SB_RAW_PRUNE_AFTER_DRAIN=1`
  to have each drain batch delete processed/discarded items after reconcile, or run
  `/second-brain:capture --prune-processed` for a one-off cleanup. Unprocessed/malformed are kept.
