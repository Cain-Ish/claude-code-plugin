# Memory Egress — Phase 1: GUARD module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the deterministic, LLM-free egress **budget guard** — the GUARD move of POINT/SERVE/GUARD — as a pure, fully-unit-tested TypeScript module, and surface per-candidate token-count labels in `knowledge_search` so Claude can budget its own context spend.

**Architecture:** A new pure module `mcp/src/tools/egress-budget.ts` exports `estimateTokens` (chars/4), `egressBudgetTokens` (env-configurable cap), `capText` (grapheme-safe truncation with a drill-down marker, never expands), and `capList` (keep ranked items until budget, append "N more — drill down"). Phase 1 wires only the cheap, high-value `estimateTokens` label into `knowledge_search`; `capText`/`capList` are consumed by later phases (SERVE `knowledge_fetch`, episodic). Pure functions → trivially testable, offline, no LLM.

**Tech Stack:** TypeScript (ESM, node20), Vitest, `Intl.Segmenter` (built-in) for grapheme-safe truncation. No new dependencies.

**Scope note:** This is Phase 1 of the 4-phase subsystem in `docs/superpowers/specs/2026-05-24-context-aware-memory-egress-design.md`. Phases 2 (SERVE/`knowledge_fetch`), 3 (maintainer ENRICH summaries), and 4 (POINT rework) get their own plans. Each phase ships working, tested software on its own.

**Commit convention:** repo uses Conventional Commits. End every commit message body with the trailer `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

**Build/test commands:** all run from `mcp/`:
- Test (single file): `cd mcp && npx vitest run test/egress-budget.test.ts`
- Test (all): `cd mcp && npm test`
- Build/bundle (only needed before a release or when wiring into the server): `cd mcp && npm run build`

---

### Task 1: Token estimation + configurable budget

**Files:**
- Create: `mcp/src/tools/egress-budget.ts`
- Test: `mcp/test/egress-budget.test.ts`

- [ ] **Step 1: Write the failing test**

Create `mcp/test/egress-budget.test.ts`:

```ts
import { describe, it, expect, afterEach } from 'vitest';
import {
  estimateTokens,
  egressBudgetTokens,
  DEFAULT_EGRESS_BUDGET_TOKENS,
} from '../src/tools/egress-budget.js';

describe('estimateTokens', () => {
  it('uses the chars/4 heuristic, rounding up', () => {
    expect(estimateTokens('')).toBe(0);
    expect(estimateTokens('abcd')).toBe(1);
    expect(estimateTokens('abcde')).toBe(2);
  });
});

describe('egressBudgetTokens', () => {
  afterEach(() => { delete process.env.SB_EGRESS_BUDGET_TOKENS; });

  it('falls back to the default when env is unset', () => {
    delete process.env.SB_EGRESS_BUDGET_TOKENS;
    expect(egressBudgetTokens()).toBe(DEFAULT_EGRESS_BUDGET_TOKENS);
  });

  it('reads a positive integer from env', () => {
    process.env.SB_EGRESS_BUDGET_TOKENS = '500';
    expect(egressBudgetTokens()).toBe(500);
  });

  it('ignores non-positive / non-numeric env values', () => {
    process.env.SB_EGRESS_BUDGET_TOKENS = 'nope';
    expect(egressBudgetTokens()).toBe(DEFAULT_EGRESS_BUDGET_TOKENS);
    process.env.SB_EGRESS_BUDGET_TOKENS = '0';
    expect(egressBudgetTokens()).toBe(DEFAULT_EGRESS_BUDGET_TOKENS);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npx vitest run test/egress-budget.test.ts`
Expected: FAIL — `Failed to resolve import "../src/tools/egress-budget.js"` (module does not exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `mcp/src/tools/egress-budget.ts`:

```ts
/**
 * Deterministic egress budget guard for second-brain → Claude responses.
 * Pure, LLM-free, offline. This is the GUARD move of POINT/SERVE/GUARD:
 * cap how much any single retrieval dumps into Claude's context, never expand,
 * and always leave a drill-down affordance.
 * Spec: docs/superpowers/specs/2026-05-24-context-aware-memory-egress-design.md
 */

const CHARS_PER_TOKEN = 4;

export const DEFAULT_EGRESS_BUDGET_TOKENS = 2000;

/** Estimate token count with the chars/4 heuristic used across the plugin. */
export function estimateTokens(text: string): number {
  if (!text) return 0;
  return Math.ceil(text.length / CHARS_PER_TOKEN);
}

/** Configured egress budget (env override), falling back to the default. */
export function egressBudgetTokens(): number {
  const raw = process.env.SB_EGRESS_BUDGET_TOKENS;
  const n = raw ? parseInt(raw, 10) : NaN;
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_EGRESS_BUDGET_TOKENS;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npx vitest run test/egress-budget.test.ts`
Expected: PASS (5 assertions across 2 describe blocks).

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/egress-budget.ts mcp/test/egress-budget.test.ts
git commit -m "feat(egress): token estimate + configurable budget (phase 1)"
```

---

### Task 2: `capText` — grapheme-safe truncation with drill-down marker

**Files:**
- Modify: `mcp/src/tools/egress-budget.ts`
- Test: `mcp/test/egress-budget.test.ts` (append)

- [ ] **Step 1: Write the failing test**

Append to `mcp/test/egress-budget.test.ts` (and add `capText` to the existing import from `../src/tools/egress-budget.js`):

```ts
import { capText } from '../src/tools/egress-budget.js'; // add to existing import

describe('capText', () => {
  it('returns text unchanged when within budget (never expands)', () => {
    const r = capText('short text', 100);
    expect(r.truncated).toBe(false);
    expect(r.text).toBe('short text');
    expect(r.omittedTokens).toBe(0);
  });

  it('truncates oversized text and stays within budget', () => {
    const text = 'x'.repeat(1000); // ~250 tokens
    const r = capText(text, 50);
    expect(r.truncated).toBe(true);
    expect(estimateTokens(r.text)).toBeLessThanOrEqual(50);
    expect(r.text).toContain('truncated');
    expect(r.omittedTokens).toBeGreaterThan(0);
  });

  it('includes the pointer in the marker when provided', () => {
    const r = capText('y'.repeat(1000), 50, 'knowledge_fetch(foo, full)');
    expect(r.text).toContain('knowledge_fetch(foo, full)');
  });

  it('never splits a multi-byte grapheme cluster', () => {
    const text = '👨‍👩‍👧‍👦'.repeat(100); // ZWJ family emoji
    const r = capText(text, 8);
    const seg = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
    // Re-segmenting the kept portion (before the marker) yields only whole clusters.
    const kept = r.text.split('\n')[0];
    expect([...seg.segment(kept)].every(s => s.segment === '👨‍👩‍👧‍👦' || s.segment === '')).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npx vitest run test/egress-budget.test.ts`
Expected: FAIL — `capText is not exported` / `capText is not a function`.

- [ ] **Step 3: Write minimal implementation**

Append to `mcp/src/tools/egress-budget.ts`:

```ts
export interface CapTextResult {
  text: string;
  truncated: boolean;
  omittedTokens: number;
}

/**
 * Truncate text to a token budget on a grapheme boundary (never splits an
 * emoji/CJK cluster), appending a drill-down marker. Never expands: text that
 * already fits is returned unchanged with truncated=false.
 */
export function capText(
  text: string,
  maxTokens: number,
  pointer?: string,
): CapTextResult {
  const total = estimateTokens(text);
  if (total <= maxTokens) {
    return { text, truncated: false, omittedTokens: 0 };
  }
  const marker = pointer ? `\n… truncated — full text via ${pointer}` : `\n… truncated`;
  const keepChars = Math.max(0, (maxTokens - estimateTokens(marker))) * CHARS_PER_TOKEN;
  const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
  let out = '';
  for (const { segment } of segmenter.segment(text)) {
    if (out.length + segment.length > keepChars) break;
    out += segment;
  }
  return { text: out + marker, truncated: true, omittedTokens: total - estimateTokens(out) };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npx vitest run test/egress-budget.test.ts`
Expected: PASS (all `capText` cases green; earlier Task 1 cases still green).

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/egress-budget.ts mcp/test/egress-budget.test.ts
git commit -m "feat(egress): grapheme-safe capText with drill-down marker (phase 1)"
```

---

### Task 3: `capList` — ranked-list budget cap with drill-down affordance

**Files:**
- Modify: `mcp/src/tools/egress-budget.ts`
- Test: `mcp/test/egress-budget.test.ts` (append)

- [ ] **Step 1: Write the failing test**

Append to `mcp/test/egress-budget.test.ts` (add `capList` to the import):

```ts
import { capList } from '../src/tools/egress-budget.js'; // add to existing import

describe('capList', () => {
  const render = (s: string) => s;

  it('keeps all items when within budget', () => {
    const r = capList(['a', 'b', 'c'], render, 1000, 'drill down');
    expect(r.kept).toEqual(['a', 'b', 'c']);
    expect(r.omitted).toBe(0);
    expect(r.text).not.toContain('more');
  });

  it('drops items past the budget and appends a drill-down affordance', () => {
    const big = 'z'.repeat(400); // ~100 tokens each
    const r = capList([big, big, big, big], render, 150, 'knowledge_fetch');
    expect(r.kept.length).toBeLessThan(4);
    expect(r.omitted).toBeGreaterThan(0);
    expect(r.text).toContain(`${r.omitted} more`);
    expect(r.text).toContain('knowledge_fetch');
  });

  it('always keeps at least the top item even if it exceeds budget', () => {
    const huge = 'q'.repeat(10000);
    const r = capList([huge, 'b'], render, 10, 'more');
    expect(r.kept.length).toBe(1);
    expect(r.kept[0]).toBe(huge);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npx vitest run test/egress-budget.test.ts`
Expected: FAIL — `capList is not exported`.

- [ ] **Step 3: Write minimal implementation**

Append to `mcp/src/tools/egress-budget.ts`:

```ts
export interface CapListResult<T> {
  kept: T[];
  text: string;
  omitted: number;
}

/**
 * Render a ranked list under a token budget. Keeps items in order until the
 * next would exceed the budget, then appends a drill-down affordance
 * ("N more — <hint>"). Always keeps at least the top item. Never expands.
 */
export function capList<T>(
  items: T[],
  render: (item: T) => string,
  maxTokens: number,
  moreHint: string,
  separator = '\n\n',
): CapListResult<T> {
  const kept: T[] = [];
  const parts: string[] = [];
  let used = 0;
  for (const item of items) {
    const piece = render(item);
    const cost = estimateTokens(piece) + estimateTokens(separator);
    if (kept.length > 0 && used + cost > maxTokens) break;
    kept.push(item);
    parts.push(piece);
    used += cost;
  }
  const omitted = items.length - kept.length;
  let text = parts.join(separator);
  if (omitted > 0) text += `${separator}… ${omitted} more — ${moreHint}`;
  return { kept, text, omitted };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npx vitest run test/egress-budget.test.ts`
Expected: PASS (all `capList` cases green; Tasks 1–2 still green).

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/egress-budget.ts mcp/test/egress-budget.test.ts
git commit -m "feat(egress): capList budget cap with drill-down affordance (phase 1)"
```

---

### Task 4: Surface per-candidate token-count labels in `knowledge_search`

Lets Claude budget its own spend ("context as a bank account") — the cheapest high-value win from the research. Each candidate gains `tokens` = the estimated cost of `Read`-ing that full page.

**Files:**
- Modify: `mcp/src/tools/knowledge-search.ts` (interface + the `scored` map + the returned candidates)
- Test: `mcp/test/knowledge-search.test.ts` (append one case)

- [ ] **Step 1: Write the failing test**

Append to `mcp/test/knowledge-search.test.ts` inside the existing `describe('knowledge_search v1', ...)` block:

```ts
  it('labels each candidate with an estimated token count', async () => {
    const res = await knowledgeSearch({ query: 'counting pipeline grep', knowledgeDir });
    expect(res.candidates.length).toBeGreaterThan(0);
    for (const c of res.candidates) {
      expect(typeof c.tokens).toBe('number');
      expect(c.tokens).toBeGreaterThan(0);
    }
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npx vitest run test/knowledge-search.test.ts`
Expected: FAIL — `c.tokens` is `undefined`, so `typeof` is `"undefined"` and the assertion fails.

- [ ] **Step 3: Write minimal implementation**

In `mcp/src/tools/knowledge-search.ts`:

(a) Add the import at the top (after the existing `embeddings.js` import):

```ts
import { estimateTokens } from './egress-budget.js';
```

(b) Extend the result candidate type. Change the `KnowledgeSearchResult` interface:

```ts
export interface KnowledgeSearchResult { candidates: { path: string; score: number; first_lines: string; tokens: number }[]; }
```

(c) Add `tokens` to the `scored` map (the object literal currently producing `{ path, score, related, first_lines }`):

```ts
  const scored = allDocs.map(({ doc, rawContent }) => ({
    path: doc.path,
    score: scoreBM25(queryTokens, doc, avgDL, N, dfMap),
    related: doc.related,
    first_lines: rawContent.slice(0, SNIPPET_CHARS),
    tokens: estimateTokens(rawContent),
  }));
```

The existing `.map(({ related, ...rest }) => rest)` at the end already strips `related` and keeps `tokens`, so the returned candidates carry the new field automatically — no change needed there.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mcp && npx vitest run test/knowledge-search.test.ts`
Expected: PASS — the new token-label case green; the three pre-existing cases still green.

- [ ] **Step 5: Run the full suite to confirm no regressions**

Run: `cd mcp && npm test`
Expected: PASS — all vitest files green (egress-budget + knowledge-search + the rest).

- [ ] **Step 6: Commit**

```bash
git add mcp/src/tools/knowledge-search.ts mcp/test/knowledge-search.test.ts
git commit -m "feat(egress): per-candidate token-count labels in knowledge_search (phase 1)"
```

---

## Definition of done (Phase 1)

- `mcp/src/tools/egress-budget.ts` exists with `estimateTokens`, `egressBudgetTokens`, `capText`, `capList`, all unit-tested.
- `knowledge_search` candidates carry a `tokens` field.
- `cd mcp && npm test` is green.
- No bundle rebuild required this phase (no `server.ts` wiring yet — `capText`/`capList` are consumed in Phase 2 when `knowledge_fetch` lands). If a later phase wires the server, run `cd mcp && npm run build` and commit the regenerated `dist/` bundles.

## Hand-off to Phase 2 (SERVE)
Phase 2 introduces `knowledge_fetch(slug, tier)` and switches `knowledge_search` to return the curated `description` instead of raw `first_lines`. It will consume `capText` (per-tier body cap) and `capList` (aggregate response cap via `egressBudgetTokens()`), wiring GUARD into the actual egress points and rebuilding the server bundle.
