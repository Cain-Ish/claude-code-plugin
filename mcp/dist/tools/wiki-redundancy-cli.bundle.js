// src/tools/wiki-redundancy-cli.ts
import { promises as fs } from "fs";
import { join as join2, basename, dirname } from "path";

// src/tools/graph-cluster.ts
function djb2(s) {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h ^ s.charCodeAt(i)) >>> 0;
  return h.toString(36);
}

// src/tools/ai-block.ts
var AI_BLOCK_RE = /<!--\s*ai:begin[^\n]*?-->\n?([\s\S]*?)<!--\s*ai:end\s*-->/;
var AI_BLOCK_RE_G = new RegExp(AI_BLOCK_RE.source, "g");
function stripAiBlock(text) {
  return text.replace(AI_BLOCK_RE_G, "");
}

// src/tools/sanitize.ts
var INVISIBLE_RE = /[\u{200B}\u{2060}\u{FEFF}\u{E0000}-\u{E007F}]/gu;
function stripInvisible(s) {
  return s.replace(INVISIBLE_RE, "");
}

// src/tools/minhash.ts
var SHINGLE_K = 3;
var NUM_HASHES = 128;
var EMPTY_HASH = 4294967295;
var A = new Uint32Array(NUM_HASHES);
var B = new Uint32Array(NUM_HASHES);
{
  let seed = 2654435761 >>> 0;
  const nextRand = () => {
    seed = Math.imul(seed, 1664525) + 1013904223 >>> 0;
    return seed;
  };
  for (let i = 0; i < NUM_HASHES; i++) {
    A[i] = (nextRand() | 1) >>> 0;
    B[i] = nextRand() >>> 0;
  }
}
function proseTokens(content) {
  let t = stripAiBlock(stripInvisible(content));
  t = t.replace(/^---\r?\n[\s\S]*?\r?\n---/, "");
  t = t.replace(/<!--\s*theme:begin[\s\S]*?theme:end\s*-->/g, "");
  t = t.replace(/<!--\s*graph:begin[\s\S]*?graph:end\s*-->/g, "");
  t = t.replace(/\[\[([^\]]+)\]\]/g, " ");
  return t.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
}
function shingles(content, k = SHINGLE_K) {
  const w = proseTokens(content);
  const set = /* @__PURE__ */ new Set();
  if (w.length === 0) return set;
  if (w.length < k) {
    set.add(w.join(" "));
    return set;
  }
  for (let i = 0; i + k <= w.length; i++) set.add(w.slice(i, i + k).join(" "));
  return set;
}
function baseHash(shingle) {
  return parseInt(djb2(shingle), 36) >>> 0;
}
function minhashSignature(shingleSet) {
  const sig = new Uint32Array(NUM_HASHES).fill(EMPTY_HASH);
  for (const sh of shingleSet) {
    const base = baseHash(sh);
    for (let i = 0; i < NUM_HASHES; i++) {
      const h = Math.imul(A[i], base) + B[i] >>> 0;
      if (h < sig[i]) sig[i] = h;
    }
  }
  return sig;
}
function jaccardEstimate(a, b) {
  const n = Math.min(a.length, b.length);
  if (n === 0) return 0;
  let eq = 0;
  for (let i = 0; i < n; i++) if (a[i] === b[i]) eq++;
  return eq / n;
}
function isEmptySignature(sig) {
  if (sig.length === 0) return true;
  for (let i = 0; i < sig.length; i++) if (sig[i] !== EMPTY_HASH) return false;
  return true;
}
function nearDuplicatePairs(pages, threshold = 0.7) {
  const real = pages.filter((p) => !isEmptySignature(p.sig));
  const out = [];
  for (let i = 0; i < real.length; i++) {
    for (let j = i + 1; j < real.length; j++) {
      const sim = jaccardEstimate(real[i].sig, real[j].sig);
      if (sim < threshold) continue;
      const [p, q] = real[i].slug <= real[j].slug ? [real[i], real[j]] : [real[j], real[i]];
      out.push({ a: p.slug, b: q.slug, sim: Math.round(sim * 1e3) / 1e3, a_cat: p.cat, b_cat: q.cat });
    }
  }
  out.sort((x, y) => y.sim - x.sim || (x.a < y.a ? -1 : x.a > y.a ? 1 : x.b < y.b ? -1 : x.b > y.b ? 1 : 0));
  return out;
}

// src/brain-paths.ts
import { join } from "path";
import { homedir } from "os";

// src/path-guard.ts
function cleanEnvPath(s) {
  return (s ?? "").replace(/[\r\n]/g, "");
}

// src/brain-paths.ts
function resolveKnowledgeDir(override) {
  if (override) return override;
  return cleanEnvPath(
    process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR || process.env.KNOWLEDGE_DIR
  ) || join(homedir(), "knowledge");
}

// src/tools/wiki-redundancy-cli.ts
function resolveWikiDir(argv) {
  if (argv[0] === "--knowledge-dir" && argv[1]) return join2(argv[1], "wiki");
  if (argv[0]) return argv[0];
  return join2(resolveKnowledgeDir(), "wiki");
}
async function collect(dir, acc = []) {
  let entries;
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return acc;
  }
  for (const e of entries) {
    const p = join2(dir, e.name);
    if (e.isDirectory()) {
      if (!e.name.startsWith(".") && e.name !== "projects" && e.name !== "themes") await collect(p, acc);
    } else if (e.name.endsWith(".md") && e.name !== "index.md") acc.push(p);
  }
  return acc;
}
function envFloat(name, def, lo, hi) {
  const v = parseFloat(process.env[name] ?? "");
  return Number.isFinite(v) && v >= lo && v <= hi ? v : def;
}
async function main() {
  const wikiDir = resolveWikiDir(process.argv.slice(2));
  const threshold = envFloat("SB_REDUNDANCY_THRESHOLD", 0.7, 0.01, 1);
  const mp = parseInt(process.env.SB_REDUNDANCY_MAX_PAIRS ?? "", 10);
  const maxPairs = Math.max(1, Number.isNaN(mp) ? 50 : mp);
  const files = await collect(wikiDir);
  const pages = [];
  for (const f of files) {
    let content = "";
    try {
      content = await fs.readFile(f, "utf-8");
    } catch {
      continue;
    }
    if (!content.trim()) continue;
    const sh = shingles(content);
    if (sh.size === 0) continue;
    pages.push({ slug: basename(f, ".md"), cat: basename(dirname(f)), sig: minhashSignature(sh) });
  }
  const pairs = nearDuplicatePairs(pages, threshold).slice(0, maxPairs);
  process.stdout.write(JSON.stringify(pairs) + "\n");
}
main().catch((e) => {
  process.stderr.write(String(e) + "\n");
  process.exit(1);
});
