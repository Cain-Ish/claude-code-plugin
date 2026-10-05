import { promises as fs } from 'fs';
import { atomicWriteJson } from './atomic-write.js';
import { join, basename, relative, isAbsolute } from 'path';
import { embedTexts, cosineSimilarity } from './embeddings.js';
import { assertWithin } from '../path-guard.js';
import { stripInvisible } from './sanitize.js';

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

interface IndexedExchange {
  id: string;
  sessionId: string;
  project: string;
  date: string;
  userSnippet: string;
  assistantSnippet: string;
  archivePath: string;
  lineStart: number;
  lineEnd: number;
  embedding: number[];
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
 *  3 = harness tags are an allowlist (no generic <x-… rule) and image/interrupt prefix lines are
 *      stripped with the human text after them kept (R1 review, 2026-10). */
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
 *  "<my-component> doesn't render" (R1 review). Human pastes use <pasted_content (underscore). */
export const MACHINE_TAG_PREFIXES: readonly string[] = [
  '<task-notification>',
  '<system-reminder>',
  '<command-name>',
  '<command-message>',
  '<command-args>',
  '<local-command-',
  '<agent-message',
  '<cross-session-message',
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

/** Peer message (subagent hand-back or cross-session): drop the header, the wrapper tag pair,
 *  the leading frame lines and anything after the closing tag; keep the report body. */
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
  let j = 0;
  while (j < body.length && (!body[j].trim() || /^\s*\[(Subagent hand-back\]|harness:)/.test(body[j]))) j++;
  return body.slice(j).join('\n').trim();
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
// The hardcoded per-engine similarity floor (no knob, R1#3), the pool and the served cap.
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
  return [EPISODIC_SERVE_HEADER, ...served.map(r => {
    const sim = Math.round(r.similarity * 100);
    return `- "${r.userSnippet.slice(0, 80)}..." (${r.project}, ${r.date}, ${sim}%)`;
  })];
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

async function loadIndex(brainDir: string): Promise<EpisodicIndex> {
  const indexPath = join(brainDir, INDEX_FILE);
  try {
    const data = await fs.readFile(indexPath, 'utf-8');
    return JSON.parse(data);
  } catch {
    return { model: 'Xenova/all-MiniLM-L6-v2', indexed_files: {}, exchanges: [] };
  }
}

async function saveIndex(brainDir: string, index: EpisodicIndex): Promise<void> {
  await atomicWriteJson(join(brainDir, INDEX_FILE), index);
}

export async function buildEpisodicIndex(brainDir: string): Promise<{ indexed: number; total: number; repaired: number; pending: number }> {
  const archiveDir = join(brainDir, 'transcripts');
  let files: string[];
  try {
    const entries = await fs.readdir(archiveDir);
    files = entries.filter(f => f.endsWith('.txt')).map(f => join(archiveDir, f));
  } catch {
    return { indexed: 0, total: 0, repaired: 0, pending: 0 };
  }

  const index = await loadIndex(brainDir);
  const newExchanges: Exchange[] = [];
  const reparsed: Record<string, string> = {};

  for (const filePath of files) {
    // Sanitize untrusted transcript text before indexing it (P6b — invisible/Tags-block
    // smuggling defense). Hash the cleaned content so a previously-dirty file re-indexes once.
    const content = stripInvisible(await fs.readFile(filePath, 'utf-8'));
    const hash = simpleHash(content);
    const fname = basename(filePath);

    // Unchanged AND parsed by the current parser: skip. A changed file, a bare-string entry
    // (pre-version writer) or an older parser version is re-parsed from scratch.
    if (isCurrentEntry(index.indexed_files[fname], hash)) continue;
    reparsed[fname] = hash;

    index.exchanges = index.exchanges.filter(e => basename(e.archivePath) !== fname);
    const lines = content.split('\n');
    const { meta, bodyStart } = parseSessionMeta(lines);
    newExchanges.push(...parseExchanges(lines, bodyStart, meta, filePath));
  }

  // Drop exchanges from deleted transcripts.
  const validFiles = new Set(files.map(f => basename(f)));
  index.exchanges = index.exchanges.filter(e => validFiles.has(basename(e.archivePath)));

  // Persist new exchanges immediately (text-searchable). Embeddings may be empty
  // and will be filled in by the repair pass below or on a future run.
  for (const e of newExchanges) {
    index.exchanges.push({
      id: e.id,
      sessionId: e.sessionId,
      project: e.project,
      date: e.date,
      userSnippet: e.userMessage.slice(0, SNIPPET_LEN),
      assistantSnippet: e.assistantMessage.slice(0, SNIPPET_LEN),
      archivePath: e.archivePath,
      lineStart: e.lineStart,
      lineEnd: e.lineEnd,
      embedding: [],
    });
  }

  // Repair pass: every exchange with an empty embedding gets re-embedded on every run.
  // This is the core fix — the production bug was that empty rows persisted forever.
  // A re-parsed row's text goes through the embedding cache, keyed `episodic:<id>` AND checked
  // against a hash of the exact text: an unchanged row is served from the cache (no model call),
  // a row whose text changed (e.g. cleaned by a parser bump) misses and re-embeds once.
  // episodic-reembed.test.ts locks both halves.
  const needsEmbed = index.exchanges.filter(e => !e.embedding || e.embedding.length === 0);
  let repaired = 0;
  if (needsEmbed.length > 0) {
    const texts = needsEmbed.map(r => `${r.userSnippet}\n${r.assistantSnippet}`.slice(0, EMBEDDING_TEXT_CAP));
    const paths = needsEmbed.map(r => `episodic:${r.id}`);
    const embeddings = await embedTexts(texts, join(brainDir, 'transcripts'), paths);
    if (embeddings) {
      for (let i = 0; i < needsEmbed.length; i++) {
        if (embeddings[i] && embeddings[i].length > 0) {
          needsEmbed[i].embedding = embeddings[i];
          repaired++;
        }
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
  const pending = index.exchanges.filter(e => !e.embedding || e.embedding.length === 0).length;
  return { indexed: newExchanges.length, total: index.exchanges.length, repaired, pending };
}

export async function episodicSearch(args: EpisodicSearchArgs, brainDir: string): Promise<EpisodicSearchResult> {
  const index = await loadIndex(brainDir);
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
  const withEmbeddings = filtered.filter(e => e.embedding.length > 0);
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
      .map(e => ({ ...e, similarity: cosineSimilarity(qVec, e.embedding) }))
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
      // tf >= tokens.length (each token hits >=1). Map into (0, 0.5] monotonically
      // in tf, saturating below 0.5 so a vector match (up to 1.0) still outranks.
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
  const withEmbeddings = filtered.filter(e => e.embedding.length > 0);
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
    const similarities = conceptEmbeddings.map(cv => cosineSimilarity(cv, e.embedding));
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
