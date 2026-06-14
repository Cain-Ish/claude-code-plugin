// src/tools/graph-cluster-cli.ts
import { promises as fs } from "fs";
import { join, basename } from "path";

// src/tools/graph-cluster.ts
function buildAdjacency(pages) {
  const known = new Set(pages.map((p) => p.slug));
  const adj = /* @__PURE__ */ new Map();
  const ensure = (s) => {
    let x = adj.get(s);
    if (!x) {
      x = /* @__PURE__ */ new Set();
      adj.set(s, x);
    }
    return x;
  };
  for (const p of pages) {
    ensure(p.slug);
    for (const n of /* @__PURE__ */ new Set([...p.related ?? [], ...p.bodyLinks ?? []])) {
      if (n === p.slug || !known.has(n)) continue;
      ensure(p.slug).add(n);
      ensure(n).add(p.slug);
    }
  }
  return adj;
}
function normalize(labels) {
  const groups = /* @__PURE__ */ new Map();
  for (const [node, lab] of labels) {
    let g = groups.get(lab);
    if (!g) {
      g = [];
      groups.set(lab, g);
    }
    g.push(node);
  }
  const out = /* @__PURE__ */ new Map();
  for (const members of groups.values()) {
    const id = [...members].sort()[0];
    for (const m of members) out.set(m, id);
  }
  return out;
}
function labelPropagate(adj, opts = {}) {
  const maxIter = opts.maxIter ?? 20;
  const nodes = [...adj.keys()].sort();
  let labels = new Map(nodes.map((n) => [n, n]));
  for (let iter = 0; iter < maxIter; iter++) {
    const next = /* @__PURE__ */ new Map();
    let changed = false;
    for (const node of nodes) {
      const own = labels.get(node);
      const nbrs = adj.get(node);
      if (nbrs.size === 0) {
        next.set(node, own);
        continue;
      }
      const tally = /* @__PURE__ */ new Map();
      for (const nb of nbrs) {
        const l = labels.get(nb);
        tally.set(l, (tally.get(l) ?? 0) + 1);
      }
      const max = Math.max(...tally.values());
      const tied = [...tally.entries()].filter(([, c]) => c === max).map(([l]) => l);
      const chosen = tied.includes(own) ? own : tied.sort()[0];
      next.set(node, chosen);
      if (chosen !== own) changed = true;
    }
    labels = next;
    if (!changed) break;
  }
  return normalize(labels);
}
function clusters(labels, opts) {
  const groups = /* @__PURE__ */ new Map();
  for (const [node, lab] of labels) {
    let g = groups.get(lab);
    if (!g) {
      g = [];
      groups.set(lab, g);
    }
    g.push(node);
  }
  const out = [];
  for (const [id, members] of groups) {
    if (members.length >= opts.minSize) out.push({ id, members: [...members].sort() });
  }
  return out.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}
function djb2(s) {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h ^ s.charCodeAt(i)) >>> 0;
  return h.toString(36);
}
function memberHash(sortedMembers, contentHashBySlug) {
  const basis = sortedMembers.join("|") + "::" + sortedMembers.map((s) => contentHashBySlug[s] ?? "").join("|");
  return djb2(basis);
}

// src/tools/graph-cluster-cli.ts
function resolveWikiDir(argv) {
  if (argv[0] === "--knowledge-dir" && argv[1]) return join(argv[1], "wiki");
  if (argv[0]) return argv[0];
  const kd = process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR || process.env.KNOWLEDGE_DIR || join(process.env.HOME ?? "", "knowledge");
  return join(kd, "wiki");
}
async function collect(dir, acc = []) {
  let entries;
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return acc;
  }
  for (const e of entries) {
    const p = join(dir, e.name);
    if (e.isDirectory()) {
      if (!e.name.startsWith(".") && e.name !== "projects" && e.name !== "themes") await collect(p, acc);
    } else if (e.name.endsWith(".md") && e.name !== "index.md") acc.push(p);
  }
  return acc;
}
function frontmatter(content) {
  const m = content.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  return m ? m[1] : "";
}
function links(text) {
  return [...text.matchAll(/\[\[([^\]]+)\]\]/g)].map((m) => m[1].split("|")[0].trim()).filter(Boolean);
}
function relatedFrom(fm) {
  const line = fm.split("\n").find((l) => /^related:/.test(l));
  if (!line) return [];
  const wl = links(line);
  if (wl.length) return wl;
  const m = line.match(/^related:\s*\[(.*)\]\s*$/);
  if (!m) return [];
  return m[1].split(",").map((s) => s.trim().replace(/^["']|["']$/g, "")).filter((s) => /^[a-z0-9][a-z0-9-]*$/i.test(s));
}
async function main() {
  const wikiDir = resolveWikiDir(process.argv.slice(2));
  const minSize = parseInt(process.env.SB_SUMMARIZE_MIN_CLUSTER ?? "4", 10) || 4;
  const files = await collect(wikiDir);
  const pages = [];
  const contentHash = {};
  for (const f of files) {
    let content = "";
    try {
      content = await fs.readFile(f, "utf-8");
    } catch {
      continue;
    }
    if (!content.trim()) continue;
    const slug = basename(f, ".md");
    const fm = frontmatter(content);
    const body = content.replace(/^---\r?\n[\s\S]*?\r?\n---/, "");
    pages.push({ slug, related: relatedFrom(fm), bodyLinks: [...new Set(links(body))] });
    contentHash[slug] = djb2(content);
  }
  const maxPages = parseInt(process.env.SB_SUMMARIZE_MAX_PAGES ?? "8", 10) || 8;
  const labels = labelPropagate(buildAdjacency(pages));
  const capped = [...clusters(labels, { minSize })].sort((a, b) => b.members.length - a.members.length || (a.id < b.id ? -1 : 1)).slice(0, maxPages).sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  const out = capped.map((c) => ({
    id: c.id,
    members: c.members,
    member_hash: memberHash(c.members, contentHash)
  }));
  process.stdout.write(JSON.stringify(out) + "\n");
}
main().catch((e) => {
  process.stderr.write(String(e) + "\n");
  process.exit(1);
});
