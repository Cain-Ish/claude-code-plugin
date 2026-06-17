# Phase A — Attribution Incident Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop project-attribution misrouting at capture → drain → dream by making each raw item carry an authoritative `origin:`, making the setup deep-scan fail loud when the resolved destination ≠ the scanned repo, holding foreign-origin items out of the maintainer drain, and defaulting dream consolidation to the active project.

**Architecture:** All three units are additive and back-compatible. `origin` is a new optional field on `RawItem`/`CaptureInput`, written at capture and read at drain. Decision logic that is hard to unit-test inside a CLI `main()` is extracted into small **pure exported functions** (`originGuard`, `partitionPending`, `buildSnapshotArgs`) that are unit-tested directly; the CLIs/server then call them. Agent-prose changes (`knowledge-maintainer.md`, `dream/SKILL.md`) accompany the code that backs them.

**Tech Stack:** TypeScript (ESM, `node>=22`), vitest (`npm test` = `vitest run`), esbuild bundles (`npm run build` = `tsc --noEmit && npm run bundle`), bash scripts, `jq`.

## Global Constraints

- **Fail loud, never silent.** No `2>/dev/null` swallow patterns; surface mismatches on stderr/stdout. (USER.md)
- **Additive + back-compatible.** `origin:` is OPTIONAL. Legacy raw items without it MUST still parse (not `malformed`) and MUST still be drainable (conservative default = current active slug). Never destructively rewrite existing raw items.
- **Pure-function test surface.** Logic that decides routing/scope lives in an exported pure function with a unit test; CLI `main()` only wires it.
- **Path-qualified `<root>__<leaf>` slugs and `parent`/`root_path` fields are Phase B — OUT OF SCOPE here.** Phase A only adds `origin` provenance + scope defaults.
- **Working dir for all `npm`/`vitest`/`build` commands:** `mcp/` (the package root). Test files live beside source as `*.test.ts` under `mcp/src/tools/`.
- **Rebuild bundles after editing any CLI** (`raw-scan-cli.ts`, `raw-capture-cli.ts`) or the server-imported `dream.ts`: `npm run build`. Vitest red/green runs against `src` (TS) and does NOT need the build; the build is required before the e2e shell tests and before commit of CLI-affecting tasks.

---

### Task 1: `origin` provenance field round-trips through the raw inbox

**Files:**
- Modify: `mcp/src/tools/raw-inbox.ts` (interface `RawItem` ~8-21; interface `CaptureInput` ~23-32; `serialize()` ~70-84; `parse()` ~86-117; `captureItem()` item construction ~252-256)
- Test: `mcp/src/tools/raw-inbox.test.ts` (add two cases)

**Interfaces:**
- Consumes: nothing (leaf data-layer change).
- Produces: `RawItem.origin?: string`, `CaptureInput.origin?: string`; `serialize` emits an `origin: <value>` frontmatter line iff set; `parse` reads `origin` (undefined when absent); `captureItem` persists `input.origin`. Tasks 2 and 3 depend on these.

- [ ] **Step 1: Write the failing tests**

Add to `mcp/src/tools/raw-inbox.test.ts` (ensure the import line at the top includes `mkdtempSync, rmSync, mkdirSync, writeFileSync` from `'fs'`, `tmpdir` from `'os'`, `join` from `'path'`, and `captureItem, listItems` from `'./raw-inbox.js'` — add any missing):

```ts
it('round-trips the origin provenance field', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'sb-raw-origin-'));
  await captureItem({ brainDir: dir, slug: 'proja', kind: 'paste', source: 'paste', content: 'hello world', origin: 'proja' });
  const [item] = await listItems(dir, 'proja');
  expect(item.origin).toBe('proja');
  rmSync(dir, { recursive: true, force: true });
});

it('treats a legacy item with no origin as well-formed (origin undefined)', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'sb-raw-legacy-'));
  const raw = join(dir, 'projects', 'proja', 'raw');
  mkdirSync(raw, { recursive: true });
  writeFileSync(join(raw, '20260101-000000-x.md'),
    '---\nid: 20260101-000000-x\nsource: x\ncaptured_at: 2026-01-01T00:00:00Z\n' +
    'captured_by: user\ncontent_type: text/markdown\nstatus: unprocessed\nhash: abc\ngist: x\n---\n\nbody\n');
  const [item] = await listItems(dir, 'proja');
  expect(item.origin).toBeUndefined();
  expect(item.malformed).toBeFalsy();
  rmSync(dir, { recursive: true, force: true });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mcp && npx vitest run src/tools/raw-inbox.test.ts -t origin`
Expected: FAIL — first test asserts `item.origin === 'proja'` but gets `undefined` (field not persisted yet).

- [ ] **Step 3: Add `origin` to the two interfaces**

In `mcp/src/tools/raw-inbox.ts`, `RawItem` — add the field after `captured_by`:

```ts
export interface RawItem {
  id: string;
  source: string;
  captured_at: string;
  captured_by: CapturedBy;
  origin?: string;          // authoritative project the item was captured FROM (basename of the resource)
  content_type: string;
  status: RawStatus;
  target_node?: string;
  blob?: string;
  hash: string;
  gist: string;
  body: string;
  malformed?: boolean;
}
```

In the same file, `CaptureInput` — add the field:

```ts
export interface CaptureInput {
  brainDir: string;
  slug: string;
  source: string;                 // file path, url, or 'paste'
  kind: 'file' | 'url' | 'paste';
  content?: string;               // paste text / url string; for files it is read from disk
  targetNode?: string;
  capturedBy?: CapturedBy;
  origin?: string;                // authoritative origin project (defaults to slug at the call site)
  now?: string;                   // ISO timestamp; injectable for deterministic tests
}
```

- [ ] **Step 4: Serialize and parse `origin`**

In `serialize()`, add the `origin` push after the `captured_by` push (conditional, like `target_node` — absent items stay clean):

```ts
function serialize(item: RawItem): string {
  const fm: string[] = ['---'];
  fm.push(`id: ${fmValue(item.id)}`);
  fm.push(`source: ${fmValue(item.source)}`);
  fm.push(`captured_at: ${fmValue(item.captured_at)}`);
  fm.push(`captured_by: ${fmValue(item.captured_by)}`);
  if (item.origin) fm.push(`origin: ${fmValue(item.origin)}`);
  fm.push(`content_type: ${fmValue(item.content_type)}`);
  fm.push(`status: ${fmValue(item.status)}`);
  if (item.target_node) fm.push(`target_node: ${fmValue(item.target_node)}`);
  if (item.blob) fm.push(`blob: ${fmValue(item.blob)}`);
  fm.push(`hash: ${fmValue(item.hash)}`);
  fm.push(`gist: ${fmValue(item.gist)}`);
  fm.push('---', '', item.body, '');
  return fm.join('\n');
}
```

In `parse()`, add `origin` to the constructed `item` (after the `captured_by` line). **Do NOT add it to the `malformed` condition** — it is optional, and legacy items must stay well-formed:

```ts
  const item: RawItem = {
    id,
    source: get('source') ?? '',
    captured_at: get('captured_at') ?? '',
    captured_by: (get('captured_by') as CapturedBy) ?? 'user',
    origin: get('origin') || undefined,
    content_type: get('content_type') ?? '',
    status: validStatus ? status : 'unprocessed',
    target_node: get('target_node') || undefined,
    blob: get('blob') || undefined,
    hash: get('hash') ?? '',
    gist: get('gist') ?? '',
    body: body.trim(),
  };
```

- [ ] **Step 5: Persist `origin` in `captureItem`**

In `captureItem()`, add `origin` to the `RawItem` construction (~252-256):

```ts
  const item: RawItem = {
    id, source: input.source, captured_at: now, captured_by: capturedBy,
    origin: input.origin,
    content_type: contentType, status: 'unprocessed',
    target_node: input.targetNode, blob, hash, gist, body,
  };
```

- [ ] **Step 6: Run tests + typecheck to verify green**

Run: `cd mcp && npx vitest run src/tools/raw-inbox.test.ts && npm run typecheck`
Expected: PASS (both new tests) and typecheck clean.

- [ ] **Step 7: Commit**

```bash
git add mcp/src/tools/raw-inbox.ts mcp/src/tools/raw-inbox.test.ts
git commit -m "feat(raw-inbox): add optional origin provenance field (Phase A capture-origin)"
```

---

### Task 2: capture derives `origin` from `SCAN_ROOT` + fail-loud destination guard

**Files:**
- Modify: `mcp/src/tools/raw-scan.ts` (`runScan` opts + `captureItem` call ~69-86; add exported `originGuard`)
- Modify: `mcp/src/tools/raw-scan-cli.ts` (compute origin slug, guard, thread origin ~1-41)
- Modify: `mcp/src/tools/raw-capture-cli.ts` (manual captures stamp `origin: slug` ~paste/capture actions)
- Modify: `skills/setup/SKILL.md` (step 6: `cd "$SCAN_ROOT_DIR"` before the scan)
- Test: `mcp/src/tools/raw-scan.test.ts` (new file)

**Interfaces:**
- Consumes: `RawItem.origin`, `CaptureInput.origin` (Task 1); `slugFromProjectDir` (existing, `project-dir.ts`); `runScan` (existing).
- Produces: `originGuard(originSlug, destSlug, hasExplicitOverride): { ok: boolean; reason?: string }`; `runScan` gains `opts.origin?: string` and stamps it on each captured item.

- [ ] **Step 1: Write the failing test**

Create `mcp/src/tools/raw-scan.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { mkdtempSync, writeFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { originGuard, runScan } from './raw-scan.js';
import { listItems } from './raw-inbox.js';

describe('originGuard', () => {
  it('passes when the resource slug cannot be derived', () => {
    expect(originGuard(undefined, 'b', false).ok).toBe(true);
  });
  it('passes when origin matches destination', () => {
    expect(originGuard('a', 'a', false).ok).toBe(true);
  });
  it('FAILS LOUD when origin and destination disagree and no override is set', () => {
    const r = originGuard('a', 'b', false);
    expect(r.ok).toBe(false);
    expect(r.reason).toContain('a');
    expect(r.reason).toContain('b');
  });
  it('passes a mismatch when SB_ACTIVE_SLUG override is set', () => {
    expect(originGuard('a', 'b', true).ok).toBe(true);
  });
});

describe('runScan stamps origin', () => {
  it('writes the supplied origin onto captured items', async () => {
    const repo = mkdtempSync(join(tmpdir(), 'sb-scan-repo-'));
    writeFileSync(join(repo, 'README.md'), '# Title\n\nbody\n');
    const brain = mkdtempSync(join(tmpdir(), 'sb-scan-brain-'));
    await runScan(repo, brain, 'dest', { origin: 'resource' });
    const items = await listItems(brain, 'dest');
    expect(items.length).toBeGreaterThan(0);
    expect(items[0].origin).toBe('resource');
    rmSync(repo, { recursive: true, force: true });
    rmSync(brain, { recursive: true, force: true });
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd mcp && npx vitest run src/tools/raw-scan.test.ts`
Expected: FAIL — `originGuard` is not exported (import error) and `opts.origin` is not threaded.

- [ ] **Step 3: Add `originGuard` and thread `origin` through `runScan`**

In `mcp/src/tools/raw-scan.ts`, add the exported guard (place it above `runScan`):

```ts
/** Cross-check the capture DESTINATION slug against the scanned resource's slug. Returns ok:false when
 *  they disagree and no explicit SB_ACTIVE_SLUG override is set, so the CLI fails loud instead of
 *  silently filing repo A's docs into project B (the 88-doc misroute class). */
export function originGuard(
  originSlug: string | undefined,   // basename(SCAN_ROOT) — the resource scanned
  destSlug: string,                 // the resolved capture destination
  hasExplicitOverride: boolean,     // SB_ACTIVE_SLUG set
): { ok: boolean; reason?: string } {
  if (!originSlug) return { ok: true };               // cannot derive resource slug → no cross-check
  if (originSlug === destSlug) return { ok: true };
  if (hasExplicitOverride) return { ok: true };       // operator explicitly chose the destination
  return {
    ok: false,
    reason: `refusing to file ${originSlug}'s docs into ${destSlug} ` +
            `(resolved active project ≠ scanned repo). cd into ${originSlug}, ` +
            `or set SB_ACTIVE_SLUG=${destSlug} to override.`,
  };
}
```

Update the `runScan` signature and the `captureItem` call to carry `origin`:

```ts
export async function runScan(projectRoot: string, brainDir: string, slug: string,
                              opts: { dryRun?: boolean; origin?: string }): Promise<ScanResult> {
  assertSafeSlug(slug);
  const all = await scanCandidates(projectRoot);
  const cap = scanCap();
  const candidates = all.slice(0, cap);
  const overflow = all.slice(cap);
  const truncated = overflow.length;
  if (opts.dryRun) return { candidates, overflow, captured: 0, skipped: 0, errored: 0, truncated };
  let captured = 0, skipped = 0, errored = 0;
  for (const src of candidates) {
    try {
      const r = await captureItem({ brainDir, slug, kind: 'file', source: src, capturedBy: 'setup-scan', origin: opts.origin ?? slug });
      if (r.duplicate) skipped++; else captured++;
    } catch { skipped++; errored++; }  // unreadable → skip, never abort the scan
  }
  return { candidates, overflow, captured, skipped, errored, truncated };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd mcp && npx vitest run src/tools/raw-scan.test.ts && npm run typecheck`
Expected: PASS (all `originGuard` cases + origin stamping) and typecheck clean.

- [ ] **Step 5: Wire the guard + origin into `raw-scan-cli.ts`**

In `mcp/src/tools/raw-scan-cli.ts`: import `slugFromProjectDir` and `originGuard`, then compute the origin slug, run the guard, and thread origin. Replace the imports and the body of `main()` up to the `runScan` call:

```ts
import { homedir } from 'os';
import { join, basename, relative } from 'path';
import { existsSync, readFileSync } from 'fs';
import { runScan, originGuard } from './raw-scan.js';
import { resolveActiveSlug, slugFromProjectDir } from './project-dir.js';
import { cleanEnvPath } from '../path-guard.js';
```

```ts
async function main(): Promise<void> {
  const brainDir = cleanEnvPath(process.env.BRAIN_DIR) || join(homedir(), '.second-brain');
  const projectRoot = process.env.SCAN_ROOT || process.cwd();
  const slug = resolveSlug(brainDir);
  if (!slug) { console.log('scan: could not resolve the active project. cd into a project.'); return; }
  // Source of truth = the scanned resource, not the ambient session. Refuse a destination that
  // disagrees with the repo being scanned unless SB_ACTIVE_SLUG explicitly overrides.
  const originSlug = slugFromProjectDir(projectRoot);
  const guard = originGuard(originSlug, slug, !!process.env.SB_ACTIVE_SLUG);
  if (!guard.ok) { console.log(`scan: ${guard.reason}`); return; }
  const dryRun = process.argv.includes('--dry-run');
  try {
    const r = await runScan(projectRoot, brainDir, slug, { dryRun, origin: originSlug });
```

(Leave the rest of `main()` — the dry-run/captured reporting and the `catch` — unchanged.)

- [ ] **Step 6: Stamp `origin` on manual captures in `raw-capture-cli.ts`**

Manual `capture <path>` / `paste` are deliberate captures into the active project, so origin = the resolved slug. In `mcp/src/tools/raw-capture-cli.ts`, add `origin: slug` to BOTH `captureItem` calls:

The `paste` action:

```ts
    } else if (action === 'paste') {
      const content = readFileSync(0, 'utf-8');           // stdin
      if (!content.trim()) { console.log('capture: nothing on stdin.'); return; }
      const r = await captureItem({ brainDir, slug, kind: 'paste', source: 'paste', content, targetNode: node, origin: slug });
      console.log(`${r.duplicate ? 'Already captured' : 'Captured'} ${r.id} — ${r.unprocessed} unprocessed.`);
```

The `capture` action:

```ts
      const r = await captureItem({ brainDir, slug, kind, source, content, targetNode: node, origin: slug });
      console.log(`${r.duplicate ? 'Already captured' : 'Captured'} ${r.id} (${kind}) — ${r.unprocessed} unprocessed.`);
```

- [ ] **Step 7: Add `cd "$SCAN_ROOT_DIR"` to setup step 6**

In `skills/setup/SKILL.md` step 6, add a `cd` into the scanned repo before each `node` invocation so the resolver's cwd tier aligns with the scanned resource (belt-and-suspenders with the new guard). The dry-run block:

```bash
if [ "${SB_SCAN_SKIP:-0}" != "1" ]; then
  SCAN_CLI="${CLAUDE_PLUGIN_ROOT}/mcp/dist/tools/raw-scan-cli.bundle.js"
  SCAN_ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  cd "$SCAN_ROOT_DIR" || { echo "setup: cannot cd into $SCAN_ROOT_DIR"; exit 1; }
  SCAN_ROOT="$SCAN_ROOT_DIR" node "$SCAN_CLI" --dry-run
fi
```

The capture block:

```bash
SCAN_CLI="${CLAUDE_PLUGIN_ROOT}/mcp/dist/tools/raw-scan-cli.bundle.js"
SCAN_ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$SCAN_ROOT_DIR" || { echo "setup: cannot cd into $SCAN_ROOT_DIR"; exit 1; }
SCAN_ROOT="$SCAN_ROOT_DIR" node "$SCAN_CLI"
```

- [ ] **Step 8: Build the bundles and run the raw-capture e2e**

Run: `cd mcp && npm run build`
Expected: typecheck + bundle succeed (regenerates `dist/tools/raw-scan-cli.bundle.js` and `raw-capture-cli.bundle.js`).

Run: `bash tests/test-raw-capture.sh`
Expected: PASS (existing capture/pending/process e2e still green with the new `origin:` line present in captured items).

- [ ] **Step 9: Commit**

```bash
git add mcp/src/tools/raw-scan.ts mcp/src/tools/raw-scan.test.ts mcp/src/tools/raw-scan-cli.ts mcp/src/tools/raw-capture-cli.ts skills/setup/SKILL.md mcp/dist
git commit -m "feat(capture): stamp origin + fail-loud destination guard for setup scan (Phase A capture-origin)"
```

---

### Task 3: drain-guard — hold foreign-origin items out of the maintainer work-list

**Files:**
- Modify: `mcp/src/tools/raw-inbox.ts` (add exported `partitionPending`)
- Modify: `mcp/src/tools/raw-capture-cli.ts` (`pending` action uses `partitionPending`, flags foreign on stderr)
- Modify: `agents/knowledge-maintainer.md` (Phase 4c prose: foreign held back; node `project:` from `origin:`)
- Test: `mcp/src/tools/raw-inbox.test.ts` (add `partitionPending` cases)

**Interfaces:**
- Consumes: `RawItem.origin` (Task 1).
- Produces: `partitionPending(items: RawItem[], activeSlug: string): { drainable: RawItem[]; foreign: RawItem[] }`.

- [ ] **Step 1: Write the failing test**

Add to `mcp/src/tools/raw-inbox.test.ts`. Ensure `partitionPending` is added to the `'./raw-inbox.js'` import, and that `RawItem` is imported as a type (`import type { RawItem } from './raw-inbox.js';` if not already present):

```ts
describe('partitionPending', () => {
  const mk = (over: Partial<RawItem>): RawItem => ({
    id: 'i', source: 's', captured_at: 't', captured_by: 'user', content_type: 'text/markdown',
    status: 'unprocessed', hash: 'h', gist: 'g', body: 'b', ...over,
  });
  it('drains own-origin, legacy (no origin), holds foreign, skips processed/malformed', () => {
    const items: RawItem[] = [
      mk({ id: 'own', origin: 'proja' }),
      mk({ id: 'legacy' }),                                   // no origin → conservative default
      mk({ id: 'foreign', origin: 'projb' }),                // different project → held back
      mk({ id: 'done', origin: 'proja', status: 'processed' }),
      mk({ id: 'bad', origin: 'proja', malformed: true }),
    ];
    const { drainable, foreign } = partitionPending(items, 'proja');
    expect(drainable.map(i => i.id)).toEqual(['own', 'legacy']);
    expect(foreign.map(i => i.id)).toEqual(['foreign']);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd mcp && npx vitest run src/tools/raw-inbox.test.ts -t partitionPending`
Expected: FAIL — `partitionPending` is not exported.

- [ ] **Step 3: Implement `partitionPending`**

In `mcp/src/tools/raw-inbox.ts`, add the exported helper (near `listItems`/`unprocessedCount`):

```ts
/** Split the drainable work-list from foreign-origin items. Drainable iff unprocessed, well-formed,
 *  AND (no origin → legacy conservative default) OR origin === activeSlug. Foreign-origin items are
 *  held back so the maintainer never silently drains repo A's capture into project B. */
export function partitionPending(items: RawItem[], activeSlug: string): { drainable: RawItem[]; foreign: RawItem[] } {
  const drainable: RawItem[] = [];
  const foreign: RawItem[] = [];
  for (const i of items) {
    if (i.status !== 'unprocessed' || i.malformed) continue;
    if (i.origin && i.origin !== activeSlug) { foreign.push(i); continue; }
    drainable.push(i);
  }
  return { drainable, foreign };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd mcp && npx vitest run src/tools/raw-inbox.test.ts -t partitionPending`
Expected: PASS.

- [ ] **Step 5: Wire `partitionPending` into the `pending` CLI action**

In `mcp/src/tools/raw-capture-cli.ts`, add `partitionPending` to the `'./raw-inbox.js'` import, then replace the `pending` branch:

```ts
    } else if (action === 'pending') {
      // Deterministic TSV work-list for the maintainer drain (Phase 4c): own/legacy-origin drainable only.
      const { drainable, foreign } = partitionPending(await listItems(brainDir, slug), slug);
      for (const i of drainable) {
        const path = join(rawDir(brainDir, slug), `${i.id}.md`);
        const cell = (s: string) => (s || '').replace(/[\t\r\n]+/g, ' ');
        // cell() every variable field — a tab in target_node (fmValue strips CR/LF, not tabs)
        // would otherwise shift the TSV columns and corrupt the machine work-list.
        console.log([i.id, path, i.captured_by, cell(i.target_node ?? ''), cell(i.gist)].join('\t'));
      }
      if (foreign.length) {
        // fail loud: foreign-origin items are NEVER drained silently (the 88-doc misroute class).
        console.error(`pending: held back ${foreign.length} foreign-origin item(s) (origin≠${slug}): ` +
          `${foreign.map(i => i.id).join(', ')} — re-capture in the right project or /second-brain:capture --discard <id>`);
      }
    } else if (action === 'process') {
```

- [ ] **Step 6: Update the maintainer Phase 4c prose**

In `agents/knowledge-maintainer.md`, Phase 4c: (a) note `pending` already excludes foreign-origin items, and (b) change the facet-stamping rule to use the item's `origin:`. Edit step 1's note and the create-branch facet line.

Replace the parenthetical after the `pending` code block:

```
   Each TSV row is `id⇥path⇥captured_by⇥target_node⇥gist`. Empty output → skip this phase. (Malformed
   items are excluded here — they still show in `/second-brain:capture --list` for manual repair.
   Foreign-origin items are also held back and flagged on stderr — the CLI refuses to mix another
   project's capture into this drain; re-capture them in the right project.)
```

Replace the facet clause in the "create a new page" bullet (the `frontmatter (title, type, the active project: facet)` text) with:

```
     `~/knowledge/wiki/<type>/<kebab-slug>.md` with frontmatter (`title`, `type`, and the `project:`
     facet taken from the item's `origin:` — the resource it was captured from; for a legacy item with
     no `origin:`, fall back to the active slug) + body authored from the material, then add an ai-block
     via the Phase 4b `ai-block-render-cli` path.
```

- [ ] **Step 7: Build + run the maintainer-drain e2e**

Run: `cd mcp && npm run build && npm run typecheck`
Expected: clean.

Run: `bash tests/test-raw-capture.sh && bash tests/test-maintainer-raw-drain.sh`
Expected: PASS (pending still emits the 5-column TSV for own/legacy items; maintainer drain assertions still hold).

- [ ] **Step 8: Commit**

```bash
git add mcp/src/tools/raw-inbox.ts mcp/src/tools/raw-inbox.test.ts mcp/src/tools/raw-capture-cli.ts agents/knowledge-maintainer.md mcp/dist
git commit -m "feat(drain): hold foreign-origin raw items out of the drain work-list (Phase A drain-guard)"
```

---

### Task 4: dream-scope — default consolidation to the active project

**Files:**
- Modify: `mcp/src/tools/dream.ts` (add exported `buildSnapshotArgs`; `dreamCreate` uses it; `DreamStatus.inputs.project_slug?`)
- Modify: `scripts/dream-snapshot.sh` (write `project_slug` into `status.json` inputs)
- Modify: `skills/dream/SKILL.md` (Phase: Creation prose — default = active project; `"all"` opt-out)
- Test: `mcp/src/tools/dream.test.ts` (add `buildSnapshotArgs` cases)

**Interfaces:**
- Consumes: `resolveActiveSlug` (existing, `project-dir.ts`).
- Produces: `buildSnapshotArgs(args: DreamCreateArgs, activeSlug: string | undefined): string[]`; `status.json.inputs.project_slug` (scope used).

- [ ] **Step 1: Write the failing tests**

Add to `mcp/src/tools/dream.test.ts` (add `buildSnapshotArgs` to the existing `'./dream.js'` import):

```ts
describe('buildSnapshotArgs', () => {
  it('defaults scope to the active project when none requested', () => {
    expect(buildSnapshotArgs({}, 'proja')).toEqual(['--slug', 'proja', '--max-count', '50']);
  });
  it('omits --slug for the explicit "all" opt-out', () => {
    expect(buildSnapshotArgs({ transcript_filter: { project_slug: 'all' } }, 'proja')).toEqual(['--max-count', '50']);
  });
  it('uses an explicit project_slug verbatim', () => {
    expect(buildSnapshotArgs({ transcript_filter: { project_slug: 'other' } }, 'proja')).toEqual(['--slug', 'other', '--max-count', '50']);
  });
  it('falls back to all transcripts when there is no active slug and none requested', () => {
    expect(buildSnapshotArgs({}, undefined)).toEqual(['--max-count', '50']);
  });
  it('clamps max_count to 100', () => {
    expect(buildSnapshotArgs({ transcript_filter: { max_count: 500 } }, undefined)).toEqual(['--max-count', '100']);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mcp && npx vitest run src/tools/dream.test.ts -t buildSnapshotArgs`
Expected: FAIL — `buildSnapshotArgs` is not exported.

- [ ] **Step 3: Extract and export `buildSnapshotArgs`**

In `mcp/src/tools/dream.ts`, add the exported pure builder (place it above `dreamCreate`):

```ts
/** Build the dream-snapshot.sh argv. Scope default: when the caller gives no project_slug, mine the
 *  ACTIVE project (leaf). project_slug:"all" is the explicit cross-project opt-out (no --slug → every
 *  transcript). An explicit slug is used verbatim. (Assumes instructions length already validated.) */
export function buildSnapshotArgs(args: DreamCreateArgs, activeSlug: string | undefined): string[] {
  const out: string[] = [];
  if (args.instructions) out.push('--instructions', args.instructions);
  const requested = args.transcript_filter?.project_slug;
  const scope = requested ?? activeSlug;            // default = active project (leaf)
  if (scope && scope !== 'all') out.push('--slug', scope);
  if (args.transcript_filter?.since) out.push('--since', args.transcript_filter.since);
  const maxCount = Math.min(args.transcript_filter?.max_count ?? 50, 100);
  out.push('--max-count', String(maxCount));
  if (args.model) out.push('--model', args.model);
  return out;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd mcp && npx vitest run src/tools/dream.test.ts -t buildSnapshotArgs`
Expected: PASS (all five cases).

- [ ] **Step 5: Use the builder in `dreamCreate`**

In `mcp/src/tools/dream.ts`, ensure these imports exist at the top (add any missing):

```ts
import { homedir } from 'os';
import { resolveActiveSlug } from './project-dir.js';
import { cleanEnvPath } from '../path-guard.js';
```

Replace the manual `scriptArgs` assembly inside `dreamCreate` (keep the 4096-char guard) with a call to the builder:

```ts
export async function dreamCreate(
  args: DreamCreateArgs
): Promise<DreamCreateResult> {
  if (args.instructions && args.instructions.length > 4096) {
    return { ok: false, dream: null, reason: "instructions exceed 4096 char limit" };
  }
  const brainDir = cleanEnvPath(process.env.BRAIN_DIR) || join(homedir(), ".second-brain");
  const activeSlug = resolveActiveSlug(brainDir);
  const scriptArgs = buildSnapshotArgs(args, activeSlug);

  try {
    const { stdout, stderr } = await exec(
      "bash",
      [toBashPath(join(scriptsDir(), "dream-snapshot.sh")), ...scriptArgs],
      { timeout: 30_000, env: { ...process.env } }
    );
    const dreamId = stdout.trim();
    if (!dreamId.startsWith("drm_")) {
      return { ok: false, dream: null, reason: stderr.trim() || "dream-snapshot.sh failed" };
    }
    const status = await readStatus(dreamId);
    return { ok: true, dream: status };
  } catch (err: any) {
    return { ok: false, dream: null, reason: err.stderr?.trim() || err.message || String(err) };
  }
}
```

- [ ] **Step 6: Add `project_slug` to the `DreamStatus` interface**

In `mcp/src/tools/dream.ts`, extend the `inputs` block of `DreamStatus`:

```ts
  inputs: {
    transcript_count: number;
    wiki_page_count: number;
    wiki_snapshot_bytes: number;
    project_slug?: string;
  };
```

- [ ] **Step 7: Persist the scope in `status.json`**

In `scripts/dream-snapshot.sh`, after `FILTER_SLUG` is parsed from `--slug`, record a display value (empty filter = `"all"`). Add it after the arg-parsing loop that sets `FILTER_SLUG`:

```bash
PROJECT_SLUG_RECORD="${FILTER_SLUG:-all}"
```

Then in the `jq -nc` that writes `status.json`, add the `--arg` and the `inputs.project_slug` field:

```bash
jq -nc \
  --arg id "$DREAM_ID" \
  --arg now "$NOW" \
  --arg model "$MODEL" \
  --arg instr "$INSTRUCTIONS" \
  --arg pslug "$PROJECT_SLUG_RECORD" \
  --argjson tc "$SELECTED" \
  --argjson wpc "$WIKI_PAGE_COUNT" \
  --argjson wsb "$SNAPSHOT_BYTES" \
  '{
    id: $id,
    status: "pending",
    created_at: $now,
    started_at: null,
    ended_at: null,
    archived_at: null,
    model: $model,
    instructions: $instr,
    inputs: {
      transcript_count: $tc,
      wiki_page_count: $wpc,
      wiki_snapshot_bytes: $wsb,
      project_slug: $pslug
    },
    outputs: {
      pages_added: 0,
      pages_modified: 0,
      pages_removed: 0
    },
    error: null
  }' > "$DREAM_DIR/status.json"
```

- [ ] **Step 8: Update the dream SKILL.md creation prose**

In `skills/dream/SKILL.md`, Phase: Creation step 2, replace the `transcript_filter` bullet:

```
   - `transcript_filter`: omit `project_slug` to default to the **active project**
     (`resolveActiveSlug`); pass `project_slug: "all"` to mine every project's transcripts.
     (`--family` — mining the whole monorepo family — arrives in Phase B.)
```

- [ ] **Step 9: Build, typecheck, and run the dream e2e**

Run: `cd mcp && npm run build && npm run typecheck`
Expected: clean (server bundle regenerated; `dream.ts` ships via `dist/server.bundle.js`).

Run: `ls tests/test-dream-*.sh` then run the lifecycle test it lists, e.g. `bash tests/test-dream-lifecycle.sh`
Expected: PASS (dream still creates/loads; `status.json` now also carries `inputs.project_slug`).

- [ ] **Step 10: Commit**

```bash
git add mcp/src/tools/dream.ts mcp/src/tools/dream.test.ts scripts/dream-snapshot.sh skills/dream/SKILL.md mcp/dist
git commit -m "feat(dream): default consolidation scope to the active project (Phase A dream-scope)"
```

---

### Task 5: Phase A integration verification

**Files:** none (verification only).

- [ ] **Step 1: Full unit suite**

Run: `cd mcp && npm test`
Expected: PASS — all vitest suites including the new `raw-inbox`, `raw-scan`, and `dream` cases.

- [ ] **Step 2: Typecheck + build clean**

Run: `cd mcp && npm run build`
Expected: `tsc --noEmit` clean + all bundles rebuilt.

- [ ] **Step 3: Affected e2e shell tests**

Run: `bash tests/test-raw-capture.sh && bash tests/test-maintainer-raw-drain.sh && bash tests/test-dream-lifecycle.sh`
Expected: PASS for each (resolve the exact dream lifecycle filename via `ls tests/test-dream-*.sh`).

- [ ] **Step 4: Manual misroute smoke (the original bug)**

Reproduce the guard: from a cwd whose basename is NOT the scanned repo, run the scan CLI against a repo and confirm it now refuses instead of misfiling.

```bash
SCAN_ROOT="/c/Workplace/Projects/claude-code-plugin" \
  node mcp/dist/tools/raw-scan-cli.bundle.js --dry-run
```
Expected (when the resolved active slug ≠ `claude-code-plugin` and `SB_ACTIVE_SLUG` is unset): a `scan: refusing to file claude-code-plugin's docs into <other>` message and NO capture. With `SB_ACTIVE_SLUG=claude-code-plugin` set, it proceeds.

- [ ] **Step 5: Report Phase A complete**

Summarize: tests green, build clean, the three units (`capture-origin`, `drain-guard`, `dream-scope`) landed; note Phase B (M3 scoping) is the next plan.

---

## Self-Review (against the spec)

**Spec coverage — incident fix (`Settled decisions` §, spec lines 38-48):**
- "Capture derives destination from `basename(SCAN_ROOT)`; cross-checks `resolveActiveSlug()`; fail loud on mismatch unless `SB_ACTIVE_SLUG` set" → Task 2 (`originGuard` + raw-scan-cli wiring). ✓
- "`setup/SKILL.md` `cd "$SCAN_ROOT"` before invoking" → Task 2 Step 7. ✓
- "Each raw item gains an authoritative `origin:` field at capture" → Task 1 + Task 2 (scan) + Task 2 Step 6 (manual). ✓
- "Drain mismatch guard: maintainer compares `origin:` to active slug; on mismatch skip + flag" → Task 3 (`partitionPending` + stderr flag + maintainer prose). ✓
- "Node `project:` set from `origin:`" → Task 3 Step 6 (maintainer facet rule). ✓
- "Dream default-scope: `project_slug = resolveActiveSlug()`; persist in `status.json`; `"all"` opt-out" → Task 4 (`buildSnapshotArgs` + status.json + SKILL.md). ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every command has an expected result. The dream lifecycle filename is resolved at run time via `ls tests/test-dream-*.sh` rather than hard-coded blindly.

**Type consistency:** `RawItem.origin?: string` and `CaptureInput.origin?: string` (Task 1) are consumed by `runScan opts.origin` (Task 2) and `partitionPending` (Task 3) — names/types match. `buildSnapshotArgs(args, activeSlug)` (Task 4) returns `string[]` consumed by `dreamCreate`'s `exec`. `DreamStatus.inputs.project_slug?` (Task 4 Step 6) matches the `status.json` `inputs.project_slug` jq field (Task 4 Step 7).

**Scope:** Phase A only. No `parent`/`root_path`/path-qualified slugs/family-tier (Phase B) and no migration/collision (Phase C) leaked in.
