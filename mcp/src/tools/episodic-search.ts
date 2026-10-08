import { promises as fs } from 'fs';
import { atomicWriteJsonStrict } from './atomic-write.js';
import { join, basename, relative, isAbsolute } from 'path';
import { embedTexts, appendErrorLog, embeddingsOptedOut, EMBEDDING_DIM } from './embeddings.js';
import { assertWithin } from '../path-guard.js';
import { stripInvisible } from './sanitize.js';
import { capList, estimateTokens } from './egress-budget.js';

const INDEX_FILE = 'episodic-index.json';
const SNIPPET_LEN = 200;
const DEFAULT_LIMIT = 10;
const MAX_LIMIT = 30;
const EMBEDDING_TEXT_CAP = 512;

export interface EpisodicSearchArgs {
  query: string | string[];
  mode?: 'vector' | 'text' | 'both';
  limit?: number;
  /** Hard filter — return only this project's exchanges. Wins over activeProject. */
  project?: string;
  /**
   * Soft default scope (SP-1 parity for the episodic tier): prefer same-project
   * exchanges and suppress other-project noise, broadening only when the active
   * project has no in-scope hit. Callers (MCP handler, per-prompt CLI) populate
   * this from the resolved active slug so episodic recall stops leaking across
   * projects. An explicit `project` (incl. "all"→omit) overrides it.
   */
  activeProject?: string;
  after?: string;
  before?: string;
  /** Drop this session's own rows (the per-prompt hook: they are already in context). Applied
   *  with the other filters, BEFORE ranking, scoping and the limit slice. */
  excludeSessionId?: string;
  /** Drop rows with no human words on the user side (cleaned machine turns, and parser-1 rows
   *  still holding raw boilerplate). Same placement as excludeSessionId. */
  requireUserText?: boolean;
  /** Drop ranked hits under this similarity BEFORE project scoping and the limit slice, so a
   *  sub-floor in-scope vector hit cannot stand in for a real one and block broadening. */
  minSimilarity?: number;
}

export interface EpisodicSearchResult {
  results: {
    sessionId: string;
    project: string;
    date: string;
    userSnippet: string;
    assistantSnippet: string;
    similarity: number;
    archivePath: string;
    lineStart: number;
    lineEnd: number;
  }[];
  /** Present when vector search was requested but unavailable (no embeddings /
   *  model missing): 'text-only' = text matching ran as the fallback (mode
   *  'both'); 'vector-unavailable' = nothing could run (explicit vector mode /
   *  multi-concept) (R2.3). */
  degraded?: 'text-only' | 'vector-unavailable';
}

export interface EpisodicReadResult {
  content: string;
  sessionId: string;
  project: string;
  date: string;
}

interface SessionMeta {
  sessionId: string;
  project: string;
  date: string;
}

interface Exchange {
  id: string;
  sessionId: string;
  project: string;
  date: string;
  userMessage: string;
  assistantMessage: string;
  archivePath: string;
  lineStart: number;
  lineEnd: number;
}

/** One stored vector (R2#6, 0.56.0): `e8` holds the int8 components, base64, and `es` the
 *  per-vector scale, so component i = es * int8[i]. A float JSON array cost ~8 KB of index text
 *  per row, and the index is parsed on every prompt; this costs ~550 characters. */
export interface CompactVector { e8: string; es: number }

/** A row with no vector yet (the model was unavailable) has neither e8 nor es. */
interface IndexedExchange extends Partial<CompactVector> {
  id: string;
  sessionId: string;
  project: string;
  date: string;
  userSnippet: string;
  assistantSnippet: string;
  archivePath: string;
  lineStart: number;
  lineEnd: number;
}

/** A row as any writer stored it: before 0.56.0 the vector was a float array (`[]` = none). */
type StoredExchange = IndexedExchange & { embedding?: unknown };

/** Symmetric int8: es = max|x| / 127, component = round(x / es). Rounding error is at most es/2
 *  per component. A zero vector stores es = 0. Callers pass finite components (the build checks
 *  before storing): a NaN would quantize to 0 and an Infinity would make es Infinity. */
export function quantizeEmbedding(vec: ArrayLike<number>): CompactVector {
  let maxAbs = 0;
  for (let i = 0; i < vec.length; i++) {
    const a = Math.abs(vec[i]);
    if (a > maxAbs) maxAbs = a;
  }
  const es = maxAbs / 127;
  const q = new Int8Array(vec.length);
  if (es > 0) for (let i = 0; i < vec.length; i++) q[i] = Math.max(-127, Math.min(127, Math.round(vec[i] / es)));
  return { e8: Buffer.from(q.buffer, q.byteOffset, q.byteLength).toString('base64'), es };
}

function decodeE8(e8: string): Int8Array {
  const b = Buffer.from(e8, 'base64');
  return new Int8Array(b.buffer, b.byteOffset, b.byteLength);
}

function dotDequantized(query: ArrayLike<number>, v: Int8Array, es: number): number {
  let dot = 0;
  const n = Math.min(query.length, v.length);
  for (let i = 0; i < n; i++) dot += query[i] * v[i];
  return dot * es;
}

/** The legacy score (embeddings.ts cosineSimilarity: a dot product, the model's vectors being
 *  normalized) against the dequantized row vector. */
export function embeddingSimilarity(query: ArrayLike<number>, row: CompactVector): number {
  return dotDequantized(query, decodeE8(row.e8), row.es);
}

function hasVector(e: IndexedExchange): e is IndexedExchange & CompactVector {
  return typeof e.e8 === 'string' && e.e8.length > 0;
}

/** A stored row in the current shape. A float row (a pre-0.56.0 writer) is quantized here, in
 *  memory; the build that loaded it writes it back compact, so the migration runs once and needs
 *  no model. A vector that is not EMBEDDING_DIM finite components is dropped (`dropped`, so the
 *  build can log it) and its row re-embeds like any row without one. */
function currentRow(stored: StoredExchange): { row: IndexedExchange; dropped: boolean } {
  const { embedding, e8, es, ...row } = stored;
  if (typeof e8 === 'string' && e8) {
    const ok = typeof es === 'number' && Number.isFinite(es) && es >= 0 && decodeE8(e8).length === EMBEDDING_DIM;
    return ok ? { row: { ...row, e8, es }, dropped: false } : { row, dropped: true };
  }
  if (Array.isArray(embedding) && embedding.length > 0) {
    const ok = embedding.length === EMBEDDING_DIM && embedding.every(x => typeof x === 'number' && Number.isFinite(x));
    return ok ? { row: { ...row, ...quantizeEmbedding(embedding) }, dropped: false } : { row, dropped: true };
  }
  return { row, dropped: false };
}

/** Per-file index state. A bare string is the pre-version format (parser 1): re-parsed. */
type IndexedFileEntry = string | { hash: string; parser: number };

interface EpisodicIndex {
  model: string;
  indexed_files: Record<string, IndexedFileEntry>;
  exchanges: IndexedExchange[];
}

/** Bumped whenever parseExchanges changes what it stores for the same archive. Every file
 *  indexed by an older (or unversioned) parser is re-parsed once on the next build. Row ids
 *  derive from archivePath + line range, so a re-parse keeps ids as long as exchange
 *  boundaries do not move — the hygiene tests pin them.
 *  2 = machine-turn user text cleaned (R1#3, 2026-10).
 *  3 = harness tags are an allowlist (no generic <x-… rule), image/interrupt prefix lines are
 *      stripped with the human text after them kept, and a peer body keeps its provenance
 *      marker and harness flag line (R1 review, 2026-10). */
export const EPISODIC_PARSER_VERSION = 3;

function isCurrentEntry(entry: IndexedFileEntry | undefined, hash: string): boolean {
  return typeof entry === 'object' && entry !== null
    && entry.hash === hash && entry.parser >= EPISODIC_PARSER_VERSION;
}

// --- Machine-turn text (shared contract with scripts/persona-context.sh) --------------------
// The hook skips retrieval on these prompts (`# machine-turn:begin/end` block); the archive side
// cleans them out of the episodic user text. episodic-hygiene.test.ts locks the parity: every
// quoted prefix in the hook block must satisfy isMachineTurnText.
const PEER_PREFIX = 'Another Claude session sent a message:';
/** The harness tags a machine-written turn opens with: an ALLOWLIST, the same one the hook's
 *  `case` carries. Never "any leading <x-…" tag: that blanked human prompts such as
 *  "<my-component> doesn't render", "<v-btn …>", "<router-view/>" (R1 review). Over 400 real
 *  transcripts every leading hyphenated tag was one of these families. Human pastes use
 *  <pasted_content (underscore). */
export const MACHINE_TAG_PREFIXES: readonly string[] = [
  '<task-notification>',
  '<system-reminder>',
  '<agent-message',
  '<cross-session-message',
  '<command-',          // command-name, command-message, command-args
  '<local-command-',    // local-command-stdout, local-command-caveat, …
  '<bash-',             // bash-input, bash-stdout, bash-stderr (the ! shell mode)
];
const MACHINE_TURN_PREFIXES = [
  ...MACHINE_TAG_PREFIXES,
  PEER_PREFIX,
  'Stop hook feedback:',
  'This session is being continued from a previous conversation',
  // Archive-only: the harness writes these as user turns, but they never reach the hook as a prompt.
  'Base directory for this skill:',
  'Caveat: The messages below were generated',
];
// Archive-only LINE prefixes the harness puts in front of a human prompt (a pasted image, an
// interrupt). Only these lines are machine; the human text after them is kept.
const MACHINE_LINE_PREFIXES = ['[Image: source:', '[Image: original', '[Request interrupted by user'];

function stripLead(text: string): string {
  return text.replace(/^[\s﻿]+/, '');
}

export function isMachineTurnText(text: string): boolean {
  const t = stripLead(text);
  return MACHINE_TURN_PREFIXES.some(p => t.startsWith(p)) || MACHINE_LINE_PREFIXES.some(p => t.startsWith(p));
}

/** Provenance markers a cleaned peer body is stored with (security review): the body is never
 *  the user's words, so it must never read as them once its wrapper is gone. */
export const SUBAGENT_REPORT_MARK = '(subagent report) ';
export const PEER_MESSAGE_MARK = '(peer message) ';

/** Peer message (subagent hand-back or cross-session): drop the header, the wrapper tag pair,
 *  the hand-back preamble and anything after the closing tag; keep the report body, prefixed with
 *  its provenance marker, plus any `[harness: …]` flag line (folded, so it opens no frame). */
function peerReportBody(rest: string): string {
  const lines = rest.split('\n');
  let i = 0;
  while (i < lines.length && !lines[i].trim()) i++;
  const open = lines[i]?.trim().match(/^<([a-z]+(?:-[a-z]+)+)\b[^>]*>(.*)$/);
  let body: string[];
  if (open) {
    const close = `</${open[1]}>`;
    body = [open[2], ...lines.slice(i + 1)];
    const end = body.findIndex(l => l.trim().startsWith(close));
    if (end >= 0) body = body.slice(0, end);
  } else {
    body = lines.slice(i);
  }
  const flags: string[] = [];
  let j = 0;
  for (; j < body.length; j++) {
    const l = body[j].trim();
    if (!l || l.startsWith('[Subagent hand-back]')) continue;
    if (l.startsWith('[harness:')) { flags.push(foldServedSnippet(l)); continue; }
    break;
  }
  const report = body.slice(j).join('\n').trim();
  if (!report) return '';
  const mark = open?.[1] === 'agent-message' ? SUBAGENT_REPORT_MARK : PEER_MESSAGE_MARK;
  // Report first, flag after: the served bullet (80 chars) and the dedup key (60) read the start,
  // so a leading flag made every flagged report the same boilerplate line. The 200-char snippet
  // can cut the flag off a long report; the marker in front is what carries the provenance.
  return mark + [report, ...flags].join('\n');
}

// Serve-time fold, the TS twin of session-load.sh's card fold (sb_card_trunc) and protocol-guard.sh's
// item fold, so a stored snippet can never close the hook's "[End untrusted reference]" frame or
// start a line that reads as a new turn:
//  - every control (C0, DEL, C1), format character (\p{Cf}: bidi controls, zero-width characters,
//    soft hyphen, BOM), Unicode space (\p{Zs}) and line/paragraph separator becomes a space, except
//    ZWNJ/ZWJ (U+200C/U+200D), which are part of the text in many scripts and in emoji sequences
//    and break no line (review 2, P-T7);
//  - every opening/closing bracket becomes a parenthesis: \p{Ps}/\p{Pe}, the bracket-shaped initial
//    and final punctuation (\p{Pi}/\p{Pf} in U+2E02-2E21), and the look-alikes Unicode files as
//    symbols (FOLD_OPEN_EXTRA/FOLD_CLOSE_EXTRA). A fixed lookalike list missed whole blocks (X7:
//    U+298B/298C passed; review 2: U+2E0C/2E0D and the corner pieces passed). Kept as they are:
//    ASCII ( ) { } (they cannot pass for the frame's square brackets, and code in a snippet stays
//    readable) and the quotation marks (FOLD_QUOTE_KEEP), which are quotes, not brackets;
//  - the frame's own phrase "untrusted reference" becomes "untrusted-reference" however it is
//    spelled (neutraliseFramePhrase: fullwidth, mathematical, accented, confusable, split by spaces,
//    punctuation or invisible characters). The bash fold maps two Cyrillic letters everywhere; here
//    only the span that spells the phrase changes, so other text is left intact.
// No literal non-ASCII character and no escape sequence a tool could decode: the code points are
// built with String.fromCodePoint, U+2028/2029 are \p{Zl}/\p{Zp}.
const cps = (...xs: number[]): string => String.fromCodePoint(...xs);
const ZWNJ = cps(0x200c), ZWJ = cps(0x200d);
const FOLD_SPACE_RE = /[\p{Cc}\p{Cf}\p{Zs}\p{Zl}\p{Zp}]/gu;
// The square-bracket pieces (U+23A1-23A6, math symbols), the corner brackets U+231C-231F, the
// dentistry bracket pieces U+23BE/23BF/23CB/23CC and the light box-drawing corners and tees, by the
// side of the bracket each one looks like.
const FOLD_OPEN_EXTRA = cps(0x23a1, 0x23a2, 0x23a3, 0x231c, 0x231e, 0x23be, 0x23bf, 0x250c, 0x2514, 0x251c);
const FOLD_CLOSE_EXTRA = cps(0x23a4, 0x23a5, 0x23a6, 0x231d, 0x231f, 0x23cb, 0x23cc, 0x2510, 0x2518, 0x2524);
const FOLD_OPEN_RE = new RegExp(`[\\p{Ps}\\p{Pi}${FOLD_OPEN_EXTRA}]`, 'gu');
const FOLD_CLOSE_RE = new RegExp(`[\\p{Pe}\\p{Pf}${FOLD_CLOSE_EXTRA}]`, 'gu');
// Quotation marks filed as Ps/Pe (U+201A, U+201E, U+2E42, U+301D-301F) and every Pi/Pf below U+2E00
// (U+00AB/00BB, U+2018-201F, U+2039/203A): folding U+2019 would turn every "don't" into "don)t".
const FOLD_QUOTE_KEEP = new Set(cps(0x201a, 0x201e, 0x2e42, 0x301d, 0x301e, 0x301f,
  0xab, 0xbb, 0x2018, 0x2019, 0x201b, 0x201c, 0x201d, 0x201f, 0x2039, 0x203a));

// The phrase test runs on a skeleton of the text, one code point at a time: compatibility
// decomposition (NFKD: fullwidth and mathematical letters, ligatures, long s, accented letters),
// lowercase, the confusable letters below mapped to the Latin letter they pass for, and everything
// that is not a letter or a digit dropped (combining marks, format characters such as the soft
// hyphen and ZWJ, spaces, punctuation, symbols). Where the skeleton holds "untrustedreference", the
// span of the text it came from becomes "untrusted-reference" (review 2, P-S3/P-T2).
// Confusables: only those of the phrase's letters that NFKD leaves alone, as they read after
// lowercasing (Greek, Cyrillic, Armenian, Latin small capitals, Lisu).
const FRAME_PHRASE_SKELETON = 'untrustedreference';
const CONFUSABLE = new Map<string, string>();
for (const [latin, from] of [
  ['c', [0x441, 0x3c2, 0x3c3, 0x1d04, 0xa4da]],
  ['d', [0x501, 0x1d05, 0xa4d3]],
  ['e', [0x435, 0x3b5, 0x454, 0x1d07, 0xa4f0]],
  ['f', [0x3dd, 0xa730, 0xa4dd]],
  ['n', [0x3b7, 0x3bd, 0x43f, 0x578, 0x274, 0xa4e0]],
  ['r', [0x433, 0x280, 0x27e, 0xa4e3]],
  ['s', [0x455, 0xa731, 0xa4e2]],
  ['t', [0x3c4, 0x442, 0x1d1b, 0xa4d4]],
  ['u', [0x3c5, 0x57d, 0x1d1c, 0x28b, 0xa4f4]],
] as [string, number[]][]) {
  for (const c of from) CONFUSABLE.set(cps(c), latin);
}
const LETTER_OR_DIGIT_RE = /^[\p{L}\p{N}]$/u;
const SKELETON_CACHE = new Map<number, string>();

function skeletonOf(ch: string): string {
  const c = ch.codePointAt(0) ?? 0;
  if (c < 0x80) {   // ASCII: letters lowercased, digits kept, the rest dropped
    if ((c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39)) return ch;
    return c >= 0x41 && c <= 0x5a ? String.fromCharCode(c + 0x20) : '';
  }
  let s = SKELETON_CACHE.get(c);
  if (s === undefined) {
    s = '';
    for (const d of ch.normalize('NFKD').toLowerCase().normalize('NFKD')) {
      const m = CONFUSABLE.get(d) ?? d;
      if (LETTER_OR_DIGIT_RE.test(m)) s += m;
    }
    if (SKELETON_CACHE.size < 4096) SKELETON_CACHE.set(c, s);
  }
  return s;
}

/** The text with every span whose skeleton spells "untrustedreference" replaced by
 *  "untrusted-reference"; the text itself when there is none (the common case: one pass). */
function neutraliseFramePhrase(text: string): string {
  let skeleton = '';
  for (const ch of text) skeleton += skeletonOf(ch);
  if (!skeleton.includes(FRAME_PHRASE_SKELETON)) return text;
  // Second pass: for each skeleton character, the [start, end) of the code point it came from.
  const start: number[] = [], end: number[] = [];
  let i = 0;
  for (const ch of text) {
    const n = skeletonOf(ch).length;
    for (let k = 0; k < n; k++) { start.push(i); end.push(i + ch.length); }
    i += ch.length;
  }
  let out = '', last = 0;
  for (let j = skeleton.indexOf(FRAME_PHRASE_SKELETON); j >= 0;
    j = skeleton.indexOf(FRAME_PHRASE_SKELETON, j + FRAME_PHRASE_SKELETON.length)) {
    out += `${text.slice(last, Math.max(start[j], last))}untrusted-reference`;
    last = end[j + FRAME_PHRASE_SKELETON.length - 1];
  }
  return out + text.slice(last);
}

export function foldServedSnippet(text: string): string {
  return neutraliseFramePhrase(text
    .replace(FOLD_SPACE_RE, (m) => (m === ZWNJ || m === ZWJ ? m : ' '))
    .replace(FOLD_OPEN_RE, (m) => (m === '(' || m === '{' || FOLD_QUOTE_KEEP.has(m) ? m : '('))
    .replace(FOLD_CLOSE_RE, (m) => (m === ')' || m === '}' || FOLD_QUOTE_KEEP.has(m) ? m : ')')));
}

/** The user line of an episodic_search MCP result. A row with no human words is never shown as
 *  **User**: a peer body is labelled by its marker, a cleaned machine row is `[machine turn]`.
 *  Legacy rows (an older parser's raw text) are re-cleaned first. */
export function episodeUserLine(userSnippet: string): string {
  const u = cleanUserText(userSnippet).trim();
  if (!u) return '[machine turn]';
  if (u.startsWith(SUBAGENT_REPORT_MARK)) return `**Subagent report**: ${foldServedSnippet(u.slice(SUBAGENT_REPORT_MARK.length))}`;
  if (u.startsWith(PEER_MESSAGE_MARK)) return `**Peer message**: ${foldServedSnippet(u.slice(PEER_MESSAGE_MARK.length))}`;
  return `**User**: ${foldServedSnippet(u)}`;
}

/** The user side of an exchange as the episodic index stores it. Human text is returned
 *  unchanged; machine boilerplate becomes ''; a peer message keeps only its report body,
 *  which is real content. The assistant side is never passed through here. */
export function cleanUserText(text: string): string {
  if (!isMachineTurnText(text)) return text;
  const t = stripLead(text);
  if (MACHINE_LINE_PREFIXES.some(p => t.startsWith(p))) {
    // Drop the leading image/interrupt lines, then clean what follows in turn (it may itself be
    // boilerplate). The remainder is strictly shorter, so this terminates.
    const lines = t.split('\n');
    let i = 0;
    while (i < lines.length && (!lines[i].trim() || MACHINE_LINE_PREFIXES.some(p => stripLead(lines[i]).startsWith(p)))) i++;
    const rest = lines.slice(i).join('\n').trim();
    return rest ? cleanUserText(rest) : '';
  }
  if (t.startsWith(PEER_PREFIX)) return peerReportBody(t.slice(PEER_PREFIX.length));
  return '';
}

export interface ServeOpts { sessionId: string; minSimilarity: number; max: number }

/** Rows the per-prompt hook may show (context-serve-cli), in ranked order: the user side is
 *  re-cleaned (rows from an older parser still carry raw boilerplate until their file is
 *  re-parsed); rows with no human words, rows from the live session (already in context, so an
 *  echo) and rows under the similarity floor are dropped; duplicate openings collapse; capped. */
export function servableEpisodes<R extends { sessionId: string; userSnippet: string; similarity: number }>(
  rows: R[], o: ServeOpts,
): R[] {
  const seen = new Set<string>();
  const out: R[] = [];
  for (const r of rows) {
    const userSnippet = cleanUserText(r.userSnippet);
    if (r.similarity < o.minSimilarity || !userSnippet.trim()) continue;
    if (o.sessionId && r.sessionId === o.sessionId) continue;
    const key = userSnippet.slice(0, 60);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ ...r, userSnippet });
    if (out.length >= o.max) break;
  }
  return out;
}

export interface EpisodicServeOpts { sessionId: string; activeProject?: string }

export const EPISODIC_SERVE_HEADER = '[Past sessions — use episodic_search for full context]';
// The pool, the served cap and the hardcoded similarity floor (no knob, R1#3). The floor is ONE
// value applied to the merged ranking of both engines, not a per-engine floor, and in practice it
// only filters VECTOR hits: a text hit scores 0.5*tf/(tf+n) with tf >= n query tokens, so never
// below 0.25. The text engine's real filter is its AND gate (textSearch: every query token must
// appear in the exchange).
const SERVE_MIN_SIMILARITY = 0.15;
const SERVE_POOL = 10;
const SERVE_MAX = 2;

/** The per-prompt "[Past sessions]" section, as lines (empty = serve nothing). ONE step for both
 *  per-prompt CLIs: context-serve-cli and its fallback episodic-search-cli must serve the same
 *  rows, or the fallback re-opens the noise R1 closed. */
export async function serveEpisodicLines(query: string, brainDir: string, o: EpisodicServeOpts): Promise<string[]> {
  // Unservable rows are filtered INSIDE the search, before scoping and the pool slice. Filtered
  // only afterwards, this session's rows and machine rows filled the in-scope pool and were then
  // dropped, so a long session served nothing. servableEpisodes below stays as the second net.
  const result = await episodicSearch({
    query, limit: SERVE_POOL, mode: 'both', activeProject: o.activeProject,
    excludeSessionId: o.sessionId || undefined, requireUserText: true, minSimilarity: SERVE_MIN_SIMILARITY,
  }, brainDir);
  const served = servableEpisodes(result.results,
    { sessionId: o.sessionId, minSimilarity: SERVE_MIN_SIMILARITY, max: SERVE_MAX });
  if (served.length === 0) return [];
  // Every field that came from an archive is folded: one line, no square bracket.
  return [EPISODIC_SERVE_HEADER, ...served.map(r => {
    const sim = Math.round(r.similarity * 100);
    return `- "${foldServedSnippet(r.userSnippet).slice(0, 80)}..." (${foldServedSnippet(r.project)}, ${foldServedSnippet(r.date)}, ${sim}%)`;
  })];
}

/** The episodic_search MCP tool's text (server.ts returns it as is). Archive text is untrusted:
 *  every snippet is folded to one bracket-free line, and a row with no human words is labelled by
 *  its provenance (subagent report, peer message, machine turn), never with the user label
 *  (security review, R1).
 *  result.degraded reaches the model here (D3, 2026-10-07: the handler used to drop it, so a
 *  concept array on an install without embeddings read as "no such conversation"):
 *  'vector-unavailable' (a concept array or explicit vector mode: nothing could run) -> a no-results
 *  line that says why and how to retry; 'text-only' -> a not-found line that says only text ran, or
 *  a footer under the rows. The footer goes on AFTER capList, so the egress cap cannot drop it. */
export function renderEpisodicSearch(result: EpisodicSearchResult, budgetTokens: number): string {
  if (result.results.length === 0) {
    if (result.degraded === 'vector-unavailable') {
      return 'No results — vector search unavailable (embeddings missing); retry as a single string query (mode "both" or "text") for text matching.';
    }
    if (result.degraded === 'text-only') {
      return 'No matching conversations found (text matching only — vector search unavailable (embeddings missing)).';
    }
    return 'No matching conversations found.';
  }
  const render = (r: EpisodicSearchResult['results'][number]) => {
    const sim = r.similarity > 0 ? ` (${Math.round(r.similarity * 100)}%)` : '';
    return [
      `### ${foldServedSnippet(r.project)} — ${foldServedSnippet(r.date)}${sim}`,
      episodeUserLine(r.userSnippet),
      `**Assistant**: ${foldServedSnippet(r.assistantSnippet)}`,
      `*Session: ${r.sessionId} | Lines ${r.lineStart}-${r.lineEnd} | ${r.archivePath}*`,
    ].join('\n');
  };
  // T4 (R3 review): the footer is appended after capList, so the rows get the budget minus the
  // footer; capList given the whole budget packed up to it and the footer broke the ceiling.
  const footer = result.degraded
    ? '\n\n_Degraded: vector search unavailable (embeddings missing) — these are text matches only._'
    : '';
  const rowBudget = Math.max(0, budgetTokens - estimateTokens(footer));
  return capList(result.results, render, rowBudget, 'narrow the query or use episodic_read on a specific result').text + footer;
}

// A cleaned machine row has an empty user side (cleanUserText). Human-facing renderers show the
// assistant side under a label instead of a blank line; `max`, when given, caps the result.
export function displaySnippet(r: { userSnippet: string; assistantSnippet?: string }, max?: number): string {
  const text = r.userSnippet.trim()
    ? r.userSnippet
    : `[machine turn]${r.assistantSnippet ? ' ' + r.assistantSnippet : ''}`;
  return max === undefined ? text : text.slice(0, max);
}

function simpleHash(s: string): string {
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = ((h << 5) - h + s.charCodeAt(i)) | 0;
  }
  return h.toString(36);
}

function parseSessionMeta(lines: string[]): { meta: SessionMeta; bodyStart: number } {
  const meta: SessionMeta = { sessionId: '', project: '', date: '' };
  let i = 0;
  if (lines[0]?.startsWith('--- session-meta ---')) {
    i = 1;
    while (i < lines.length && !lines[i].startsWith('---')) {
      const m = lines[i].match(/^(\w+):\s*(.+)/);
      if (m) {
        if (m[1] === 'session_id') meta.sessionId = m[2].trim();
        else if (m[1] === 'project_slug') meta.project = m[2].trim();
        else if (m[1] === 'date') meta.date = m[2].trim();
      }
      i++;
    }
    i++; // skip closing ---
    if (i < lines.length && lines[i] === '') i++; // skip blank line after header
  }
  return { meta, bodyStart: i };
}

function parseExchanges(lines: string[], bodyStart: number, meta: SessionMeta, archivePath: string): Exchange[] {
  const exchanges: Exchange[] = [];
  let userMsg = '';
  let assistantMsg = '';
  let exchangeStart = bodyStart;
  let inUser = false;
  let inAssistant = false;

  const flush = (endLine: number) => {
    if (userMsg.trim() || assistantMsg.trim()) {
      const user = userMsg.trim();
      const assistant = assistantMsg.trim();
      // Skip trivial exchanges (tool-only assistant responses with no user text). Judged on the
      // RAW text, before cleaning, so parser 2 keeps exactly the rows (and ids) parser 1 kept.
      if (user.length > 10 || assistant.length > 20) {
        exchanges.push({
          id: simpleHash(`${archivePath}:${exchangeStart}-${endLine}`),
          sessionId: meta.sessionId,
          project: meta.project,
          date: meta.date,
          userMessage: cleanUserText(user),
          assistantMessage: assistant,
          archivePath,
          lineStart: exchangeStart + 1, // 1-indexed for Read tool
          lineEnd: endLine + 1,
        });
      }
    }
    userMsg = '';
    assistantMsg = '';
  };

  for (let i = bodyStart; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith('USER:')) {
      if (inUser || inAssistant) flush(i - 1);
      exchangeStart = i;
      inUser = true;
      inAssistant = false;
      const rest = line.slice(5).trim();
      if (rest) userMsg += rest + '\n';
    } else if (line.startsWith('ASSISTANT:')) {
      if (!inUser && !inAssistant) {
        // Assistant without preceding user — start new exchange
        exchangeStart = i;
      }
      inAssistant = true;
      inUser = false;
      const rest = line.slice(10).trim();
      if (rest) assistantMsg += rest + '\n';
    } else if (inUser) {
      userMsg += line.trimStart() + '\n';
    } else if (inAssistant) {
      assistantMsg += line.trimStart() + '\n';
    }
  }
  flush(lines.length - 1);
  return exchanges;
}

const emptyIndex = (): EpisodicIndex => ({ model: 'Xenova/all-MiniLM-L6-v2', indexed_files: {}, exchanges: [] });

/** The row fields every writer stores as strings and the readers dereference (basename,
 *  toLowerCase, the snippet clean and fold): without them a row throws in search and build alike. */
const ROW_STRING_FIELDS = ['id', 'sessionId', 'project', 'date', 'userSnippet', 'assistantSnippet', 'archivePath'] as const;

function isStoredRow(v: unknown): v is StoredExchange {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return false;
  const o = v as Record<string, unknown>;
  return ROW_STRING_FIELDS.every(k => typeof o[k] === 'string');
}

interface LoadedIndex {
  index: EpisodicIndex;
  /** Rows whose stored vector was unusable (kept, without a vector: they re-embed). */
  dropped: number;
  /** Elements of `exchanges` that are not a row at all (null, a primitive, a row without its
   *  string fields): skipped. The archive one still names has lost its file entry, so the next
   *  build re-parses it and no real row is lost. */
  malformed: number;
}

/** A missing index is the normal first run. Anything else that cannot be used (unreadable,
 *  unparseable, or without an exchanges array) is reset to empty AND logged: the next build
 *  re-indexes every archive, and the reset must not pass for a healthy empty index. A missing or
 *  malformed `indexed_files` only means "re-parse every file", so it is normalized to {}.
 *  Rows come back in the current shape (currentRow). */
async function loadIndex(brainDir: string): Promise<LoadedIndex> {
  const indexPath = join(brainDir, INDEX_FILE);
  const reset = { index: emptyIndex(), dropped: 0, malformed: 0 };
  let data: string;
  try {
    data = await fs.readFile(indexPath, 'utf-8');
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === 'ENOENT') return reset;
    await appendErrorLog(brainDir, 'episodic-index',
      `corrupt episodic index reset: ${indexPath} unreadable (${e instanceof Error ? e.message : String(e)})`);
    return reset;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(data);
  } catch (e) {
    await appendErrorLog(brainDir, 'episodic-index',
      `corrupt episodic index reset: ${indexPath} is not JSON (${e instanceof Error ? e.message : String(e)})`);
    return reset;
  }
  const o = parsed as { model?: unknown; indexed_files?: unknown; exchanges?: unknown } | null;
  if (!o || typeof o !== 'object' || Array.isArray(o) || !Array.isArray(o.exchanges)) {
    await appendErrorLog(brainDir, 'episodic-index',
      `corrupt episodic index reset: ${indexPath} has no exchanges array`);
    return reset;
  }
  const files = o.indexed_files;
  const indexedFiles: EpisodicIndex['indexed_files'] =
    files && typeof files === 'object' && !Array.isArray(files) ? files as EpisodicIndex['indexed_files'] : {};
  let dropped = 0;
  let malformed = 0;
  const exchanges: IndexedExchange[] = [];
  for (const stored of o.exchanges as unknown[]) {
    if (!isStoredRow(stored)) {
      malformed++;
      const archivePath = (stored as { archivePath?: unknown } | null)?.archivePath;
      if (typeof archivePath === 'string') delete indexedFiles[basename(archivePath)];
      continue;
    }
    const r = currentRow(stored);
    if (r.dropped) dropped++;
    exchanges.push(r.row);
  }
  return {
    index: {
      model: typeof o.model === 'string' ? o.model : emptyIndex().model,
      indexed_files: indexedFiles,
      exchanges,
    },
    dropped,
    malformed,
  };
}

/** The build is the index's ONLY writer. A search never writes, not even the format migration:
 *  the builder holds no lock, so a search that loaded before a build saved and wrote after it would
 *  drop the build's new rows. tmp + rename, so a crash or a failed write leaves the previous file
 *  whole (a legacy float index stays readable and the next build retries); the failure is logged,
 *  not thrown, because the CLI runs in the Stop and PreCompact hooks. */
async function saveIndex(brainDir: string, index: EpisodicIndex): Promise<void> {
  const indexPath = join(brainDir, INDEX_FILE);
  try {
    await atomicWriteJsonStrict(indexPath, index);
  } catch (e) {
    await appendErrorLog(brainDir, 'episodic-index',
      `episodic index write failed: ${indexPath} (${e instanceof Error ? e.message : String(e)}); `
      + 'the previous index is kept and the next build retries');
  }
}

/** The one-time 0.56.0 archive scrub (scripts/extract-drain.sh drain_scrub_migrate). Its to-do
 *  list names the files written before 0.56.0 that still hold a credential literal, one
 *  `<path relative to BRAIN_DIR>\t<failed scrub attempts>` per line, the path
 *  `transcripts/<b>.txt` or `dreams/<id>/transcripts/<b>.txt`. The marker means the migration is
 *  done, so a list left behind is stale. */
export const SCRUB_MARK = '.archive-scrub-v1';
export const SCRUB_TODO = `${SCRUB_MARK}.todo`;

export interface ScrubTodoEntry { path: string; fails: number }

/** The to-do list's entries, read the way drain_scrub_migrate normalizes them: a trailing CR is
 *  dropped, the path is the field before the first tab, a path with no `/` (a bare basename from
 *  a 0.56 pre-release list) is a transcripts/ entry, and an attempt count that is not a plain
 *  integer is 0. Empty lines are skipped. */
export function parseScrubTodo(text: string): ScrubTodoEntry[] {
  const entries: ScrubTodoEntry[] = [];
  for (const raw of text.split('\n')) {
    const [first, fc = ''] = raw.replace(/\r$/, '').split('\t');
    if (!first) continue;
    const path = first.includes('/') ? first : `transcripts/${first}`;
    entries.push({ path, fails: /^[0-9]+$/.test(fc) ? Number(fc) : 0 });
  }
  return entries;
}

/** The archives a build holds out of the index while the scrub migration is pending: their text
 *  is still in clear. No list holds nothing (no migration, or its first tick has not run). A list
 *  that cannot be read holds nothing too, so recall does not go dark on a read error, and that is
 *  logged. One read per build. */
async function scrubPendingArchives(brainDir: string): Promise<Set<string>> {
  const pending = new Set<string>();
  try {
    await fs.stat(join(brainDir, SCRUB_MARK));
    return pending;
  } catch { /* not done yet: the list decides */ }
  const todoPath = join(brainDir, SCRUB_TODO);
  let text: string;
  try {
    text = await fs.readFile(todoPath, 'utf-8');
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== 'ENOENT') {
      await appendErrorLog(brainDir, 'episodic-index',
        `cannot read the archive-scrub to-do list ${todoPath} (${e instanceof Error ? e.message : String(e)}); `
        + 'nothing is held out of the episodic index, so archives the scrub has not reached yet are indexed in clear');
    }
    return pending;
  }
  // Only a transcripts/<b> entry holds archive <b>: a dream copy of the same name is never indexed.
  for (const { path } of parseScrubTodo(text)) {
    const m = /^transcripts\/([^/]+)$/.exec(path);
    if (m) pending.add(m[1]);
  }
  return pending;
}

export async function buildEpisodicIndex(brainDir: string): Promise<{ indexed: number; total: number; repaired: number; pending: number; held: number }> {
  const archiveDir = join(brainDir, 'transcripts');
  let files: string[];
  try {
    const entries = await fs.readdir(archiveDir);
    files = entries.filter(f => f.endsWith('.txt')).map(f => join(archiveDir, f));
  } catch {
    return { indexed: 0, total: 0, repaired: 0, pending: 0, held: 0 };
  }

  const scrubPending = await scrubPendingArchives(brainDir);
  let held = 0;
  const { index, dropped, malformed } = await loadIndex(brainDir);
  if (malformed > 0) {
    await appendErrorLog(brainDir, 'episodic-index',
      `${malformed} malformed row(s) (not an object with the row's string fields) were dropped from the episodic `
      + 'index; an archive such a row names is re-parsed');
  }
  if (dropped > 0) {
    await appendErrorLog(brainDir, 'episodic-index',
      `${dropped} stored vector(s) not ${EMBEDDING_DIM} components were dropped from the episodic index; those rows re-embed`);
  }
  const newExchanges: Exchange[] = [];
  const reparsed: Record<string, string> = {};
  // Rows of re-parsed files, by id, captured before they are dropped: a row whose stored text
  // comes out of the re-parse unchanged carries its vector over (no model call, and no loss when
  // the model or the embedding cache is unavailable).
  const previous = new Map<string, IndexedExchange>();

  for (const filePath of files) {
    const fname = basename(filePath);
    // Held while the scrub has not reached it: not read, its rows dropped below, its file entry
    // forgotten. The forgotten entry is what re-derives it on the first build after it leaves the
    // list, whether the scrub changed its text or found nothing to redact.
    if (scrubPending.has(fname)) {
      delete index.indexed_files[fname];
      held++;
      continue;
    }
    // Sanitize untrusted transcript text before indexing it (P6b — invisible/Tags-block
    // smuggling defense). Hash the cleaned content so a previously-dirty file re-indexes once.
    const content = stripInvisible(await fs.readFile(filePath, 'utf-8'));
    const hash = simpleHash(content);

    // Unchanged AND parsed by the current parser: skip. A changed file, a bare-string entry
    // (pre-version writer) or an older parser version is re-parsed from scratch.
    if (isCurrentEntry(index.indexed_files[fname], hash)) continue;
    reparsed[fname] = hash;

    for (const e of index.exchanges) if (basename(e.archivePath) === fname) previous.set(e.id, e);
    index.exchanges = index.exchanges.filter(e => basename(e.archivePath) !== fname);
    const lines = content.split('\n');
    const { meta, bodyStart } = parseSessionMeta(lines);
    newExchanges.push(...parseExchanges(lines, bodyStart, meta, filePath));
  }

  // Drop exchanges from deleted transcripts and from held ones.
  const validFiles = new Set(files.map(f => basename(f)));
  index.exchanges = index.exchanges.filter(e => {
    const fname = basename(e.archivePath);
    return validFiles.has(fname) && !scrubPending.has(fname);
  });

  // Persist new exchanges immediately (text-searchable). Embeddings may be empty
  // and will be filled in by the repair pass below or on a future run.
  for (const e of newExchanges) {
    const userSnippet = e.userMessage.slice(0, SNIPPET_LEN);
    const assistantSnippet = e.assistantMessage.slice(0, SNIPPET_LEN);
    // The vector embeds exactly these two snippets, so equal text means the old vector is valid.
    const old = previous.get(e.id);
    const carried = old && old.userSnippet === userSnippet && old.assistantSnippet === assistantSnippet
      && hasVector(old) ? { e8: old.e8, es: old.es } : {};
    index.exchanges.push({
      id: e.id,
      sessionId: e.sessionId,
      project: e.project,
      date: e.date,
      userSnippet,
      assistantSnippet,
      archivePath: e.archivePath,
      lineStart: e.lineStart,
      lineEnd: e.lineEnd,
      ...carried,
    });
  }

  // Repair pass: every exchange with an empty embedding gets re-embedded on every run.
  // This is the core fix — the production bug was that empty rows persisted forever.
  // A re-parsed row's text goes through the embedding cache, keyed `episodic:<id>` AND checked
  // against a hash of the exact text: an unchanged row is served from the cache (no model call),
  // a row whose text changed (e.g. cleaned by a parser bump) misses and re-embeds once.
  // episodic-reembed.test.ts locks both halves.
  const needsEmbed = index.exchanges.filter(e => !hasVector(e));
  let repaired = 0;
  if (needsEmbed.length > 0) {
    const texts = needsEmbed.map(r => `${r.userSnippet}\n${r.assistantSnippet}`.slice(0, EMBEDDING_TEXT_CAP));
    const paths = needsEmbed.map(r => `episodic:${r.id}`);
    const embeddings = await embedTexts(texts, join(brainDir, 'transcripts'), paths);
    if (embeddings) {
      let nonFinite = 0;
      for (let i = 0; i < needsEmbed.length; i++) {
        // Only a full vector of finite components is stored. loadIndex drops any other length,
        // and JSON writes Infinity as null (an Infinity component makes es Infinity), so storing
        // either would drop and re-embed it on every build; a NaN would quantize silently to 0.
        // Every component finite means es (max|x| / 127) is finite too.
        const vec = embeddings[i];
        if (!vec || vec.length !== EMBEDDING_DIM) continue;
        if (!vec.every(Number.isFinite)) { nonFinite++; continue; }
        Object.assign(needsEmbed[i], quantizeEmbedding(vec));
        repaired++;
      }
      if (nonFinite > 0) {
        await appendErrorLog(brainDir, 'episodic-index',
          `${nonFinite} embedding(s) with a non-finite component were not stored; those rows stay pending `
          + 'and the next build embeds them again (the embedding cache does not keep such a vector)');
      }
    }
  }

  // Always mark files as structurally indexed. They are text-searchable; vector
  // search will work for rows whose embeddings got filled in. The parser version is recorded
  // per file, in the SAME atomic index write as the re-parsed rows, so a crash can never leave
  // a file marked current while it still holds rows from the older parser.
  for (const [fname, hash] of Object.entries(reparsed)) {
    index.indexed_files[fname] = { hash, parser: EPISODIC_PARSER_VERSION };
  }
  for (const fname of Object.keys(index.indexed_files)) {
    if (!validFiles.has(fname)) delete index.indexed_files[fname];
  }

  await saveIndex(brainDir, index);
  const pending = index.exchanges.filter(e => !hasVector(e)).length;
  // Rows without a vector are invisible to vector recall; say so, unless the user opted out of
  // embeddings (an acknowledged choice, which episodic-index.test.ts keeps out of the error log).
  if (pending > 0 && !embeddingsOptedOut()) {
    await appendErrorLog(brainDir, 'episodic-index',
      `${pending} of ${index.exchanges.length} rows have no embedding after the repair pass: vector recall `
      + 'misses them until a build can embed them (check the embedding model / vector deps)');
  }
  return { indexed: newExchanges.length, total: index.exchanges.length, repaired, pending, held };
}

export async function episodicSearch(args: EpisodicSearchArgs, brainDir: string): Promise<EpisodicSearchResult> {
  const { index } = await loadIndex(brainDir);
  if (index.exchanges.length === 0) return { results: [] };

  const limit = Math.min(args.limit ?? DEFAULT_LIMIT, MAX_LIMIT);
  const query = args.query;

  // Multi-concept AND search
  if (Array.isArray(query)) {
    return multiConceptSearch(query, index, limit, args, brainDir);
  }

  const mode = args.mode ?? 'both';
  // When scoping to an active project we may discard other-project candidates,
  // so widen the per-engine pool to keep enough in-scope hits in play.
  const candLimit = (args.activeProject && !args.project) ? Math.max(limit * 5, 25) : limit * 2;
  let vectorResults: (IndexedExchange & { similarity: number })[] = [];
  let textResults: (IndexedExchange & { similarity: number })[] = [];

  let degraded: 'text-only' | 'vector-unavailable' | undefined;
  if (mode === 'vector' || mode === 'both') {
    const v = await vectorSearch(query, index, candLimit, args, brainDir);
    vectorResults = v.hits;
    // 'text-only' is honest only when text actually runs as the fallback;
    // explicit vector mode has no fallback (deep-review W4).
    if (v.unavailable) degraded = mode === 'both' ? 'text-only' : 'vector-unavailable';
  }

  if (mode === 'text' || mode === 'both') {
    textResults = textSearch(query, index, candLimit, args);
  }

  // Merge and dedup — vector results take precedence
  const seen = new Set<string>();
  const merged: (IndexedExchange & { similarity: number })[] = [];
  for (const r of vectorResults) {
    if (!seen.has(r.id)) { seen.add(r.id); merged.push(r); }
  }
  for (const r of textResults) {
    if (!seen.has(r.id)) { seen.add(r.id); merged.push(r); }
  }

  merged.sort((a, b) => b.similarity - a.similarity);

  return {
    results: scopeAndBroaden(aboveFloor(merged, args), args).slice(0, limit).map(r => ({
      sessionId: r.sessionId,
      project: r.project,
      date: r.date,
      userSnippet: r.userSnippet,
      assistantSnippet: r.assistantSnippet,
      similarity: Math.round(r.similarity * 1000) / 1000,
      archivePath: r.archivePath,
      lineStart: r.lineStart,
      lineEnd: r.lineEnd,
    })),
    ...(degraded ? { degraded } : {}),
  };
}

async function vectorSearch(
  query: string, index: EpisodicIndex, limit: number,
  filters: EpisodicSearchArgs, brainDir: string
): Promise<{ hits: (IndexedExchange & { similarity: number })[]; unavailable: boolean }> {
  const filtered = applyFilters(index.exchanges, filters);
  const withEmbeddings = filtered.filter(hasVector);
  // unavailable = vector search COULD have matched but can't run (no vectors /
  // no model); an empty filter result is not a degradation (R2.3).
  if (withEmbeddings.length === 0) return { hits: [], unavailable: filtered.length > 0 };

  const queryEmbedding = await embedTexts(
    [query], join(brainDir, 'transcripts'), ['']
  );
  if (!queryEmbedding) return { hits: [], unavailable: true };
  const qVec = queryEmbedding[0];

  return {
    hits: withEmbeddings
      .map(e => ({ ...e, similarity: embeddingSimilarity(qVec, e) }))
      .sort((a, b) => b.similarity - a.similarity)
      .slice(0, limit),
    unavailable: false,
  };
}

function textSearch(
  query: string, index: EpisodicIndex, limit: number, filters: EpisodicSearchArgs
): (IndexedExchange & { similarity: number })[] {
  const filtered = applyFilters(index.exchanges, filters);
  // Tokenize on non-alphanumeric. Filter trivial tokens. AND-match: every token must
  // appear in either snippet. Score by how many tokens hit, so longer-overlap wins.
  const tokens = query.toLowerCase().split(/[^a-z0-9]+/).filter(t => t.length >= 2);
  if (tokens.length === 0) return [];

  const scored: (IndexedExchange & { similarity: number })[] = [];
  for (const e of filtered) {
    const hay = (e.userSnippet + ' ' + e.assistantSnippet).toLowerCase();
    // AND-gate: every query token must appear. Score by total term FREQUENCY so
    // a denser overlap outranks a single-mention match (P8: the old code broke
    // on first miss and forced hits/tokens.length === 1 → a constant 0.5).
    let allHit = true;
    let tf = 0;
    for (const t of tokens) {
      const occ = hay.split(t).length - 1;
      if (occ === 0) { allHit = false; break; }
      tf += occ;
    }
    if (allHit) {
      // tf >= tokens.length (each token hits >=1), so this maps into [0.25, 0.5), monotonic
      // in tf and saturating below 0.5 so a vector match (up to 1.0) still outranks. Being
      // >= 0.25, a text hit always clears the serve floor (0.15): the AND gate above is the
      // only thing that filters text hits.
      const similarity = 0.5 * (tf / (tf + tokens.length));
      scored.push({ ...e, similarity });
    }
  }
  // Sort by similarity DESC before truncating — slicing an unsorted list kept an
  // arbitrary first-N, not the best-N (the other half of the P8 bug).
  scored.sort((a, b) => b.similarity - a.similarity);
  return scored.slice(0, limit);
}

async function multiConceptSearch(
  concepts: string[], index: EpisodicIndex, limit: number,
  filters: EpisodicSearchArgs, brainDir: string
): Promise<EpisodicSearchResult> {
  // brainDir comes from the caller (deep-review C2): deriving it from the first
  // exchange's archivePath silently reverted to the LIVE brain when the index
  // came from a hermetic/test dir — the exact leak class R2.2 closed.

  const filtered = applyFilters(index.exchanges, filters);
  const withEmbeddings = filtered.filter(hasVector);
  // Multi-concept search is vector-only: no embeddings = honestly degraded, not
  // silently empty (R2.3). An empty FILTER result is not a degradation (I6).
  if (withEmbeddings.length === 0) {
    return { results: [], ...(filtered.length > 0 ? { degraded: 'vector-unavailable' as const } : {}) };
  }

  const conceptEmbeddings = await embedTexts(
    concepts,
    join(brainDir, 'transcripts'),
    concepts.map((_, i) => `concept-${i}`)
  );
  if (!conceptEmbeddings) return { results: [], degraded: 'vector-unavailable' };

  // Score each exchange against all concepts
  const scored = withEmbeddings.map(e => {
    const v = decodeE8(e.e8);
    const similarities = conceptEmbeddings.map(cv => dotDequantized(cv, v, e.es));
    const minSim = Math.min(...similarities);
    const avgSim = similarities.reduce((a, b) => a + b, 0) / similarities.length;
    return { ...e, similarity: avgSim, minSimilarity: minSim };
  });

  // Only return exchanges that have reasonable match to ALL concepts
  const threshold = 0.2;
  const ranked = scopeAndBroaden(
    aboveFloor(scored.filter(s => s.minSimilarity >= threshold).sort((a, b) => b.similarity - a.similarity), filters),
    filters
  );
  return {
    results: ranked
      .slice(0, limit)
      .map(r => ({
        sessionId: r.sessionId,
        project: r.project,
        date: r.date,
        userSnippet: r.userSnippet,
        assistantSnippet: r.assistantSnippet,
        similarity: Math.round(r.similarity * 1000) / 1000,
        archivePath: r.archivePath,
        lineStart: r.lineStart,
        lineEnd: r.lineEnd,
      })),
  };
}

function applyFilters(exchanges: IndexedExchange[], filters: EpisodicSearchArgs): IndexedExchange[] {
  let result = exchanges;
  if (filters.project) {
    const p = filters.project.toLowerCase();
    result = result.filter(e => e.project.toLowerCase() === p);
  }
  if (filters.after) {
    result = result.filter(e => e.date >= filters.after!);
  }
  if (filters.before) {
    result = result.filter(e => e.date <= filters.before!);
  }
  if (filters.excludeSessionId) {
    const sid = filters.excludeSessionId;
    result = result.filter(e => e.sessionId !== sid);
  }
  if (filters.requireUserText) {
    result = result.filter(e => cleanUserText(e.userSnippet).trim() !== '');
  }
  return result;
}

function aboveFloor<T extends { similarity: number }>(ranked: T[], filters: EpisodicSearchArgs): T[] {
  const floor = filters.minSimilarity;
  return floor === undefined ? ranked : ranked.filter(r => r.similarity >= floor);
}

/**
 * Default the episodic search to the active project (MCP handler + CLI use this).
 * Mirrors how knowledge_search auto-passes the active slug, closing the
 * cross-project episodic leak. Precedence: an explicit `project` is a hard
 * filter and wins; the sentinel `project: "all"` is a deliberate broaden (drop
 * the filter, no scope); otherwise default the soft `activeProject` scope to the
 * resolved slug.
 */
export function withActiveScope(args: EpisodicSearchArgs, activeSlug: string | undefined): EpisodicSearchArgs {
  if (args.project) {
    if (args.project.toLowerCase() === 'all') {
      // Deliberate broaden: drop BOTH the hard filter and any soft scope a caller pre-set,
      // so "all" truly means every project (not just no hard filter).
      const { project, activeProject, ...rest } = args;
      return rest;
    }
    return args;
  }
  return activeSlug ? { ...args, activeProject: activeSlug } : args;
}

// Scope-first, broaden-if-thin: prefer same-project exchanges; fall back to the full ranked
// set only when the active project has fewer than the minimum in-scope hits (so a thin/new
// project still gets recall). A hard `project` filter (applied in applyFilters) takes
// precedence — activeProject is the soft default scope. Default minHits is 1 (broaden ONLY on
// zero in-scope hits): intentionally more aggressive than knowledge_search's floor of 3, to
// keep cross-project session noise out of the human's and Claude's context entirely — when a
// project has any in-scope hit we hard-drop higher-scoring other-project results (a deliberate
// anti-noise trade-off). Tune via SB_EPISODIC_SCOPE_MIN_HITS; pass project:"all" to broaden on
// demand. Exported for direct unit testing of the shared scoping used by both query paths.
export function scopeAndBroaden<T extends { project: string }>(ranked: T[], args: EpisodicSearchArgs): T[] {
  if (!args.activeProject || args.project) return ranked;
  const slug = args.activeProject.toLowerCase();
  const inScope = ranked.filter(r => r.project.toLowerCase() === slug);
  const parsed = parseInt(process.env.SB_EPISODIC_SCOPE_MIN_HITS ?? '', 10);
  const minHits = Number.isFinite(parsed) && parsed >= 1 ? parsed : 1;
  return inScope.length >= minHits ? inScope : ranked;
}

/**
 * episodic_read entry-point guard — the one G-MCP-1 surface the v0.21.0
 * hardening pass (commit 4837873) missed. The model-supplied path must
 * resolve inside ${brainDir}/transcripts, symlinks resolved BEFORE
 * validation (path-guard doctrine). Returns the validated real path.
 */
export function assertTranscriptPath(brainDir: string, filePath: string): string {
  const base = join(brainDir, 'transcripts');
  const rel = isAbsolute(filePath) ? relative(base, filePath) : filePath;
  return assertWithin(base, rel);
}

export async function episodicRead(
  filePath: string, startLine?: number, endLine?: number
): Promise<EpisodicReadResult> {
  const content = stripInvisible(await fs.readFile(filePath, 'utf-8'));
  const lines = content.split('\n');
  const { meta } = parseSessionMeta(lines);

  const start = (startLine ?? 1) - 1;
  const end = endLine ?? lines.length;
  const selected = lines.slice(start, end).join('\n');

  return {
    content: selected,
    sessionId: meta.sessionId,
    project: meta.project,
    date: meta.date,
  };
}
