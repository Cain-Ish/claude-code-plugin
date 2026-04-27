import fs from "fs";
import path from "path";
function cosineSimilarity(a, b) {
    let dot = 0;
    let normA = 0;
    let normB = 0;
    for (let i = 0; i < a.length; i++) {
        dot += a[i] * b[i];
        normA += a[i] * a[i];
        normB += b[i] * b[i];
    }
    const denom = Math.sqrt(normA) * Math.sqrt(normB);
    return denom === 0 ? 0 : dot / denom;
}
// BM25 parameters (standard defaults)
const BM25_K1 = 1.2;
const BM25_B = 0.75;
function tokenize(text) {
    return text
        .toLowerCase()
        .replace(/[^\w\s-]/g, " ")
        .split(/\s+/)
        .filter((t) => t.length > 1);
}
function computeBM25(queryTokens, docTokens, avgDocLen, docFreqs, totalDocs) {
    const docLen = docTokens.length;
    const termFreqs = new Map();
    for (const t of docTokens) {
        termFreqs.set(t, (termFreqs.get(t) || 0) + 1);
    }
    let score = 0;
    for (const qt of queryTokens) {
        const tf = termFreqs.get(qt) || 0;
        if (tf === 0)
            continue;
        const df = docFreqs.get(qt) || 0;
        const idf = Math.log((totalDocs - df + 0.5) / (df + 0.5) + 1);
        const tfNorm = (tf * (BM25_K1 + 1)) /
            (tf + BM25_K1 * (1 - BM25_B + BM25_B * (docLen / avgDocLen)));
        score += idf * tfNorm;
    }
    return score;
}
export class VectorDB {
    storePath;
    store;
    dirty = false;
    constructor(knowledgeDir) {
        const dbDir = path.join(knowledgeDir, ".embeddings");
        fs.mkdirSync(dbDir, { recursive: true });
        this.storePath = path.join(dbDir, "vectors.json");
        this.store = this.load();
    }
    load() {
        if (fs.existsSync(this.storePath)) {
            try {
                const data = fs.readFileSync(this.storePath, "utf-8");
                return JSON.parse(data);
            }
            catch {
                return { version: 1, entries: [] };
            }
        }
        return { version: 1, entries: [] };
    }
    writeStore() {
        const tmpPath = this.storePath + ".tmp";
        fs.writeFileSync(tmpPath, JSON.stringify(this.store), "utf-8");
        fs.renameSync(tmpPath, this.storePath);
        this.dirty = false;
    }
    flush() {
        if (this.dirty)
            this.writeStore();
    }
    isIndexed(filePath, lastModified) {
        const entry = this.store.entries.find((e) => e.path === filePath);
        return entry !== undefined && entry.lastModified >= lastModified;
    }
    upsertPage(page, embedding) {
        const idx = this.store.entries.findIndex((e) => e.path === page.path);
        const entry = {
            path: page.path,
            title: page.title,
            content: page.content,
            category: page.category,
            lastModified: page.lastModified,
            indexedAt: Date.now(),
            embedding: Array.from(embedding),
        };
        if (idx >= 0) {
            this.store.entries[idx] = entry;
        }
        else {
            this.store.entries.push(entry);
        }
        this.dirty = true;
    }
    search(queryEmbedding, limit = 5, category, minScore = 0.25, queryText) {
        let candidates = this.store.entries;
        if (category) {
            candidates = candidates.filter((e) => e.category === category);
        }
        if (candidates.length === 0)
            return [];
        // Vector similarity scores
        const vectorScored = candidates.map((entry, i) => ({
            idx: i,
            entry,
            vectorScore: cosineSimilarity(queryEmbedding, entry.embedding),
        }));
        // BM25 keyword scores (when query text provided)
        let bm25Scored = [];
        if (queryText) {
            const queryTokens = tokenize(queryText);
            if (queryTokens.length > 0) {
                const docTokensCache = candidates.map((e) => tokenize(`${e.title} ${e.content}`));
                const avgDocLen = docTokensCache.reduce((sum, d) => sum + d.length, 0) /
                    candidates.length;
                // Compute document frequencies for IDF
                const docFreqs = new Map();
                for (const tokens of docTokensCache) {
                    const unique = new Set(tokens);
                    for (const t of unique) {
                        docFreqs.set(t, (docFreqs.get(t) || 0) + 1);
                    }
                }
                bm25Scored = docTokensCache.map((tokens, i) => ({
                    idx: i,
                    bm25Score: computeBM25(queryTokens, tokens, avgDocLen, docFreqs, candidates.length),
                }));
            }
        }
        // Reciprocal rank fusion: combine vector and BM25 rankings
        const RRF_K = 60;
        const vectorRanked = [...vectorScored].sort((a, b) => b.vectorScore - a.vectorScore);
        const vectorRankMap = new Map();
        vectorRanked.forEach((v, rank) => vectorRankMap.set(v.idx, rank + 1));
        let bm25RankMap = new Map();
        if (bm25Scored.length > 0) {
            const bm25Ranked = [...bm25Scored].sort((a, b) => b.bm25Score - a.bm25Score);
            bm25Ranked.forEach((v, rank) => bm25RankMap.set(v.idx, rank + 1));
        }
        const fused = vectorScored.map((v) => {
            const vectorRank = vectorRankMap.get(v.idx) || candidates.length;
            const rrfVector = 1 / (RRF_K + vectorRank);
            let rrfBM25 = 0;
            if (bm25RankMap.size > 0) {
                const bm25Rank = bm25RankMap.get(v.idx) || candidates.length;
                rrfBM25 = 1 / (RRF_K + bm25Rank);
            }
            // Weight: 60% vector, 40% BM25 when both available
            const score = bm25RankMap.size > 0
                ? 0.6 * rrfVector + 0.4 * rrfBM25
                : rrfVector;
            return { entry: v.entry, score, vectorScore: v.vectorScore };
        });
        fused.sort((a, b) => b.score - a.score);
        return fused
            .filter((s) => s.vectorScore >= minScore)
            .slice(0, limit)
            .map((s) => ({
            path: s.entry.path,
            title: s.entry.title,
            excerpt: s.entry.content.slice(0, 500),
            category: s.entry.category,
            score: s.vectorScore,
        }));
    }
    getStats() {
        const categories = {};
        let maxIndexed = 0;
        for (const entry of this.store.entries) {
            categories[entry.category] = (categories[entry.category] || 0) + 1;
            if (entry.indexedAt > maxIndexed)
                maxIndexed = entry.indexedAt;
        }
        return {
            totalPages: this.store.entries.length,
            categories,
            lastIndexed: maxIndexed > 0 ? new Date(maxIndexed).toISOString() : null,
        };
    }
    removeStale(existingPaths) {
        const before = this.store.entries.length;
        this.store.entries = this.store.entries.filter((e) => existingPaths.has(e.path));
        const removed = before - this.store.entries.length;
        if (removed > 0)
            this.writeStore();
        return removed;
    }
}
//# sourceMappingURL=vectordb.js.map