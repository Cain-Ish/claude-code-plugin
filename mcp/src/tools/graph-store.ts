import { promises as fs } from 'fs';
import { dirname } from 'path';

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

function isValidRecord(r: any): r is EdgeRecord {
  if (!(r && typeof r === 'object')) return false;
  if (r.op !== 'assert' && r.op !== 'invalidate') return false;
  if (typeof r.from !== 'string' || r.from.length === 0) return false;
  if (typeof r.to !== 'string' || r.to.length === 0) return false;
  if (!(EDGE_TYPES as string[]).includes(r.type)) return false;
  if (typeof r.recorded_at !== 'string' || r.recorded_at.length < 10) return false;
  // valid_from / valid_to, when present, must be ISO-ish strings (or null) — a
  // number or object here would silently corrupt the lexicographic cmpTime in
  // validAt. Reject the record rather than fold garbage into the graph.
  for (const k of ['valid_from', 'valid_to'] as const) {
    const v = (r as any)[k];
    if (v !== undefined && v !== null && typeof v !== 'string') return false;
  }
  return true;
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
      // An assert ONLY opens an interval — it never closes one. Any valid_to on
      // an assert record is ignored (closing is exclusively invalidate's job),
      // so a stray/garbage valid_to can't open a pre-closed, never-valid edge.
      if (!cur || cur.valid_to !== null) {
        map.set(id, {
          from: r.from, to: r.to, type: r.type,
          valid_from: r.valid_from ?? dateOf(r.recorded_at),
          valid_to: null,
          source: r.source, confidence: r.confidence,
        });
      } else {
        if (r.valid_from != null) cur.valid_from = r.valid_from;
        if (r.source) cur.source = r.source;
        if (r.confidence) cur.confidence = r.confidence;
      }
    } else { // invalidate
      if (cur) cur.valid_to = r.valid_to ?? dateOf(r.recorded_at);
    }
  }
  return [...map.values()];
}

/** True iff the edge is valid at time T: valid_from <= T AND (valid_to null OR valid_to > T).
 *  Half-open interval — an edge invalidated on date D is NOT valid at D.
 *  Operands are normalized to date granularity (dateOf) before comparison so a
 *  full-ISO valid_from/valid_to and a date-only T (or vice versa) compare on the
 *  same footing — the graph is date-granular, and a noon assert must be visible
 *  to a same-day date-only query. */
export function validAt(
  e: { valid_from: string; valid_to: string | null },
  t: string,
): boolean {
  const td = dateOf(t);
  if (cmpTime(dateOf(e.valid_from), td) > 0) return false;
  if (e.valid_to === null) return true;
  return cmpTime(dateOf(e.valid_to), td) > 0;
}

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

/** BFS over current-valid edges from `slug`, up to `depth` hops. Each distinct
 *  edge (from,type,to) is emitted at most ONCE, keeping its min-hop occurrence
 *  (score = TYPE_WEIGHT * GRAPH_DECAY^(hop-1)). This matters for the default
 *  `direction:'both'`, where an edge a-b is otherwise discovered from both
 *  endpoints (and again at deeper hops) and would be emitted multiple times
 *  with conflicting scores. */
export function neighbors(edges: CurrentEdge[], slug: string, opts: NeighborOpts = {}): NeighborEdge[] {
  const depth = opts.depth ?? 2;
  const direction = opts.direction ?? 'both';
  const asOf = opts.asOf ?? new Date().toISOString();
  const typeOk = (t: EdgeType) => !opts.edgeTypes || opts.edgeTypes.includes(t);
  const live = edges.filter(e => validAt(e, asOf) && typeOk(e.type));

  const best = new Map<string, NeighborEdge>(); // edge identity -> min-hop row
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
        const id = identity(e);
        const row: NeighborEdge = {
          from: e.from, to: e.to, type: e.type,
          hops: hop + 1, score: TYPE_WEIGHT[e.type] * Math.pow(GRAPH_DECAY, hop),
          valid_from: e.valid_from, valid_to: e.valid_to,
        };
        const prev = best.get(id);
        if (!prev || row.hops < prev.hops) best.set(id, row);
        if (!seen.has(other)) { seen.add(other); next.push({ node: other, hop: hop + 1 }); }
      }
    }
    frontier = next;
  }
  return [...best.values()];
}

/** Append one validated edge record as a single JSONL line. Used by the
 *  knowledge_relate MCP tool. (The hook write path appends from bash directly;
 *  the JSONL line format is the shared contract.) Each line is a single
 *  appendFile call (O_APPEND); for typical short records this is atomic on local
 *  filesystems, but very large records under concurrent writers are not lock-
 *  protected — loadEdges skips any torn line, so the failure mode is a dropped
 *  edge, never a crash. */
export async function appendEdge(path: string, rec: EdgeRecord): Promise<void> {
  if (!isValidRecord(rec)) throw new Error(`invalid edge record: ${JSON.stringify(rec)}`);
  await fs.mkdir(dirname(path), { recursive: true });
  await fs.appendFile(path, JSON.stringify(rec) + '\n', 'utf-8');
}
