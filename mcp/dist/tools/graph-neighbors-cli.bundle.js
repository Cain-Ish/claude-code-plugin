// src/tools/knowledge-neighbors.ts
import { join } from "path";

// src/tools/graph-store.ts
import { promises as fs } from "fs";
var EDGE_TYPES = ["requires", "affects", "relates", "part_of", "supersedes"];
function cmpTime(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}
function dateOf(iso) {
  return iso.slice(0, 10);
}
function isValidRecord(r2) {
  if (!(r2 && typeof r2 === "object")) return false;
  if (r2.op !== "assert" && r2.op !== "invalidate") return false;
  if (typeof r2.from !== "string" || r2.from.length === 0) return false;
  if (typeof r2.to !== "string" || r2.to.length === 0) return false;
  if (!EDGE_TYPES.includes(r2.type)) return false;
  if (typeof r2.recorded_at !== "string" || r2.recorded_at.length < 10) return false;
  for (const k of ["valid_from", "valid_to"]) {
    const v = r2[k];
    if (v !== void 0 && v !== null && typeof v !== "string") return false;
  }
  return true;
}
async function loadEdges(path) {
  let raw;
  try {
    raw = await fs.readFile(path, "utf-8");
  } catch {
    return [];
  }
  const out = [];
  for (const line of raw.split("\n")) {
    const t = line.trim();
    if (!t) continue;
    try {
      const parsed = JSON.parse(t);
      if (isValidRecord(parsed)) out.push(parsed);
    } catch {
    }
  }
  return out;
}
function identity(r2) {
  return `${r2.from}	${r2.type}	${r2.to}`;
}
function foldToCurrent(records) {
  const ordered = [...records].sort((a, b) => cmpTime(a.recorded_at, b.recorded_at));
  const map = /* @__PURE__ */ new Map();
  for (const r2 of ordered) {
    const id = identity(r2);
    const cur = map.get(id);
    if (r2.op === "assert") {
      if (!cur || cur.valid_to !== null) {
        map.set(id, {
          from: r2.from,
          to: r2.to,
          type: r2.type,
          valid_from: r2.valid_from ?? dateOf(r2.recorded_at),
          valid_to: null,
          source: r2.source,
          confidence: r2.confidence
        });
      } else {
        if (r2.valid_from != null) cur.valid_from = r2.valid_from;
        if (r2.source) cur.source = r2.source;
        if (r2.confidence) cur.confidence = r2.confidence;
      }
    } else {
      if (cur) cur.valid_to = r2.valid_to ?? dateOf(r2.recorded_at);
    }
  }
  return [...map.values()];
}
function validAt(e, t) {
  const td = dateOf(t);
  if (cmpTime(dateOf(e.valid_from), td) > 0) return false;
  if (e.valid_to === null) return true;
  return cmpTime(dateOf(e.valid_to), td) > 0;
}
var GRAPH_DECAY = 0.3;
var TYPE_WEIGHT = {
  requires: 1,
  affects: 1,
  part_of: 0.8,
  supersedes: 0.6,
  relates: 0.5
};
function neighbors(edges, slug2, opts = {}) {
  const depth2 = opts.depth ?? 2;
  const direction2 = opts.direction ?? "both";
  const asOf = opts.asOf ?? (/* @__PURE__ */ new Date()).toISOString();
  const typeOk = (t) => !opts.edgeTypes || opts.edgeTypes.includes(t);
  const live = edges.filter((e) => validAt(e, asOf) && typeOk(e.type));
  const adj = /* @__PURE__ */ new Map();
  const push = (k, v) => {
    let list = adj.get(k);
    if (!list) {
      list = [];
      adj.set(k, list);
    }
    list.push(v);
  };
  for (const e of live) {
    if (direction2 === "out" || direction2 === "both") push(e.from, { e, other: e.to });
    if ((direction2 === "in" || direction2 === "both") && !(direction2 === "both" && e.from === e.to)) {
      push(e.to, { e, other: e.from });
    }
  }
  const best = /* @__PURE__ */ new Map();
  const seen = /* @__PURE__ */ new Set([slug2]);
  let frontier = [{ node: slug2, hop: 0 }];
  while (frontier.length) {
    const next = [];
    for (const { node, hop } of frontier) {
      if (hop >= depth2) continue;
      for (const { e, other } of adj.get(node) ?? []) {
        const id = identity(e);
        const row = {
          from: e.from,
          to: e.to,
          type: e.type,
          hops: hop + 1,
          score: TYPE_WEIGHT[e.type] * Math.pow(GRAPH_DECAY, hop),
          valid_from: e.valid_from,
          valid_to: e.valid_to
        };
        const prev = best.get(id);
        if (!prev || row.hops < prev.hops) best.set(id, row);
        if (!seen.has(other)) {
          seen.add(other);
          next.push({ node: other, hop: hop + 1 });
        }
      }
    }
    frontier = next;
  }
  return [...best.values()];
}

// src/path-guard.ts
var PathGuardError = class extends Error {
  constructor(message, baseDir, candidate) {
    super(message);
    this.baseDir = baseDir;
    this.candidate = candidate;
    this.name = "PathGuardError";
  }
  baseDir;
  candidate;
};
function validateSlug(slug2) {
  if (typeof slug2 !== "string") {
    throw new PathGuardError("slug must be a string", "", String(slug2));
  }
  if (slug2.length === 0 || slug2.length > 128) {
    throw new PathGuardError(`slug length must be 1..128, got ${slug2.length}`, "", slug2);
  }
  if (slug2.startsWith(".")) {
    throw new PathGuardError(`slug must not start with '.': ${JSON.stringify(slug2)}`, "", slug2);
  }
  if (!/^[a-zA-Z0-9._-]+$/.test(slug2)) {
    throw new PathGuardError(`slug contains disallowed characters: ${JSON.stringify(slug2)}`, "", slug2);
  }
}

// src/tools/knowledge-neighbors.ts
async function knowledgeNeighbors(args) {
  try {
    validateSlug(args.slug);
  } catch (e) {
    if (e instanceof PathGuardError) return { slug: args.slug, edges: [] };
    throw e;
  }
  const records = await loadEdges(join(args.knowledgeDir, "graph", "edges.jsonl"));
  if (records.length === 0) return { slug: args.slug, edges: [] };
  const current = foldToCurrent(records);
  const edges = neighbors(current, args.slug, {
    depth: args.depth,
    direction: args.direction,
    edgeTypes: args.edge_types,
    asOf: args.as_of
  });
  return { slug: args.slug, edges };
}

// src/tools/graph-neighbors-cli.ts
var slug = process.argv[2] || "";
if (!slug) process.exit(0);
var depth = parseInt(process.argv[3] || "1", 10);
var direction = process.argv[4] || "both";
var knowledgeDir = process.env.KNOWLEDGE_DIR;
if (!knowledgeDir) process.exit(0);
var r = await knowledgeNeighbors({ slug, depth, direction, knowledgeDir });
for (const e of r.edges) {
  console.log(`${e.type}	${e.from}	${e.to}	${e.hops}`);
}
