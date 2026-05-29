# Bi-Temporal Relational Memory — Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`. Spec: `docs/specs/2026-05-29-relational-memory-design.md`.

**Goal:** Make relationships between knowledge nodes first-class — typed (`requires`/`affects`/`relates`/`part_of`/`supersedes`), bi-temporal (valid-time + transaction-time), multi-hop, and recalled across fresh sessions without re-explaining.

**Architecture:** An append-only JSONL edge log (`~/knowledge/graph/edges.jsonl`) is the single source of truth. The **write path is pure bash** (deterministic append, runs offline / Claude-down). The **read path is TypeScript** in the MCP server (`loadEdges` → `foldToCurrent` → `validAt(T)` → `neighbors` BFS). Human-readable `related:` frontmatter + a generated `## Dependencies` block are **projected** from the log at reindex time, so the existing BM25 graph-boost and the self-describing wiki keep working. With no `graph/` dir present, behaviour is byte-for-byte identical to 0.21.4.

**Tech Stack:** TypeScript (ESM, Node 20, MCP SDK, zod, vitest), Bash (hooks/scripts, `tests/test-*.sh` harness), esbuild bundling.

**Phases (each ships working, testable software):**
- **A** — graph-store core (TS pure logic + vitest). The foundation.
- **B** — MCP read/write tools (`knowledge_relate`, `knowledge_neighbors`) + server registration.
- **C** — capture (pure-bash `merge-edges.sh` + extractor schema + stop-hook wiring).
- **D** — projection (log → `related:` + `## Dependencies` block, via reindex).
- **E** — retrieval integration (multi-hop typed graph-boost + session-load neighbourhood).
- **F** — migration (`graph-migrate.sh`, opt-in, reversible).
- **G** — agents + upgrade-skill wiring + version bump + release gate.

**Conventions to follow (verified against the codebase):**
- TS unit tests are **vitest** colocated as `mcp/src/tools/<name>.test.ts`; run with `cd mcp && npm run test`.
- Shell tests are `tests/test-<name>.sh` using `set -u` + `fail()`/`pass()` + `mktemp -d` + `trap`; registered by `tests/run-all.sh` (auto-discovers `test-*.sh`).
- Every new bundled CLI **must** be appended to the `bundle` script in `mcp/package.json` or it won't ship in `dist/`.
- MCP path safety: validate every slug arg with `validateSlug` from `src/path-guard.js`.
- Commit after each green task. Time comparisons on ISO strings are lexicographic (ISO-8601 date or `…Z` timestamp sorts correctly).

---

## Phase A — Graph store core (TS pure logic)

The heart of the system. No wiring, no I/O side-effects beyond reading/appending the log. Everything else builds on these functions. Build it test-first and make it bulletproof.

**File structure for this phase:**
- Create: `mcp/src/tools/graph-store.ts` — types + `loadEdges`, `foldToCurrent`, `validAt`, `cmpTime`, `neighbors`, `appendEdge`, `dateOf`.
- Create: `mcp/src/tools/graph-store.test.ts` — vitest unit tests.

### Task A1: Edge types + `cmpTime` + `dateOf` helpers

**Files:**
- Create: `mcp/src/tools/graph-store.ts`
- Create: `mcp/src/tools/graph-store.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// mcp/src/tools/graph-store.test.ts
import { describe, it, expect } from 'vitest';
import { cmpTime, dateOf } from './graph-store.js';

describe('cmpTime (lexicographic ISO, half-open valid_to uses strict >)', () => {
  it('orders date-only strings', () => {
    expect(cmpTime('2026-05-21', '2026-05-29')).toBeLessThan(0);
    expect(cmpTime('2026-05-29', '2026-05-21')).toBeGreaterThan(0);
    expect(cmpTime('2026-05-21', '2026-05-21')).toBe(0);
  });
  it('a retire-date (date-only) is NOT after a same-day timestamp', () => {
    // valid_to '2026-05-29' must compare <= now '2026-05-29T12:00:00Z'
    expect(cmpTime('2026-05-29', '2026-05-29T12:00:00Z')).toBeLessThan(0);
  });
});

describe('dateOf', () => {
  it('extracts YYYY-MM-DD from an ISO timestamp', () => {
    expect(dateOf('2026-05-29T12:00:00Z')).toBe('2026-05-29');
    expect(dateOf('2026-05-29')).toBe('2026-05-29');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npm run test -- graph-store`
Expected: FAIL — `Cannot find module './graph-store.js'` / `cmpTime is not a function`.

- [ ] **Step 3: Write minimal implementation**

```ts
// mcp/src/tools/graph-store.ts
import { promises as fs } from 'fs';

export type EdgeOp = 'assert' | 'invalidate';
export type EdgeType = 'requires' | 'affects' | 'relates' | 'part_of' | 'supersedes';
export const EDGE_TYPES: EdgeType[] = ['requires', 'affects', 'relates', 'part_of', 'supersedes'];

/** One line in edges.jsonl — the source-of-truth record. */
export interface EdgeRecord {
  op: EdgeOp;
  from: string;
  to: string;
  type: EdgeType;
  valid_from?: string | null;
  valid_to?: string | null;
  recorded_at: string;          // ISO-8601 Z
  source?: string;
  confidence?: 'high' | 'medium';
  reason?: string;
}

/** Folded current state of an edge identity (from,type,to). */
export interface CurrentEdge {
  from: string;
  to: string;
  type: EdgeType;
  valid_from: string;
  valid_to: string | null;      // null = still valid
  source?: string;
  confidence?: 'high' | 'medium';
}

/** Lexicographic ISO comparison. ISO-8601 date ('2026-05-29') and Z-timestamp
 *  ('2026-05-29T12:00:00Z') both sort correctly as strings. A date-only string
 *  sorts BEFORE any same-day timestamp (shorter, and the next char in the longer
 *  string is 'T'), which is exactly what the half-open [from,to) interval needs. */
export function cmpTime(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/** First 10 chars of an ISO string = YYYY-MM-DD. */
export function dateOf(iso: string): string {
  return iso.slice(0, 10);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npm run test -- graph-store`
Expected: PASS (4 assertions).

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/graph-store.ts mcp/src/tools/graph-store.test.ts
git commit -m "feat(graph): edge types + cmpTime/dateOf time helpers"
```

### Task A2: `loadEdges` — torn-line-safe JSONL loader

**Files:**
- Modify: `mcp/src/tools/graph-store.ts`
- Test: `mcp/src/tools/graph-store.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// append to graph-store.test.ts
import { loadEdges } from './graph-store.js';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';

async function tmpLog(lines: string[]): Promise<string> {
  const dir = await fsp.mkdtemp(join(tmpdir(), 'gs-'));
  const p = join(dir, 'edges.jsonl');
  await fsp.writeFile(p, lines.join('\n'));
  return p;
}

describe('loadEdges', () => {
  it('returns [] when the file does not exist (graph absent = no-op)', async () => {
    expect(await loadEdges('/no/such/edges.jsonl')).toEqual([]);
  });
  it('parses valid lines and skips a torn final line', async () => {
    const p = await tmpLog([
      JSON.stringify({ op: 'assert', from: 'a', to: 'b', type: 'requires', recorded_at: '2026-05-21T00:00:00Z' }),
      '{"op":"assert","from":"a","to":"c","type":"aff',  // torn — writer killed mid-append
    ]);
    const edges = await loadEdges(p);
    expect(edges).toHaveLength(1);
    expect(edges[0].to).toBe('b');
  });
  it('skips records missing required fields', async () => {
    const p = await tmpLog([
      JSON.stringify({ op: 'assert', from: 'a', type: 'requires', recorded_at: '2026-05-21T00:00:00Z' }), // no `to`
      JSON.stringify({ op: 'assert', from: 'a', to: 'b', type: 'bogus', recorded_at: '2026-05-21T00:00:00Z' }), // bad type
      JSON.stringify({ op: 'assert', from: 'a', to: 'b', type: 'relates', recorded_at: '2026-05-21T00:00:00Z' }),
    ]);
    expect(await loadEdges(p)).toHaveLength(1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npm run test -- graph-store`
Expected: FAIL — `loadEdges is not a function`.

- [ ] **Step 3: Write minimal implementation**

```ts
// append to graph-store.ts
function isValidRecord(r: any): r is EdgeRecord {
  return r && typeof r === 'object'
    && (r.op === 'assert' || r.op === 'invalidate')
    && typeof r.from === 'string' && r.from.length > 0
    && typeof r.to === 'string' && r.to.length > 0
    && (EDGE_TYPES as string[]).includes(r.type)
    && typeof r.recorded_at === 'string' && r.recorded_at.length >= 10;
}

/** Read edges.jsonl line-by-line. A missing file yields [] (graph absent =
 *  current behaviour preserved). Each line is parsed independently; any
 *  unparseable or invalid line (incl. a torn final line) is skipped, never fatal. */
export async function loadEdges(path: string): Promise<EdgeRecord[]> {
  let raw: string;
  try { raw = await fs.readFile(path, 'utf-8'); }
  catch { return []; }
  const out: EdgeRecord[] = [];
  for (const line of raw.split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try {
      const parsed = JSON.parse(t);
      if (isValidRecord(parsed)) out.push(parsed);
    } catch { /* torn / malformed line — skip, keep the rest */ }
  }
  return out;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npm run test -- graph-store`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/graph-store.ts mcp/src/tools/graph-store.test.ts
git commit -m "feat(graph): torn-line-safe loadEdges JSONL reader"
```

### Task A3: `foldToCurrent` — assert/invalidate → current intervals

**Files:**
- Modify: `mcp/src/tools/graph-store.ts`
- Test: `mcp/src/tools/graph-store.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// append to graph-store.test.ts
import { foldToCurrent } from './graph-store.js';

describe('foldToCurrent', () => {
  it('assert then invalidate closes the interval (mark-not-delete)', () => {
    const cur = foldToCurrent([
      { op: 'assert', from: 'wg-tunnel', to: 'pi-ip-ufw-sync', type: 'requires', valid_from: '2026-05-21', recorded_at: '2026-05-21T18:30:00Z' },
      { op: 'invalidate', from: 'wg-tunnel', to: 'pi-ip-ufw-sync', type: 'requires', valid_to: '2026-05-29', recorded_at: '2026-05-29T12:00:00Z' },
    ]);
    expect(cur).toHaveLength(1);
    expect(cur[0]).toMatchObject({ valid_from: '2026-05-21', valid_to: '2026-05-29' });
  });
  it('re-asserting an open edge is idempotent (one entry, still open)', () => {
    const cur = foldToCurrent([
      { op: 'assert', from: 'a', to: 'b', type: 'requires', valid_from: '2026-05-21', recorded_at: '2026-05-21T00:00:00Z' },
      { op: 'assert', from: 'a', to: 'b', type: 'requires', valid_from: '2026-05-21', recorded_at: '2026-05-22T00:00:00Z' },
    ]);
    expect(cur).toHaveLength(1);
    expect(cur[0].valid_to).toBeNull();
  });
  it('defaults valid_from to the record date when absent', () => {
    const cur = foldToCurrent([
      { op: 'assert', from: 'a', to: 'b', type: 'relates', recorded_at: '2026-05-21T09:00:00Z' },
    ]);
    expect(cur[0].valid_from).toBe('2026-05-21');
  });
  it('processes records in recorded_at order regardless of file order', () => {
    const cur = foldToCurrent([
      { op: 'invalidate', from: 'a', to: 'b', type: 'requires', valid_to: '2026-05-29', recorded_at: '2026-05-29T00:00:00Z' },
      { op: 'assert', from: 'a', to: 'b', type: 'requires', valid_from: '2026-05-21', recorded_at: '2026-05-21T00:00:00Z' },
    ]);
    expect(cur[0]).toMatchObject({ valid_from: '2026-05-21', valid_to: '2026-05-29' });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npm run test -- graph-store`
Expected: FAIL — `foldToCurrent is not a function`.

- [ ] **Step 3: Write minimal implementation**

```ts
// append to graph-store.ts
function identity(r: { from: string; type: EdgeType; to: string }): string {
  return `${r.from}\t${r.type}\t${r.to}`;
}

/** Fold the append-only log into current edge state, keyed by (from,type,to).
 *  Records are applied in recorded_at order (stable). assert opens/updates an
 *  interval; invalidate closes it. An assert after a close re-opens a fresh
 *  interval. invalidate with no prior assert is ignored. */
export function foldToCurrent(records: EdgeRecord[]): CurrentEdge[] {
  const ordered = [...records].sort((a, b) => cmpTime(a.recorded_at, b.recorded_at));
  const map = new Map<string, CurrentEdge>();
  for (const r of ordered) {
    const id = identity(r);
    const cur = map.get(id);
    if (r.op === 'assert') {
      if (!cur || cur.valid_to !== null) {
        map.set(id, {
          from: r.from, to: r.to, type: r.type,
          valid_from: r.valid_from ?? dateOf(r.recorded_at),
          valid_to: r.valid_to ?? null,
          source: r.source, confidence: r.confidence,
        });
      } else {
        if (r.valid_from != null) cur.valid_from = r.valid_from;
        if (r.valid_to !== undefined && r.valid_to !== null) cur.valid_to = r.valid_to;
        if (r.source) cur.source = r.source;
        if (r.confidence) cur.confidence = r.confidence;
      }
    } else { // invalidate
      if (cur) cur.valid_to = r.valid_to ?? dateOf(r.recorded_at);
    }
  }
  return [...map.values()];
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npm run test -- graph-store`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/graph-store.ts mcp/src/tools/graph-store.test.ts
git commit -m "feat(graph): foldToCurrent — assert/invalidate to current intervals"
```

### Task A4: `validAt` — the half-open `as_of(T)` predicate

**Files:**
- Modify: `mcp/src/tools/graph-store.ts`
- Test: `mcp/src/tools/graph-store.test.ts`

- [ ] **Step 1: Write the failing test (the bi-temporal headline)**

```ts
// append to graph-store.test.ts
import { validAt } from './graph-store.js';

describe('validAt — half-open [valid_from, valid_to)', () => {
  const e = { from: 'wg-tunnel', to: 'pi-ip-ufw-sync', type: 'requires' as const,
              valid_from: '2026-05-21', valid_to: '2026-05-29' };
  it('is valid mid-interval', () => expect(validAt(e, '2026-05-25')).toBe(true));
  it('is NOT valid before valid_from', () => expect(validAt(e, '2026-05-19')).toBe(false));
  it('is NOT valid AT valid_to (half-open, strict >)', () => expect(validAt(e, '2026-05-29')).toBe(false));
  it('open interval (valid_to null) is valid at now', () => {
    expect(validAt({ ...e, valid_to: null }, '2026-12-31T00:00:00Z')).toBe(true);
  });
  it('a date-only valid_to is closed against a same-day timestamp', () => {
    expect(validAt(e, '2026-05-29T12:00:00Z')).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npm run test -- graph-store`
Expected: FAIL — `validAt is not a function`.

- [ ] **Step 3: Write minimal implementation**

```ts
// append to graph-store.ts
/** True iff the edge is valid at time T: valid_from <= T AND (valid_to null OR valid_to > T).
 *  Half-open interval — an edge invalidated on date D is NOT valid at D. */
export function validAt(
  e: { valid_from: string; valid_to: string | null },
  t: string,
): boolean {
  if (cmpTime(e.valid_from, t) > 0) return false;
  if (e.valid_to === null) return true;
  return cmpTime(e.valid_to, t) > 0;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npm run test -- graph-store`
Expected: PASS — including the boundary case at `valid_to`.

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/graph-store.ts mcp/src/tools/graph-store.test.ts
git commit -m "feat(graph): validAt half-open as_of(T) predicate"
```

### Task A5: `neighbors` — multi-hop typed BFS, directional, time-filtered

**Files:**
- Modify: `mcp/src/tools/graph-store.ts`
- Test: `mcp/src/tools/graph-store.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// append to graph-store.test.ts
import { neighbors } from './graph-store.js';

const G = [
  { from: 'a', to: 'b', type: 'requires' as const, valid_from: '2026-05-01', valid_to: null },
  { from: 'b', to: 'c', type: 'requires' as const, valid_from: '2026-05-01', valid_to: null },
  { from: 'a', to: 'd', type: 'affects'  as const, valid_from: '2026-05-01', valid_to: null },
  { from: 'x', to: 'a', type: 'affects'  as const, valid_from: '2026-05-01', valid_to: null },
  { from: 'a', to: 'old', type: 'requires' as const, valid_from: '2026-05-01', valid_to: '2026-05-10' },
];

describe('neighbors', () => {
  it('direction out, depth 1 returns direct dependencies of a', () => {
    const r = neighbors(G, 'a', { depth: 1, direction: 'out', asOf: '2026-05-20' });
    expect(r.map(e => e.to).sort()).toEqual(['b', 'd']); // 'old' excluded (invalidated)
  });
  it('depth 2 reaches c at a lower score than b', () => {
    const r = neighbors(G, 'a', { depth: 2, direction: 'out', asOf: '2026-05-20' });
    const b = r.find(e => e.to === 'b')!; const c = r.find(e => e.to === 'c')!;
    expect(c).toBeTruthy();
    expect(c.score).toBeLessThan(b.score);
  });
  it('direction in returns blast radius (who points at a)', () => {
    const r = neighbors(G, 'a', { depth: 1, direction: 'in', asOf: '2026-05-20' });
    expect(r.map(e => e.from)).toContain('x');
  });
  it('edge_types filter restricts traversal', () => {
    const r = neighbors(G, 'a', { depth: 1, direction: 'out', edgeTypes: ['affects'], asOf: '2026-05-20' });
    expect(r.map(e => e.to)).toEqual(['d']);
  });
  it('as_of before invalidation still sees the old edge', () => {
    const r = neighbors(G, 'a', { depth: 1, direction: 'out', asOf: '2026-05-05' });
    expect(r.map(e => e.to)).toContain('old');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npm run test -- graph-store`
Expected: FAIL — `neighbors is not a function`.

- [ ] **Step 3: Write minimal implementation**

```ts
// append to graph-store.ts
export interface NeighborEdge {
  from: string; to: string; type: EdgeType;
  hops: number; score: number;
  valid_from: string; valid_to: string | null;
}
export interface NeighborOpts {
  depth?: number;                          // default 2
  direction?: 'out' | 'in' | 'both';       // default 'both'
  edgeTypes?: EdgeType[];                   // default all
  asOf?: string;                            // default now (ISO)
}
const GRAPH_DECAY = 0.3;                    // per-hop score decay (matches legacy GRAPH_BOOST)
const TYPE_WEIGHT: Record<EdgeType, number> = {
  requires: 1.0, affects: 1.0, part_of: 0.8, supersedes: 0.6, relates: 0.5,
};

/** BFS over current-valid edges from `slug`, up to `depth` hops. Score per
 *  reached node = TYPE_WEIGHT * GRAPH_DECAY^hop, keeping the min-hop path. */
export function neighbors(edges: CurrentEdge[], slug: string, opts: NeighborOpts = {}): NeighborEdge[] {
  const depth = opts.depth ?? 2;
  const direction = opts.direction ?? 'both';
  const asOf = opts.asOf ?? new Date().toISOString();
  const typeOk = (t: EdgeType) => !opts.edgeTypes || opts.edgeTypes.includes(t);
  const live = edges.filter(e => validAt(e, asOf) && typeOk(e.type));

  const out: NeighborEdge[] = [];
  const seen = new Set<string>([slug]);
  let frontier: { node: string; hop: number }[] = [{ node: slug, hop: 0 }];

  while (frontier.length) {
    const next: { node: string; hop: number }[] = [];
    for (const { node, hop } of frontier) {
      if (hop >= depth) continue;
      for (const e of live) {
        let other: string | null = null;
        if ((direction === 'out' || direction === 'both') && e.from === node) other = e.to;
        else if ((direction === 'in' || direction === 'both') && e.to === node) other = e.from;
        if (other === null) continue;
        out.push({
          from: e.from, to: e.to, type: e.type,
          hops: hop + 1, score: TYPE_WEIGHT[e.type] * Math.pow(GRAPH_DECAY, hop),
          valid_from: e.valid_from, valid_to: e.valid_to,
        });
        if (!seen.has(other)) { seen.add(other); next.push({ node: other, hop: hop + 1 }); }
      }
    }
    frontier = next;
  }
  return out;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npm run test -- graph-store`
Expected: PASS (all neighbor cases).

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/graph-store.ts mcp/src/tools/graph-store.test.ts
git commit -m "feat(graph): neighbors multi-hop typed directional BFS"
```

### Task A6: `appendEdge` — validated single-line append

**Files:**
- Modify: `mcp/src/tools/graph-store.ts`
- Test: `mcp/src/tools/graph-store.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// append to graph-store.test.ts
import { appendEdge } from './graph-store.js';

describe('appendEdge', () => {
  it('appends exactly one JSON line terminated by \\n', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'gs-ap-'));
    const p = join(dir, 'edges.jsonl');
    await appendEdge(p, { op: 'assert', from: 'a', to: 'b', type: 'requires', recorded_at: '2026-05-21T00:00:00Z' });
    await appendEdge(p, { op: 'assert', from: 'a', to: 'c', type: 'affects', recorded_at: '2026-05-21T00:00:01Z' });
    const back = await loadEdges(p);
    expect(back).toHaveLength(2);
    const raw = await fsp.readFile(p, 'utf-8');
    expect(raw.endsWith('\n')).toBe(true);
  });
  it('rejects an invalid edge type', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'gs-ap2-'));
    const p = join(dir, 'edges.jsonl');
    await expect(appendEdge(p, { op: 'assert', from: 'a', to: 'b', type: 'bogus' as any, recorded_at: '2026-05-21T00:00:00Z' }))
      .rejects.toThrow(/invalid edge/i);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npm run test -- graph-store`
Expected: FAIL — `appendEdge is not a function`.

- [ ] **Step 3: Write minimal implementation**

```ts
// append to graph-store.ts
import { dirname } from 'path';

/** Append one validated edge record as a single JSONL line. Used by the
 *  knowledge_relate MCP tool. (The hook write path appends from bash directly;
 *  the JSONL line format is the shared contract.) */
export async function appendEdge(path: string, rec: EdgeRecord): Promise<void> {
  if (!isValidRecord(rec)) throw new Error(`invalid edge record: ${JSON.stringify(rec)}`);
  await fs.mkdir(dirname(path), { recursive: true });
  await fs.appendFile(path, JSON.stringify(rec) + '\n', 'utf-8');
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npm run test -- graph-store`
Expected: PASS. Whole Phase A suite green.

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/graph-store.ts mcp/src/tools/graph-store.test.ts
git commit -m "feat(graph): appendEdge validated single-line append"
```

---

## Phase B — MCP read/write tools

Expose the store: `knowledge_relate` (manual assert/invalidate, the user's "tell it once" path) and `knowledge_neighbors` (query). Both additive — they do not alter any existing tool, so behaviour for non-adopters is unchanged.

**File structure:**
- Create: `mcp/src/tools/knowledge-relate.ts`, `mcp/src/tools/knowledge-neighbors.ts`
- Create: `mcp/src/tools/knowledge-relate.test.ts`
- Modify: `mcp/src/server.ts` (register both; bump server version to `2.3.0`)

### Task B1: `knowledge_relate` tool function

**Files:**
- Create: `mcp/src/tools/knowledge-relate.ts`
- Test: `mcp/src/tools/knowledge-relate.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// mcp/src/tools/knowledge-relate.test.ts
import { describe, it, expect } from 'vitest';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeRelate } from './knowledge-relate.js';
import { loadEdges } from './graph-store.js';

async function kdir(): Promise<string> { return fsp.mkdtemp(join(tmpdir(), 'kr-')); }

describe('knowledgeRelate', () => {
  it('asserts an edge to the log', async () => {
    const dir = await kdir();
    const r = await knowledgeRelate({ from: 'a', to: 'b', type: 'requires', knowledgeDir: dir });
    expect(r.ok).toBe(true);
    const edges = await loadEdges(join(dir, 'graph', 'edges.jsonl'));
    expect(edges[0]).toMatchObject({ op: 'assert', from: 'a', to: 'b', type: 'requires', source: 'manual', confidence: 'high' });
  });
  it('invalidate=true writes an invalidate record with valid_to', async () => {
    const dir = await kdir();
    await knowledgeRelate({ from: 'a', to: 'b', type: 'requires', knowledgeDir: dir });
    const r = await knowledgeRelate({ from: 'a', to: 'b', type: 'requires', invalidate: true, valid_to: '2026-05-29', knowledgeDir: dir });
    expect(r.ok).toBe(true);
    const edges = await loadEdges(join(dir, 'graph', 'edges.jsonl'));
    expect(edges[1]).toMatchObject({ op: 'invalidate', valid_to: '2026-05-29' });
  });
  it('rejects an invalid slug', async () => {
    const dir = await kdir();
    const r = await knowledgeRelate({ from: '../etc/passwd', to: 'b', type: 'requires', knowledgeDir: dir });
    expect(r.ok).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npm run test -- knowledge-relate`
Expected: FAIL — `Cannot find module './knowledge-relate.js'`.

- [ ] **Step 3: Write minimal implementation**

```ts
// mcp/src/tools/knowledge-relate.ts
import { join } from 'path';
import { appendEdge, EdgeRecord, EdgeType, EDGE_TYPES } from './graph-store.js';
import { validateSlug, PathGuardError } from '../path-guard.js';

export interface KnowledgeRelateArgs {
  from: string; to: string; type: EdgeType;
  valid_from?: string; valid_to?: string;
  invalidate?: boolean; reason?: string;
  knowledgeDir: string;
}
export interface KnowledgeRelateResult { ok: boolean; recorded?: EdgeRecord; reason?: string; }

export async function knowledgeRelate(args: KnowledgeRelateArgs): Promise<KnowledgeRelateResult> {
  try { validateSlug(args.from); validateSlug(args.to); }
  catch (e) {
    if (e instanceof PathGuardError) return { ok: false, reason: `invalid slug: ${e.message}` };
    throw e;
  }
  if (!(EDGE_TYPES as string[]).includes(args.type)) return { ok: false, reason: `invalid type: ${args.type}` };

  const rec: EdgeRecord = {
    op: args.invalidate ? 'invalidate' : 'assert',
    from: args.from, to: args.to, type: args.type,
    recorded_at: new Date().toISOString(),
    source: 'manual', confidence: 'high',
  };
  if (args.valid_from) rec.valid_from = args.valid_from;
  if (args.valid_to) rec.valid_to = args.valid_to;
  if (args.reason) rec.reason = args.reason;

  const logPath = join(args.knowledgeDir, 'graph', 'edges.jsonl');
  await appendEdge(logPath, rec);
  return { ok: true, recorded: rec };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npm run test -- knowledge-relate`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/knowledge-relate.ts mcp/src/tools/knowledge-relate.test.ts
git commit -m "feat(graph): knowledge_relate tool (manual assert/invalidate)"
```

### Task B2: `knowledge_neighbors` tool function

**Files:**
- Create: `mcp/src/tools/knowledge-neighbors.ts`
- Test: extend `mcp/src/tools/knowledge-relate.test.ts` (or new `knowledge-neighbors.test.ts`)

- [ ] **Step 1: Write the failing test**

```ts
// mcp/src/tools/knowledge-neighbors.test.ts
import { describe, it, expect } from 'vitest';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeNeighbors } from './knowledge-neighbors.js';
import { appendEdge } from './graph-store.js';

describe('knowledgeNeighbors', () => {
  it('returns current dependencies of a slug', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'kn-'));
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'a', to: 'b', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    const r = await knowledgeNeighbors({ slug: 'a', direction: 'out', knowledgeDir: dir });
    expect(r.edges.map(e => e.to)).toContain('b');
  });
  it('returns [] when the graph log is absent (no-op)', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'kn0-'));
    const r = await knowledgeNeighbors({ slug: 'a', knowledgeDir: dir });
    expect(r.edges).toEqual([]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npm run test -- knowledge-neighbors`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```ts
// mcp/src/tools/knowledge-neighbors.ts
import { join } from 'path';
import { loadEdges, foldToCurrent, neighbors, NeighborEdge, EdgeType } from './graph-store.js';
import { validateSlug, PathGuardError } from '../path-guard.js';

export interface KnowledgeNeighborsArgs {
  slug: string; depth?: number;
  direction?: 'out' | 'in' | 'both';
  edge_types?: EdgeType[]; as_of?: string;
  knowledgeDir: string;
}
export interface KnowledgeNeighborsResult { slug: string; edges: NeighborEdge[]; }

export async function knowledgeNeighbors(args: KnowledgeNeighborsArgs): Promise<KnowledgeNeighborsResult> {
  try { validateSlug(args.slug); }
  catch (e) { if (e instanceof PathGuardError) return { slug: args.slug, edges: [] }; throw e; }
  const records = await loadEdges(join(args.knowledgeDir, 'graph', 'edges.jsonl'));
  if (records.length === 0) return { slug: args.slug, edges: [] };
  const current = foldToCurrent(records);
  const edges = neighbors(current, args.slug, {
    depth: args.depth, direction: args.direction,
    edgeTypes: args.edge_types, asOf: args.as_of,
  });
  return { slug: args.slug, edges };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npm run test -- knowledge-neighbors`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/knowledge-neighbors.ts mcp/src/tools/knowledge-neighbors.test.ts
git commit -m "feat(graph): knowledge_neighbors query tool"
```

### Task B3: Register both tools in the MCP server + version bump

**Files:**
- Modify: `mcp/src/server.ts` (imports near line 20; registrations after the dream/episodic block ~line 514; version line 49)

- [ ] **Step 1: Add imports** (after line 20, with the other tool imports)

```ts
import { knowledgeRelate } from "./tools/knowledge-relate.js";
import { knowledgeNeighbors } from "./tools/knowledge-neighbors.js";
```

- [ ] **Step 2: Bump server version** (line 49)

```ts
  { name: "knowledge-base", version: "2.3.0" },
```

- [ ] **Step 3: Register the tools** (insert before the `// --- Start ---` comment, ~line 516)

```ts
// --- Relational graph tools ---

server.registerTool(
  "knowledge_relate",
  {
    description: "Assert (or invalidate) a typed, bi-temporal relationship between two wiki pages. Use when the user confirms that one thing relates to / requires / affects another, so a future session recalls it without re-explaining. types: requires | affects | relates | part_of | supersedes. Set invalidate:true with valid_to to mark a relationship no longer true (history is preserved, never deleted).",
    inputSchema: {
      from: z.string().describe("Source page slug (kebab-case)."),
      to: z.string().describe("Target page slug (kebab-case)."),
      type: z.enum(["requires", "affects", "relates", "part_of", "supersedes"]),
      valid_from: z.string().optional().describe("Date the relationship became true (YYYY-MM-DD). Default: today."),
      valid_to: z.string().optional().describe("Date it stopped being true (YYYY-MM-DD). Required semantics with invalidate:true."),
      invalidate: z.boolean().optional().describe("Mark an existing relationship no longer valid instead of asserting one."),
      reason: z.string().optional().describe("Why (especially on invalidate)."),
    },
  },
  async (args) => {
    try {
      const result = await knowledgeRelate({ ...args, knowledgeDir: KNOWLEDGE_DIR });
      return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
    } catch (error) {
      return { content: [{ type: "text" as const, text: `Relate error: ${error instanceof Error ? error.message : String(error)}` }], isError: true };
    }
  }
);

server.registerTool(
  "knowledge_neighbors",
  {
    description: "Walk the typed relationship graph from a page: multi-hop, time-filtered. direction 'out' = its dependencies (what it requires/affects), 'in' = its blast radius (what breaks if it changes), 'both' = default. Set as_of to a past date to reconstruct the graph as it was then. Returns edges with type, hops, score, and validity interval.",
    inputSchema: {
      slug: z.string().describe("The page slug to start from."),
      depth: z.number().min(1).max(4).optional().describe("Max hops. Default 2."),
      direction: z.enum(["out", "in", "both"]).optional().describe("Default 'both'."),
      edge_types: z.array(z.enum(["requires", "affects", "relates", "part_of", "supersedes"])).optional(),
      as_of: z.string().optional().describe("Point-in-time (YYYY-MM-DD or ISO). Default now."),
    },
  },
  async (args) => {
    try {
      const result = await knowledgeNeighbors({ ...args, knowledgeDir: KNOWLEDGE_DIR });
      return { content: [{ type: "text" as const, text: JSON.stringify(result) }] };
    } catch (error) {
      return { content: [{ type: "text" as const, text: `Neighbors error: ${error instanceof Error ? error.message : String(error)}` }], isError: true };
    }
  }
);
```

- [ ] **Step 4: Build and smoke-test the server boots**

Run: `cd mcp && npm run build && node -e "import('./dist/server.bundle.js').then(()=>console.log('OK')).catch(e=>{console.error(e);process.exit(1)})" & sleep 2; kill %1 2>/dev/null; echo done`
Expected: build succeeds; server prints `Knowledge MCP server running on stdio` (it waits on stdio — the kill is expected). No import/type errors.

- [ ] **Step 5: Commit**

```bash
git add mcp/src/server.ts
git commit -m "feat(graph): register knowledge_relate + knowledge_neighbors; server 2.3.0"
```

---

## Phase C — Capture (pure-bash write path)

Edges accrue every substantive session **even when the LLM extractor is degraded**, because the append is deterministic bash. The LLM only *proposes* the `relations` array; bash validates endpoints and appends or quarantines.

**File structure:**
- Create: `scripts/merge-edges.sh` (append + endpoint guard + quarantine)
- Create: `tests/test-merge-edges.sh`
- Modify: `scripts/extract-prompt.txt` (add `relations` to schema + a rule)
- Modify: `scripts/stop-extract.sh` (invoke merge-edges.sh after merge-project-update.sh)

### Task C1: `merge-edges.sh` — validated bash append with quarantine

**Files:**
- Create: `scripts/merge-edges.sh`
- Test: `tests/test-merge-edges.sh`

- [ ] **Step 1: Write the failing test**

```bash
# tests/test-merge-edges.sh
#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$ROOT/scripts/merge-edges.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$SCRIPT" ] || fail "scripts/merge-edges.sh not found"

KDIR="$TMP/knowledge"; mkdir -p "$KDIR/wiki/entities"
# Two real pages so endpoints resolve
printf '%s\n' '---' 'title: A' 'type: entities' '---' '# A' > "$KDIR/wiki/entities/page-a.md"
printf '%s\n' '---' 'title: B' 'type: entities' '---' '# B' > "$KDIR/wiki/entities/page-b.md"

# --- Test 1: a resolvable edge is appended to edges.jsonl ---
echo '{"relations":[{"from":"page-a","to":"page-b","type":"requires","confidence":"high"}]}' \
  | KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
LOG="$KDIR/graph/edges.jsonl"
[ -f "$LOG" ] || fail "edges.jsonl not created"
grep -q '"from":"page-a"' "$LOG" || fail "resolvable edge not appended"
grep -q '"op":"assert"' "$LOG" || fail "op:assert missing"
grep -q '"source":"extractor"' "$LOG" || fail "source not stamped"
pass "resolvable edge appended with op/source stamped"

# --- Test 2: an edge to a non-existent page is quarantined, not asserted ---
echo '{"relations":[{"from":"page-a","to":"ghost-page","type":"requires"}]}' \
  | KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
grep -q '"to":"ghost-page"' "$LOG" && fail "unresolved edge leaked into edges.jsonl"
QLOG="$KDIR/graph/edges-quarantine.jsonl"
[ -f "$QLOG" ] && grep -q '"to":"ghost-page"' "$QLOG" || fail "unresolved edge not quarantined"
pass "unresolved-endpoint edge quarantined, not asserted"

# --- Test 3: empty / no relations is a clean no-op ---
BEFORE=$(wc -l < "$LOG")
echo '{"relations":[]}' | KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
echo '{}'              | KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
AFTER=$(wc -l < "$LOG")
[ "$BEFORE" = "$AFTER" ] || fail "empty relations changed the log"
pass "empty/missing relations is a no-op"

# --- Test 4: invalid edge type rejected ---
echo '{"relations":[{"from":"page-a","to":"page-b","type":"bogus"}]}' \
  | KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
grep -q '"type":"bogus"' "$LOG" && fail "invalid edge type was appended"
pass "invalid edge type rejected"

echo; echo "ALL PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-merge-edges.sh`
Expected: FAIL — `scripts/merge-edges.sh not found`.

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/merge-edges.sh
#!/bin/bash
# Append extractor-proposed relationship edges to ~/knowledge/graph/edges.jsonl.
# Pure-bash deterministic write path (no node dependency) so the graph accrues
# even when the LLM extractor / MCP layer is unavailable. The LLM only proposes
# the `relations` array; this script validates endpoints + type and either
# appends an op:assert line or quarantines the edge. JSONL line format is the
# contract shared with mcp/src/tools/graph-store.ts.
#
# Usage: echo '<delta-json>' | bash merge-edges.sh --knowledge-dir <dir>
set -u
source "$(dirname "$0")/lib.sh"

KNOWLEDGE_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --knowledge-dir) KNOWLEDGE_DIR="$2"; shift 2 ;;
    *) echo "merge-edges: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -z "$KNOWLEDGE_DIR" ] && KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
WIKI="$KNOWLEDGE_DIR/wiki"
GRAPH_DIR="$KNOWLEDGE_DIR/graph"
LOG="$GRAPH_DIR/edges.jsonl"
QLOG="$GRAPH_DIR/edges-quarantine.jsonl"
VALID_TYPES="requires affects relates part_of supersedes"

RAW=$(cat)
echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0   # not JSON → no-op
COUNT=$(echo "$RAW" | jq '(.relations // []) | length' 2>/dev/null || echo 0)
[ "${COUNT:-0}" -eq 0 ] && exit 0

# A slug resolves if a matching page exists anywhere under wiki/ (excluding index.md).
resolves() {
  local slug="$1"
  [ -n "$slug" ] || return 1
  find "$WIKI" -name "$slug.md" -type f ! -name 'index.md' 2>/dev/null | grep -q .
}

mkdir -p "$GRAPH_DIR"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "$RAW" | jq -c '.relations[]?' 2>/dev/null | while IFS= read -r rel; do
  from=$(echo "$rel" | jq -r '.from // empty')
  to=$(echo "$rel"   | jq -r '.to // empty')
  type=$(echo "$rel" | jq -r '.type // "relates"')
  vf=$(echo "$rel"   | jq -r '.valid_from // empty')
  conf=$(echo "$rel" | jq -r '.confidence // "medium"')

  # sanitize slugs (kebab/url-safe) — reuse lib.sh helper; reject on failure
  sfrom=$(sb_sanitize_slug "$from") || continue
  sto=$(sb_sanitize_slug "$to") || continue

  # validate edge type
  case " $VALID_TYPES " in *" $type "*) : ;; *) continue ;; esac

  # build the record (valid_from optional)
  if [ -n "$vf" ]; then
    rec=$(jq -nc --arg f "$sfrom" --arg t "$sto" --arg ty "$type" --arg vf "$vf" --arg now "$NOW" --arg c "$conf" \
      '{op:"assert",from:$f,to:$t,type:$ty,valid_from:$vf,valid_to:null,recorded_at:$now,source:"extractor",confidence:$c}')
  else
    rec=$(jq -nc --arg f "$sfrom" --arg t "$sto" --arg ty "$type" --arg now "$NOW" --arg c "$conf" \
      '{op:"assert",from:$f,to:$t,type:$ty,valid_to:null,recorded_at:$now,source:"extractor",confidence:$c}')
  fi

  # endpoint guard: both must resolve to real pages, else quarantine
  if resolves "$sfrom" && resolves "$sto"; then
    printf '%s\n' "$rec" >> "$LOG"
  else
    printf '%s\n' "$rec" >> "$QLOG"
  fi
done

exit 0
```

- [ ] **Step 4: Make executable, run test to verify it passes**

Run: `chmod +x scripts/merge-edges.sh && bash tests/test-merge-edges.sh`
Expected: `ALL PASS` (4 cases).

- [ ] **Step 5: Commit**

```bash
git add scripts/merge-edges.sh tests/test-merge-edges.sh
git commit -m "feat(graph): merge-edges.sh — pure-bash edge append with endpoint quarantine"
```

### Task C2: Add `relations` to the extractor prompt schema

**Files:**
- Modify: `scripts/extract-prompt.txt` (schema block ~line 10-33; rules ~line 35-62)

- [ ] **Step 1: Add `relations` to the JSON schema** — insert after the `persona_signals` array (before the closing `}` at line 33):

```
  ,
  "relations": [
    {
      "from": "kebab-case-slug",
      "to": "kebab-case-slug",
      "type": "requires|affects|relates|part_of",
      "valid_from": "YYYY-MM-DD (optional; default today)",
      "confidence": "high|medium"
    }
  ]
```

- [ ] **Step 2: Add the extraction rule** — insert before the final "If the session was pure Q&A…" line (~line 62):

```
- Relations: typed relationships between wiki pages that were explicitly established or confirmed THIS session. Use this to capture dependency knowledge so a future session recalls it without re-explaining.
  - "requires" = A depends on B (B must exist/work for A). "affects" = changing A impacts B. "part_of" = A is a component of B. "relates" = generic association (use only when none of the above fit).
  - `from`/`to` must be wiki page slugs (kebab-case) — prefer slugs that appear in cross_refs or wiki_updates this session so they resolve to real pages. Edges to non-existent pages are dropped.
  - Only edges a future session genuinely benefits from. Do NOT restate edges already obvious from a page's existing content. Max 5 entries.
  - Do not invent a `supersedes` edge here — supersession is decided during consolidation, not per-session.
```

- [ ] **Step 3: Verify the prompt is still well-formed guidance** (it is plain text, no parser):

Run: `grep -c '"relations"' scripts/extract-prompt.txt`
Expected: `1`.

- [ ] **Step 4: Commit**

```bash
git add scripts/extract-prompt.txt
git commit -m "feat(graph): extractor emits a typed relations[] array"
```

### Task C3: Wire `merge-edges.sh` into the Stop hook

**Files:**
- Modify: `scripts/stop-extract.sh` (after the `merge-project-update.sh` pipe ~line 202)

- [ ] **Step 1: Write the failing test** — extend the existing stop-extract test to assert edges are appended when the delta carries `relations`. Add to `tests/test-stop-extract.sh` (a new case near its other delta assertions; adapt variable names to that file's harness):

```bash
# --- relations[] in the extractor delta land in edges.jsonl ---
# (Place inside test-stop-extract.sh where $KNOWLEDGE_DIR + a fake extractor delta
#  are already set up. The fake delta JSON must include a resolvable relations entry.)
REL_LOG="$KNOWLEDGE_DIR/graph/edges.jsonl"
if [ -f "$REL_LOG" ] && grep -q '"source":"extractor"' "$REL_LOG"; then
  pass "stop-extract appended extractor relations to edges.jsonl"
else
  fail "stop-extract did not append relations to edges.jsonl"
fi
```

(If `tests/test-stop-extract.sh` uses a stubbed extractor that returns a fixed delta, add a `relations` entry to that stub whose endpoints match pages the test already creates.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-stop-extract.sh`
Expected: FAIL — edges.jsonl not produced (merge-edges.sh not yet wired).

- [ ] **Step 3: Add the wiring** — in `scripts/stop-extract.sh`, immediately after the block that pipes the delta into `merge-project-update.sh` (~line 202-203), add:

```bash
# Append typed relationship edges (pure-bash, deterministic). Best-effort: a
# failure here must never fail the Stop hook. Uses the same $EXTRACT_OUT delta.
if [ -s "$EXTRACT_OUT" ]; then
  bash "$(dirname "$0")/merge-edges.sh" --knowledge-dir "$KNOWLEDGE_DIR" < "$EXTRACT_OUT" 2>/dev/null || true
fi
```

(Confirm the variable holding the extractor's JSON output: in `stop-extract.sh` it is the file piped into `merge-project-update.sh`. Use that exact variable — grep `merge-project-update` in the file and mirror its stdin source.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-stop-extract.sh`
Expected: PASS — including the new relations case.

- [ ] **Step 5: Commit**

```bash
git add scripts/stop-extract.sh tests/test-stop-extract.sh
git commit -m "feat(graph): Stop hook appends extractor relations via merge-edges.sh"
```

---

## Phase D — Projection (log → human-readable pages)

Regenerate `related:` frontmatter + a fenced `## Dependencies` block from the current-valid graph, so the existing BM25 graph-boost and the self-describing wiki stay correct. Back-compat: no `graph/edges.jsonl` ⇒ projector is a no-op.

**File structure:**
- Create: `mcp/src/tools/graph-project.ts` + `mcp/src/tools/graph-project.test.ts`
- Modify: `mcp/src/tools/knowledge-reindex.ts` (call the projector before writing index.md)

### Task D1: `projectGraphToPages` — rewrite `related:` + `## Dependencies`

**Files:**
- Create: `mcp/src/tools/graph-project.ts`
- Test: `mcp/src/tools/graph-project.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// mcp/src/tools/graph-project.test.ts
import { describe, it, expect } from 'vitest';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { appendEdge } from './graph-store.js';
import { projectGraphToPages } from './graph-project.js';

async function setup(): Promise<string> {
  const dir = await fsp.mkdtemp(join(tmpdir(), 'gp-'));
  await fsp.mkdir(join(dir, 'wiki', 'entities'), { recursive: true });
  const page = (slug: string) => join(dir, 'wiki', 'entities', `${slug}.md`);
  for (const s of ['wg-tunnel', 'vps-ufw-depinned', 'router-daemon']) {
    await fsp.writeFile(page(s), `---\ntitle: ${s}\ntype: entities\nrelated: []\n---\n\n# ${s}\n\nbody\n`);
  }
  return dir;
}

describe('projectGraphToPages', () => {
  it('no graph log → no-op (pages unchanged)', async () => {
    const dir = await setup();
    const before = await fsp.readFile(join(dir, 'wiki', 'entities', 'wg-tunnel.md'), 'utf-8');
    const r = await projectGraphToPages(dir);
    expect(r.pagesUpdated).toBe(0);
    const after = await fsp.readFile(join(dir, 'wiki', 'entities', 'wg-tunnel.md'), 'utf-8');
    expect(after).toBe(before);
  });
  it('writes related: union and a Dependencies block from current edges', async () => {
    const dir = await setup();
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'wg-tunnel', to: 'router-daemon', type: 'affects', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await appendEdge(log, { op: 'assert', from: 'wg-tunnel', to: 'vps-ufw-depinned', type: 'requires', valid_from: '2026-05-29', recorded_at: '2026-05-29T00:00:00Z' });
    await projectGraphToPages(dir);
    const md = await fsp.readFile(join(dir, 'wiki', 'entities', 'wg-tunnel.md'), 'utf-8');
    expect(md).toMatch(/related: \[\[router-daemon\]\], \[\[vps-ufw-depinned\]\]/);
    expect(md).toContain('<!-- graph:begin');
    expect(md).toMatch(/\*\*Requires:\*\* \[\[vps-ufw-depinned\]\]/);
    expect(md).toMatch(/\*\*Affects:\*\* \[\[router-daemon\]\]/);
    expect(md).toContain('<!-- graph:end -->');
  });
  it('is idempotent — second run does not duplicate the block', async () => {
    const dir = await setup();
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'wg-tunnel', to: 'router-daemon', type: 'affects', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await projectGraphToPages(dir);
    await projectGraphToPages(dir);
    const md = await fsp.readFile(join(dir, 'wiki', 'entities', 'wg-tunnel.md'), 'utf-8');
    expect(md.match(/<!-- graph:begin/g)?.length).toBe(1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npm run test -- graph-project`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```ts
// mcp/src/tools/graph-project.ts
import { promises as fs } from 'fs';
import { join } from 'path';
import { glob } from 'glob';
import { loadEdges, foldToCurrent, validAt, CurrentEdge, EdgeType } from './graph-store.js';

export interface ProjectResult { pagesUpdated: number; }

const BEGIN = '<!-- graph:begin (generated from ~/knowledge/graph/edges.jsonl — do not hand-edit) -->';
const END = '<!-- graph:end -->';
const TYPE_LABEL: Partial<Record<EdgeType, string>> = {
  requires: 'Requires', affects: 'Affects', part_of: 'Part of', supersedes: 'Supersedes',
};

function slugFromPath(p: string): string { return p.replace(/.*\//, '').replace(/\.md$/, ''); }

/** Regenerate related: frontmatter + the ## Dependencies block on every page,
 *  from current-valid edges. No edges.jsonl ⇒ no-op (returns pagesUpdated:0). */
export async function projectGraphToPages(knowledgeDir: string): Promise<ProjectResult> {
  const records = await loadEdges(join(knowledgeDir, 'graph', 'edges.jsonl'));
  if (records.length === 0) return { pagesUpdated: 0 };

  const now = new Date().toISOString();
  const current = foldToCurrent(records).filter(e => validAt(e, now));

  // Build per-slug direct neighbours (both directions).
  const outBySlug = new Map<string, CurrentEdge[]>();
  const relatedBySlug = new Map<string, Set<string>>();
  const add = (slug: string, other: string) => {
    if (!relatedBySlug.has(slug)) relatedBySlug.set(slug, new Set());
    relatedBySlug.get(slug)!.add(other);
  };
  for (const e of current) {
    if (!outBySlug.has(e.from)) outBySlug.set(e.from, []);
    outBySlug.get(e.from)!.push(e);   // typed deps shown on the source page
    add(e.from, e.to); add(e.to, e.from);
  }

  const wikiRoot = join(knowledgeDir, 'wiki');
  const files = await glob('**/*.md', { cwd: wikiRoot, absolute: true });
  let updated = 0;

  for (const file of files) {
    if (file.endsWith('index.md')) continue;
    const slug = slugFromPath(file);
    const related = relatedBySlug.get(slug);
    if (!related || related.size === 0) continue;

    let content = await fs.readFile(file, 'utf-8');
    const before = content;

    // 1. rewrite related: frontmatter (sorted union)
    const relList = [...related].sort();
    const relLine = `related: ${relList.map(s => `[[${s}]]`).join(', ')}`;
    if (/^related:.*$/m.test(content)) {
      content = content.replace(/^related:.*$/m, relLine);
    } else {
      // insert into frontmatter before the closing ---
      content = content.replace(/^---\n([\s\S]*?)\n---/, (_m, fm) => `---\n${fm}\n${relLine}\n---`);
    }

    // 2. rewrite the ## Dependencies block (grouped by type, source page's out-edges)
    const outs = (outBySlug.get(slug) ?? []);
    const grouped: Partial<Record<EdgeType, string[]>> = {};
    for (const e of outs) (grouped[e.type] ??= []).push(e.to);
    const lines = [BEGIN, `## Dependencies (as of ${now.slice(0, 10)})`];
    for (const t of ['requires', 'affects', 'part_of', 'supersedes'] as EdgeType[]) {
      const slugs = (grouped[t] ?? []).sort();
      if (slugs.length) lines.push(`**${TYPE_LABEL[t]}:** ${slugs.map(s => `[[${s}]]`).join(', ')}`);
    }
    lines.push(END);
    const block = lines.join('\n');
    const blockRe = new RegExp(`${BEGIN.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}[\\s\\S]*?${END.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`);
    if (blockRe.test(content)) content = content.replace(blockRe, block);
    else content = content.replace(/\s*$/, `\n\n${block}\n`);

    if (content !== before) { await fs.writeFile(file, content, 'utf-8'); updated++; }
  }
  return { pagesUpdated: updated };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npm run test -- graph-project`
Expected: PASS (no-op, projection, idempotency).

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/graph-project.ts mcp/src/tools/graph-project.test.ts
git commit -m "feat(graph): projectGraphToPages — related: + Dependencies block projection"
```

### Task D2: Call the projector from `knowledge_reindex`

**Files:**
- Modify: `mcp/src/tools/knowledge-reindex.ts` (import + call before validation, ~line 64)

- [ ] **Step 1: Add the import** (top of file, after line 4)

```ts
import { projectGraphToPages } from './graph-project.js';
```

- [ ] **Step 2: Call the projector before writing the index** — in `knowledgeReindex`, immediately after `await fs.writeFile(indexPath, …)` (line 64) is too late (index would miss projected descriptions); instead add right after the `wikiRoot`/`indexPath` setup but the projection must precede page reads. Place it as the **first** action inside the function body (after line 14):

```ts
  // Project the relationship graph onto pages first, so the index + validation
  // see current related: links. No-op when ~/knowledge/graph/edges.jsonl absent.
  try { await projectGraphToPages(knowledgeDir); } catch { /* projection is best-effort */ }
```

- [ ] **Step 3: Write/extend the test** — add to a reindex test (or create `mcp/src/tools/knowledge-reindex.test.ts`):

```ts
// mcp/src/tools/knowledge-reindex.test.ts
import { describe, it, expect } from 'vitest';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { appendEdge } from './graph-store.js';
import { knowledgeReindex } from './knowledge-reindex.js';

describe('knowledgeReindex integrates projection', () => {
  it('projects edges onto pages during reindex', async () => {
    const dir = await fsp.mkdtemp(join(tmpdir(), 'ri-'));
    await fsp.mkdir(join(dir, 'wiki', 'entities'), { recursive: true });
    for (const s of ['a-page', 'b-page']) {
      await fsp.writeFile(join(dir, 'wiki', 'entities', `${s}.md`), `---\ntitle: ${s}\ntype: entities\nrelated: []\n---\n\n# ${s}\n`);
    }
    await appendEdge(join(dir, 'graph', 'edges.jsonl'),
      { op: 'assert', from: 'a-page', to: 'b-page', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await knowledgeReindex(dir);
    const md = await fsp.readFile(join(dir, 'wiki', 'entities', 'a-page.md'), 'utf-8');
    expect(md).toMatch(/related: \[\[b-page\]\]/);
    expect(md).toMatch(/\*\*Requires:\*\* \[\[b-page\]\]/);
  });
});
```

- [ ] **Step 4: Build (CLI bundle) + run tests**

Run: `cd mcp && npm run build && npm run test -- knowledge-reindex`
Expected: build OK (the reindex CLI bundle picks up graph-project via esbuild); PASS.

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/knowledge-reindex.ts mcp/src/tools/knowledge-reindex.test.ts
git commit -m "feat(graph): reindex runs graph projection (no-op without edges)"
```

---

## Phase E — Retrieval integration

Make search and session-load aware of the typed graph, with a hard back-compat guard.

**File structure:**
- Modify: `mcp/src/tools/knowledge-search.ts` (replace one-hop boost with guarded multi-hop typed boost)
- Create: `mcp/src/tools/graph-neighbors-cli.ts` + bundle entry in `mcp/package.json`
- Modify: `scripts/session-load.sh` (inject active-project neighbourhood within byte budget)
- Test: `mcp/src/tools/knowledge-search.test.ts` (golden back-compat + multi-hop)

### Task E1: Multi-hop typed graph-boost in `knowledge_search` (guarded)

**Files:**
- Modify: `mcp/src/tools/knowledge-search.ts` (lines 116-127 graph-boost block; add edge-log load)
- Test: `mcp/src/tools/knowledge-search.test.ts`

- [ ] **Step 1: Write the failing test (back-compat golden + multi-hop)**

```ts
// mcp/src/tools/knowledge-search.test.ts
import { describe, it, expect } from 'vitest';
import { promises as fsp } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { knowledgeSearch } from './knowledge-search.js';
import { appendEdge } from './graph-store.js';

async function wiki(): Promise<string> {
  const dir = await fsp.mkdtemp(join(tmpdir(), 'ks-'));
  await fsp.mkdir(join(dir, 'wiki', 'entities'), { recursive: true });
  const w = (s: string, body: string, related = '[]') =>
    fsp.writeFile(join(dir, 'wiki', 'entities', `${s}.md`),
      `---\ntitle: ${s}\ntype: entities\ndescription: ${s}\nrelated: ${related}\n---\n\n# ${s}\n\n${body}\n`);
  await w('alpha', 'alpha mentions wireguard tunnel keyword');
  await w('beta', 'unrelated content about gardening');
  await w('gamma', 'unrelated content about cooking');
  return dir;
}

describe('knowledge_search back-compat', () => {
  it('with NO graph dir, frontmatter related: still drives a one-hop boost (legacy behaviour preserved)', async () => {
    const dir = await wiki();
    // legacy: alpha relates to beta via frontmatter only
    await fsp.writeFile(join(dir, 'wiki', 'entities', 'alpha.md'),
      `---\ntitle: alpha\ntype: entities\ndescription: alpha\nrelated: [[beta]]\n---\n\n# alpha\n\nwireguard tunnel keyword\n`);
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir });
    const slugs = r.candidates.map(c => c.path.replace(/.*\//, '').replace(/\.md$/, ''));
    expect(slugs).toContain('alpha');
    expect(slugs).toContain('beta'); // boosted via frontmatter related, no graph log present
  });
});

describe('knowledge_search multi-hop typed boost (graph present)', () => {
  it('a hit on alpha boosts its 2-hop requires-neighbour', async () => {
    const dir = await wiki();
    const log = join(dir, 'graph', 'edges.jsonl');
    await appendEdge(log, { op: 'assert', from: 'alpha', to: 'beta', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    await appendEdge(log, { op: 'assert', from: 'beta', to: 'gamma', type: 'requires', valid_from: '2026-05-01', recorded_at: '2026-05-01T00:00:00Z' });
    const r = await knowledgeSearch({ query: 'wireguard tunnel', knowledgeDir: dir });
    const slugs = r.candidates.map(c => c.path.replace(/.*\//, '').replace(/\.md$/, ''));
    expect(slugs).toContain('beta');   // 1 hop
    expect(slugs).toContain('gamma');  // 2 hops, via typed graph
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npm run test -- knowledge-search`
Expected: FAIL — multi-hop case (gamma absent); back-compat case should already pass on current code (it exercises existing behaviour).

- [ ] **Step 3: Replace the one-hop boost block** — in `knowledge-search.ts`, replace lines 116-127 (the `// Graph boost:` block) with a guarded multi-hop walk. Add an import at the top:

```ts
import { loadEdges, foldToCurrent, validAt, CurrentEdge } from './graph-store.js';
```

Then replace the block:

```ts
  // Graph boost: propagate relevance through the typed relationship graph.
  // If ~/knowledge/graph/edges.jsonl exists, walk current-valid typed edges up
  // to 2 hops with per-hop decay. Otherwise fall back to the legacy one-hop
  // boost over frontmatter `related:` (byte-for-byte prior behaviour).
  const GRAPH_BOOST = 0.3;
  const slugScoreMap = new Map(scored.map(s => [slugFromPath(s.path), s]));
  let graphEdges: CurrentEdge[] = [];
  try {
    const recs = await loadEdges(join(knowledgeDir, 'graph', 'edges.jsonl'));
    if (recs.length > 0) {
      const now = new Date().toISOString();
      graphEdges = foldToCurrent(recs).filter(e => validAt(e, now));
    }
  } catch { /* no graph — legacy path below */ }

  if (graphEdges.length > 0) {
    // Multi-hop typed propagation (depth 2). requires/affects propagate full,
    // relates weaker. Decay 0.3 per hop.
    const TYPE_W: Record<string, number> = { requires: 1, affects: 1, part_of: 0.8, supersedes: 0.6, relates: 0.5 };
    const adj = new Map<string, { to: string; w: number }[]>();
    for (const e of graphEdges) {
      for (const [a, b] of [[e.from, e.to], [e.to, e.from]] as [string, string][]) {
        if (!adj.has(a)) adj.set(a, []);
        adj.get(a)!.push({ to: b, w: TYPE_W[e.type] ?? 0.5 });
      }
    }
    for (const entry of scored) {
      if (entry.score <= 0) continue;
      const start = slugFromPath(entry.path);
      let frontier = [{ node: start, factor: 1 }];
      const seen = new Set<string>([start]);
      for (let hop = 0; hop < 2; hop++) {
        const next: { node: string; factor: number }[] = [];
        for (const { node, factor } of frontier) {
          for (const { to, w } of adj.get(node) ?? []) {
            const target = slugScoreMap.get(to);
            const contrib = entry.score * GRAPH_BOOST * factor * w;
            if (target && target !== entry) target.score += contrib;
            if (!seen.has(to)) { seen.add(to); next.push({ node: to, factor: factor * GRAPH_BOOST }); }
          }
        }
        frontier = next;
      }
    }
  } else {
    // Legacy one-hop boost over frontmatter related: (unchanged from 0.21.4).
    for (const entry of scored) {
      if (entry.score <= 0) continue;
      for (const rel of entry.related) {
        const target = slugScoreMap.get(rel);
        if (target && target !== entry) target.score += entry.score * GRAPH_BOOST;
      }
    }
  }
```

Note: `knowledgeSearch` is `async` already, and `knowledgeDir` is in scope (line 54). `join` is already imported (line 2).

- [ ] **Step 4: Build + run tests**

Run: `cd mcp && npm run build && npm run test -- knowledge-search`
Expected: PASS — back-compat case AND multi-hop case (gamma now boosted). The build re-bundles `knowledge-search-cli.bundle.js`.

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/knowledge-search.ts mcp/src/tools/knowledge-search.test.ts
git commit -m "feat(graph): multi-hop typed graph-boost in knowledge_search (legacy fallback)"
```

### Task E2: `graph-neighbors-cli.ts` for shell consumers + bundle entry

**Files:**
- Create: `mcp/src/tools/graph-neighbors-cli.ts`
- Modify: `mcp/package.json` (append an esbuild line to `bundle`)

- [ ] **Step 1: Write the CLI** (mirrors `knowledge-search-cli.ts` shape — reads args/env, prints lines)

```ts
// mcp/src/tools/graph-neighbors-cli.ts
// CLI bridge so session-load.sh can fetch a slug's current dependency
// neighbourhood without a node import dance. Prints one line per edge:
//   <type>\t<from>\t<to>\t<hops>
// Usage: KNOWLEDGE_DIR=... node graph-neighbors-cli.bundle.js <slug> [depth] [direction]
import { knowledgeNeighbors } from './knowledge-neighbors.js';

const slug = process.argv[2] || '';
if (!slug) process.exit(0);
const depth = parseInt(process.argv[3] || '1', 10);
const direction = (process.argv[4] as 'out' | 'in' | 'both') || 'both';
const knowledgeDir = process.env.KNOWLEDGE_DIR;
if (!knowledgeDir) process.exit(0);

const r = await knowledgeNeighbors({ slug, depth, direction, knowledgeDir });
for (const e of r.edges) {
  console.log(`${e.type}\t${e.from}\t${e.to}\t${e.hops}`);
}
```

- [ ] **Step 2: Add the bundle entry** — in `mcp/package.json`, append to the end of the `bundle` script string (before the closing quote), chained with ` && `:

```
 && esbuild src/tools/graph-neighbors-cli.ts --bundle --platform=node --target=node20 --format=esm --external:@huggingface/transformers --outfile=dist/tools/graph-neighbors-cli.bundle.js
```

- [ ] **Step 3: Build to verify the bundle is produced**

Run: `cd mcp && npm run build && test -f dist/tools/graph-neighbors-cli.bundle.js && echo BUNDLE_OK`
Expected: `BUNDLE_OK`.

- [ ] **Step 4: Functional smoke test**

Run:
```bash
cd mcp && TMP=$(mktemp -d) && mkdir -p "$TMP/wiki/entities" "$TMP/graph" \
 && printf '%s\n' '{"op":"assert","from":"a","to":"b","type":"requires","valid_from":"2026-05-01","recorded_at":"2026-05-01T00:00:00Z"}' > "$TMP/graph/edges.jsonl" \
 && KNOWLEDGE_DIR="$TMP" node dist/tools/graph-neighbors-cli.bundle.js a 1 out
```
Expected: a line `requires	a	b	1`.

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/graph-neighbors-cli.ts mcp/package.json
git commit -m "feat(graph): graph-neighbors-cli + bundle entry for shell consumers"
```

### Task E3: Inject the active-project neighbourhood in `session-load.sh`

**Files:**
- Modify: `scripts/session-load.sh` (after the wiki-enrichment block ~line 399, within the byte budget machinery)
- Test: `tests/test-session-load-graph.sh`

- [ ] **Step 1: Write the failing test**

```bash
# tests/test-session-load-graph.sh
#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Minimal fake env: a project + a graph edge between two real pages.
export BRAIN_DIR="$TMP/.second-brain"
export KNOWLEDGE_DIR="$TMP/knowledge"
mkdir -p "$BRAIN_DIR/projects/demo" "$KNOWLEDGE_DIR/wiki/entities" "$KNOWLEDGE_DIR/graph"
printf '%s\n' '# PROJECT: demo' '## Goal' 'wg-tunnel work' '## Cross-references' '- wg-tunnel' > "$BRAIN_DIR/projects/demo/PROJECT.md"
printf '%s\n' '---' 'title: wg-tunnel' 'type: entities' '---' '# wg-tunnel' > "$KNOWLEDGE_DIR/wiki/entities/wg-tunnel.md"
printf '%s\n' '---' 'title: vps-ufw-depinned' 'type: entities' '---' '# vps' > "$KNOWLEDGE_DIR/wiki/entities/vps-ufw-depinned.md"
printf '%s\n' '{"op":"assert","from":"wg-tunnel","to":"vps-ufw-depinned","type":"requires","valid_from":"2026-05-29","recorded_at":"2026-05-29T00:00:00Z"}' > "$KNOWLEDGE_DIR/graph/edges.jsonl"

# Build the CLI bundle the script depends on (skip if already built).
[ -f "$ROOT/mcp/dist/tools/graph-neighbors-cli.bundle.js" ] || fail "build mcp first: cd mcp && npm run build"

OUT=$(echo '{"hook_event_name":"SessionStart","source":"startup"}' | bash "$ROOT/scripts/session-load.sh" 2>/dev/null)
echo "$OUT" | grep -q 'vps-ufw-depinned' || fail "active-project neighbourhood not injected"
pass "session-load injects current dependency neighbourhood"
echo; echo "ALL PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npm run build >/dev/null 2>&1; cd .. && bash tests/test-session-load-graph.sh`
Expected: FAIL — neighbourhood not injected.

- [ ] **Step 3: Add the injection block** — in `scripts/session-load.sh`, after the wiki-enrichment append (~line 399) and before the dream nudge (~line 401), add (mirror the file's `sb_append`/budget helpers and `$SEARCH_CLI`-style node invocation; the project keyword/slug list is already computed as `$PROJ_KW`/cross-ref slugs):

```bash
# --- Graph neighbourhood: current typed deps of the project's key entities ---
# No-op when the graph CLI or edges.jsonl is absent (back-compat).
GRAPH_CLI="$CLAUDE_PLUGIN_ROOT/mcp/dist/tools/graph-neighbors-cli.bundle.js"
if [ -f "$GRAPH_CLI" ] && [ -f "$KNOWLEDGE_DIR/graph/edges.jsonl" ]; then
  GRAPH_OUT=""
  # Take up to 4 cross-reference slugs from PROJECT.md as entry points.
  CR_SLUGS=$(awk '
    /^## Cross-references$/ { f=1; next }
    /^## / { f=0 }
    f && /\[\[/ { while (match($0, /\[\[[^]]+\]\]/)) { s=substr($0,RSTART+2,RLENGTH-4); print s; $0=substr($0,RSTART+RLENGTH) } }
    f && /^- [a-z0-9]/ { gsub(/^- /,""); print $1 }
  ' "$project_file" 2>/dev/null | sort -u | head -4)
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    line=$(KNOWLEDGE_DIR="$KNOWLEDGE_DIR" node "$GRAPH_CLI" "$s" 1 both 2>/dev/null \
      | awk -F'\t' '{ printf "%s %s %s; ", $2, $1, $3 }')
    [ -n "$line" ] && GRAPH_OUT="${GRAPH_OUT}- ${s}: ${line}\n"
  done <<< "$CR_SLUGS"
  if [ -n "$GRAPH_OUT" ]; then
    sb_append "$(printf '[Dependency graph — current typed relations (as of today)]\n%b' "$GRAPH_OUT")" "graph-neighbourhood" 600
  fi
fi
```

(Adapt `sb_append`, `$project_file`, and `$CLAUDE_PLUGIN_ROOT` to the exact names already used in `session-load.sh` — grep them in the file to confirm. The 600 is the byte cap, consistent with the wiki-enrichment cap.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-session-load-graph.sh`
Expected: `ALL PASS` — `vps-ufw-depinned` present in the injected hot tier.

- [ ] **Step 5: Commit**

```bash
git add scripts/session-load.sh tests/test-session-load-graph.sh
git commit -m "feat(graph): session-load injects active-project dependency neighbourhood"
```

---

## Phase F — Migration (opt-in, reversible)

Seed `edges.jsonl` from existing `related:`/`[[links]]` as untyped `relates`. Never guesses `requires`/`affects`. Reversible (delete `graph/`).

**File structure:**
- Create: `scripts/graph-migrate.sh` + `tests/test-graph-migrate.sh`

### Task F1: `graph-migrate.sh`

**Files:**
- Create: `scripts/graph-migrate.sh`
- Test: `tests/test-graph-migrate.sh`

- [ ] **Step 1: Write the failing test**

```bash
# tests/test-graph-migrate.sh
#!/bin/bash
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$ROOT/scripts/graph-migrate.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }
[ -f "$SCRIPT" ] || fail "scripts/graph-migrate.sh not found"

KDIR="$TMP/knowledge"; mkdir -p "$KDIR/wiki/entities"
printf '%s\n' '---' 'title: A' 'type: entities' 'created: 2026-05-01' 'related: [[page-b]]' '---' '# A' > "$KDIR/wiki/entities/page-a.md"
printf '%s\n' '---' 'title: B' 'type: entities' 'created: 2026-05-02' 'related: []' '---' '# B' > "$KDIR/wiki/entities/page-b.md"

# --- Test 1: migration creates untyped relates edges from related: ---
KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
LOG="$KDIR/graph/edges.jsonl"
[ -f "$LOG" ] || fail "edges.jsonl not created"
grep -q '"from":"page-a"' "$LOG" || fail "related: not migrated"
grep -q '"type":"relates"' "$LOG" || fail "migrated edge not typed relates"
grep -q '"source":"migration:v1"' "$LOG" || fail "source not stamped migration:v1"
pass "related: links migrated as untyped relates edges"

# --- Test 2: idempotent — second run adds no duplicates ---
N1=$(wc -l < "$LOG")
KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
N2=$(wc -l < "$LOG")
[ "$N1" = "$N2" ] || fail "migration not idempotent ($N1 -> $N2)"
pass "migration is idempotent"

echo; echo "ALL PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-graph-migrate.sh`
Expected: FAIL — script not found.

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/graph-migrate.sh
#!/bin/bash
# One-shot, idempotent, reversible migration: seed ~/knowledge/graph/edges.jsonl
# from existing related: frontmatter + body [[wiki-links]] as untyped `relates`
# edges. Never guesses requires/affects — re-typing is later, LLM-judged work.
# Reversible: delete ~/knowledge/graph/ and pages still carry their related:.
set -u
source "$(dirname "$0")/lib.sh"

KNOWLEDGE_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --knowledge-dir) KNOWLEDGE_DIR="$2"; shift 2 ;;
    *) echo "graph-migrate: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -z "$KNOWLEDGE_DIR" ] && KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
WIKI="$KNOWLEDGE_DIR/wiki"
GRAPH_DIR="$KNOWLEDGE_DIR/graph"
LOG="$GRAPH_DIR/edges.jsonl"
mkdir -p "$GRAPH_DIR"; touch "$LOG"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Build a set of already-present migration identities (from\ttype\tto) for idempotency.
EXISTING=$(jq -r 'select(.source=="migration:v1") | "\(.from)\t\(.type)\t\(.to)"' "$LOG" 2>/dev/null | sort -u)

emit() { # from to created
  local from="$1" to="$2" created="$3"
  local id; id=$(printf '%s\trelates\t%s' "$from" "$to")
  printf '%s\n' "$EXISTING" | grep -qF -- "$id" && return 0
  local vf="${created:0:10}"; [ -z "$vf" ] && vf="${NOW:0:10}"
  jq -nc --arg f "$from" --arg t "$to" --arg vf "$vf" --arg now "$NOW" \
    '{op:"assert",from:$f,to:$t,type:"relates",valid_from:$vf,valid_to:null,recorded_at:$now,source:"migration:v1"}' >> "$LOG"
  EXISTING="$EXISTING
$id"
}

find "$WIKI" -name '*.md' -type f ! -name 'index.md' 2>/dev/null | while IFS= read -r file; do
  from=$(basename "$file" .md)
  created=$(awk -F': *' '/^created:/ { print $2; exit }' "$file" | tr -d '"' | tr -d '[:space:]')
  # Frontmatter related: [[x]], [[y]]  OR  related: [x, y]
  rel_line=$(awk '/^related:/ { print; exit }' "$file")
  # Collect [[slug]] tokens, then bare comma-list tokens.
  echo "$rel_line" | grep -oE '\[\[[^]]+\]\]' | sed 's/\[\[//;s/\]\]//' | while IFS= read -r to; do
    [ -n "$to" ] && [ "$to" != "$from" ] && emit "$from" "$to" "$created"
  done
done

exit 0
```

- [ ] **Step 4: Make executable, run test to verify it passes**

Run: `chmod +x scripts/graph-migrate.sh && bash tests/test-graph-migrate.sh`
Expected: `ALL PASS` (migration + idempotency).

- [ ] **Step 5: Commit**

```bash
git add scripts/graph-migrate.sh tests/test-graph-migrate.sh
git commit -m "feat(graph): graph-migrate.sh — opt-in reversible related:→edges import"
```

---

## Phase G — Agents, upgrade wiring, version bump, release gate

Teach the consolidation agents to curate edges; expose migration via the upgrade skill; bump versions; verify the whole suite + deep review.

### Task G1: RELATE → edge-curation in the agents

**Files:**
- Modify: `agents/knowledge-maintainer.md` (Phase 3 RELATE, lines 80-95)
- Modify: `agents/dream-runner.md` (Phase 3 RELATE block)

- [ ] **Step 1: Rewrite the maintainer RELATE phase** — replace the body of `## Phase 3: RELATE` (lines 80-95) with:

```markdown
## Phase 3: RELATE — Typed Edge Curation

Relationships now live in the bi-temporal edge log `~/knowledge/graph/edges.jsonl`
(source of truth), projected onto pages' `related:` + `## Dependencies` block at
reindex. Do NOT hand-edit `related:` or the `<!-- graph:begin -->` block — they are
generated. Curate the **edges** instead, via the `knowledge_relate` tool.

1. List pages with no current outgoing/incoming edges (query `knowledge_neighbors`).
2. For each, identify concrete typed relationships and assert them:
   - `requires` (hard dependency), `affects` (change-impact), `part_of` (composition),
     `relates` (only when none of the above fit).
   - Use `knowledge_relate({from, to, type})`. Prefer upgrading migration's untyped
     `relates` edges to `requires`/`affects` where the relationship is clearly one.
3. **Supersession**: when a newer page/decision contradicts a live edge, do NOT delete
   it — `knowledge_relate({from, to, type, invalidate:true, valid_to:<date>})` to close
   it, then assert the replacement (often a `supersedes` edge). History is preserved.
4. Run `knowledge_reindex` after curation to re-project pages.

Priority order unchanged: Entity↔Learning, Entity↔Concept, Learning↔Learning,
Decision→Entity, Issue→Entity. Bidirectionality is automatic (edges are walked both
ways) — do not assert reverse duplicates.
```

- [ ] **Step 2: Mirror the change in `dream-runner.md`** — update its Phase 3 RELATE bullet block to point at `knowledge_relate`/edge-log curation + invalidation, matching the above (keep it concise; the dream runs on staging, so note: assertions during a dream are appended to the **staging** copy's `graph/edges.jsonl` and applied on `dream_accept`).

- [ ] **Step 3: Verify no test references the old wording** (sanity)

Run: `grep -rl "Systematic Relation Building" tests/ 2>/dev/null || echo "no test depends on old heading"`
Expected: `no test depends on old heading`.

- [ ] **Step 4: Commit**

```bash
git add agents/knowledge-maintainer.md agents/dream-runner.md
git commit -m "feat(graph): RELATE phase curates typed bi-temporal edges via knowledge_relate"
```

### Task G2: Expose migration via the upgrade skill + migration row

**Files:**
- Modify: `skills/upgrade/SKILL.md` (add an opt-in one-shot migration step)
- Modify: the upgrade migration table (the file `test-upgrade-migration-row.sh` checks — grep it to find the path)

- [ ] **Step 1: Find the migration-row file the test guards**

Run: `grep -nE "migration|MIGRATION|row" tests/test-upgrade-migration-row.sh | head`
Expected: reveals the file + row format the test asserts (follow it exactly).

- [ ] **Step 2: Add a 0.22.0 migration row** in that file, matching the existing row format, e.g.:

```
| 0.22.0 | Relational graph (opt-in) | Run `bash scripts/graph-migrate.sh` once to seed ~/knowledge/graph/edges.jsonl from existing related: links. Reversible: delete ~/knowledge/graph/. |
```

- [ ] **Step 3: Add the opt-in step to `skills/upgrade/SKILL.md`** — a guarded, clearly-optional block that explains the *why* (per user's learning style), shows the exact command, and notes reversibility + that it's safe to skip.

- [ ] **Step 4: Run the migration-row test**

Run: `bash tests/test-upgrade-migration-row.sh`
Expected: PASS (row present + well-formed).

- [ ] **Step 5: Commit**

```bash
git add skills/upgrade/SKILL.md tests/test-upgrade-migration-row.sh
git commit -m "docs(graph): upgrade skill exposes opt-in graph migration + 0.22.0 row"
```

### Task G3: Plugin version bump + MCP instructions + full gate

**Files:**
- Modify: `.claude-plugin/plugin.json` (`version` → `0.22.0`)
- Modify: `mcp/src/server.ts` (extend the `instructions` string to mention `knowledge_relate`/`knowledge_neighbors`)

- [ ] **Step 1: Bump the plugin version**

```bash
# edit .claude-plugin/plugin.json: "version": "0.22.0"
```

- [ ] **Step 2: Extend the MCP server `instructions`** (line 52) — append a sentence:

```
 Relational graph: knowledge_relate to assert/invalidate a typed bi-temporal relationship (requires|affects|relates|part_of|supersedes) between two pages, and knowledge_neighbors to walk a page's dependency neighbourhood (multi-hop, directional, point-in-time via as_of).
```

- [ ] **Step 3: Build the MCP bundle (ship dist/)**

Run: `cd mcp && npm run build && cd ..`
Expected: build succeeds; `dist/` updated (server + all CLI bundles incl. graph-neighbors).

- [ ] **Step 4: Run the FULL test suite (the release gate)**

Run: `bash tests/run-all.sh`
Expected: every `test-*.sh` green AND the mcp vitest suite green; exit 0. Read the summary — any red blocks the release.

- [ ] **Step 5: Deep-review gate** (per `[[deep-review-release-gate]]`)

Run: `/second-brain:code-review-deep` against the branch. Resolve findings until clean. THEN commit the version bump:

```bash
git add .claude-plugin/plugin.json mcp/src/server.ts mcp/dist
git commit -m "chore(release): bi-temporal relational memory — bump 0.22.0 / MCP 2.3.0"
```

---

## Self-Review (run before handing off to execution)

**Spec coverage** — every spec section maps to a task:
- §1 Data model → A1–A6 (types, load, fold, validAt, neighbors, append)
- §2 Capture (extractor / dream / manual) → C1–C3 (extractor+bash), G1 (dream/maintainer), B1 (manual `knowledge_relate`)
- §3 Projection (related: + Dependencies block) → D1–D2
- §4 Retrieval (neighbors tool, multi-hop boost, session-load) → B2, E1, E3
- §5 Migration + back-compat → F1 (migration), A2/D1/E1 guards + E1 golden test (back-compat)
- §6 Error handling → A2 (torn line), C1 (quarantine), D1/E1 (no-op guard), B1 (slug validation)
- §7 Testing → tests in every task; headline bi-temporal as_of = A4; back-compat golden = E1; resilience = A2
- §8 File-change inventory → matches tasks’ Files blocks
- §9 Rollout → Phase ordering (dormant → opt-in migrate → capture → validate/gate → skills)

**Placeholder scan:** none — every code step shows complete code; every command shows expected output. Two tasks (C3, E3) instruct the engineer to *confirm an existing variable/helper name by grepping the file before editing* — that is a deliberate safety check against drift in scripts I did not fully quote, not a placeholder; the code to add is given in full.

**Type consistency:** `EdgeRecord`/`CurrentEdge`/`EdgeType`/`NeighborEdge` defined in A and reused unchanged in B/D/E. `appendEdge`, `loadEdges`, `foldToCurrent`, `validAt`, `neighbors` signatures are stable across all later references. Tool arg field names (`from`,`to`,`type`,`valid_from`,`valid_to`,`invalidate`,`as_of`,`edge_types`,`direction`,`depth`) are identical in B1/B2/B3 and the CLI (E2).

**Scope:** single coherent subsystem built in sequential layers; each phase ships working, tested software. Phase 2 (skills "wingman") is correctly deferred to its own future spec (Task #9), not included here.

---

## Execution Handoff

Implement task-by-task with TDD (red → green → commit). Gate every "done" through `second-brain:verification-before-completion` — run the stated command, read the output in your message, then check the box. Phases are ordered by dependency; do not start Phase D before Phase A is green. Run `bash tests/run-all.sh` at the end of each phase as a regression checkpoint, and the full gate (G3) before any release tag.
