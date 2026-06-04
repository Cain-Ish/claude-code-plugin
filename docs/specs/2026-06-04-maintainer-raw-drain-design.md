# SP-4 — Maintainer Raw-Inbox Drain (Phase 4c) — Design

**Status:** approved (2026-06-04)
**Vision:** consolidation roadmap — sub-project SP-4 of 6 (SP-0 ✓, SP-1 ✓, SP-2 raw inbox ✓, SP-3 setup deep-scan ✓).
**Scope chosen:** *Conservative + provenance.* The existing `knowledge-maintainer` agent gains a phase that drains the raw inbox into wiki nodes — create/update only (never auto-discard), with bidirectional provenance. Extends the existing maintainer; does not build a new one.

---

## Problem

SP-2 built the raw inbox and SP-3 fills it (setup deep-scan), but nothing **drains** it — unprocessed items accumulate with no path into the wiki. The `knowledge-maintainer` agent already keeps the KB state-of-the-art (Phase 1 AUDIT, 2 DEDUPLICATE, 3 RELATE, 4 ENRICH, 5 REINDEX, cold-tier archive awareness, the 50/run cap), and Phase 4b already does deliberate, explicit-only, schema-grounded **authoring** of page content from existing material. SP-4 adds the one missing intake: a Phase 4c that turns raw-inbox items into wiki nodes, reusing 4b's discipline.

## Goals

1. Drain unprocessed raw items (SP-2 capture + SP-3 setup-scan) into wiki nodes.
2. Conservative: create or update, **never auto-discard**; nothing silently dropped.
3. Bidirectional provenance: the node records its source; the raw item records the node it became and is marked `processed` (kept as the audit trail).
4. Reuse the maintainer's existing authoring discipline (closed vocab, no invented content, 50/run cap, explicit-invocation only).

## Non-goals (deferred)

- SP-5 surface cleanup + cross-OS finish.
- Authoring from binary blobs (a blob item yields a node from its manifest **gist** only; the bytes stay as the raw blob).
- A standalone `/second-brain:maintain` command (the maintainer stays dispatched as today).
- Auto-discard of noise (the user chose conservative; low-value items are reported, not removed).
- New MCP server tool / kb-schema change (`processed` is already a valid status; the 8 content categories already exist).

---

## Architecture

```
/second-brain:maintain (or "clean up the KB")  ──▶  knowledge-maintainer agent
   Phases 1–4, 4b, 5, 6  (existing)
   Phase 4c RAW DRAIN     (NEW, explicit-only):
     raw-capture-cli pending  ──▶  TSV work-list (unprocessed items, this project)
       for each item (≤ remaining 50/run budget):
         Read raw/<id>.md  ──▶  decide:
           target_node set      → UPDATE that node
           else strong search   → UPDATE matched node
           else                 → CREATE wiki/<type>/<slug>.md  (+ ai-block)
         add "## Sources" provenance line to the node
         raw-capture-cli process <id> --node <slug>   (status→processed, target_node back-ref)
       knowledge_reindex
       report: created / updated / left-unprocessed (low-value, for manual prune)
```

The **authoring** is the agent's judgment (LLM, like Phase 4/4b). The **plumbing** (work-list + status transition) is deterministic TS/bash.

### Components

| Unit | Responsibility | Action |
|---|---|---|
| `mcp/src/tools/raw-inbox.ts` | `markProcessed(brainDir, slug, id, nodeSlug?)` — status→`processed`, optional `target_node` back-ref (atomic, reuses setStatus's rewrite) | Modify |
| `mcp/src/tools/raw-inbox.test.ts` | vitest for `markProcessed` | Modify |
| `mcp/src/tools/raw-capture-cli.ts` | `pending` (TSV work-list) + `process <id> [--node <slug>]` actions | Modify |
| `tests/test-raw-capture.sh` | e2e for `pending` + `process` | Modify |
| `agents/knowledge-maintainer.md` | **Phase 4c** (the drain prompt) + boundary/cap wording | Modify |
| `tests/test-maintainer-raw-drain.sh` | structural guard on the agent prompt | Create |

---

## Phase 4c — the drain (agent prompt)

Inserted after Phase 4b, before Phase 5 REINDEX. Mirrors 4b's structure:

1. **Work-list (deterministic).**
   ```bash
   node "$CLAUDE_PLUGIN_ROOT/mcp/dist/tools/raw-capture-cli.bundle.js" pending
   ```
   Emits a TSV row per **unprocessed** item for the active project: `id⇥path⇥captured_by⇥target_node⇥gist`. Processed/discarded items are excluded (idempotent re-runs). Empty output → skip the phase.

2. **For each item** (closed vocabulary; never invent content — author from the raw material + existing prose only, the 4b discipline):
   - `Read` the item's `path` (the captured text, or a binary item's manifest gist).
   - **Decide the target node:**
     - `target_node` set (non-empty) → **update** `wiki/**/<target_node>.md` (read it in full first).
     - else `knowledge_search` the gist/key terms → if a top hit is a strong, same-topic match → **update** it.
     - else **create** a new page. **Type** (one of the 8 content categories `learnings decisions entities issues concepts security state sources`) is judged from the content; `captured_by` is a hint — `setup-scan` (existing repo docs: READMEs, ADRs, designs) leans `entities`/`concepts`/`decisions`/`sources`; `user`/`dream` captures lean `learnings`/`decisions`. Slug = kebab-case of the title/gist. Author frontmatter + body + an ai-block (via `ai-block-render-cli`, the 4b path).
   - **Provenance (forward):** add/extend a `## Sources` section on the node with `- captured from <source> (raw <id>)` (where `<source>` is the item's `source` frontmatter — a path or URL).
   - **Mark processed (back-ref):**
     ```bash
     node "$CLAUDE_PLUGIN_ROOT/mcp/dist/tools/raw-capture-cli.bundle.js" process <id> --node <slug>
     ```
     Sets the item's `status: processed` and `target_node: <slug>` (the node it became). The raw `.md` stays in `raw/` as the audit trail.
   - **Self-check:** a follow-up `knowledge_validate` shows no new `broken_link`/`ai_block_*` error for the node.

3. **Conservative rule:** **never** mark an item `discarded`. A low-value/noise item (boilerplate, a stub, a `LICENSE` that slipped the SP-3 denylist) is **left unprocessed** and listed in the run report (`left N item(s) unprocessed — review with /second-brain:capture --list, prune with --discard <id>`).

4. **Budget:** each item processed counts as **one change against the 50/run cap** (shared with the other phases). Exceed → process the highest-value first, report the remainder for the next run.

**Boundary:** Phase 4c runs **only on an explicit `/second-brain:maintain`** (or "maintain/clean up the KB"). An auto-dispatched run (threshold counter / reindex-issues / post-extraction) **skips Phase 4c** — same §5b boundary as 4b (bulk-authoring page content stays deliberate, never unattended).

---

## Data / CLI contract

### `raw-inbox.ts` — `markProcessed`

```typescript
export async function markProcessed(brainDir: string, slug: string, id: string,
                                    nodeSlug?: string): Promise<boolean>;
```
- `assertSafeSlug(slug)`; reject an unsafe `id` (the SP-2 `isSafeId` guard) → `false`.
- Rewrites the item's frontmatter: `status: processed`, and if `nodeSlug` given, sets/updates `target_node: <nodeSlug>` (newline-sanitized via the SP-2 `fmValue`; `nodeSlug` is a wiki slug — no traversal risk in a frontmatter value). Atomic temp+rename. Returns `false` if the item is absent.

### `raw-capture-cli.ts` — two actions

- `pending` → for each `listItems` entry with `status === 'unprocessed'` (note: a `malformed` item is surfaced by `--list` but is **not** drainable, so `pending` emits only well-formed unprocessed items), print `\t`-joined `id`, absolute `path` (`rawDir/<id>.md`), `captured_by`, `target_node` (empty if unset), `gist`. One row per item; nothing else on stdout (machine-readable).
- `process <id> [--node <slug>]` → `markProcessed(brainDir, slug, id, node)`; print `Processed <id>` (or `No raw item with id <id>`).

## Error handling

- No active project → both new actions refuse (same as the rest of the CLI).
- Unsafe `id` → `markProcessed` returns false; CLI prints the not-found message.
- A `malformed` raw item → excluded from `pending` (not drainable); it still shows in `--list` for manual repair/discard.
- Agent-side: an item it can't confidently author → skip + report (stays unprocessed); never invent content; never exceed the cap.
- Re-run safety: `pending` is status-derived, so a processed item never reappears.

## Cross-platform

`markProcessed`/`pending` use `path` + node `fs` (portable). The agent prompt's bash is a single `node …` invocation per call (no awk; mawk-safe). TSV uses literal tabs.

## Testing (TDD)

| Test | Covers |
|---|---|
| `raw-inbox.test.ts` (vitest) | `markProcessed` sets `status: processed`; with `nodeSlug` sets `target_node`; rejects an unsafe id (false); returns false for an absent id; `unprocessedCount` drops after processing |
| `test-raw-capture.sh` (bash) | `pending` emits a TSV row for an unprocessed item (path + captured_by + gist) and **omits** a processed and a malformed one; `process <id> --node foo` flips status + sets target_node (grep the file); re-`pending` no longer lists it |
| `test-maintainer-raw-drain.sh` (bash) | the agent prompt contains a **Phase 4c** that: invokes `raw-capture-cli pending` + `process`; states the create/update/attach decision; states **never auto-discard** (leave unprocessed + report); states the **explicit-only** boundary + the **50/run** cap |

## Versioning

Plugin patch bump + migration row (additive; Phase 4c only fires on explicit maintain, and only when the raw inbox is non-empty). MCP server unchanged (the CLI is a standalone bundle; no server tool). Back-compat: with an empty inbox or an auto-dispatched run, the maintainer behaves exactly as before.
