# Memory Egress — Phase 2: SERVE (tiered retrieval) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Give Claude tiered, progressive-disclosure access to wiki pages — `knowledge_search` returns the curated one-line gist (not a raw frontmatter chop), and a new `knowledge_fetch(slug, tier)` tool serves gist → skeleton → summary → full on demand, with the Phase-1 GUARD enforcing a hard ceiling on body size. Also wires GUARD into `episodic_search` aggregate output.

**Architecture:** New pure-ish module `mcp/src/tools/knowledge-fetch.ts` resolves a slug to its page and extracts the requested tier (reusing `parseDoc` from `knowledge-search.ts`); it caps full/summary bodies via `capText` from Phase 1's `egress-budget.ts` and always returns a source pointer. `knowledge_search` swaps `first_lines` → curated `description`. `server.ts` registers `knowledge_fetch` and wraps `episodic_search` rendering in `capList`. Summary tier (T2) has no stored data until Phase 3 (maintainer ENRICH), so `tier:summary` gracefully falls back to skeleton + a note.

**Tech Stack:** TypeScript (ESM, node20), Vitest, glob (already a dep). No new dependencies.

**Design choices made here (call out if any is wrong before execution):**
- `knowledge_search` candidate field changes `first_lines` → `description` (curated gist; falls back to a 200-char snippet when a page has no `description:`). This is spec decision D-1.
- `knowledge_fetch` tiers: **gist** = frontmatter description; **skeleton** = description + the page's `##` headings; **summary** = the page's `## Summary` section if present, else falls back to skeleton with a "no summary yet — use tier=full" note (the `## Summary` block is populated later by Phase 3); **full** = body, capped by `capText` to the egress budget with a `Read <path>` pointer.
- GUARD on `episodic_search` is applied at the server render layer via `capList` (aggregate cap), not inside the search function.

**Build/test:** from `mcp/`:
- Targeted: `cd mcp && npx vitest run test/<file>.test.ts`
- Full: `cd mcp && npm test`
- Bundle (required in Task 3 because `server.ts` changed): `cd mcp && npm run build` — commit the regenerated `dist/` artifacts.

**Commit convention:** Conventional Commits; end the body with `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

**Scope note:** Phase 2 of the subsystem in `docs/superpowers/specs/2026-05-24-context-aware-memory-egress-design.md`. Phase 3 (maintainer ENRICH summaries) and Phase 4 (POINT rework) follow.

---

### Task 1: `knowledge_search` returns the curated gist (`description`)

**Files:**
- Modify: `mcp/src/tools/knowledge-search.ts`
- Test: `mcp/test/knowledge-search.test.ts` (append)

- [ ] **Step 1: Write the failing test** — append inside `describe('knowledge_search v1', ...)`:

```ts
  it('returns the curated description as the gist, not a raw frontmatter chop', async () => {
    writeFileSync(
      join(knowledgeDir, 'wiki', 'concepts', 'gist-page.md'),
      `---\ntitle: "Gist page"\ndescription: "One-line curated gist about widgets"\n---\n\n# Gist page\n\nBody about widgets and gizmos.\n`,
      'utf-8'
    );
    const res = await knowledgeSearch({ query: 'widgets gizmos gist', knowledgeDir });
    const hit = res.candidates.find(c => c.path.endsWith('gist-page.md'));
    expect(hit).toBeDefined();
    expect(hit!.description).toBe('One-line curated gist about widgets');
    expect(hit as any).not.toHaveProperty('first_lines');
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd mcp && npx vitest run test/knowledge-search.test.ts`
Expected: FAIL — candidate has `first_lines`, not `description`.

- [ ] **Step 3: Implement** — in `mcp/src/tools/knowledge-search.ts`:

(a) Change the `KnowledgeSearchResult` interface:
```ts
export interface KnowledgeSearchResult { candidates: { path: string; score: number; description: string; tokens: number }[]; }
```

(b) In the `scored` map, replace the `first_lines` field with `description` (curated gist; fall back to a trimmed snippet when the page has no `description:`):
```ts
  const scored = allDocs.map(({ doc, rawContent }) => ({
    path: doc.path,
    score: scoreBM25(queryTokens, doc, avgDL, N, dfMap),
    related: doc.related,
    description: doc.description || rawContent.slice(0, SNIPPET_CHARS).replace(/\s+/g, ' ').trim(),
    tokens: estimateTokens(rawContent),
  }));
```
(`SNIPPET_CHARS` and `doc.description` already exist; `estimateTokens` is already imported from Phase 1.)

The final `.map(({ related, ...rest }) => rest)` already passes the new `description` field through. Do NOT change it.

- [ ] **Step 4: Run targeted + full suite**

Run: `cd mcp && npx vitest run test/knowledge-search.test.ts` → PASS (new case + the existing 4 cases; note the older `first_lines` assertions were already replaced by the token-label test in Phase 1 — confirm no test still references `first_lines`; if one does, update it to `description`).
Run: `cd mcp && npm test` → all green.

- [ ] **Step 5: Commit**
```bash
git add mcp/src/tools/knowledge-search.ts mcp/test/knowledge-search.test.ts
git commit -m "$(printf 'feat(serve): knowledge_search returns curated description gist (phase 2)\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: `knowledge-fetch.ts` — slug resolution + tier extraction

**Files:**
- Create: `mcp/src/tools/knowledge-fetch.ts`
- Test: `mcp/test/knowledge-fetch.test.ts`

- [ ] **Step 1: Write the failing test** `mcp/test/knowledge-fetch.test.ts`:

```ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeFetch } from '../src/tools/knowledge-fetch.js';
import { estimateTokens } from '../src/tools/egress-budget.js';

describe('knowledge_fetch', () => {
  let knowledgeDir: string;
  beforeEach(() => {
    knowledgeDir = mkdtempSync(join(tmpdir(), 'kf-'));
    mkdirSync(join(knowledgeDir, 'wiki', 'concepts'), { recursive: true });
    writeFileSync(
      join(knowledgeDir, 'wiki', 'concepts', 'widget.md'),
      `---\ntitle: "Widget"\ndescription: "A widget is a small gizmo"\n---\n\n# Widget\n\nIntro para.\n\n## Design\n\nDesign details here.\n\n## Summary\n\nWidgets are small gizmos used for X.\n`,
      'utf-8'
    );
    writeFileSync(
      join(knowledgeDir, 'wiki', 'concepts', 'nosum.md'),
      `---\ntitle: "NoSum"\ndescription: "Page without a summary"\n---\n\n# NoSum\n\n## Alpha\n\ntext\n`,
      'utf-8'
    );
  });
  afterEach(() => { rmSync(knowledgeDir, { recursive: true, force: true }); });

  it('gist tier returns the frontmatter description + pointer', async () => {
    const r = await knowledgeFetch({ slug: 'widget', tier: 'gist', knowledgeDir });
    expect(r.tier).toBe('gist');
    expect(r.text).toBe('A widget is a small gizmo');
    expect(r.path).toMatch(/widget\.md$/);
    expect(r.pointer).toContain('widget');
  });

  it('skeleton tier returns description + headings', async () => {
    const r = await knowledgeFetch({ slug: 'widget', tier: 'skeleton', knowledgeDir });
    expect(r.text).toContain('A widget is a small gizmo');
    expect(r.text).toContain('## Design');
    expect(r.text).toContain('## Summary');
    expect(r.text).not.toContain('Design details here'); // headings only, not body
  });

  it('summary tier returns the ## Summary section when present', async () => {
    const r = await knowledgeFetch({ slug: 'widget', tier: 'summary', knowledgeDir });
    expect(r.text).toContain('Widgets are small gizmos used for X');
  });

  it('summary tier falls back to skeleton + note when no ## Summary exists', async () => {
    const r = await knowledgeFetch({ slug: 'nosum', tier: 'summary', knowledgeDir });
    expect(r.text).toContain('## Alpha');
    expect(r.text.toLowerCase()).toContain('no summary');
  });

  it('full tier returns the body and stays within the egress budget', async () => {
    const r = await knowledgeFetch({ slug: 'widget', tier: 'full', knowledgeDir });
    expect(r.text).toContain('Design details here');
    expect(estimateTokens(r.text)).toBeLessThanOrEqual(2000);
  });

  it('returns path=null and a helpful message for an unknown slug', async () => {
    const r = await knowledgeFetch({ slug: 'does-not-exist', tier: 'gist', knowledgeDir });
    expect(r.path).toBeNull();
    expect(r.text.toLowerCase()).toContain('not found');
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd mcp && npx vitest run test/knowledge-fetch.test.ts`
Expected: FAIL — `Failed to resolve import "../src/tools/knowledge-fetch.js"`.

- [ ] **Step 3: Implement** `mcp/src/tools/knowledge-fetch.ts`:

```ts
import { promises as fs } from 'fs';
import { join } from 'path';
import { glob } from 'glob';
import { parseDoc } from './knowledge-search.js';
import { capText, egressBudgetTokens, estimateTokens } from './egress-budget.js';

export type Tier = 'gist' | 'skeleton' | 'summary' | 'full';

export interface KnowledgeFetchArgs {
  slug: string;
  tier?: Tier;
  knowledgeDir?: string;
}

export interface KnowledgeFetchResult {
  slug: string;
  path: string | null;
  tier: Tier;
  text: string;
  tokens: number;
  truncated: boolean;
  pointer: string;
}

/** Collect the page's `##`/`###` headings, in order. */
function headings(body: string): string[] {
  return body.split('\n').filter((l) => /^#{2,3}\s+\S/.test(l.trim())).map((l) => l.trim());
}

/** Extract the body of a `## Summary` section (until the next `## ` or EOF). */
function summarySection(body: string): string | null {
  const lines = body.split('\n');
  const start = lines.findIndex((l) => /^##\s+summary\s*$/i.test(l.trim()));
  if (start === -1) return null;
  const out: string[] = [];
  for (let i = start + 1; i < lines.length; i++) {
    if (/^##\s+\S/.test(lines[i].trim())) break;
    out.push(lines[i]);
  }
  return out.join('\n').trim() || null;
}

export async function knowledgeFetch(args: KnowledgeFetchArgs): Promise<KnowledgeFetchResult> {
  const tier: Tier = args.tier ?? 'gist';
  const knowledgeDir = args.knowledgeDir ?? join(process.env.HOME ?? '', 'knowledge');
  const wikiRoot = join(knowledgeDir, 'wiki');

  const matches = await glob(`**/${args.slug}.md`, { cwd: wikiRoot, absolute: true }).catch(() => [] as string[]);
  const filePath = matches[0] ?? null;
  if (!filePath) {
    return {
      slug: args.slug,
      path: null,
      tier,
      text: `Page not found for slug "${args.slug}". Try knowledge_search to find the right slug.`,
      tokens: 0,
      truncated: false,
      pointer: 'knowledge_search',
    };
  }

  const raw = await fs.readFile(filePath, 'utf-8');
  const doc = parseDoc(raw, filePath);
  const fullPointer = `Read ${filePath} for the full page`;
  const gist = doc.description || (doc.title ? doc.title : args.slug);

  let text: string;
  let truncated = false;

  if (tier === 'gist') {
    text = gist;
  } else if (tier === 'skeleton') {
    const hs = headings(doc.body);
    text = [gist, '', ...hs].join('\n').trim();
  } else if (tier === 'summary') {
    const summary = summarySection(doc.body);
    if (summary) {
      const capped = capText(summary, egressBudgetTokens(), fullPointer);
      text = capped.text;
      truncated = capped.truncated;
    } else {
      const hs = headings(doc.body);
      text = [gist, '', ...hs, '', '(no summary yet — use tier=full for the body)'].join('\n').trim();
    }
  } else {
    // full
    const capped = capText(doc.body.trim(), egressBudgetTokens(), fullPointer);
    text = capped.text;
    truncated = capped.truncated;
  }

  return {
    slug: args.slug,
    path: filePath,
    tier,
    text,
    tokens: estimateTokens(text),
    truncated,
    pointer: tier === 'full' ? fullPointer : `knowledge_fetch("${args.slug}", "full")`,
  };
}
```

- [ ] **Step 4: Run targeted + full suite**

Run: `cd mcp && npx vitest run test/knowledge-fetch.test.ts` → PASS (6 cases).
Run: `cd mcp && npm test` → all green.

- [ ] **Step 5: Commit**
```bash
git add mcp/src/tools/knowledge-fetch.ts mcp/test/knowledge-fetch.test.ts
git commit -m "$(printf 'feat(serve): knowledge_fetch tiered retrieval (gist/skeleton/summary/full) (phase 2)\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>')"
```

---

### Task 3: Register `knowledge_fetch` in the MCP server + rebuild bundle

**Files:**
- Modify: `mcp/src/server.ts` (import + `registerTool`)
- Modify: `mcp/dist/server.bundle.js` (regenerated by `npm run build` — commit the artifact)

- [ ] **Step 1: Add the import** in `mcp/src/server.ts`, after the `knowledgeSearch` import (line ~11):
```ts
import { knowledgeFetch } from "./tools/knowledge-fetch.js";
```

- [ ] **Step 2: Register the tool** — add this `server.registerTool(...)` block immediately after the existing `knowledge_search` registration block (after its closing `);` near line 71):
```ts
server.registerTool(
  "knowledge_fetch",
  {
    description: "Fetch a wiki page at a chosen detail tier (progressive disclosure). tier: 'gist' (one-line), 'skeleton' (gist + headings), 'summary' (the page's ## Summary section, or skeleton if none yet), 'full' (body, capped to the egress budget). Always returns a source pointer so you can escalate to the full page only when needed. Prefer this over reading the raw file for large pages.",
    inputSchema: {
      slug: z.string().describe("The page slug (filename without .md), e.g. from a knowledge_search result path."),
      tier: z.enum(["gist", "skeleton", "summary", "full"]).optional().describe("Detail level. Default 'gist'."),
    },
  },
  async ({ slug, tier }) => {
    try {
      const result = await knowledgeFetch({ slug, tier, knowledgeDir: KNOWLEDGE_DIR });
      return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
    } catch (error) {
      return {
        content: [{ type: "text" as const, text: `Fetch error: ${error instanceof Error ? error.message : String(error)}` }],
        isError: true,
      };
    }
  }
);
```

- [ ] **Step 3: Type-check + build the bundle**

Run: `cd mcp && npm run build`
Expected: `tsc` exits 0 (no type errors) and esbuild regenerates `dist/server.bundle.js` (which now inlines `knowledge-fetch.ts` since `server.ts` imports it).

- [ ] **Step 4: Verify the tool made it into the rebuilt bundle**

Run:
```bash
cd mcp && test -f dist/server.bundle.js && grep -q '"knowledge_fetch"' dist/server.bundle.js && echo "ok: knowledge_fetch registered in bundle"
```
Expected: `ok: knowledge_fetch registered in bundle`
(The TS type-check in Step 3's `npm run build` is the real correctness gate; this just confirms the bundle was regenerated with the new tool. Do NOT `node`-import the `.ts` source directly — node has no TS loader; the test runner/bundler handle TS.)

- [ ] **Step 5: Full suite (no regressions)**

Run: `cd mcp && npm test` → all green.

- [ ] **Step 6: Commit (source + regenerated bundle)**
```bash
git add mcp/src/server.ts mcp/dist/server.bundle.js
git commit -m "$(printf 'feat(serve): register knowledge_fetch MCP tool + rebuild bundle (phase 2)\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>')"
```

---

### Task 4: Wire GUARD into `episodic_search` aggregate output

`episodic_search` renders up to `limit` (default 10) results as markdown joined by `\n\n`, uncapped. Wrap that in `capList` so a wide search can't flood context, with an `episodic_read` drill-down affordance.

**Files:**
- Modify: `mcp/src/server.ts` (the `episodic_search` handler, ~line 365-388)
- Modify: `mcp/dist/server.bundle.js` (rebuild)

- [ ] **Step 1: Add the import** in `mcp/src/server.ts` (after the egress-budget consumers; add near the other tool imports):
```ts
import { capList, egressBudgetTokens } from "./tools/egress-budget.js";
```

- [ ] **Step 2: Replace the `episodic_search` result rendering.** In the `episodic_search` handler, the current code maps results to `lines` and returns `lines.join('\n\n')`. Replace the `const lines = result.results.map(...)` + return with:
```ts
      const render = (r: typeof result.results[number]) => {
        const sim = r.similarity > 0 ? ` (${Math.round(r.similarity * 100)}%)` : '';
        return [
          `### ${r.project} — ${r.date}${sim}`,
          `**User**: ${r.userSnippet}`,
          `**Assistant**: ${r.assistantSnippet}`,
          `*Session: ${r.sessionId} | Lines ${r.lineStart}-${r.lineEnd} | ${r.archivePath}*`,
        ].join('\n');
      };
      const capped = capList(result.results, render, egressBudgetTokens(), 'narrow the query or use episodic_read on a specific result');
      return { content: [{ type: "text" as const, text: capped.text }] };
```
(Keep the existing empty-results early return `"No matching conversations found."` above this unchanged.)

- [ ] **Step 3: Type-check + build**

Run: `cd mcp && npm run build`
Expected: `tsc` exits 0; bundle regenerated.

- [ ] **Step 4: Full suite**

Run: `cd mcp && npm test` → all green (episodic tests test the `episodicSearch` function directly, not the server render layer, so they remain unaffected; confirm green).

- [ ] **Step 5: Commit**
```bash
git add mcp/src/server.ts mcp/dist/server.bundle.js
git commit -m "$(printf 'feat(serve): cap episodic_search output via GUARD capList (phase 2)\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>')"
```

---

## Definition of done (Phase 2)
- `knowledge_search` candidates carry `description` (curated gist) + `tokens`, no `first_lines`.
- `mcp/src/tools/knowledge-fetch.ts` exists; `knowledge_fetch` registered in `server.ts`; serves gist/skeleton/summary/full with GUARD capping and a source pointer; summary falls back gracefully pre-Phase-3.
- `episodic_search` output is GUARD-capped.
- `cd mcp && npm test` green; `dist/server.bundle.js` rebuilt and committed.

## Hand-off to Phase 3 (maintainer ENRICH)
Phase 3 extends `agents/knowledge-maintainer.md` Phase 4 to generate a `## Summary` section for pages over the size threshold (using the existing extractor). Once those exist, `knowledge_fetch tier=summary` starts returning real précis instead of the skeleton fallback — no code change needed in this module.
