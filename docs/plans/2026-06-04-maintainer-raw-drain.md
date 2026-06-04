# SP-4 Maintainer Raw-Inbox Drain Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** The `knowledge-maintainer` agent gains Phase 4c — a conservative, explicit-only drain that turns unprocessed raw-inbox items into wiki nodes with bidirectional provenance — backed by two new `raw-capture-cli` actions (`pending`, `process`) and a new `markProcessed` in `raw-inbox.ts`.

**Architecture:** `markProcessed` (status→processed + optional `target_node` back-ref) mirrors `setStatus`'s surgical frontmatter rewrite. The CLI gains `pending` (deterministic TSV work-list of drainable items) and `process <id> [--node <slug>]`. The agent's Phase 4c reads the work-list, authors a node per item (create/update, never auto-discard), writes a `## Sources` provenance line, and calls `process`. Pure plumbing in TS/bash; authoring judgment in the agent prompt.

**Tech Stack:** TypeScript (esbuild ESM), vitest, POSIX bash (mawk-safe), the maintainer agent prompt.

**Spec:** `docs/specs/2026-06-04-maintainer-raw-drain-design.md`

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `mcp/src/tools/raw-inbox.ts` | `markProcessed(brainDir, slug, id, nodeSlug?)` | Modify |
| `mcp/src/tools/raw-inbox.test.ts` | vitest for `markProcessed` | Modify |
| `mcp/src/tools/raw-capture-cli.ts` | `pending` + `process` actions | Modify |
| `tests/test-raw-capture.sh` | e2e for `pending` + `process` | Modify |
| `agents/knowledge-maintainer.md` | **Phase 4c** (the drain prompt) | Modify |
| `tests/test-maintainer-raw-drain.sh` | structural guard on the agent prompt | Create |

No new MCP server tool, no kb-schema change (`processed` already valid; the 8 categories already exist).

---

## Task 1: `markProcessed` in `raw-inbox.ts`

**Files:**
- Modify: `mcp/src/tools/raw-inbox.ts`
- Test: `mcp/src/tools/raw-inbox.test.ts`

- [ ] **Step 1: Write the failing test.** In `mcp/src/tools/raw-inbox.test.ts`, change the import to add `markProcessed`:

```typescript
import { captureItem, listItems, setStatus, unprocessedCount, rawDir, markProcessed } from './raw-inbox.js';
```

Then add this block just before the final closing `});` of the top-level `describe('raw-inbox', ...)`:

```typescript
  it('markProcessed sets status processed and the target_node back-ref', async () => {
    const { brainDir, slug } = await brain();
    const r = await captureItem({ brainDir, slug, kind: 'paste', source: 'paste', content: 'drain me', now: NOW });
    expect(await markProcessed(brainDir, slug, r.id, 'auth-design')).toBe(true);
    const item = (await listItems(brainDir, slug))[0];
    expect(item.status).toBe('processed');
    expect(item.target_node).toBe('auth-design');
    expect(await unprocessedCount(brainDir, slug)).toBe(0);
  });

  it('markProcessed without a node still processes (no target_node added)', async () => {
    const { brainDir, slug } = await brain();
    const r = await captureItem({ brainDir, slug, kind: 'paste', source: 'paste', content: 'no node', now: NOW });
    expect(await markProcessed(brainDir, slug, r.id)).toBe(true);
    const item = (await listItems(brainDir, slug))[0];
    expect(item.status).toBe('processed');
    expect(item.target_node).toBeUndefined();
  });

  it('markProcessed rejects an unsafe id and a missing id', async () => {
    const { brainDir, slug } = await brain();
    expect(await markProcessed(brainDir, slug, '../evil', 'x')).toBe(false);
    expect(await markProcessed(brainDir, slug, 'nope', 'x')).toBe(false);
  });
```

- [ ] **Step 2: Run it to verify it fails.**

Run: `cd mcp && npx vitest run raw-inbox.test.ts`
Expected: FAIL — `markProcessed is not a function` (not exported).

- [ ] **Step 3: Implement `markProcessed`.** In `mcp/src/tools/raw-inbox.ts`, add it immediately after the existing `setStatus` function:

```typescript
/** Drain transition: status→processed, and (if given) record the wiki node this item became as a
 *  target_node back-ref. Surgical rewrite like setStatus; the raw .md is kept as the audit trail. */
export async function markProcessed(brainDir: string, slug: string, id: string, nodeSlug?: string): Promise<boolean> {
  assertSafeSlug(slug);
  if (!isSafeId(id)) return false;
  const file = join(rawDir(brainDir, slug), `${id}.md`);
  let content: string;
  try { content = await fs.readFile(file, 'utf-8'); } catch { return false; }
  let next = /^status:[ \t]*.*$/m.test(content)
    ? content.replace(/^status:[ \t]*.*$/m, 'status: processed')
    : content.replace(/^---\r?\n/, '---\nstatus: processed\n');
  if (nodeSlug) {
    const tn = `target_node: ${fmValue(nodeSlug)}`;
    next = /^target_node:[ \t]*.*$/m.test(next)
      ? next.replace(/^target_node:[ \t]*.*$/m, tn)               // update existing
      : next.replace(/^status:[ \t]*processed$/m, `status: processed\n${tn}`); // insert after status
  }
  const tmp = `${file}.tmp`;
  await fs.writeFile(tmp, next);
  await fs.rename(tmp, file); // atomic
  return true;
}
```

> Reuses the private `isSafeId`, `fmValue`, and the exported `rawDir`/`assertSafeSlug` already in this file. `nodeSlug` is a wiki slug placed in a frontmatter value — `fmValue` strips any CR/LF (no injection), and it is never used as a path here (no traversal risk).

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `cd mcp && npx vitest run raw-inbox.test.ts`
Expected: PASS (all raw-inbox tests, including the 3 new ones).

- [ ] **Step 5: Commit.**

```bash
git add mcp/src/tools/raw-inbox.ts mcp/src/tools/raw-inbox.test.ts
git commit -m "feat(kb): raw-inbox markProcessed — drain transition + provenance back-ref (SP-4 Task 1)"
```

---

## Task 2: `pending` + `process` CLI actions

**Files:**
- Modify: `mcp/src/tools/raw-capture-cli.ts`
- Test: `tests/test-raw-capture.sh`

- [ ] **Step 1: Write the failing test.** In `tests/test-raw-capture.sh`, add this block immediately before the final `rm -rf "$T"` / `echo; echo "ALL PASS"` lines:

```bash
# --- SP-4: pending work-list + process (drain plumbing) ---
run capture "a fresh drain candidate note" >/dev/null
PID=$(run pending | cut -f1 | head -1)
[ -n "$PID" ] || fail "pending emitted no unprocessed item"
run pending | grep -q "$RAW/$PID.md" || fail "pending row missing the item path"
run pending | grep -q 'a fresh drain candidate note' || fail "pending row missing the gist"
pass "pending emits a TSV work-list (id, path, gist) of unprocessed items"

run process "$PID" --node my-node | grep -q "Processed $PID" || fail "process did not report"
grep -q '^status: processed$' "$RAW/$PID.md" || fail "status not flipped to processed"
grep -q '^target_node: my-node$' "$RAW/$PID.md" || fail "target_node back-ref not set"
[ -z "$(run pending | grep "$PID" || true)" ] || fail "processed item still appears in pending"
pass "process flips status + sets target_node; pending excludes processed"
```

- [ ] **Step 2: Run it to verify it fails.**

Run: `bash tests/test-raw-capture.sh`
Expected: FAIL — `pending emitted no unprocessed item` (the `pending` action prints the usage line, not TSV, so `cut -f1` is empty).

- [ ] **Step 3: Add the actions.** In `mcp/src/tools/raw-capture-cli.ts`:

First extend the import (add `markProcessed` and `rawDir`):

```typescript
import { captureItem, listItems, setStatus, unprocessedCount, markProcessed, rawDir } from './raw-inbox.js';
```

Then add two branches to the `if (action === …)` chain, immediately after the `discard` branch:

```typescript
    } else if (action === 'pending') {
      // Deterministic TSV work-list for the maintainer drain (Phase 4c): drainable items only.
      for (const i of await listItems(brainDir, slug)) {
        if (i.status !== 'unprocessed' || i.malformed) continue;
        const path = join(rawDir(brainDir, slug), `${i.id}.md`);
        const cell = (s: string) => (s || '').replace(/[\t\r\n]+/g, ' ');
        console.log([i.id, path, i.captured_by, i.target_node ?? '', cell(i.gist)].join('\t'));
      }
    } else if (action === 'process') {
      const id = rest[0];
      if (!id) { console.log('usage: capture process <id> [--node <slug>]'); return; }
      console.log(await markProcessed(brainDir, slug, id, node)
        ? `Processed ${id}` : `No raw item with id ${id}.`);
```

> `node` (the `--node <slug>` value) is already parsed by the existing `takeNode(process.argv.slice(3))`. `join`/`rawDir` give the absolute item path. `pending` prints ONLY TSV rows (machine-readable — no header/footer).

- [ ] **Step 4: Build, then run the test to verify it passes.**

Run: `cd mcp && npm run build && cd .. && bash tests/test-raw-capture.sh`
Expected: `ALL PASS` (existing assertions + the 2 new SP-4 ones).

- [ ] **Step 5: Commit.**

```bash
git add mcp/src/tools/raw-capture-cli.ts tests/test-raw-capture.sh mcp/dist
git commit -m "feat(kb): raw-capture-cli pending + process actions (SP-4 Task 2)"
```

---

## Task 3: Phase 4c in the maintainer agent

**Files:**
- Modify: `agents/knowledge-maintainer.md`
- Test: `tests/test-maintainer-raw-drain.sh`

- [ ] **Step 1: Write the failing structural test.** Create `tests/test-maintainer-raw-drain.sh`:

```bash
#!/bin/bash
# Guard: the knowledge-maintainer agent has a Phase 4c raw-inbox drain wired to the SP-2 CLI,
# conservative (never auto-discard), explicit-only, with provenance.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
A="$ROOT/agents/knowledge-maintainer.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

[ -f "$A" ] || fail "knowledge-maintainer.md missing"
grep -q 'Phase 4c' "$A" || fail "no Phase 4c (raw-inbox drain) section"
grep -q 'raw-capture-cli.bundle.js' "$A" || fail "Phase 4c does not invoke raw-capture-cli"
grep -qw 'pending' "$A" || fail "Phase 4c missing the pending work-list"
grep -qE 'process <id>|process \$' "$A" || fail "Phase 4c missing the process action"
pass "Phase 4c invokes pending work-list + process"

grep -qiE 'never .*discard|do not .*discard|left .*unprocessed' "$A" \
  || fail "Phase 4c missing the conservative never-auto-discard rule"
pass "Phase 4c states the conservative (no auto-discard) policy"

grep -q '## Sources' "$A" || fail "Phase 4c missing the ## Sources provenance"
pass "Phase 4c records ## Sources provenance"

# explicit-only boundary appears for Phase 4c (the section names itself alongside 4b)
grep -qiE 'Phase 4c.*explicit|explicit.*Phase 4c|4b/4c|4b and 4c|4b, 4c' "$A" \
  || grep -qiE 'explicit-invocation only' "$A" \
  || fail "Phase 4c missing the explicit-only boundary"
pass "Phase 4c is explicit-invocation only"

echo; echo "ALL PASS"
```

- [ ] **Step 2: Run it to verify it fails.**

Run: `bash tests/test-maintainer-raw-drain.sh`
Expected: FAIL — `no Phase 4c (raw-inbox drain) section`.

- [ ] **Step 3: Insert Phase 4c.** In `agents/knowledge-maintainer.md`, insert the following block immediately BEFORE the `## Phase 5: REINDEX` heading:

````markdown
## Phase 4c: RAW-INBOX DRAIN — turn captured material into wiki nodes

The raw inbox (`~/.second-brain/projects/<slug>/raw/`) holds **unprocessed** material dropped by
`/second-brain:capture` (SP-2) and the setup deep-scan (SP-3). This phase turns it into wiki nodes —
**conservatively** and with provenance. Same authoring discipline as Phase 4b: author only from the
captured material + existing prose, **never invent** content.

1. **Get the deterministic work-list** (drainable = unprocessed, well-formed; for the active project):
   ```bash
   node "$CLAUDE_PLUGIN_ROOT/mcp/dist/tools/raw-capture-cli.bundle.js" pending
   ```
   Each TSV row is `id⇥path⇥captured_by⇥target_node⇥gist`. Empty output → skip this phase. (Malformed
   items are excluded here — they still show in `/second-brain:capture --list` for manual repair.)

2. **For each item** (closed vocabulary — the 8 content categories `learnings decisions entities issues
   concepts security state sources`; never invent a type or content):
   - `Read` the item's `path`.
   - **Decide the target node:**
     - `target_node` non-empty → **update** that wiki page (`Read` it in full first).
     - else `knowledge_search` the gist / key terms → a top hit that is a *strong, same-topic* match →
       **update** it.
     - else **create** a new page. Judge the type from the content (`captured_by` is a hint:
       `setup-scan` = existing repo docs → lean `entities`/`concepts`/`decisions`/`sources`;
       `user`/`dream` = deliberate → lean `learnings`/`decisions`). `Write`
       `~/knowledge/wiki/<type>/<kebab-slug>.md` with frontmatter (`title`, `type`, the active
       `project:` facet) + body authored from the material, then add an ai-block via the Phase 4b
       `ai-block-render-cli` path.
   - **Provenance (forward):** add or extend a `## Sources` section on the node:
     `- captured from <source> (raw <id>)` (use the item's `source` value — a path or URL).
   - **Mark processed (back-ref):**
     ```bash
     node "$CLAUDE_PLUGIN_ROOT/mcp/dist/tools/raw-capture-cli.bundle.js" process <id> --node <slug>
     ```
     Sets the item `status: processed` and `target_node: <slug>` (the node it became). The raw `.md`
     stays in `raw/` as the audit trail — never delete it.
   - **Self-check:** a follow-up `knowledge_validate` shows no new `broken_link` / `ai_block_*` error
     for the node.

3. **Conservative — never auto-discard.** If an item is low-value / noise (boilerplate, a stub, a
   `LICENSE` that slipped SP-3's denylist), **leave it unprocessed** and list it in the run report
   (`left N item(s) unprocessed — prune with /second-brain:capture --discard <id>`). Do **not** mark an
   item `discarded` yourself — pruning is the user's call.

4. **Budget:** each item processed counts as **one change against the 50/run cap** (shared with the
   other phases). Over budget → process the highest-value first and report the remainder for the next run.

5. **Reindex:** after the loop, the Phase 5 `knowledge_reindex` catalogues the new/updated pages.

**Boundary:** like Phase 4b, Phase 4c is **explicit-invocation only** — a `/second-brain:maintain`
(or "maintain / clean up the KB") request. An auto-dispatched run (threshold counter / reindex-issues /
post-extraction) **skips Phase 4c**: draining bulk-authors page content, which stays deliberate and
reviewed, never unattended (the §5b automation boundary).
````

- [ ] **Step 4: Update the Autonomous-Dispatch exception to name 4c.** In `agents/knowledge-maintainer.md`, find the `**Exception — Phase 4b (ai-block authoring/backfill):**` paragraph and change its first line to cover both phases — replace `**Exception — Phase 4b (ai-block authoring/backfill):**` with `**Exception — Phases 4b (ai-block authoring/backfill) and 4c (raw-inbox drain):**`, and in that paragraph change `**skips Phase 4b**` to `**skips Phases 4b and 4c**` and `backfilling ai-blocks bulk-authors page content` to `backfilling ai-blocks and draining the raw inbox bulk-author page content`.

- [ ] **Step 5: Run the test to verify it passes.**

Run: `bash tests/test-maintainer-raw-drain.sh`
Expected: `ALL PASS`.

- [ ] **Step 6: Commit.**

```bash
git add agents/knowledge-maintainer.md tests/test-maintainer-raw-drain.sh
git commit -m "feat(kb): maintainer Phase 4c — raw-inbox drain (SP-4 Task 3)"
```

---

## Task 4: Ship — gate, version bump, PR

- [ ] **Step 1: Branch (if not already).** `git checkout -b feat/sp4-maintainer-raw-drain` (do all of SP-4 on this branch from the start).

- [ ] **Step 2: Build + full suite.** `cd mcp && npm run build && cd .. && bash tests/run-all.sh` → expect `ALL GREEN` (includes `test-maintainer-raw-drain`, `test-raw-capture`, `test-mcp-typecheck`).

- [ ] **Step 3: Deep-review gate.** Run `second-brain:code-review-deep --base main`. Fix any confirmed (≥70) finding with TDD; re-run until clean.

- [ ] **Step 4: Version bump + migration row.**
  - `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json`: `0.24.12` → `0.24.13`.
  - `skills/upgrade/SKILL.md`: add a `**0.24.13**` row above `**0.24.12**` (maintainer Phase 4c: conservative explicit-only drain of the raw inbox into wiki nodes — create/update/never-auto-discard, bidirectional provenance; new `raw-capture-cli pending`/`process` + `markProcessed`; closes the SP-2→SP-3→SP-4 pipeline; no MCP server tool change, server stays 2.6.4; additive — only fires on explicit maintain with a non-empty inbox).

- [ ] **Step 5: Rebuild + verify lockstep + migration-row test.**

```bash
cd mcp && npm run build && cd ..
bash scripts/validate-plugin.sh
bash tests/test-upgrade-migration-row.sh
```
Expected: `OK: all plugin files valid` + `PASS: upgrade migration row present for 0.24.13`.

- [ ] **Step 6: Commit + PR + merge.**

```bash
git add -A
git commit -m "chore(release): maintainer raw drain (SP-4) — bump 0.24.13 + migration row"
git push -u origin feat/sp4-maintainer-raw-drain
gh pr create --base main --title "feat(kb): maintainer raw-inbox drain (SP-4)" --body "<summary>"
gh pr merge --merge --delete-branch
git checkout main && git pull --ff-only origin main
```

---

## Self-Review

**1. Spec coverage:**
- Phase 4c modeled on 4b (explicit-only, 50/run cap, no invented content) → Task 3. ✓
- Per-item create/update/attach via target_node + search → Task 3 step 2. ✓
- Never auto-discard; report unprocessed → Task 3 step 3 + test. ✓
- Bidirectional provenance (`## Sources` + `process --node` back-ref) → Task 3 step 2 + Task 1/2. ✓
- `pending` TSV work-list + `process` action → Task 2. ✓
- `markProcessed` (status→processed, optional target_node) → Task 1. ✓
- No server/schema change → no server.ts/kb-schema edits in any task. ✓
- Explicit-only boundary named for 4c (incl. the Autonomous-Dispatch exception) → Task 3 steps 3–4. ✓

**2. Placeholder scan:** Task 4 Step 6 `--body "<summary>"` is filled at ship time. The agent prompt's `<id>`/`<slug>`/`<type>`/`<source>` are intentional prompt placeholders the agent fills at runtime (not plan placeholders). No code-step placeholders.

**3. Type consistency:** `markProcessed(brainDir, slug, id, nodeSlug?): Promise<boolean>` is identical in Task 1 (impl), Task 1 (test), and Task 2 (CLI import + call with `node`). `pending` emits `id⇥path⇥captured_by⇥target_node⇥gist` consistently in Task 2 (impl), its test, and the Task 3 agent prompt. `process <id> --node <slug>` matches between Task 2 and the Task 3 prompt. Reused SP-2 internals (`isSafeId`, `fmValue`, `rawDir`, `assertSafeSlug`, `setStatus` pattern) are all already present in `raw-inbox.ts`.
