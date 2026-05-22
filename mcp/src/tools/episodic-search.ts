import { promises as fs } from 'fs';
import { join, basename } from 'path';
import { embedTexts, cosineSimilarity } from './embeddings.js';

const INDEX_FILE = 'episodic-index.json';
const SNIPPET_LEN = 200;
const DEFAULT_LIMIT = 10;
const MAX_LIMIT = 30;
const EMBEDDING_TEXT_CAP = 512;

export interface EpisodicSearchArgs {
  query: string | string[];
  mode?: 'vector' | 'text' | 'both';
  limit?: number;
  project?: string;
  after?: string;
  before?: string;
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

interface EpisodicIndex {
  model: string;
  indexed_files: Record<string, string>;
  exchanges: IndexedExchange[];
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
      // Skip trivial exchanges (tool-only assistant responses with no user text)
      if (user.length > 10 || assistant.length > 20) {
        exchanges.push({
          id: simpleHash(`${archivePath}:${exchangeStart}-${endLine}`),
          sessionId: meta.sessionId,
          project: meta.project,
          date: meta.date,
          userMessage: user,
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
  await fs.writeFile(join(brainDir, INDEX_FILE), JSON.stringify(index));
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
  const fileHashes: Record<string, string> = {};

  for (const filePath of files) {
    const content = await fs.readFile(filePath, 'utf-8');
    const hash = simpleHash(content);
    const fname = basename(filePath);
    fileHashes[fname] = hash;

    if (index.indexed_files[fname] === hash) continue;

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
  // search will work for rows whose embeddings got filled in.
  for (const [fname, hash] of Object.entries(fileHashes)) {
    index.indexed_files[fname] = hash;
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
    return multiConceptSearch(query, index, limit, args);
  }

  const mode = args.mode ?? 'both';
  let vectorResults: (IndexedExchange & { similarity: number })[] = [];
  let textResults: (IndexedExchange & { similarity: number })[] = [];

  if (mode === 'vector' || mode === 'both') {
    vectorResults = await vectorSearch(query, index, limit * 2, args, brainDir);
  }

  if (mode === 'text' || mode === 'both') {
    textResults = textSearch(query, index, limit * 2, args);
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
    results: merged.slice(0, limit).map(r => ({
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

async function vectorSearch(
  query: string, index: EpisodicIndex, limit: number,
  filters: EpisodicSearchArgs, brainDir: string
): Promise<(IndexedExchange & { similarity: number })[]> {
  const filtered = applyFilters(index.exchanges, filters);
  const withEmbeddings = filtered.filter(e => e.embedding.length > 0);
  if (withEmbeddings.length === 0) return [];

  const queryEmbedding = await embedTexts(
    [query], join(brainDir, 'transcripts'), ['']
  );
  if (!queryEmbedding) return [];
  const qVec = queryEmbedding[0];

  return withEmbeddings
    .map(e => ({ ...e, similarity: cosineSimilarity(qVec, e.embedding) }))
    .sort((a, b) => b.similarity - a.similarity)
    .slice(0, limit);
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
    let hits = 0;
    for (const t of tokens) {
      if (hay.includes(t)) hits++;
      else { hits = -1; break; }
    }
    if (hits === tokens.length) {
      // Normalize score to (0, 0.5] so vector matches (which can score up to 1.0) still rank above text.
      scored.push({ ...e, similarity: 0.25 + (hits / tokens.length) * 0.25 });
    }
  }
  return scored.slice(0, limit);
}

async function multiConceptSearch(
  concepts: string[], index: EpisodicIndex, limit: number,
  filters: EpisodicSearchArgs
): Promise<EpisodicSearchResult> {
  const brainDir = index.exchanges[0]?.archivePath
    ? join(index.exchanges[0].archivePath, '..', '..')
    : join(process.env.HOME ?? '', '.second-brain');

  const filtered = applyFilters(index.exchanges, filters);
  const withEmbeddings = filtered.filter(e => e.embedding.length > 0);
  if (withEmbeddings.length === 0) return { results: [] };

  const conceptEmbeddings = await embedTexts(
    concepts,
    join(brainDir, 'transcripts'),
    concepts.map((_, i) => `concept-${i}`)
  );
  if (!conceptEmbeddings) return { results: [] };

  // Score each exchange against all concepts
  const scored = withEmbeddings.map(e => {
    const similarities = conceptEmbeddings.map(cv => cosineSimilarity(cv, e.embedding));
    const minSim = Math.min(...similarities);
    const avgSim = similarities.reduce((a, b) => a + b, 0) / similarities.length;
    return { ...e, similarity: avgSim, minSimilarity: minSim };
  });

  // Only return exchanges that have reasonable match to ALL concepts
  const threshold = 0.2;
  return {
    results: scored
      .filter(s => s.minSimilarity >= threshold)
      .sort((a, b) => b.similarity - a.similarity)
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
  return result;
}

export async function episodicRead(
  filePath: string, startLine?: number, endLine?: number
): Promise<EpisodicReadResult> {
  const content = await fs.readFile(filePath, 'utf-8');
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
