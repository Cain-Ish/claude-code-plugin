/**
 * Embedding-free near-duplicate detection for wiki prose. Word k-shingles -> MinHash signature
 * -> Jaccard estimate. Fully DETERMINISTIC (fixed hash seeds, integer-only via Math.imul; no
 * Math.random / no float drift) so the same corpus yields byte-identical signatures on every OS
 * and every run — the redundancy signal feeding the dream DEDUPLICATE merge-candidate surfacing
 * and the FORGET redundancy gate. Pure module, no I/O, no native deps. Reuses the shared djb2
 * primitive + the prose strippers so "what counts as prose" never drifts from the FORGET scorer /
 * search. Spec: 2026-06-26 constitution-and-diet P4 (redundancy/importance forgetting).
 */
import { djb2 } from './graph-cluster.js';
import { stripAiBlock } from './ai-block.js';
import { stripInvisible } from './sanitize.js';

export const SHINGLE_K = 3;     // word 3-grams — the prose near-duplicate sweet spot
export const NUM_HASHES = 128;  // signature length; Jaccard standard error ≤ 1/(2·sqrt(128)) ≈ 0.044 (max at J=0.5)
const EMPTY_HASH = 0xffffffff;  // per-position sentinel = no shingle ever lowered this slot

// NUM_HASHES fixed (a, b) pairs deriving independent hashes from one base hash via the
// universal-hashing family h_i(x) = (a_i * base(x) + b_i) mod 2^32. Generated once from a
// fixed-seed LCG — NO Math.random, so identical on every platform/run (cross-platform determinism).
const A = new Uint32Array(NUM_HASHES);
const B = new Uint32Array(NUM_HASHES);
{
  let seed = 0x9e3779b1 >>> 0; // golden-ratio constant
  const nextRand = (): number => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed; };
  for (let i = 0; i < NUM_HASHES; i++) { A[i] = (nextRand() | 1) >>> 0; B[i] = nextRand() >>> 0; } // a_i forced odd
}

/** Strip everything that is NOT authored prose so structure can't dominate similarity: invisibles,
 *  the ai:begin / theme:begin / graph:begin marked regions, YAML frontmatter, and [[wiki-link]]
 *  markup. Then lowercase to alnum word tokens. */
export function proseTokens(content: string): string[] {
  let t = stripAiBlock(stripInvisible(content));
  t = t.replace(/^---\r?\n[\s\S]*?\r?\n---/, '');                  // YAML frontmatter
  t = t.replace(/<!--\s*theme:begin[\s\S]*?theme:end\s*-->/g, ''); // generated theme region
  t = t.replace(/<!--\s*graph:begin[\s\S]*?graph:end\s*-->/g, ''); // projected dependencies region
  t = t.replace(/\[\[([^\]]+)\]\]/g, ' ');                         // drop link markup (structure, not prose)
  return t.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
}

/** Word k-shingle SET. A page shorter than k words collapses to one whole-text shingle, so two
 *  identical short pages still match while two different short pages do not. */
export function shingles(content: string, k: number = SHINGLE_K): Set<string> {
  const w = proseTokens(content);
  const set = new Set<string>();
  if (w.length === 0) return set;
  if (w.length < k) { set.add(w.join(' ')); return set; }
  for (let i = 0; i + k <= w.length; i++) set.add(w.slice(i, i + k).join(' '));
  return set;
}

/** 32-bit base hash of a shingle, via the shared djb2 primitive (base36 string -> uint32, lossless
 *  because djb2 emits an unsigned 32-bit value < 2^32 which round-trips exactly through Number). */
function baseHash(shingle: string): number { return parseInt(djb2(shingle), 36) >>> 0; }

/** MinHash signature: for each of NUM_HASHES hash functions, the min hash over the shingle set.
 *  Empty set -> all 0xFFFFFFFF (equal only to another empty set; callers skip blank pages). */
export function minhashSignature(shingleSet: Set<string>): Uint32Array {
  const sig = new Uint32Array(NUM_HASHES).fill(EMPTY_HASH);
  for (const sh of shingleSet) {
    const base = baseHash(sh);
    for (let i = 0; i < NUM_HASHES; i++) {
      const h = (Math.imul(A[i], base) + B[i]) >>> 0; // 32-bit integer arithmetic — no float precision loss
      if (h < sig[i]) sig[i] = h;
    }
  }
  return sig;
}

/** Convenience: page content -> signature. */
export function signatureOf(content: string): Uint32Array { return minhashSignature(shingles(content)); }

/** Estimated Jaccard similarity = fraction of signature positions that agree (0..1). */
export function jaccardEstimate(a: Uint32Array, b: Uint32Array): number {
  const n = Math.min(a.length, b.length);
  if (n === 0) return 0;
  let eq = 0;
  for (let i = 0; i < n; i++) if (a[i] === b[i]) eq++;
  return eq / n;
}

export interface PageSig { slug: string; cat: string; sig: Uint32Array; }
export interface DupPair { a: string; b: string; sim: number; a_cat: string; b_cat: string; }

/** True when a signature is all-sentinel — the page had ZERO prose shingles (a frontmatter/ai-block-
 *  only stub). Such pages are NOT duplicate candidates: two DISTINCT empty-prose stubs would otherwise
 *  collide at sim 1.0 and drive false merges. (A real page producing an all-sentinel signature would
 *  require every one of NUM_HASHES positions to hash to 2^32-1 — probability 2^-4096 — so this
 *  reliably means "no shingles", not "unlucky content".) */
export function isEmptySignature(sig: Uint32Array): boolean {
  if (sig.length === 0) return true;
  for (let i = 0; i < sig.length; i++) if (sig[i] !== EMPTY_HASH) return false;
  return true;
}

/** All-pairs near-duplicate detection (O(n^2) Jaccard estimates — fine for a single-dev wiki of
 *  ~hundreds of pages; LSH banding is the documented scale path). Prose-empty pages are dropped
 *  first (defense-in-depth vs the empty-signature collision; callers should skip them before hashing
 *  too). Emits each pair once with the lexicographically-smaller slug as `a`, sorted by similarity
 *  desc then slug — fully deterministic. */
export function nearDuplicatePairs(pages: PageSig[], threshold = 0.7): DupPair[] {
  const real = pages.filter((p) => !isEmptySignature(p.sig));
  const out: DupPair[] = [];
  for (let i = 0; i < real.length; i++) {
    for (let j = i + 1; j < real.length; j++) {
      const sim = jaccardEstimate(real[i].sig, real[j].sig);
      if (sim < threshold) continue;
      const [p, q] = real[i].slug <= real[j].slug ? [real[i], real[j]] : [real[j], real[i]];
      out.push({ a: p.slug, b: q.slug, sim: Math.round(sim * 1000) / 1000, a_cat: p.cat, b_cat: q.cat });
    }
  }
  out.sort((x, y) => y.sim - x.sim || (x.a < y.a ? -1 : x.a > y.a ? 1 : x.b < y.b ? -1 : x.b > y.b ? 1 : 0));
  return out;
}
