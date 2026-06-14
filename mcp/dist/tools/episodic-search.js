import { promises as fs } from 'fs';
import { atomicWriteJson } from './atomic-write.js';
import { join, basename, relative, isAbsolute } from 'path';
import { embedTexts, cosineSimilarity } from './embeddings.js';
import { assertWithin } from '../path-guard.js';
const INDEX_FILE = 'episodic-index.json';
const SNIPPET_LEN = 200;
const DEFAULT_LIMIT = 10;
const MAX_LIMIT = 30;
const EMBEDDING_TEXT_CAP = 512;
function simpleHash(s) {
    let h = 0;
    for (let i = 0; i < s.length; i++) {
        h = ((h << 5) - h + s.charCodeAt(i)) | 0;
    }
    return h.toString(36);
}
function parseSessionMeta(lines) {
    const meta = { sessionId: '', project: '', date: '' };
    let i = 0;
    if (lines[0]?.startsWith('--- session-meta ---')) {
        i = 1;
        while (i < lines.length && !lines[i].startsWith('---')) {
            const m = lines[i].match(/^(\w+):\s*(.+)/);
            if (m) {
                if (m[1] === 'session_id')
                    meta.sessionId = m[2].trim();
                else if (m[1] === 'project_slug')
                    meta.project = m[2].trim();
                else if (m[1] === 'date')
                    meta.date = m[2].trim();
            }
            i++;
        }
        i++; // skip closing ---
        if (i < lines.length && lines[i] === '')
            i++; // skip blank line after header
    }
    return { meta, bodyStart: i };
}
function parseExchanges(lines, bodyStart, meta, archivePath) {
    const exchanges = [];
    let userMsg = '';
    let assistantMsg = '';
    let exchangeStart = bodyStart;
    let inUser = false;
    let inAssistant = false;
    const flush = (endLine) => {
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
            if (inUser || inAssistant)
                flush(i - 1);
            exchangeStart = i;
            inUser = true;
            inAssistant = false;
            const rest = line.slice(5).trim();
            if (rest)
                userMsg += rest + '\n';
        }
        else if (line.startsWith('ASSISTANT:')) {
            if (!inUser && !inAssistant) {
                // Assistant without preceding user — start new exchange
                exchangeStart = i;
            }
            inAssistant = true;
            inUser = false;
            const rest = line.slice(10).trim();
            if (rest)
                assistantMsg += rest + '\n';
        }
        else if (inUser) {
            userMsg += line.trimStart() + '\n';
        }
        else if (inAssistant) {
            assistantMsg += line.trimStart() + '\n';
        }
    }
    flush(lines.length - 1);
    return exchanges;
}
async function loadIndex(brainDir) {
    const indexPath = join(brainDir, INDEX_FILE);
    try {
        const data = await fs.readFile(indexPath, 'utf-8');
        return JSON.parse(data);
    }
    catch {
        return { model: 'Xenova/all-MiniLM-L6-v2', indexed_files: {}, exchanges: [] };
    }
}
async function saveIndex(brainDir, index) {
    await atomicWriteJson(join(brainDir, INDEX_FILE), index);
}
export async function buildEpisodicIndex(brainDir) {
    const archiveDir = join(brainDir, 'transcripts');
    let files;
    try {
        const entries = await fs.readdir(archiveDir);
        files = entries.filter(f => f.endsWith('.txt')).map(f => join(archiveDir, f));
    }
    catch {
        return { indexed: 0, total: 0, repaired: 0, pending: 0 };
    }
    const index = await loadIndex(brainDir);
    const newExchanges = [];
    const fileHashes = {};
    for (const filePath of files) {
        const content = await fs.readFile(filePath, 'utf-8');
        const hash = simpleHash(content);
        const fname = basename(filePath);
        fileHashes[fname] = hash;
        if (index.indexed_files[fname] === hash)
            continue;
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
        if (!validFiles.has(fname))
            delete index.indexed_files[fname];
    }
    await saveIndex(brainDir, index);
    const pending = index.exchanges.filter(e => !e.embedding || e.embedding.length === 0).length;
    return { indexed: newExchanges.length, total: index.exchanges.length, repaired, pending };
}
export async function episodicSearch(args, brainDir) {
    const index = await loadIndex(brainDir);
    if (index.exchanges.length === 0)
        return { results: [] };
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
    let vectorResults = [];
    let textResults = [];
    let degraded;
    if (mode === 'vector' || mode === 'both') {
        const v = await vectorSearch(query, index, candLimit, args, brainDir);
        vectorResults = v.hits;
        // 'text-only' is honest only when text actually runs as the fallback;
        // explicit vector mode has no fallback (deep-review W4).
        if (v.unavailable)
            degraded = mode === 'both' ? 'text-only' : 'vector-unavailable';
    }
    if (mode === 'text' || mode === 'both') {
        textResults = textSearch(query, index, candLimit, args);
    }
    // Merge and dedup — vector results take precedence
    const seen = new Set();
    const merged = [];
    for (const r of vectorResults) {
        if (!seen.has(r.id)) {
            seen.add(r.id);
            merged.push(r);
        }
    }
    for (const r of textResults) {
        if (!seen.has(r.id)) {
            seen.add(r.id);
            merged.push(r);
        }
    }
    merged.sort((a, b) => b.similarity - a.similarity);
    return {
        results: scopeAndBroaden(merged, args).slice(0, limit).map(r => ({
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
async function vectorSearch(query, index, limit, filters, brainDir) {
    const filtered = applyFilters(index.exchanges, filters);
    const withEmbeddings = filtered.filter(e => e.embedding.length > 0);
    // unavailable = vector search COULD have matched but can't run (no vectors /
    // no model); an empty filter result is not a degradation (R2.3).
    if (withEmbeddings.length === 0)
        return { hits: [], unavailable: filtered.length > 0 };
    const queryEmbedding = await embedTexts([query], join(brainDir, 'transcripts'), ['']);
    if (!queryEmbedding)
        return { hits: [], unavailable: true };
    const qVec = queryEmbedding[0];
    return {
        hits: withEmbeddings
            .map(e => ({ ...e, similarity: cosineSimilarity(qVec, e.embedding) }))
            .sort((a, b) => b.similarity - a.similarity)
            .slice(0, limit),
        unavailable: false,
    };
}
function textSearch(query, index, limit, filters) {
    const filtered = applyFilters(index.exchanges, filters);
    // Tokenize on non-alphanumeric. Filter trivial tokens. AND-match: every token must
    // appear in either snippet. Score by how many tokens hit, so longer-overlap wins.
    const tokens = query.toLowerCase().split(/[^a-z0-9]+/).filter(t => t.length >= 2);
    if (tokens.length === 0)
        return [];
    const scored = [];
    for (const e of filtered) {
        const hay = (e.userSnippet + ' ' + e.assistantSnippet).toLowerCase();
        // AND-gate: every query token must appear. Score by total term FREQUENCY so
        // a denser overlap outranks a single-mention match (P8: the old code broke
        // on first miss and forced hits/tokens.length === 1 → a constant 0.5).
        let allHit = true;
        let tf = 0;
        for (const t of tokens) {
            const occ = hay.split(t).length - 1;
            if (occ === 0) {
                allHit = false;
                break;
            }
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
async function multiConceptSearch(concepts, index, limit, filters, brainDir) {
    // brainDir comes from the caller (deep-review C2): deriving it from the first
    // exchange's archivePath silently reverted to the LIVE brain when the index
    // came from a hermetic/test dir — the exact leak class R2.2 closed.
    const filtered = applyFilters(index.exchanges, filters);
    const withEmbeddings = filtered.filter(e => e.embedding.length > 0);
    // Multi-concept search is vector-only: no embeddings = honestly degraded, not
    // silently empty (R2.3). An empty FILTER result is not a degradation (I6).
    if (withEmbeddings.length === 0) {
        return { results: [], ...(filtered.length > 0 ? { degraded: 'vector-unavailable' } : {}) };
    }
    const conceptEmbeddings = await embedTexts(concepts, join(brainDir, 'transcripts'), concepts.map((_, i) => `concept-${i}`));
    if (!conceptEmbeddings)
        return { results: [], degraded: 'vector-unavailable' };
    // Score each exchange against all concepts
    const scored = withEmbeddings.map(e => {
        const similarities = conceptEmbeddings.map(cv => cosineSimilarity(cv, e.embedding));
        const minSim = Math.min(...similarities);
        const avgSim = similarities.reduce((a, b) => a + b, 0) / similarities.length;
        return { ...e, similarity: avgSim, minSimilarity: minSim };
    });
    // Only return exchanges that have reasonable match to ALL concepts
    const threshold = 0.2;
    const ranked = scopeAndBroaden(scored.filter(s => s.minSimilarity >= threshold).sort((a, b) => b.similarity - a.similarity), filters);
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
function applyFilters(exchanges, filters) {
    let result = exchanges;
    if (filters.project) {
        const p = filters.project.toLowerCase();
        result = result.filter(e => e.project.toLowerCase() === p);
    }
    if (filters.after) {
        result = result.filter(e => e.date >= filters.after);
    }
    if (filters.before) {
        result = result.filter(e => e.date <= filters.before);
    }
    return result;
}
/**
 * Default the episodic search to the active project (MCP handler + CLI use this).
 * Mirrors how knowledge_search auto-passes the active slug, closing the
 * cross-project episodic leak. Precedence: an explicit `project` is a hard
 * filter and wins; the sentinel `project: "all"` is a deliberate broaden (drop
 * the filter, no scope); otherwise default the soft `activeProject` scope to the
 * resolved slug.
 */
export function withActiveScope(args, activeSlug) {
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
export function scopeAndBroaden(ranked, args) {
    if (!args.activeProject || args.project)
        return ranked;
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
export function assertTranscriptPath(brainDir, filePath) {
    const base = join(brainDir, 'transcripts');
    const rel = isAbsolute(filePath) ? relative(base, filePath) : filePath;
    return assertWithin(base, rel);
}
export async function episodicRead(filePath, startLine, endLine) {
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
//# sourceMappingURL=episodic-search.js.map