# AI-Native Representation — Phase 1 Implementation Plan

> **For agentic workers:** Implement task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Make the per-page `<!-- ai:begin -->` structured block a *recognized, parsed, schema-validated, and safe* construct across the KB pipeline — the deterministic foundation for the AI-native representation (spec `docs/specs/2026-06-02-ai-native-knowledge-representation-design.md`).

**Architecture:** A new pure `ai-block.ts` module owns the marker, the flat-YAML parse, the per-type schemas, and `stripAiBlock`. `parseDoc` exposes `aiBlock`; `knowledge_validate` schema-checks it (gentle warnings); and every length/first-sentence consumer (`firstSentence`, FORGET `wc -c`, the search stub-penalty) strips the block first so it can't skew signals. No authoring, no consumption changes yet — those are Phase 1b/2/3.

**Tech Stack:** TypeScript (mcp/src/tools, vitest), bash (scripts + tests/test-*.sh), esbuild bundles.

**Out of scope (later phases):** extractor authoring of blocks at capture (Phase 1b: `extract-prompt.txt` + `merge-project-update.sh`); search-weight/return + session-load injection + `knowledge_fetch` tier (Phase 2); dream/maintainer refresh + lint staleness + one-shot backfill (Phase 3).

**Hard constraints (from spec §5b state-check):** block values are plain slugs (never `[[links]]`); the block is excluded from FORGET `wc -c` and the `<100`-char stub penalty; `firstSentence` strips it; graph-project must not clobber it.

---

### Task 1: Pure `ai-block` module — marker, parse, schemas, validate, strip

**Files:**
- Create: `mcp/src/tools/ai-block.ts`
- Test: `mcp/src/tools/ai-block.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
import { describe, it, expect } from 'vitest';
import { parseAiBlock, stripAiBlock, validateAiBlock, AI_BLOCK_SCHEMAS } from './ai-block.js';

const page = [
  '---', 'title: awk', 'type: learnings', '---',
  '<!-- ai:begin (schema\'d, machine-first) -->',
  'claim: never interpolate shell vars into awk',
  'trigger: writing awk in a .sh',
  'action: pass via -v + numeric coercion',
  'scope: mawk (Pi default)',
  '<!-- ai:end -->', '', '## Notes', 'mawk errors on empty interpolation. Period.',
].join('\n');

describe('ai-block', () => {
  it('parses the flat key:value block into an object', () => {
    const b = parseAiBlock(page)!;
    expect(b.claim).toBe('never interpolate shell vars into awk');
    expect(b.action).toBe('pass via -v + numeric coercion');
  });
  it('returns null when there is no block', () => {
    expect(parseAiBlock('---\ntitle: x\n---\n# x\nno block here')).toBeNull();
  });
  it('strips the block (for length/first-sentence counts)', () => {
    const s = stripAiBlock(page);
    expect(s).not.toContain('ai:begin');
    expect(s).not.toContain('claim:');
    expect(s).toContain('## Notes');
  });
  it('validateAiBlock reports missing REQUIRED fields for the type', () => {
    expect(validateAiBlock('learnings', { claim: 'x' })).toEqual(['action']); // action required, missing
    expect(validateAiBlock('learnings', { claim: 'x', action: 'y' })).toEqual([]);
    expect(validateAiBlock('unknown-type', { foo: 'bar' })).toEqual([]); // unknown type → no schema → no warnings
  });
  it('has schemas for the six structured types', () => {
    for (const t of ['learnings', 'decisions', 'entities', 'issues', 'concepts', 'security'])
      expect(AI_BLOCK_SCHEMAS[t].required.length).toBeGreaterThan(0);
  });
  it('folds a continuation line into the previous field value', () => {
    const md = ['<!-- ai:begin -->', 'claim: line one', '  continued', 'action: do it', '<!-- ai:end -->'].join('\n');
    expect(parseAiBlock(md)!.claim).toBe('line one continued');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npx vitest run src/tools/ai-block.test.ts`
Expected: FAIL — cannot find module `./ai-block.js`.

- [ ] **Step 3: Write minimal implementation**

```typescript
// mcp/src/tools/ai-block.ts
export const AI_BLOCK_RE = /<!--\s*ai:begin[\s\S]*?-->\n?([\s\S]*?)<!--\s*ai:end\s*-->/;

export interface AiBlockSchema { fields: string[]; required: string[]; }

// Per-type schemas (spec §4). `required` = the load-bearing fields a good page of that
// type should carry; missing ones are WARNINGS (gentle), never errors.
export const AI_BLOCK_SCHEMAS: Record<string, AiBlockSchema> = {
  learnings: { fields: ['claim', 'trigger', 'action', 'scope', 'evidence', 'supersedes'], required: ['claim', 'action'] },
  decisions: { fields: ['context', 'choice', 'alternatives', 'rationale', 'status', 'supersedes'], required: ['choice'] },
  entities:  { fields: ['identity', 'current_state', 'depends_on', 'owns', 'status'], required: ['identity'] },
  issues:    { fields: ['symptom', 'cause', 'fix', 'severity', 'status'], required: ['symptom', 'status'] },
  concepts:  { fields: ['problem', 'solution', 'where_applied', 'tradeoffs'], required: ['problem', 'solution'] },
  security:  { fields: ['threat', 'mitigation', 'scope', 'status'], required: ['threat', 'mitigation'] },
};

/** Parse the flat-YAML `key: value` body of the ai:begin…ai:end region into an object.
 *  A line not matching `key:` is folded (appended) into the previous field's value.
 *  Returns null when the page has no block. */
export function parseAiBlock(content: string): Record<string, string> | null {
  const m = content.match(AI_BLOCK_RE);
  if (!m) return null;
  const out: Record<string, string> = {};
  let last = '';
  for (const raw of m[1].split('\n')) {
    const line = raw.trimEnd();
    if (!line.trim()) continue;
    const kv = line.match(/^([a-z_][a-z0-9_]*):\s*(.*)$/i);
    if (kv) { last = kv[1]; out[last] = kv[2].trim(); }
    else if (last) { out[last] = (out[last] + ' ' + line.trim()).trim(); }
  }
  return out;
}

/** Remove the ai:begin…ai:end region so length/first-sentence consumers ignore it. */
export function stripAiBlock(text: string): string {
  return text.replace(AI_BLOCK_RE, '');
}

/** Missing REQUIRED fields for the page type (empty when type unknown or all present). */
export function validateAiBlock(type: string, block: Record<string, string>): string[] {
  const schema = AI_BLOCK_SCHEMAS[type];
  if (!schema) return [];
  return schema.required.filter(f => !block[f] || !block[f].trim());
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npx vitest run src/tools/ai-block.test.ts`
Expected: PASS (6 cases).

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/ai-block.ts mcp/src/tools/ai-block.test.ts
git commit -m "feat(ai-block): pure parse + per-type schemas + validate + strip"
```

---

### Task 2: `parseDoc` exposes `aiBlock`; body-link fallback ignores the block

**Files:**
- Modify: `mcp/src/tools/knowledge-search.ts` (`ParsedDoc` interface ~line 11-23; `parseDoc` ~line 305-347)
- Test: `mcp/src/tools/knowledge-search.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// add to knowledge-search.test.ts (parseDoc already imported)
describe('parseDoc ai-block', () => {
  it('exposes the parsed ai-block as doc.aiBlock', () => {
    const md = ['---', 'title: A', 'type: learnings', '---',
      '<!-- ai:begin -->', 'claim: c', 'action: a', '<!-- ai:end -->', '', '# A', 'body'].join('\n');
    const doc = parseDoc(md, '/w/learnings/a.md');
    expect(doc.aiBlock?.claim).toBe('c');
  });
  it('does NOT scrape a [[link]] that sits inside the ai-block into related:', () => {
    // (block values should be plain slugs, but guard anyway: stripped before the body-link fallback)
    const md = ['---', 'title: B', 'type: learnings', '---',
      '<!-- ai:begin -->', 'supersedes: [[ghost]]', 'claim: c', 'action: a', '<!-- ai:end -->', '', '# B', 'see [[real-page]]'].join('\n');
    const doc = parseDoc(md, '/w/learnings/b.md');
    expect(doc.related).toContain('real-page');
    expect(doc.related).not.toContain('ghost');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npx vitest run src/tools/knowledge-search.test.ts -t ai-block`
Expected: FAIL — `doc.aiBlock` undefined; `ghost` present in related.

- [ ] **Step 3: Write minimal implementation**

In `knowledge-search.ts`: import at top — `import { parseAiBlock, stripAiBlock } from './ai-block.js';`
Add to `ParsedDoc` interface: `aiBlock?: Record<string, string>;`
In `parseDoc`, after the frontmatter block is parsed and `doc.body` is set, add:
```typescript
  doc.aiBlock = parseAiBlock(content) ?? undefined;
```
And the body `[[link]]` fallback (the `if (!doc.related.length)` / wiki-link scrape, ~line 340-344) must run on a block-stripped body. Change the scrape source to `stripAiBlock(doc.body)`:
```typescript
  // existing fallback, but ignore links that live inside the ai-block:
  const bodyForLinks = stripAiBlock(doc.body);
  // ...use bodyForLinks in the [[...]] matchAll instead of doc.body...
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npx vitest run src/tools/knowledge-search.test.ts`
Expected: PASS (all, incl. the two new).

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/knowledge-search.ts mcp/src/tools/knowledge-search.test.ts
git commit -m "feat(ai-block): parseDoc exposes aiBlock; body-link fallback strips the block"
```

---

### Task 3: Search stub-penalty measures prose only (block excluded)

**Files:**
- Modify: `mcp/src/tools/knowledge-search.ts` (stub penalty ~line 213-215: `body.length < 100`)
- Test: `mcp/src/tools/knowledge-search.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
import { knowledgeSearch } from './knowledge-search.js'; // already imported
it('a short page with a big ai-block is still penalized as a stub (prose-only length)', async () => {
  const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-stub-'));
  await fsp.mkdir(join(dir, 'wiki', 'learnings'), { recursive: true });
  const bigBlock = ['<!-- ai:begin -->', 'claim: wireguard tunnel handshake', 'action: x', 'scope: y', 'evidence: z z z z z', '<!-- ai:end -->'].join('\n');
  // prose body is ~5 chars; only the block is long
  await fsp.writeFile(join(dir, 'wiki', 'learnings', 'stub.md'), `---\ntitle: stub\ntype: learnings\n---\n${bigBlock}\n\nhi.`);
  await fsp.writeFile(join(dir, 'wiki', 'learnings', 'full.md'), `---\ntitle: full\ntype: learnings\n---\n# full\n` + 'wireguard tunnel handshake details. '.repeat(20));
  const r = await knowledgeSearch({ query: 'wireguard tunnel handshake', knowledgeDir: dir });
  const stub = r.results.find((x: any) => x.slug === 'stub');
  const full = r.results.find((x: any) => x.slug === 'full');
  expect(stub && full && full.score > stub.score).toBe(true); // stub penalized despite the long block
});
```

(Adjust the result-shape accessor — `r.results`/`.slug`/`.score` — to match `knowledgeSearch`'s actual return; confirm by reading the function before writing.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npx vitest run src/tools/knowledge-search.test.ts -t stub`
Expected: FAIL — the block's length lifts `stub` over the `<100` penalty, so it is not penalized.

- [ ] **Step 3: Write minimal implementation**

In the stub-penalty check (~line 213-215), measure block-stripped prose length:
```typescript
  const proseLen = stripAiBlock(doc.body).trim().length;
  const isStub = /<!--\s*auto-extracted/.test(doc.body) || proseLen < 100;
```
(Use `proseLen`/`isStub` in place of the inline `doc.body.length < 100` check.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npx vitest run src/tools/knowledge-search.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/knowledge-search.ts mcp/src/tools/knowledge-search.test.ts
git commit -m "fix(ai-block): stub penalty measures prose only (excludes ai-block)"
```

---

### Task 4: `firstSentence` strips the ai-block (reindex)

**Files:**
- Modify: `mcp/src/tools/knowledge-reindex.ts` (`firstSentence` ~line 108-115)
- Test: `mcp/src/tools/knowledge-reindex.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// knowledge-reindex.test.ts — index.md description must come from prose, not the block
it('index.md description ignores the ai-block (firstSentence strips it)', async () => {
  const kd = await fsp.mkdtemp(join(tmpdir(), 'ri-ai-'));
  await fsp.mkdir(join(kd, 'wiki', 'concepts'), { recursive: true });
  const body = ['<!-- ai:begin -->', 'problem: BLOCKWORD should not surface', 'solution: x', '<!-- ai:end -->', '', 'Real prose sentence here.'].join('\n');
  await fsp.writeFile(join(kd, 'wiki', 'concepts', 'p.md'), `---\ntitle: P\ntype: concepts\n---\n${body}`);
  await knowledgeReindex(kd);
  const idx = await fsp.readFile(join(kd, 'wiki', 'index.md'), 'utf-8');
  expect(idx).not.toContain('BLOCKWORD');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npx vitest run src/tools/knowledge-reindex.test.ts -t ai-block`
Expected: FAIL — `firstSentence` grabs the block text (`problem: BLOCKWORD…`) as the description.

- [ ] **Step 3: Write minimal implementation**

In `knowledge-reindex.ts`, import `stripAiBlock` and add it to the `firstSentence` strip chain (it already strips `graph:begin`):
```typescript
import { stripAiBlock } from './ai-block.js';
// in firstSentence(body):
  const text = stripAiBlock(body)
    .replace(/<!-- graph:begin[\s\S]*?graph:end -->/g, '')
    .replace(/^#.*\n/m, '')
    .trim();
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npx vitest run src/tools/knowledge-reindex.test.ts`
Expected: PASS (all reindex cases).

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/knowledge-reindex.ts mcp/src/tools/knowledge-reindex.test.ts
git commit -m "fix(ai-block): firstSentence strips the ai-block before extracting description"
```

---

### Task 5: `knowledge_validate` schema-checks the block (gentle warning)

**Files:**
- Modify: `mcp/src/tools/knowledge-validate.ts` (issue type union ~line 6; the per-page loop ~line 31-95)
- Test: `mcp/src/tools/knowledge-validate.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// knowledge-validate.test.ts (knowledgeValidate imported)
it('warns (not errors) when an ai-block is missing a required field for its type', async () => {
  const dir = await fs.mkdtemp(join(tmpdir(), 'kv-ai-'));
  const wiki = join(dir, 'wiki');
  await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
  // learnings requires claim + action; this block omits action
  await fs.writeFile(join(wiki, 'learnings', 'l.md'),
    '---\ntitle: L\ntype: learnings\n---\n<!-- ai:begin -->\nclaim: c\n<!-- ai:end -->\n# L\n');
  const res = await knowledgeValidate(dir, { autofix: false });
  const w = res.issues.find(i => i.type === 'ai_block_incomplete' && /action/.test(i.message));
  expect(w).toBeDefined();
  expect(w!.severity).toBe('warning');
});
it('does not warn when the page has no ai-block (additive/optional during migration)', async () => {
  const dir = await fs.mkdtemp(join(tmpdir(), 'kv-noai-'));
  const wiki = join(dir, 'wiki');
  await fs.mkdir(join(wiki, 'learnings'), { recursive: true });
  await fs.writeFile(join(wiki, 'learnings', 'l.md'), '---\ntitle: L\ntype: learnings\n---\n# L\nprose\n');
  const res = await knowledgeValidate(dir, { autofix: false });
  expect(res.issues.find(i => i.type === 'ai_block_incomplete')).toBeUndefined();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npx vitest run src/tools/knowledge-validate.test.ts -t ai-block`
Expected: FAIL — no `ai_block_incomplete` issue type exists.

- [ ] **Step 3: Write minimal implementation**

In `knowledge-validate.ts`: add `'ai_block_incomplete'` to the `type:` union (~line 6). Import `parseAiBlock, validateAiBlock` from `./ai-block.js`. In the per-page loop (where `parseDoc(content)` already runs), after computing the page's type (`doc.type` or the folder), add:
```typescript
    const block = parseAiBlock(content);
    if (block) {
      const missing = validateAiBlock(doc.type || basename(dirname(filePath)), block);
      if (missing.length) issues.push({
        type: 'ai_block_incomplete', severity: 'warning', path: filePath,
        message: `ai-block missing required field(s) for type ${doc.type}: ${missing.join(', ')}`,
      });
    }
```
(Only when a block exists — absent block is fine, additive.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npx vitest run src/tools/knowledge-validate.test.ts`
Expected: PASS (all).

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/knowledge-validate.ts mcp/src/tools/knowledge-validate.test.ts
git commit -m "feat(ai-block): knowledge_validate warns on incomplete ai-block (gentle)"
```

---

### Task 6: FORGET byte-count excludes the ai-block

**Files:**
- Modify: `scripts/wiki-forget-score.sh` (body byte count ~line 25)
- Test: `tests/test-wiki-forget-ai-block.sh` (new)

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
# A page whose only "length" is a big ai-block must still count as a near-stub for the
# category-floor gate — the block must be excluded from the wc -c body measure (spec §5b).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SCORER="$ROOT/scripts/wiki-forget-score.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || fail "jq required"
export KNOWLEDGE_DIR="$TMP/knowledge"; export BRAIN_DIR="$TMP/.second-brain"
mkdir -p "$KNOWLEDGE_DIR/wiki/entities" "$BRAIN_DIR"
# entities is a 0.5-category; a tiny-prose page padded ONLY by a long ai-block:
{ echo '---'; echo 'title: E'; echo 'type: entities'; echo '---'
  echo '<!-- ai:begin -->'; echo 'identity: some long identity line padding padding padding padding'
  echo 'current_state: more padding padding padding padding padding padding padding'; echo '<!-- ai:end -->'
  echo '# E'; echo 'hi'; } > "$KNOWLEDGE_DIR/wiki/entities/e.md"
OUT=$(bash "$SCORER" 2>/dev/null) || fail "scorer failed"
# row: score<TAB>slug<TAB>path<TAB>reasons<TAB>protflag ; reasons must show the stub-floor body<200 hit
echo "$OUT" | awk -F'\t' '$2=="e"{print $4}' | grep -qi 'stub\|body<200\|cat=0.2\|s_cat' || true
# The robust assertion: prose is <200 bytes, so the category floor (0.2) must apply →
# the page must NOT score as a full 0.5 entity. Compare against a real long-prose entity.
{ echo '---'; echo 'title: F'; echo 'type: entities'; echo '---'; echo '# F'
  for i in $(seq 1 30); do echo "real prose line $i with enough content to exceed two hundred bytes easily"; done; } > "$KNOWLEDGE_DIR/wiki/entities/f.md"
OUT=$(bash "$SCORER" 2>/dev/null)
se=$(echo "$OUT" | awk -F'\t' '$2=="e"{print $1}'); sf=$(echo "$OUT" | awk -F'\t' '$2=="f"{print $1}')
awk -v a="$se" -v b="$sf" 'BEGIN{exit !(a+0 < b+0)}' || fail "block-padded stub (e=$se) scored >= real-prose entity (f=$sf) — block not excluded from body count"
pass "ai-block excluded from FORGET body byte-count (block-padded page still hits the stub floor)"
echo; echo "ALL PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-wiki-forget-ai-block.sh`
Expected: FAIL — `wc -c` includes the block, so `e` exceeds 200 bytes, skips the stub floor, and scores ≥ `f`.

- [ ] **Step 3: Write minimal implementation**

In `wiki-forget-score.sh`, where it computes `body=$(wc -c < "$f")` (~line 25), strip the ai-block (and other generated marked regions) first so the count is prose-only. Use awk to drop `ai:begin…ai:end` (mawk-safe — fence-style state toggle, no shell interpolation):
```bash
  body=$(awk '
    /<!--[[:space:]]*ai:begin/   { skip=1 }
    skip==1                      { if ($0 ~ /<!--[[:space:]]*ai:end[[:space:]]*-->/) skip=0; next }
    { print }
  ' "$f" | wc -c)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-wiki-forget-ai-block.sh` then `bash tests/test-wiki-forget-score.sh` (existing, must stay green)
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/wiki-forget-score.sh tests/test-wiki-forget-ai-block.sh
git commit -m "fix(ai-block): FORGET body byte-count excludes the ai-block (prose-only)"
```

---

### Task 7: graph-project never clobbers the ai-block (safety regression)

**Files:**
- Test: `mcp/src/tools/knowledge-reindex.test.ts` (graph-project runs inside reindex)

- [ ] **Step 1: Write the failing-or-passing test (regression guard)**

```typescript
it('reindex/graph-projection preserves the ai-block byte-for-byte', async () => {
  const kd = await fsp.mkdtemp(join(tmpdir(), 'ri-keep-'));
  await fsp.mkdir(join(kd, 'wiki', 'decisions'), { recursive: true });
  const block = ['<!-- ai:begin -->', 'choice: use X', 'status: active', '<!-- ai:end -->'].join('\n');
  await fsp.writeFile(join(kd, 'wiki', 'decisions', 'd.md'), `---\ntitle: D\ntype: decisions\nrelated: []\n---\n${block}\n\n# D\nbody [[other]]`);
  await fsp.mkdir(join(kd, 'wiki', 'decisions'), { recursive: true });
  await fsp.writeFile(join(kd, 'wiki', 'decisions', 'other.md'), `---\ntitle: O\ntype: decisions\n---\n# O\n`);
  await appendEdge(join(kd, 'graph', 'edges.jsonl'),
    { op: 'assert', from: 'd', to: 'other', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
  await knowledgeReindex(kd); // projects related: + ## Dependencies onto d.md
  const after = await fsp.readFile(join(kd, 'wiki', 'decisions', 'd.md'), 'utf-8');
  expect(after).toContain(block); // the ai-block region survives projection intact
});
```

- [ ] **Step 2: Run test to verify it (likely passes — graph-project only touches its own region + frontmatter)**

Run: `cd mcp && npx vitest run src/tools/knowledge-reindex.test.ts -t preserves`
Expected: PASS (graph-project rewrites only `related:` frontmatter + the `graph:begin` region, both distinct from `ai:begin`). If it FAILS, graph-project is corrupting the block → fix `graph-project.ts` to skip/preserve the `ai:begin` region; do not weaken the test.

- [ ] **Step 3: (only if Step 2 failed) preserve the block in graph-project.ts**

If failing: in `graph-project.ts`, capture the `ai:begin…ai:end` region before rewriting and restore it after, or scope the rewrite regexes to avoid it. (No code if Step 2 passed.)

- [ ] **Step 4: Re-run to confirm green**

Run: `cd mcp && npx vitest run src/tools/knowledge-reindex.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/knowledge-reindex.test.ts mcp/src/tools/graph-project.ts
git commit -m "test(ai-block): guard that reindex/projection preserves the ai-block"
```

---

### Task 8: Build, full gate, version + migration row

**Files:**
- Modify: `mcp/src/server.ts` (knowledge-base version), `.claude-plugin/plugin.json` + `marketplace.json`, `skills/upgrade/SKILL.md`

- [ ] **Step 1: Rebuild bundles** (new `ai-block.ts` must be inlined into the dependent bundles)

Run: `cd mcp && npm run build`
Expected: tsc clean; bundles rebuilt.

- [ ] **Step 2: Full suite**

Run: `bash tests/run-all.sh`
Expected: ALL GREEN (new vitest + `test-wiki-forget-ai-block.sh` auto-discovered; existing `test-wiki-forget-score.sh` + knowledge-eval not regressed).

- [ ] **Step 3: Version + migration row**

Bump `plugin.json` + `marketplace.json` to `0.24.0`; bump `mcp/src/server.ts` knowledge-base to `2.5.0`; add a `0.24.0` row to `skills/upgrade/SKILL.md` describing: AI-native representation **Phase 1** (the `ai:begin` block is parsed/schema-validated/strip-safe across parseDoc, validate, reindex firstSentence, FORGET byte-count, search stub-penalty); additive/back-compat (no block ⇒ unchanged); authoring (extractor) + consumption (search/session-load) are Phases 1b/2.

- [ ] **Step 4: Validate + migration-row gate**

Run: `bash scripts/validate-plugin.sh && bash tests/test-upgrade-migration-row.sh`
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore(release): AI-native representation Phase 1 — 0.24.0 + MCP 2.5.0"
```

---

## Release gate (after all tasks)

Run `/second-brain:code-review-deep` on the branch (the deep-review release gate), address findings, then PR. Do not merge until green + reviewed.

## Self-review checklist (run before implementing)

- **Spec coverage (Phase 1):** ai-block parse/schema/validate/strip (T1) ✓ · parseDoc.aiBlock + plain-slug guard (T2) ✓ · stub-penalty prose-only (T3) ✓ · firstSentence strip (T4) ✓ · validate gentle warning (T5) ✓ · FORGET byte-count exclude (T6) ✓ · graph-project safety (T7) ✓ · version/row (T8). Authoring (extractor) + consumption (search/session-load/knowledge_fetch) are **explicitly Phase 1b/2** (not gaps).
- **Type consistency:** `parseAiBlock(content)→Record<string,string>|null`, `stripAiBlock(text)→string`, `validateAiBlock(type, block)→string[]`, `AI_BLOCK_SCHEMAS[type].{fields,required}` — used identically across T1–T7; `ParsedDoc.aiBlock?: Record<string,string>` (T2) feeds T5.
- **No placeholders:** every code step shows real code. T3's result-shape accessor (`r.results/.slug/.score`) is flagged to confirm against `knowledgeSearch`'s actual return before writing the test.
