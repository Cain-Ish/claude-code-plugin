# KB Hierarchical Organization — Phase 1 Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Project a navigable project-MOC hierarchy and a de-hubbed two-tier `index.md` from a new `project:` frontmatter facet — the deterministic, read-side "visible wins" of `docs/specs/2026-06-02-knowledge-base-hierarchical-organization-design.md` (Phase 1 of §13). No files are ever moved.

**Architecture:** Pages keep their flat type-folder home and gain an optional `project:` facet. `reindex` reads the facet and deterministically *projects* (a) one `wiki/projects/<slug>.md` MOC per project with ≥ `SB_MOC_MIN_MEMBERS` (default 3) members, grouped by type, and (b) a thin two-tier `index.md` (Home → project/theme MOCs + per-type counts) marked `graph: exclude` with plain-text rows so a graph viewer never hubs it. A one-shot backfill seeds `project:` on the pages already connected by `part_of` to a known project anchor. Everything is a pure projection of the edge log + frontmatter — idempotent, reversible (delete generated pages + reindex).

**Tech Stack:** TypeScript (MCP tools under `mcp/src/tools/`, vitest), bash (scripts + `tests/test-*.sh`), esbuild bundles in `mcp/dist/`.

**Out of scope (later phases):** on-write facet-setting + `relates→part_of` promotion + maintainer plurality-vote (Phase 2); lint gate + `reindex --check` drift + closed-vocab post-filter (Phase 3).

---

### Task 1: `parseDoc` exposes the `project` facet

**Files:**
- Modify: `mcp/src/tools/knowledge-search.ts` (the `ParsedDoc` interface + `parseDoc`, around lines 303–320)
- Test: `mcp/src/tools/knowledge-search.test.ts` (add a case; create if absent)

- [ ] **Step 1: Write the failing test**

```typescript
import { describe, it, expect } from 'vitest';
import { parseDoc } from './knowledge-search.js';

describe('parseDoc project facet', () => {
  it('extracts the project: facet from frontmatter', () => {
    const md = ['---', 'title: Kiri Core', 'type: decisions', 'project: kiri', '---', '# Kiri Core'].join('\n');
    const doc = parseDoc(md, '/w/decisions/kiri-core-design.md');
    expect(doc.project).toBe('kiri');
  });
  it('defaults project to empty string when absent', () => {
    const md = ['---', 'title: X', 'type: concepts', '---', '# X'].join('\n');
    expect(parseDoc(md, '/w/concepts/x.md').project).toBe('');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npx vitest run src/tools/knowledge-search.test.ts -t project`
Expected: FAIL — `Property 'project' does not exist on type 'ParsedDoc'` (type error) / `undefined`.

- [ ] **Step 3: Write minimal implementation**

In `ParsedDoc` (line ~304 region) add `project: string;` (and `area: string;` for the optional area facet). In the defaults object add `project: '', area: '',`. Inside the `if (fmMatch)` block add:

```typescript
    doc.project = extractYamlValue(fm, 'project');
    doc.area = extractYamlValue(fm, 'area');
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npx vitest run src/tools/knowledge-search.test.ts -t project`
Expected: PASS (both cases).

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/knowledge-search.ts mcp/src/tools/knowledge-search.test.ts
git commit -m "feat(kb): parseDoc exposes project/area facets"
```

---

### Task 2: Pure project-MOC builder (deterministic, gated)

**Files:**
- Create: `mcp/src/tools/project-moc.ts`
- Test: `mcp/src/tools/project-moc.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
import { describe, it, expect } from 'vitest';
import { buildProjectMocs, MocInput } from './project-moc.js';

const pages: MocInput[] = [
  { slug: 'kiri-redesign', type: 'decisions', project: 'kiri', title: 'Kiri Redesign', description: 'root' },
  { slug: 'kiri-core-design', type: 'decisions', project: 'kiri', title: 'Kiri Core', description: 'core' },
  { slug: 'kiri-privilege-split', type: 'security', project: 'kiri', title: 'Kiri Priv Split', description: 'lpe' },
  { slug: 'bridge-a', type: 'decisions', project: 'cainish-bridge', title: 'Bridge A', description: '' },
  { slug: 'bridge-b', type: 'decisions', project: 'cainish-bridge', title: 'Bridge B', description: '' },
  { slug: 'lonely', type: 'concepts', project: 'solo', title: 'Solo', description: '' },
];

describe('buildProjectMocs', () => {
  it('emits one MOC per project with >= minMembers, grouped by type', () => {
    const mocs = buildProjectMocs(pages, { minMembers: 3 });
    expect([...mocs.keys()].sort()).toEqual(['kiri']);          // cainish-bridge=2, solo=1 → gated out
    const k = mocs.get('kiri')!;
    expect(k).toContain('## decisions');
    expect(k).toContain('[[kiri-redesign]]');
    expect(k).toContain('## security');
    expect(k).toContain('[[kiri-privilege-split]]');
    // deterministic: members sorted by slug within a type group
    expect(k.indexOf('[[kiri-core-design]]')).toBeLessThan(k.indexOf('[[kiri-redesign]]'));
  });
  it('is deterministic — same input, byte-identical output', () => {
    expect(buildProjectMocs(pages, { minMembers: 3 }).get('kiri'))
      .toBe(buildProjectMocs(pages, { minMembers: 3 }).get('kiri'));
  });
  it('respects an empty/whitespace project as no membership', () => {
    const mocs = buildProjectMocs([{ slug: 'x', type: 'concepts', project: '', title: 'X', description: '' }], { minMembers: 1 });
    expect(mocs.size).toBe(0);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npx vitest run src/tools/project-moc.test.ts`
Expected: FAIL — cannot find module `./project-moc.js`.

- [ ] **Step 3: Write minimal implementation**

```typescript
// mcp/src/tools/project-moc.ts
export interface MocInput { slug: string; type: string; project: string; title: string; description: string; }
export interface MocOpts { minMembers: number; }

const BEGIN = '<!-- moc:begin (generated from project: facets — do not hand-edit) -->';
const END = '<!-- moc:end -->';

/** Pure, deterministic. Returns project-slug → MOC marked-region markdown, only for
 *  projects with >= minMembers members. Members grouped by type (sorted), sorted by
 *  slug within each group. No timestamps (idempotent). */
export function buildProjectMocs(pages: MocInput[], opts: MocOpts): Map<string, string> {
  const byProject = new Map<string, MocInput[]>();
  for (const p of pages) {
    const proj = (p.project || '').trim();
    if (!proj) continue;
    if (!byProject.has(proj)) byProject.set(proj, []);
    byProject.get(proj)!.push(p);
  }
  const out = new Map<string, string>();
  for (const [proj, members] of [...byProject.entries()].sort((a, b) => a[0] < b[0] ? -1 : 1)) {
    if (members.length < opts.minMembers) continue;
    const types = [...new Set(members.map(m => m.type))].sort();
    const lines: string[] = [BEGIN];
    for (const t of types) {
      lines.push(`## ${t}`);
      for (const m of members.filter(m => m.type === t).sort((a, b) => a.slug < b.slug ? -1 : 1)) {
        const desc = m.description ? ` — ${m.description}` : '';
        lines.push(`- [[${m.slug}]]${desc}`);
      }
      lines.push('');
    }
    lines.push(END);
    out.set(proj, lines.join('\n'));
  }
  return out;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npx vitest run src/tools/project-moc.test.ts`
Expected: PASS (3 cases).

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/project-moc.ts mcp/src/tools/project-moc.test.ts
git commit -m "feat(kb): pure deterministic project-MOC builder (>= minMembers gate)"
```

---

### Task 3: `projects` is a known category; `graph: exclude` is honored

**Files:**
- Modify: `mcp/src/tools/knowledge-validate.ts` (`KNOWN_CATEGORIES`, line ~154)
- Test: `mcp/src/tools/knowledge-validate.test.ts` (extend)

- [ ] **Step 1: Write the failing test**

```typescript
import { describe, it, expect } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { knowledgeValidate } from './knowledge-validate.js';

describe('projects category', () => {
  it('does NOT flag a wiki/projects/<slug>.md page as an unknown category', async () => {
    const kd = mkdtempSync(join(tmpdir(), 'kb-'));
    mkdirSync(join(kd, 'wiki', 'projects'), { recursive: true });
    writeFileSync(join(kd, 'wiki', 'projects', 'kiri.md'),
      ['---', 'title: kiri', 'type: projects', 'generated: true', 'graph: exclude', '---', '# kiri'].join('\n'));
    const res = await knowledgeValidate(kd, { autofix: false });
    expect(res.issues.find(i => /unknown category|orphan/i.test(i.message) && /kiri/.test(JSON.stringify(i)))).toBeUndefined();
    rmSync(kd, { recursive: true, force: true });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npx vitest run src/tools/knowledge-validate.test.ts -t projects`
Expected: FAIL — `kiri.md` flagged because `projects` ∉ `KNOWN_CATEGORIES`.

- [ ] **Step 3: Write minimal implementation**

In `knowledge-validate.ts` add `'projects'` to the `KNOWN_CATEGORIES` set (line ~155–156):

```typescript
const KNOWN_CATEGORIES = new Set([
  'concepts', 'decisions', 'entities', 'issues',
  'learnings', 'security', 'state', 'sources', 'themes', 'projects',
]);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npx vitest run src/tools/knowledge-validate.test.ts -t projects`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/knowledge-validate.ts mcp/src/tools/knowledge-validate.test.ts
git commit -m "feat(kb): recognize the projects/ MOC category"
```

---

### Task 4: `reindex` writes project-MOC pages from the facet

**Files:**
- Modify: `mcp/src/tools/knowledge-reindex.ts` (collect `project` per page; write `wiki/projects/<slug>.md`)
- Test: `mcp/src/tools/knowledge-reindex.test.ts` (create if absent)

- [ ] **Step 1: Write the failing test**

```typescript
import { describe, it, expect } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { knowledgeReindex } from './knowledge-reindex.js';

function page(kd: string, cat: string, slug: string, project?: string) {
  mkdirSync(join(kd, 'wiki', cat), { recursive: true });
  const fm = ['---', `title: ${slug}`, `type: ${cat}`, ...(project ? [`project: ${project}`] : []), '---', `# ${slug}`];
  writeFileSync(join(kd, 'wiki', cat, `${slug}.md`), fm.join('\n'));
}

describe('reindex project MOCs', () => {
  it('writes wiki/projects/<slug>.md for a project with >= 3 members and skips a 2-member one', async () => {
    const kd = mkdtempSync(join(tmpdir(), 'kb-'));
    page(kd, 'decisions', 'kiri-redesign', 'kiri');
    page(kd, 'decisions', 'kiri-core-design', 'kiri');
    page(kd, 'security', 'kiri-privilege-split', 'kiri');
    page(kd, 'decisions', 'bridge-a', 'cainish-bridge');
    page(kd, 'decisions', 'bridge-b', 'cainish-bridge');
    await knowledgeReindex(kd);
    const moc = join(kd, 'wiki', 'projects', 'kiri.md');
    expect(existsSync(moc)).toBe(true);
    const body = readFileSync(moc, 'utf-8');
    expect(body).toContain('[[kiri-privilege-split]]');
    expect(body).toContain('type: projects');
    expect(body).toContain('graph: exclude');
    expect(existsSync(join(kd, 'wiki', 'projects', 'cainish-bridge.md'))).toBe(false); // 2 < 3
    rmSync(kd, { recursive: true, force: true });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npx vitest run src/tools/knowledge-reindex.test.ts -t MOC`
Expected: FAIL — `wiki/projects/kiri.md` does not exist.

- [ ] **Step 3: Write minimal implementation**

In `knowledge-reindex.ts`: (a) capture `project` while building entries (extend the entry type to `{ slug, title, description, type, project }`, reading `doc.project` from `parseDoc`); (b) after the per-dir loop, gather all entries, import and call `buildProjectMocs`, and write each MOC to `wiki/projects/<slug>.md` wrapping the marked region in frontmatter + reusing the marked-region replace pattern (create the file if absent). Minimal writer:

```typescript
import { buildProjectMocs } from './project-moc.js';
// ...collect `allPages: MocInput[]` across dirs while indexing...
const minMembers = Number(process.env.SB_MOC_MIN_MEMBERS || '3');
const mocs = buildProjectMocs(allPages, { minMembers });
const projDir = join(wikiRoot, 'projects');
if (mocs.size > 0) await fs.mkdir(projDir, { recursive: true });
for (const [proj, region] of mocs) {
  const fmHeader = ['---', `title: ${proj}`, 'type: projects', 'generated: true', 'graph: exclude',
    `description: Map of Content for project ${proj} (generated).`, '---', ''].join('\n');
  await fs.writeFile(join(projDir, `${proj}.md`), fmHeader + region + '\n', 'utf-8');
}
```

(Place the MOC write BEFORE the `knowledgeValidate` call so the new pages are validated, and BEFORE building `index.md` sections so MOCs are catalogued in Task 5. The `projects/` dir is then picked up by the existing `dirs` scan on the *next* reindex; for the same run, include it in the catalog explicitly.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npx vitest run src/tools/knowledge-reindex.test.ts -t MOC`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/knowledge-reindex.ts mcp/src/tools/knowledge-reindex.test.ts
git commit -m "feat(kb): reindex projects per-project MOC pages from the project: facet"
```

---

### Task 5: De-hubbed two-tier `index.md`

**Files:**
- Modify: `mcp/src/tools/knowledge-reindex.ts` (index assembly, lines ~30–69)
- Test: `mcp/src/tools/knowledge-reindex.test.ts` (extend)

- [ ] **Step 1: Write the failing test**

```typescript
it('emits a de-hubbed two-tier index: graph:exclude, MOC links, per-type counts, no flat page hub-links', async () => {
  const kd = mkdtempSync(join(tmpdir(), 'kb-'));
  page(kd, 'decisions', 'kiri-redesign', 'kiri');
  page(kd, 'decisions', 'kiri-core-design', 'kiri');
  page(kd, 'security', 'kiri-privilege-split', 'kiri');
  page(kd, 'concepts', 'standalone');
  await knowledgeReindex(kd);
  const idx = readFileSync(join(kd, 'wiki', 'index.md'), 'utf-8');
  expect(idx).toMatch(/^---[\s\S]*graph:\s*exclude[\s\S]*---/m); // frontmatter marks it excluded
  expect(idx).toContain('[[projects/kiri]]');                    // links the project MOC (intentional hub)
  expect(idx).toMatch(/Decisions.*\b2\b/);                       // per-type COUNT, not 2 page links
  expect(idx).not.toContain('[[kiri-core-design]]');             // individual pages are NOT hub-linked from index
  rmSync(kd, { recursive: true, force: true });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npx vitest run src/tools/knowledge-reindex.test.ts -t two-tier`
Expected: FAIL — current index has no frontmatter and lists `[[kiri-core-design]]` flatly.

- [ ] **Step 3: Write minimal implementation**

Restructure index assembly: emit a frontmatter header (`type: index`, `graph: exclude`); a `## Maps of Content` section listing `[[projects/<slug>]]` and `[[themes/theme-<id>]]` (read the `projects/` and `themes/` dirs); a `## Categories` section with one line per type giving the **count** and the page slugs as **plain text** (not `[[ ]]`) — e.g. ``- **Decisions** (28): kiri-redesign, kiri-core-design, …``. Keep the `<!-- generated: ISO -->` trailer. Concretely the header + categories:

```typescript
const sections: string[] = ['---', 'title: Knowledge Base Index', 'type: index', 'graph: exclude', '---', '', '# Knowledge Base Index', ''];
// ## Maps of Content
const mocLinks: string[] = [];
for (const moc of await collectMd(join(wikiRoot, 'projects'))) mocLinks.push(`- [[projects/${moc.split('/').pop()!.replace(/\.md$/, '')}]]`);
for (const th of await collectMd(join(wikiRoot, 'themes'))) mocLinks.push(`- [[themes/${th.split('/').pop()!.replace(/\.md$/, '')}]]`);
if (mocLinks.length) { sections.push('## Maps of Content', ...mocLinks, ''); }
// ## Categories — counts + plain-text slug rows (no [[ ]] so a graph viewer can't hub it)
sections.push('## Categories', '');
for (const dir of dirs) {
  if (dir === 'projects') continue; // MOCs already listed above
  const entries = /* the {slug,...}[] you already built for this dir */;
  if (!entries.length) continue;
  const label = dir.charAt(0).toUpperCase() + dir.slice(1);
  sections.push(`- **${label}** (${entries.length}): ${entries.map(e => e.slug).join(', ')}`);
}
sections.push('');
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npx vitest run src/tools/knowledge-reindex.test.ts -t two-tier`
Expected: PASS. Also re-run the Task 4 test to confirm no regression.

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/knowledge-reindex.ts mcp/src/tools/knowledge-reindex.test.ts
git commit -m "feat(kb): de-hubbed two-tier index (graph:exclude, MOC links, per-type counts)"
```

---

### Task 6: Reindex is idempotent (modulo the generated timestamp)

**Files:**
- Test: `mcp/src/tools/knowledge-reindex.test.ts` (extend)

- [ ] **Step 1: Write the failing test**

```typescript
it('is idempotent: a second reindex changes nothing but the generated timestamp', async () => {
  const kd = mkdtempSync(join(tmpdir(), 'kb-'));
  page(kd, 'decisions', 'kiri-redesign', 'kiri');
  page(kd, 'decisions', 'kiri-core-design', 'kiri');
  page(kd, 'security', 'kiri-privilege-split', 'kiri');
  const strip = (s: string) => s.replace(/<!-- generated:.*?-->/g, '');
  await knowledgeReindex(kd);
  const idx1 = strip(readFileSync(join(kd, 'wiki', 'index.md'), 'utf-8'));
  const moc1 = readFileSync(join(kd, 'wiki', 'projects', 'kiri.md'), 'utf-8');
  await knowledgeReindex(kd);
  const idx2 = strip(readFileSync(join(kd, 'wiki', 'index.md'), 'utf-8'));
  const moc2 = readFileSync(join(kd, 'wiki', 'projects', 'kiri.md'), 'utf-8');
  expect(idx2).toBe(idx1);
  expect(moc2).toBe(moc1); // MOC has no timestamp → byte-identical
  rmSync(kd, { recursive: true, force: true });
});
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `cd mcp && npx vitest run src/tools/knowledge-reindex.test.ts -t idempotent`
Expected: PASS if Tasks 4–5 are deterministic. If it FAILS, the failure pinpoints a non-determinism (unsorted dir read, a stray timestamp in the MOC) — fix that source, do not weaken the test.

- [ ] **Step 3: Fix any non-determinism surfaced**

If failing: ensure `allPages` is built in sorted order, MOC writing has no `Date`/timestamp, and the `projects/` dir is read deterministically. (No code if already green.)

- [ ] **Step 4: Re-run to verify green**

Run: `cd mcp && npx vitest run src/tools/knowledge-reindex.test.ts`
Expected: PASS (all reindex cases).

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/knowledge-reindex.test.ts mcp/src/tools/knowledge-reindex.ts
git commit -m "test(kb): reindex idempotency guard (MOC + index byte-stable modulo timestamp)"
```

---

### Task 7: One-shot backfill — seed `project:` from `part_of` ancestry + a registry

**Files:**
- Create: `scripts/kb-project-backfill.sh`
- Create: `tests/test-kb-project-backfill.sh`
- Modify: `mcp/src/server.ts` (version bump only — done in the release task, not here)

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
# Backfill sets project: on pages connected by part_of to a known anchor, deterministically.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; S="$ROOT/scripts/kb-project-backfill.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
KD="$TMP/knowledge"; mkdir -p "$KD/wiki/decisions" "$KD/graph"
for s in kiri-redesign kiri-core-design kiri-privilege-split unrelated; do
  printf '%s\n' '---' "title: $s" 'type: decisions' '---' "# $s" > "$KD/wiki/decisions/$s.md"; done
# part_of: core --> redesign (anchor), priv --> core ; unrelated has no edge
printf '%s\n' \
  '{"op":"assert","from":"kiri-core-design","to":"kiri-redesign","type":"part_of","valid_from":"2026-05-01","valid_to":null,"recorded_at":"2026-05-01T00:00:00Z","source":"x"}' \
  '{"op":"assert","from":"kiri-privilege-split","to":"kiri-core-design","type":"part_of","valid_from":"2026-05-01","valid_to":null,"recorded_at":"2026-05-01T00:00:00Z","source":"x"}' \
  > "$KD/graph/edges.jsonl"
# registry maps the anchor slug -> project key
printf '%s\n' '{"anchor":"kiri-redesign","project":"kiri"}' > "$KD/graph/project-registry.jsonl"
KNOWLEDGE_DIR="$KD" bash "$S" --knowledge-dir "$KD"
grep -q '^project: kiri$' "$KD/wiki/decisions/kiri-core-design.md" || fail "core not backfilled"
grep -q '^project: kiri$' "$KD/wiki/decisions/kiri-privilege-split.md" || fail "priv (2 hops) not backfilled"
grep -q '^project: kiri$' "$KD/wiki/decisions/kiri-redesign.md" || fail "anchor not backfilled"
grep -q 'project:' "$KD/wiki/decisions/unrelated.md" && fail "unrelated wrongly tagged"
pass "part_of-ancestry backfill is correct and bounded"
echo; echo ALL PASS
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-kb-project-backfill.sh`
Expected: FAIL — `scripts/kb-project-backfill.sh` not found.

- [ ] **Step 3: Write minimal implementation**

```bash
#!/bin/bash
# One-shot, idempotent: for each registry anchor->project, walk the part_of graph
# (transitive children of the anchor, following part_of edges pointing AT the anchor
# subtree) and set `project: <key>` frontmatter on each member page that lacks it.
# Deterministic, additive, reversible (remove the project: line). Read-only re: edges.
set -u
source "$(dirname "$0")/lib.sh" 2>/dev/null || true
KDIR="${2:-${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}}"; KDIR="${KDIR/#\~/$HOME}"
WIKI="$KDIR/wiki"; EDGES="$KDIR/graph/edges.jsonl"; REG="$KDIR/graph/project-registry.jsonl"
[ -f "$EDGES" ] && [ -f "$REG" ] || { echo "backfill: no edges/registry — nothing to do"; exit 0; }

# current part_of edges as "child<TAB>parent"
PO=$(jq -rn 'reduce (inputs|fromjson?) as $r ({}; .[[$r.from,$r.type,$r.to]|tojson]=$r) | [.[]]
  | map(select(.type=="part_of" and .valid_to==null)) | .[] | "\(.from)\t\(.to)"' < "$EDGES" 2>/dev/null)

set_project() { # <slug> <project>
  local slug="$1" proj="$2"
  local f; f=$(find "$WIKI" -name "$slug.md" -type f ! -name 'index.md' 2>/dev/null | head -1)
  [ -n "$f" ] || return 0
  grep -qE '^project:' "$f" && return 0          # idempotent: never overwrite
  # insert `project: <proj>` as the last line of the first frontmatter block
  awk -v p="$proj" 'NR==1&&/^---$/{print;infm=1;next} infm&&/^---$/{print "project: " p;print;infm=0;next} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# BFS from each anchor over the reverse part_of relation (children point AT parent).
while IFS= read -r line; do
  anchor=$(printf '%s' "$line" | jq -r '.anchor'); proj=$(printf '%s' "$line" | jq -r '.project')
  [ -n "$anchor" ] && [ -n "$proj" ] || continue
  queue="$anchor"; seen=" "
  while [ -n "$queue" ]; do
    node="${queue%% *}"; queue="${queue#"$node"}"; queue="${queue# }"
    case "$seen" in *" $node "*) continue;; esac
    seen="$seen$node "
    set_project "$node" "$proj"
    kids=$(printf '%s\n' "$PO" | awk -F'\t' -v a="$node" '$2==a{print $1}')
    for k in $kids; do queue="$queue $k"; done
  done
done < "$REG"
echo "backfill: done"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-kb-project-backfill.sh`
Expected: PASS — all four assertions green (anchor + 1-hop + 2-hop tagged; unrelated untouched).

- [ ] **Step 5: Run twice to confirm idempotency, then commit**

Run: `bash tests/test-kb-project-backfill.sh` (the script's own re-run guard `grep -qE '^project:'` makes a second pass a no-op).

```bash
git add scripts/kb-project-backfill.sh tests/test-kb-project-backfill.sh
git commit -m "feat(kb): one-shot part_of-ancestry project: backfill (idempotent, reversible)"
```

---

### Task 8: Rebuild bundles, full gate, version + migration row

**Files:**
- Modify: `mcp/src/server.ts` (knowledge-base version bump), `.claude-plugin/plugin.json` + `marketplace.json` (lockstep), `skills/upgrade/SKILL.md` (migration row)

- [ ] **Step 1: Rebuild the MCP bundles** (new TS must ship in `dist/`)

Run: `cd mcp && npm run build`
Expected: bundles rebuilt, no tsc errors.

- [ ] **Step 2: Run the FULL suite**

Run: `bash tests/run-all.sh`
Expected: ALL GREEN (new vitest + `test-kb-project-backfill.sh` auto-discovered; existing `test-knowledge-eval.sh` recall@2 + token budget NOT regressed).

- [ ] **Step 3: Bump version + add migration row**

Bump `plugin.json` + `marketplace.json` to the next version (e.g. `0.23.0`); bump `mcp/src/server.ts` knowledge-base version; add a `0.23.0` row to `skills/upgrade/SKILL.md` describing: project: facet + project-MOC projection + de-hubbed two-tier index + one-shot `kb-project-backfill.sh` (opt-in: run once to seed facets). Note `SB_KB_MOC`/`SB_MOC_MIN_MEMBERS` flags; additive/back-compat (no facets ⇒ flat index as before).

- [ ] **Step 4: Validate + run the migration-row gate**

Run: `bash scripts/validate-plugin.sh && bash tests/test-upgrade-migration-row.sh`
Expected: both PASS (version lockstep + row present).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore(release): KB hierarchical organization Phase 1 — <version> + migration row"
```

---

## Release gate (after all tasks)

Per `feedback_deep-review-release-gate`: run `/second-brain:code-review-deep` on the branch, address findings, then open the PR. Do NOT merge until green + reviewed.

## Self-review checklist (run before implementing)

- **Spec coverage (Phase 1 §13):** project: facet (T1, T7) ✓ · project-MOC projection ≥3 (T2, T4) ✓ · de-hubbed two-tier index + graph:exclude (T5) ✓ · idempotent projection (T6) ✓ · registry seed + backfill (T7) ✓ · projects category in validate (T3) ✓ · flags `SB_KB_MOC`/`SB_MOC_MIN_MEMBERS` (T4, T8). On-write facet-setting + relates→part_of promotion + maintainer/lint/drift are **explicitly Phase 2/3** (not gaps).
- **Type consistency:** `MocInput {slug,type,project,title,description}` and `buildProjectMocs(pages, {minMembers})` are used identically in T2/T4; `parseDoc().project` (T1) feeds T4; `project-registry.jsonl {anchor,project}` consistent T7.
- **No placeholders:** every code step shows real code; the one "/* the {slug,...}[] you already built */" in T5 references the entries array built in the same function in T4 — make it a named `const allPages`/per-dir `entries` you thread through (call it out during T5 impl).
