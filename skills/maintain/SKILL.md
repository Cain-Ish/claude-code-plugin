---
name: maintain
description: An explicit full maintenance run over the second-brain knowledge base, including the bulk-authoring work that automatic runs skip. Use when the operator wants the wiki consolidated or the raw inbox drained to completion.
user-invocable: true
disable-model-invocation: true
allowed-tools: Agent Read Bash(mktemp *) Bash(find *) Bash(test *) mcp__plugin_second-brain_knowledge-base__knowledge_reindex
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

**Before the loop — stamp the time anchor.** Create a marker file the per-batch postflight
compares against: `MAINT_STAMP=$(mktemp "${TMPDIR:-/tmp}/sb-maint.XXXXXX")`. Do this once, before
the first dispatch, and **note the printed path** — shell variables do not persist between Bash
invocations, so paste the literal stamp path into every postflight command below.

Loop, up to a hard cap of **30 iterations**:

1. Dispatch **`second-brain:raw-drainer`** with the `Agent` tool (a fresh context each time). It
   reconciles, drains up to `SB_DRAIN_BATCH` (default 5) items with full provenance, reconciles
   again, and ends its report with a line `DRAINED: <n>  REMAINING: <m>`.

   **REQUIRED delegation packet — refuse, never repair.** The dispatch prompt MUST carry all
   three fields:
   1. the **absolute** wiki destination path — `$KNOWLEDGE_DIR/wiki` resolved to an absolute
      path (default `~/knowledge/wiki`, expanded);
   2. the batch bound (`SB_DRAIN_BATCH`, default 5);
   3. the exact `DRAINED: <n>  REMAINING: <m>` report format.

   A dispatch missing any field is **REFUSED** — surface the gap; never dispatch on a guessed
   value.
2. **Touch-set postflight (REQUIRED after every batch).** If the legacy wiki (default
   `~/.second-brain/wiki`) exists and contains any `*.md` newer than the stamp:
   ```bash
   BD="${BRAIN_DIR:-$HOME/.second-brain}"; test -d "$BD/wiki" && find "$BD/wiki" -name '*.md' -newer "<literal stamp path>"
   ```
   (The `BD=` fallback is load-bearing — `BRAIN_DIR` is not exported in this context, and a bare
   `$BRAIN_DIR/wiki` would expand to `/wiki` and silently never fire.)
   Any output → **STOP the drain loop immediately** (hard abort, not a warning). List the
   offending paths, record `BLAME: child-under-delivered`, and instruct the fix: move the
   pages to `$KNOWLEDGE_DIR/wiki/<category>/`, run `knowledge_reindex`, and re-run
   `/second-brain:maintain`. Rationale: the PreToolUse wiki-write-guard covers Write/Edit but
   not Bash redirection — this postflight is the deterministic backstop.
3. Parse the report's final line.
   - **`<n>` (DRAINED) is 0** → a full pass drained nothing new (only deliberately-skipped
     low-value items remain). **Stop the loop.**
   - **`<m>` (REMAINING) is 0** → the inbox is empty. **Stop the loop.**
   - otherwise → dispatch the worker again (more items to drain).

   **No-shrink stall check.** Across **successful** batches (parseable report, `DRAINED > 0`),
   `<m>` must **strictly decrease**. The first successful batch where it fails to decrease arms
   a counter; a **second consecutive** non-decreasing batch → **stop the loop and report a
   stall naming the stuck count** (fail loud). A decreasing batch resets the counter.
   (`DRAINED: 0` already terminates the loop above — this catches the pathological
   drain-but-no-shrink shape, where batches keep claiming progress while the inbox never gets
   smaller.)
4. If you reach the 30-iteration cap with `<m>` still > 0, **stop and report a possible stall**
   (fail loud) — name the remaining count so the user can inspect with
   `/second-brain:capture --list`. (A healthy drain terminates on `DRAINED: 0` long before the
   cap.)

If a worker dispatch returns no parseable `DRAINED:`/`REMAINING:` line (e.g. it died), treat it
as progress-unknown: dispatch once more; if the second consecutive dispatch also returns no line,
stop and report it rather than looping blind. In BOTH branches (redispatch and stall-report),
scan the worker's response for a `BLAME:` line and carry it into the wrap-up — a packet refusal
reports `DRAINED: 0` with `BLAME: caller-under-supplied`, and that classification must not be
lost just because the batch made no progress.

After the loop, summarize: total items created / updated across all batches, and any items left
unprocessed. If any batch failed or was aborted, record the blame class in this wrap-up so
session extraction mines it: `BLAME: caller-under-supplied` (the delegation packet was
defective) or `BLAME: child-under-delivered` (the drainer misbehaved — e.g. postflight hit,
missing report line). Items remain only because a worker judged them obvious low-value (boilerplate / stubs)
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
