// src/tools/raw-capture-cli.ts
import { join as join5 } from "path";
import { existsSync as existsSync3, readFileSync as readFileSync4, statSync as statSync2 } from "fs";

// src/tools/raw-inbox.ts
import { promises as fs } from "fs";
import { join, basename, extname } from "path";

// src/path-guard.ts
function cleanEnvPath(s) {
  return (s ?? "").replace(/[\r\n]/g, "");
}
function assertSafeSlug(slug) {
  if (!slug || slug.length > 128 || /[\\/\x00-\x1f]|\.\./.test(slug)) {
    throw new Error(`unsafe slug: ${JSON.stringify(slug)}`);
  }
}

// src/tools/content-hash.ts
import { createHash } from "crypto";
function hashContent(content) {
  return createHash("sha256").update(content).digest("hex");
}

// ../kb-schema.json
var kb_schema_default = {
  _comment: "SINGLE SOURCE OF TRUTH for the second-brain knowledge-base structure. Edit HERE only. Read by the TS MCP server via mcp/src/constants/kb-schema.ts (esbuild inlines this JSON) and by every bash script/hook via scripts/kb-schema.sh (sourced by lib.sh, reads this file with jq). Derived sets (content/all categories) are computed by the loaders, never stored, so they cannot drift. Guarded by tests/test-kb-schema.sh.",
  structured_types: ["learnings", "decisions", "entities", "issues", "concepts", "security"],
  unstructured_types: ["state", "sources"],
  frontmatter_required: ["title", "description", "type", "created", "updated", "tags", "related"],
  ai_blocks: {
    markers: { begin: "<!-- ai:begin", end: "<!-- ai:end -->" },
    body: "flat YAML key: value lines",
    types: {
      learnings: { fields: ["claim", "trigger", "action", "scope", "evidence", "supersedes"], required: ["claim", "action"] },
      decisions: { fields: ["context", "choice", "alternatives", "rationale", "status", "supersedes"], required: ["choice"] },
      entities: { fields: ["identity", "current_state", "depends_on", "owns", "status"], required: ["identity"] },
      issues: { fields: ["symptom", "cause", "fix", "severity", "status"], required: ["symptom", "status"] },
      concepts: { fields: ["problem", "solution", "where_applied", "tradeoffs"], required: ["problem", "solution"] },
      security: { fields: ["threat", "mitigation", "scope", "status"], required: ["threat", "mitigation"] }
    }
  },
  generated_dirs: ["projects", "themes"],
  edge_types: ["requires", "affects", "relates", "part_of", "supersedes"],
  project_sections: ["blockers", "decisions"],
  forget_protection: {
    protected: ["learnings", "decisions", "concepts", "security", "themes", "projects"],
    discounted: ["entities", "sources", "issues"]
  },
  raw: {
    dir: "raw",
    tier: "project",
    statuses: ["unprocessed", "processed", "discarded"],
    searchable: false
  }
};

// src/constants/kb-schema.ts
var STRUCTURED_TYPES = kb_schema_default.structured_types;
var UNSTRUCTURED_TYPES = kb_schema_default.unstructured_types;
var GENERATED_DIRS = kb_schema_default.generated_dirs;
var EDGE_TYPES = kb_schema_default.edge_types;
var PROJECT_SECTIONS = kb_schema_default.project_sections;
var FORGET_PROTECTED = kb_schema_default.forget_protection.protected;
var FORGET_DISCOUNTED = kb_schema_default.forget_protection.discounted;
var RAW_DIR = kb_schema_default.raw.dir;
var RAW_STATUSES = kb_schema_default.raw.statuses;
var FRONTMATTER_REQUIRED = kb_schema_default.frontmatter_required;
var AI_BLOCK_TYPES = kb_schema_default.ai_blocks.types;
var CONTENT_CATEGORIES = [...STRUCTURED_TYPES, ...UNSTRUCTURED_TYPES];
var ALL_CATEGORIES = [...CONTENT_CATEGORIES, ...GENERATED_DIRS];

// src/tools/ai-block.ts
var AI_BLOCK_RE = /<!--\s*ai:begin[^\n]*?-->\n?([\s\S]*?)<!--\s*ai:end\s*-->/;
var AI_BLOCK_RE_G = new RegExp(AI_BLOCK_RE.source, "g");
function stripAiBlock(text) {
  return text.replace(AI_BLOCK_RE_G, "");
}

// src/tools/frontmatter.ts
var FM_OPEN_RE = /^---\r?\n/;
function matchFrontmatter(content) {
  const m = content.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  return m ? { fm: m[1], body: m[2] } : null;
}
function stripFrontmatter(content) {
  const m = matchFrontmatter(content);
  return m ? m.body : content;
}

// src/tools/sanitize.ts
var INVISIBLE_RE = /[\u{200B}\u{2060}\u{FEFF}\u{E0000}-\u{E007F}]/gu;
function stripInvisible(s) {
  return s.replace(INVISIBLE_RE, "");
}

// src/tools/graph-cluster.ts
function djb2(s) {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h ^ s.charCodeAt(i)) >>> 0;
  return h.toString(36);
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
  t = stripFrontmatter(t);
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
function signatureOf(content) {
  return minhashSignature(shingles(content));
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

// src/tools/raw-inbox.ts
function rawDir(brainDir, slug) {
  return join(brainDir, "projects", slug, "raw");
}
function slugify(text) {
  const s = text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40);
  return s || "item";
}
function compactStamp(iso) {
  return iso.replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
}
function isBinary(buf) {
  const n = Math.min(buf.length, 8192);
  for (let i = 0; i < n; i++) if (buf[i] === 0) return true;
  return false;
}
function contentTypeForFile(path, binary) {
  const ext = extname(path).toLowerCase();
  if (binary) return ext === ".pdf" ? "application/pdf" : "application/octet-stream";
  return ext === ".md" || ext === ".markdown" ? "text/markdown" : "text/plain";
}
function fmValue(s) {
  return stripInvisible(s).replace(/[\r\n]+/g, " ");
}
function isSafeId(id) {
  return !!id && !/[\\/]|\.\./.test(id);
}
function serialize(item) {
  const fm = ["---"];
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
  fm.push("---", "", stripInvisible(item.body), "");
  return fm.join("\n");
}
function parse(content, id) {
  const m = matchFrontmatter(content);
  const base = {
    id,
    source: "",
    captured_at: "",
    captured_by: "user",
    content_type: "",
    status: "unprocessed",
    hash: "",
    gist: "",
    body: ""
  };
  if (!m) {
    return { ...base, body: content, malformed: true };
  }
  const { fm: fmText, body } = m;
  const get = (k) => {
    const mm = fmText.match(new RegExp(`^${k}:[ \\t]*(.*)$`, "m"));
    return mm ? mm[1].trim() : void 0;
  };
  const status = get("status") ?? "";
  const validStatus = status === "unprocessed" || status === "processed" || status === "discarded";
  const item = {
    id,
    // Sanitize on READ too, so items written before the sanitizer shipped (or by any
    // non-serialize path) are cleaned on the way to the drainer/wiki, not just on write.
    source: stripInvisible(get("source") ?? ""),
    captured_at: get("captured_at") ?? "",
    captured_by: get("captured_by") ?? "user",
    origin: get("origin") || void 0,
    content_type: get("content_type") ?? "",
    status: validStatus ? status : "unprocessed",
    target_node: get("target_node") || void 0,
    blob: get("blob") || void 0,
    hash: get("hash") ?? "",
    gist: stripInvisible(get("gist") ?? ""),
    body: stripInvisible(body.trim())
  };
  if (!item.source || !item.captured_at || !item.content_type || !validStatus) item.malformed = true;
  return item;
}
async function readItems(brainDir, slug) {
  const dir = rawDir(brainDir, slug);
  let names = [];
  try {
    names = (await fs.readdir(dir)).filter((n) => n.endsWith(".md"));
  } catch {
    return [];
  }
  const items = [];
  for (const name of names.sort()) {
    try {
      const content = await fs.readFile(join(dir, name), "utf-8");
      items.push(parse(content, name.replace(/\.md$/, "")));
    } catch {
    }
  }
  return items;
}
async function listItems(brainDir, slug) {
  assertSafeSlug(slug);
  return readItems(brainDir, slug);
}
function partitionPending(items, activeSlug) {
  const drainable = [];
  const foreign = [];
  for (const i of items) {
    if (i.status !== "unprocessed" || i.malformed) continue;
    if (i.origin && i.origin !== activeSlug) {
      foreign.push(i);
      continue;
    }
    drainable.push(i);
  }
  return { drainable, foreign };
}
async function unprocessedCount(brainDir, slug) {
  assertSafeSlug(slug);
  const items = await readItems(brainDir, slug);
  return items.filter((i) => i.status === "unprocessed" || i.malformed).length;
}
async function setStatus(brainDir, slug, id, status) {
  assertSafeSlug(slug);
  if (!isSafeId(id)) return false;
  const file = join(rawDir(brainDir, slug), `${id}.md`);
  let content;
  try {
    content = await fs.readFile(file, "utf-8");
  } catch {
    return false;
  }
  const next = /^status:[ \t]*.*$/m.test(content) ? content.replace(/^status:[ \t]*.*$/m, `status: ${status}`) : content.replace(FM_OPEN_RE, `---
status: ${status}
`);
  const tmp = `${file}.tmp`;
  await fs.writeFile(tmp, next);
  await fs.rename(tmp, file);
  return true;
}
async function markProcessed(brainDir, slug, id, nodeSlug) {
  assertSafeSlug(slug);
  if (!isSafeId(id)) return false;
  const file = join(rawDir(brainDir, slug), `${id}.md`);
  let content;
  try {
    content = await fs.readFile(file, "utf-8");
  } catch {
    return false;
  }
  let next = /^status:[ \t]*.*$/m.test(content) ? content.replace(/^status:[ \t]*.*$/m, "status: processed") : content.replace(FM_OPEN_RE, "---\nstatus: processed\n");
  if (nodeSlug) {
    const tn = `target_node: ${fmValue(nodeSlug)}`;
    next = /^target_node:[ \t]*.*$/m.test(next) ? next.replace(/^target_node:[ \t]*.*$/m, tn) : next.replace(/^status:[ \t]*processed$/m, `status: processed
${tn}`);
  }
  const tmp = `${file}.tmp`;
  await fs.writeFile(tmp, next);
  await fs.rename(tmp, file);
  return true;
}
async function pruneProcessed(brainDir, slug) {
  assertSafeSlug(slug);
  const dir = rawDir(brainDir, slug);
  const items = await readItems(brainDir, slug);
  let removed = 0;
  for (const i of items) {
    if (i.malformed) continue;
    if (i.status !== "processed" && i.status !== "discarded") continue;
    if (!isSafeId(i.id)) continue;
    try {
      await fs.unlink(join(dir, `${i.id}.md`));
    } catch {
      continue;
    }
    removed++;
    if (i.blob && i.blob.startsWith(`${i.id}.`) && !/[\\/]|\.\./.test(i.blob)) {
      try {
        await fs.unlink(join(dir, i.blob));
      } catch {
      }
    }
  }
  return removed;
}
async function captureItem(input) {
  assertSafeSlug(input.slug);
  const dir = rawDir(input.brainDir, input.slug);
  const now = input.now ?? (/* @__PURE__ */ new Date()).toISOString();
  const capturedBy = input.capturedBy ?? "user";
  let body = "";
  let blobBuf;
  let blobExt = "";
  let contentType = "";
  let gistSeed = "";
  let hashInput = "";
  if (input.kind === "paste") {
    body = input.content ?? "";
    contentType = "text/markdown";
    gistSeed = body;
    hashInput = `paste:${body}`;
  } else if (input.kind === "url") {
    const url = input.content ?? input.source;
    body = url;
    contentType = "text/uri-list";
    gistSeed = url;
    hashInput = `url:${url}`;
  } else {
    const buf = await fs.readFile(input.source);
    const binary = isBinary(buf);
    contentType = contentTypeForFile(input.source, binary);
    hashInput = `file:${hashContent(buf.toString("binary"))}`;
    if (binary) {
      blobBuf = buf;
      blobExt = extname(input.source) || ".bin";
      gistSeed = basename(input.source);
      body = `(binary ${contentType}; original captured as the sibling blob) \u2014 ${basename(input.source)}`;
    } else {
      body = buf.toString("utf-8");
      gistSeed = body;
    }
  }
  const hash = hashContent(hashInput);
  const gist = gistSeed.replace(/^#\s*/, "").split("\n").map((l) => l.trim()).find(Boolean)?.slice(0, 120) ?? "";
  const items = await readItems(input.brainDir, input.slug);
  const existing = items.find((i) => i.hash === hash && i.status === "unprocessed");
  if (existing) {
    return { id: existing.id, duplicate: true, unprocessed: await unprocessedCount(input.brainDir, input.slug) };
  }
  if (!blobBuf && (process.env.SB_CAPTURE_DEDUP ?? "on").toLowerCase() !== "off") {
    const tv = parseFloat(process.env.SB_CAPTURE_DEDUP_THRESHOLD ?? "");
    const thr = Number.isFinite(tv) && tv > 0 && tv <= 1 ? tv : 0.9;
    const newBody = stripInvisible(body.trim());
    const newSig = signatureOf(body);
    if (!isEmptySignature(newSig)) {
      let best;
      for (const i of items) {
        if (i.status !== "unprocessed" || i.malformed || i.blob) continue;
        const sig = signatureOf(i.body);
        if (isEmptySignature(sig) || jaccardEstimate(newSig, sig) < thr) continue;
        if (!best || i.body.length > best.body.length) best = i;
      }
      if (best) {
        if (newBody.length > best.body.length) {
          const updated = { ...best, hash, gist, body };
          const p = join(dir, `${best.id}.md`);
          const tmp2 = `${p}.tmp`;
          await fs.mkdir(dir, { recursive: true });
          await fs.writeFile(tmp2, serialize(updated));
          await fs.rename(tmp2, p);
          return { id: best.id, duplicate: true, nearDup: "updated", unprocessed: await unprocessedCount(input.brainDir, input.slug) };
        }
        return { id: best.id, duplicate: true, nearDup: "noop", unprocessed: await unprocessedCount(input.brainDir, input.slug) };
      }
    }
  }
  await fs.mkdir(dir, { recursive: true });
  const sourceSlug = input.kind === "url" ? slugify(input.content ?? input.source) : input.kind === "file" ? slugify(basename(input.source)) : slugify(body);
  const baseId = `${compactStamp(now)}-${sourceSlug}`;
  let id = baseId;
  for (let n = 2; ; n++) {
    try {
      await fs.access(join(dir, `${id}.md`));
      id = `${baseId}-${n}`;
    } catch {
      break;
    }
  }
  const blob = blobBuf ? `${id}${blobExt}` : void 0;
  if (blobBuf && blob) {
    const btmp = join(dir, `${blob}.tmp`);
    await fs.writeFile(btmp, blobBuf);
    await fs.rename(btmp, join(dir, blob));
  }
  const item = {
    id,
    source: input.source,
    captured_at: now,
    captured_by: capturedBy,
    origin: input.origin,
    content_type: contentType,
    status: "unprocessed",
    target_node: input.targetNode,
    blob,
    hash,
    gist,
    body
  };
  const file = join(dir, `${id}.md`);
  const tmp = `${file}.tmp`;
  await fs.writeFile(tmp, serialize(item));
  await fs.rename(tmp, file);
  return { id, duplicate: false, unprocessed: await unprocessedCount(input.brainDir, input.slug) };
}

// src/tools/project-dir.ts
import { basename as basename2, join as join4 } from "path";
import { readFileSync as readFileSync3, existsSync as existsSync2 } from "fs";

// src/brain-paths.ts
import { join as join2, isAbsolute } from "path";
import { homedir } from "os";
import { readFileSync, statSync, existsSync } from "fs";
function resolveBrainDir(override) {
  if (override) return override;
  return cleanEnvPath(process.env.SB_BRAIN_DIR || process.env.BRAIN_DIR) || join2(homedir(), ".second-brain");
}
function normalizeRemote(url) {
  let s = (url ?? "").replace(/\r/g, "").replace(/[A-Z]/g, (c) => c.toLowerCase()).trim();
  s = s.replace(/^[a-z+]+:\/\//, "");
  s = s.replace(/^[^@/]*@/, "");
  s = s.replace(/^([^/:]+):/, "$1/");
  return s.replace(/\/+$/, "").replace(/\.git$/, "").replace(/\/+$/, "");
}
function originRemote(dir) {
  try {
    const d = cleanEnvPath(dir);
    if (!d) return "";
    const gitPath = join2(d, ".git");
    let configDir;
    if (statSync(gitPath).isDirectory()) {
      configDir = gitPath;
    } else {
      const m = readFileSync(gitPath, "utf-8").match(/^gitdir:\s*(.+?)\s*$/m);
      if (!m) return "";
      const gd = m[1];
      configDir = isAbsolute(gd) ? gd : join2(d, gd);
      if (!existsSync(join2(configDir, "config"))) {
        const cd = readFileSync(join2(configDir, "commondir"), "utf-8").trim();
        configDir = isAbsolute(cd) ? cd : join2(configDir, cd);
      }
    }
    const cfg = readFileSync(join2(configDir, "config"), "utf-8");
    let inOrigin = false;
    for (const line of cfg.split("\n")) {
      const t = line.trim();
      if (t.startsWith("[")) {
        inOrigin = /^\[remote\s+"origin"\]/.test(t);
        continue;
      }
      if (!inOrigin) continue;
      const mu = t.match(/^url\s*=\s*(.+)$/);
      if (mu) return mu[1].trim();
    }
    return "";
  } catch {
    return "";
  }
}

// src/tools/project-registry.ts
import { readFileSync as readFileSync2 } from "fs";
import { join as join3 } from "path";
function loadRegistry(brainDir) {
  let text;
  try {
    text = readFileSync2(join3(brainDir, "projects.jsonl"), "utf-8");
  } catch {
    return [];
  }
  const out = [];
  for (const line of text.split("\n")) {
    const s = line.trim();
    if (!s) continue;
    try {
      const r = JSON.parse(s);
      if (r && typeof r.slug === "string" && r.slug) out.push(r);
    } catch {
    }
  }
  return out;
}
function resolveSlugByPath(brainDir, dir) {
  const norm = (p) => {
    let s = cleanEnvPath(p).replace(/\\/g, "/");
    const drive = s.match(/^([A-Za-z]):\//);
    if (drive) s = "/" + drive[1].toLowerCase() + s.slice(2);
    return s.replace(/\/+$/, "");
  };
  const target = norm(dir);
  let best;
  for (const r of loadRegistry(brainDir)) {
    if (!r.root_path) continue;
    const rp = norm(r.root_path);
    if (target === rp || target.startsWith(rp + "/")) {
      if (!best || rp.length > best.len) best = { slug: r.slug, len: rp.length };
    }
  }
  return best?.slug;
}
function resolveSlugByRemote(brainDir, rawRemote) {
  const want = normalizeRemote(rawRemote);
  if (!want) return void 0;
  const matches = loadRegistry(brainDir).filter(
    (r) => typeof r.git_remote === "string" && r.git_remote !== "" && normalizeRemote(r.git_remote) === want
  );
  if (matches.length === 0) return void 0;
  const base = want.replace(/.*\//, "");
  const byBase = matches.find((r) => r.slug === base);
  if (byBase) return byBase.slug;
  return matches.reduce((a, b) => (b.last_session_iso ?? "") > (a.last_session_iso ?? "") ? b : a).slug;
}

// src/tools/project-dir.ts
function slugFromProjectDir(dir) {
  if (!dir) return void 0;
  const base = basename2(cleanEnvPath(dir));
  if (!base || base === "/" || base === "." || base === "..") return void 0;
  if (/^tmp\.|^tmp$|^\.tmp\.|^tmpfs$/.test(base)) return "scratch";
  return base;
}
function remoteIdentitySlug(brainDir, dir) {
  const url = originRemote(dir);
  if (!url) return void 0;
  return resolveSlugByRemote(brainDir, url);
}
function logRemoteOverride(dir, base, slug) {
  try {
    console.error(JSON.stringify({ event: "remote-identity-override", dir, basename: base, slug }));
  } catch {
  }
}
function resolveActiveSlug(brainDir, env = process.env, cwd = process.cwd) {
  if (env.CLAUDE_PROJECT_DIR) {
    const byPath = resolveSlugByPath(brainDir, env.CLAUDE_PROJECT_DIR);
    if (byPath) return byPath;
    const fromEnv = slugFromProjectDir(env.CLAUDE_PROJECT_DIR);
    if (fromEnv) {
      const byRemote = remoteIdentitySlug(brainDir, env.CLAUDE_PROJECT_DIR);
      if (byRemote && byRemote !== fromEnv) {
        logRemoteOverride(env.CLAUDE_PROJECT_DIR, fromEnv, byRemote);
        return byRemote;
      }
      return fromEnv;
    }
  }
  const here = cwd();
  const byCwdPath = resolveSlugByPath(brainDir, here);
  if (byCwdPath) return byCwdPath;
  const cwdSlug = slugFromProjectDir(here);
  if (cwdSlug) {
    const byRemote = remoteIdentitySlug(brainDir, here);
    if (byRemote && byRemote !== cwdSlug) {
      logRemoteOverride(here, cwdSlug, byRemote);
      return byRemote;
    }
  }
  if (cwdSlug && existsSync2(join4(brainDir, "projects", cwdSlug, "PROJECT.md"))) return cwdSlug;
  try {
    const pin = readFileSync3(join4(brainDir, ".active-session-slug"), "utf-8").trim();
    if (pin && existsSync2(join4(brainDir, "projects", pin, "PROJECT.md"))) return pin;
  } catch {
  }
  return cwdSlug;
}

// src/tools/raw-capture-cli.ts
function resolveSlug(brainDir, flagSlug) {
  return flagSlug || process.env.SB_ACTIVE_SLUG || resolveActiveSlug(brainDir);
}
function takeFlag(args, name) {
  const flag = `--${name}`;
  const i = args.indexOf(flag);
  if (i >= 0 && args[i + 1]) return { rest: [...args.slice(0, i), ...args.slice(i + 2)], value: args[i + 1] };
  return { rest: args };
}
function takeNode(args) {
  const { rest, value } = takeFlag(args, "node");
  return { rest, node: value };
}
function captureVerb(r) {
  if (r.nearDup === "updated") return "Updated near-duplicate (kept the longer version) \u2014";
  if (r.nearDup === "noop") return "Skipped near-duplicate of";
  return r.duplicate ? "Already captured" : "Captured";
}
async function main() {
  const brainDir = resolveBrainDir();
  const { rest: argvAfterSlug, value: flagSlug } = takeFlag(process.argv.slice(2), "slug");
  const slug = resolveSlug(brainDir, flagSlug);
  if (!slug) {
    console.log("capture: could not resolve the active project (no slug). cd into a project or pass --slug <project>.");
    return;
  }
  const action = argvAfterSlug[0];
  const { rest, node } = takeNode(argvAfterSlug.slice(1));
  try {
    if (action === "list") {
      const items = await listItems(brainDir, slug);
      const open = items.filter((i) => i.status === "unprocessed" || i.malformed).length;
      console.log(`Raw inbox for ${slug} \u2014 ${items.length} item(s), ${open} unprocessed:`);
      for (const i of items) {
        console.log(`  - ${i.id} [${i.malformed ? "malformed" : i.status}] ${i.gist || i.source}`);
      }
      if (items.length === 0) console.log("  (empty \u2014 capture something, e.g. /second-brain:capture ./notes.md)");
    } else if (action === "discard") {
      const id = rest[0];
      if (!id) {
        console.log("usage: capture [--slug <project>] discard <id>");
        return;
      }
      console.log(await setStatus(brainDir, slug, id, "discarded") ? `Discarded ${id}.` : `No raw item with id ${id}.`);
    } else if (action === "prune-processed") {
      const n = await pruneProcessed(brainDir, slug);
      console.log(`Pruned ${n} processed/discarded item(s) from ${slug} (audit-trail cleanup; unprocessed + malformed kept).`);
    } else if (action === "pending") {
      const { drainable, foreign } = partitionPending(await listItems(brainDir, slug), slug);
      for (const i of drainable) {
        const path = join5(rawDir(brainDir, slug), `${i.id}.md`).replace(/\\/g, "/");
        const cell = (s) => (s || "").replace(/[\t\r\n]+/g, " ");
        console.log([i.id, path, i.captured_by, cell(i.target_node ?? ""), cell(i.gist)].join("	"));
      }
      if (foreign.length) {
        console.error(`pending: held back ${foreign.length} foreign-origin item(s) (origin\u2260${slug}): ${foreign.map((i) => i.id).join(", ")} \u2014 re-capture in the right project or /second-brain:capture --discard <id>`);
      }
    } else if (action === "process") {
      const id = rest[0];
      if (!id) {
        console.log("usage: capture [--slug <project>] process <id> [--node <slug>]");
        return;
      }
      console.log(await markProcessed(brainDir, slug, id, node) ? `Processed ${id}` : `No raw item with id ${id}.`);
    } else if (action === "paste") {
      const content = readFileSync4(0, "utf-8");
      if (!content.trim()) {
        console.log("capture: nothing on stdin.");
        return;
      }
      const r = await captureItem({ brainDir, slug, kind: "paste", source: "paste", content, targetNode: node, origin: slug });
      console.log(`${captureVerb(r)} ${r.id} \u2014 ${r.unprocessed} unprocessed.`);
    } else if (action === "capture") {
      const src = rest[0];
      if (!src) {
        console.log("usage: capture [--slug <project>] <path|url> [--node <slug>]  |  capture paste");
        return;
      }
      let kind;
      let content;
      let source = src;
      if (/^https?:\/\//i.test(src)) {
        kind = "url";
        content = src;
      } else if (existsSync3(src) && statSync2(src).isFile()) {
        kind = "file";
      } else {
        kind = "paste";
        content = src;
        source = "paste";
      }
      const r = await captureItem({ brainDir, slug, kind, source, content, targetNode: node, origin: slug });
      console.log(`${captureVerb(r)} ${r.id} (${kind}) \u2014 ${r.unprocessed} unprocessed.`);
    } else {
      const n = await unprocessedCount(brainDir, slug);
      console.log(`usage: capture [--slug <project>] <path|url> | capture paste | capture list | capture discard <id> | capture pending | capture process <id> | capture prune-processed  (${n} unprocessed)`);
    }
  } catch (e) {
    console.log(`capture error: ${e instanceof Error ? e.message : String(e)}`);
  }
}
main();
