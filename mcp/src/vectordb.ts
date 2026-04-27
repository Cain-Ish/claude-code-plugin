import fs from "fs";
import path from "path";
import initSqlJs, { type Database } from "sql.js";

export interface WikiPage {
  path: string;
  title: string;
  content: string;
  category: string;
  lastModified: number;
}

export interface SearchResult {
  path: string;
  title: string;
  excerpt: string;
  category: string;
  score: number;
}

function cosineSimilarity(a: Float32Array, b: Float32Array): number {
  if (a.length !== b.length) {
    throw new Error(`Embedding dimension mismatch: ${a.length} vs ${b.length}`);
  }
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

const BM25_K1 = 1.2;
const BM25_B = 0.75;

function tokenize(text: string): string[] {
  return text
    .toLowerCase()
    .replace(/[^\w\s-]/g, " ")
    .split(/\s+/)
    .filter((t) => t.length > 1);
}

function computeBM25(
  queryTokens: string[],
  docTokens: string[],
  avgDocLen: number,
  docFreqs: Map<string, number>,
  totalDocs: number
): number {
  const docLen = docTokens.length;
  const termFreqs = new Map<string, number>();
  for (const t of docTokens) {
    termFreqs.set(t, (termFreqs.get(t) || 0) + 1);
  }

  let score = 0;
  for (const qt of queryTokens) {
    const tf = termFreqs.get(qt) || 0;
    if (tf === 0) continue;
    const df = docFreqs.get(qt) || 0;
    const idf = Math.log((totalDocs - df + 0.5) / (df + 0.5) + 1);
    const tfNorm =
      (tf * (BM25_K1 + 1)) /
      (tf + BM25_K1 * (1 - BM25_B + BM25_B * (docLen / avgDocLen)));
    score += idf * tfNorm;
  }
  return score;
}

function embeddingToBlob(embedding: Float32Array): Uint8Array {
  return new Uint8Array(embedding.buffer.slice(embedding.byteOffset, embedding.byteOffset + embedding.byteLength));
}

function blobToEmbedding(blob: Uint8Array): Float32Array {
  if (blob.length % 4 !== 0) {
    throw new Error(`Invalid embedding blob size: ${blob.length} (must be multiple of 4)`);
  }
  const copy = new ArrayBuffer(blob.length);
  new Uint8Array(copy).set(blob);
  return new Float32Array(copy);
}

export class VectorDB {
  private db: Database | null = null;
  private dbPath: string;
  private dbDir: string;
  private initPromise: Promise<void>;

  constructor(knowledgeDir: string) {
    this.dbDir = path.join(knowledgeDir, ".embeddings");
    fs.mkdirSync(this.dbDir, { recursive: true });
    this.dbPath = path.join(this.dbDir, "vectors.db");
    this.initPromise = this.init();
  }

  private async init(): Promise<void> {
    const SQL = await initSqlJs();

    const isNew = !fs.existsSync(this.dbPath);
    if (!isNew) {
      const buf = fs.readFileSync(this.dbPath);
      this.db = new SQL.Database(buf);
    } else {
      this.db = new SQL.Database();
    }

    this.db.run(`
      CREATE TABLE IF NOT EXISTS pages (
        path TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        category TEXT NOT NULL,
        lastModified REAL NOT NULL,
        indexedAt REAL NOT NULL,
        embedding BLOB NOT NULL,
        accessCount INTEGER DEFAULT 0,
        lastAccessed REAL
      )
    `);
    this.db.run("CREATE INDEX IF NOT EXISTS idx_category ON pages(category)");

    const didMigrate = this.migrate();
    if (isNew || didMigrate) this.persist();
  }

  private migrate(): boolean {
    const jsonPath = path.join(this.dbDir, "vectors.json");
    if (!fs.existsSync(jsonPath)) return false;

    let data: { entries?: Array<{ path: string; title: string; content: string; category: string; lastModified: number; indexedAt: number; embedding: number[] }> };
    try {
      data = JSON.parse(fs.readFileSync(jsonPath, "utf-8"));
    } catch {
      return false;
    }

    if (!data.entries || data.entries.length === 0) return false;

    let migrated = 0;
    let skipped = 0;
    const stmt = this.db!.prepare(
      "INSERT OR IGNORE INTO pages (path, title, content, category, lastModified, indexedAt, embedding, accessCount, lastAccessed) VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL)"
    );
    try {
      for (const e of data.entries) {
        try {
          const emb = new Float32Array(e.embedding);
          stmt.run([e.path, e.title, e.content, e.category, e.lastModified, e.indexedAt, embeddingToBlob(emb)]);
          migrated++;
        } catch (err) {
          skipped++;
          console.error(`Skipped migration entry ${e.path}: ${err instanceof Error ? err.message : String(err)}`);
        }
      }
    } finally {
      stmt.free();
    }

    const suffix = skipped > 0 ? ".partial-migrated" : ".migrated";
    fs.renameSync(jsonPath, jsonPath + suffix);
    console.error(`Migrated ${migrated}/${data.entries.length} entries from vectors.json to SQLite${skipped > 0 ? ` (${skipped} skipped)` : ""}`);
    return migrated > 0;
  }

  private persist(): void {
    if (!this.db) return;
    const data = this.db.export();
    const tmpPath = this.dbPath + ".tmp";
    fs.writeFileSync(tmpPath, Buffer.from(data));
    fs.renameSync(tmpPath, this.dbPath);
  }

  private getDb(): Database {
    if (!this.db) throw new Error("VectorDB not initialized");
    return this.db;
  }

  async ready(): Promise<void> {
    await this.initPromise;
  }

  isIndexed(filePath: string, lastModified: number): boolean {
    const db = this.getDb();
    const stmt = db.prepare("SELECT lastModified FROM pages WHERE path = ?");
    try {
      stmt.bind([filePath]);
      if (stmt.step()) {
        const row = stmt.getAsObject();
        return (row.lastModified as number) >= lastModified;
      }
      return false;
    } finally {
      stmt.free();
    }
  }

  upsertPage(page: WikiPage, embedding: Float32Array): void {
    const db = this.getDb();

    const existing = db.prepare("SELECT accessCount, lastAccessed FROM pages WHERE path = ?");
    let accessCount = 0;
    let lastAccessed: number | null = null;
    try {
      existing.bind([page.path]);
      if (existing.step()) {
        const row = existing.getAsObject();
        accessCount = (row.accessCount as number) || 0;
        lastAccessed = (row.lastAccessed as number | null) || null;
      }
    } finally {
      existing.free();
    }

    db.run(
      "INSERT OR REPLACE INTO pages (path, title, content, category, lastModified, indexedAt, embedding, accessCount, lastAccessed) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [page.path, page.title, page.content, page.category, page.lastModified, Date.now(), embeddingToBlob(embedding), accessCount, lastAccessed]
    );
  }

  search(
    queryEmbedding: Float32Array,
    limit: number = 5,
    category?: string,
    minCosineSimilarity: number = 0.25,
    queryText?: string
  ): SearchResult[] {
    const db = this.getDb();

    let sql = "SELECT path, title, content, category, embedding, accessCount FROM pages";
    const params: (string | number)[] = [];
    if (category) {
      sql += " WHERE category = ?";
      params.push(category);
    }

    interface Candidate {
      path: string;
      title: string;
      content: string;
      category: string;
      embedding: Float32Array;
      accessCount: number;
    }
    const candidates: Candidate[] = [];

    const stmt = db.prepare(sql);
    try {
      if (params.length > 0) stmt.bind(params);
      while (stmt.step()) {
        const row = stmt.getAsObject();
        candidates.push({
          path: row.path as string,
          title: row.title as string,
          content: row.content as string,
          category: row.category as string,
          embedding: blobToEmbedding(row.embedding as Uint8Array),
          accessCount: (row.accessCount as number) || 0,
        });
      }
    } finally {
      stmt.free();
    }

    if (candidates.length === 0) return [];

    const vectorScored = candidates.map((entry, i) => ({
      idx: i,
      entry,
      vectorScore: cosineSimilarity(queryEmbedding, entry.embedding),
    }));

    let bm25Scored: { idx: number; bm25Score: number }[] = [];
    if (queryText) {
      const queryTokens = tokenize(queryText);
      if (queryTokens.length > 0) {
        const docTokensCache = candidates.map((e) =>
          tokenize(`${e.title} ${e.content}`)
        );
        const avgDocLen =
          docTokensCache.reduce((sum, d) => sum + d.length, 0) /
          candidates.length;

        const docFreqs = new Map<string, number>();
        for (const tokens of docTokensCache) {
          const unique = new Set(tokens);
          for (const t of unique) {
            docFreqs.set(t, (docFreqs.get(t) || 0) + 1);
          }
        }

        bm25Scored = docTokensCache.map((tokens, i) => ({
          idx: i,
          bm25Score: computeBM25(
            queryTokens,
            tokens,
            avgDocLen,
            docFreqs,
            candidates.length
          ),
        }));
      }
    }

    const RRF_K = 60;
    const vectorRanked = [...vectorScored].sort(
      (a, b) => b.vectorScore - a.vectorScore
    );
    const vectorRankMap = new Map<number, number>();
    vectorRanked.forEach((v, rank) => vectorRankMap.set(v.idx, rank + 1));

    let bm25RankMap = new Map<number, number>();
    if (bm25Scored.length > 0) {
      const bm25Ranked = [...bm25Scored].sort(
        (a, b) => b.bm25Score - a.bm25Score
      );
      bm25Ranked.forEach((v, rank) => bm25RankMap.set(v.idx, rank + 1));
    }

    // Access-count boost: find max for normalization
    const maxAccessCount = Math.max(1, candidates.reduce((m, c) => Math.max(m, c.accessCount), 0));

    const fused = vectorScored.map((v) => {
      const vectorRank = vectorRankMap.get(v.idx) || candidates.length;
      const rrfVector = 1 / (RRF_K + vectorRank);

      let rrfBM25 = 0;
      if (bm25RankMap.size > 0) {
        const bm25Rank = bm25RankMap.get(v.idx) || candidates.length;
        rrfBM25 = 1 / (RRF_K + bm25Rank);
      }

      const rrfScore =
        bm25RankMap.size > 0
          ? 0.6 * rrfVector + 0.4 * rrfBM25
          : rrfVector;

      const accessBoost = Math.log1p(v.entry.accessCount) / Math.log1p(maxAccessCount);
      const score = 0.95 * rrfScore + 0.05 * accessBoost;

      return { entry: v.entry, score, vectorScore: v.vectorScore };
    });

    fused.sort((a, b) => b.score - a.score);

    const filtered = queryText
      ? fused
      : fused.filter((s) => s.vectorScore >= minCosineSimilarity);

    return filtered
      .slice(0, limit)
      .map((s) => ({
        path: s.entry.path,
        title: s.entry.title,
        excerpt: s.entry.content.slice(0, 500),
        category: s.entry.category,
        score: s.score,
      }));
  }

  recordAccess(paths: string[]): void {
    const db = this.getDb();
    const now = Date.now();
    const stmt = db.prepare(
      "UPDATE pages SET accessCount = accessCount + 1, lastAccessed = ? WHERE path = ?"
    );
    try {
      for (const p of paths) {
        stmt.run([now, p]);
      }
    } finally {
      stmt.free();
    }
  }

  updateAccessCount(filePath: string, delta: number): boolean {
    const db = this.getDb();
    db.run(
      "UPDATE pages SET accessCount = MAX(0, accessCount + ?) WHERE path = ?",
      [delta, filePath]
    );
    const changes = db.getRowsModified();
    if (changes > 0) this.persist();
    return changes > 0;
  }

  flush(): void {
    this.persist();
  }

  getStats(): {
    totalPages: number;
    categories: Record<string, number>;
    lastIndexed: string | null;
  } {
    const db = this.getDb();
    const categories: Record<string, number> = {};

    const catStmt = db.prepare("SELECT category, COUNT(*) as cnt FROM pages GROUP BY category");
    try {
      while (catStmt.step()) {
        const row = catStmt.getAsObject();
        categories[row.category as string] = row.cnt as number;
      }
    } finally {
      catStmt.free();
    }

    let totalPages = 0;
    const totalStmt = db.prepare("SELECT COUNT(*) as total FROM pages");
    try {
      totalStmt.step();
      totalPages = (totalStmt.getAsObject().total as number) || 0;
    } finally {
      totalStmt.free();
    }

    let maxIndexed = 0;
    const lastStmt = db.prepare("SELECT MAX(indexedAt) as lastIndexed FROM pages");
    try {
      lastStmt.step();
      maxIndexed = (lastStmt.getAsObject().lastIndexed as number) || 0;
    } finally {
      lastStmt.free();
    }

    return {
      totalPages,
      categories,
      lastIndexed: maxIndexed > 0 ? new Date(maxIndexed).toISOString() : null,
    };
  }

  removeStale(existingPaths: Set<string>): number {
    const db = this.getDb();
    const toDelete: string[] = [];

    const allStmt = db.prepare("SELECT path FROM pages");
    try {
      while (allStmt.step()) {
        const row = allStmt.getAsObject();
        if (!existingPaths.has(row.path as string)) {
          toDelete.push(row.path as string);
        }
      }
    } finally {
      allStmt.free();
    }

    if (toDelete.length === 0) return 0;

    const delStmt = db.prepare("DELETE FROM pages WHERE path = ?");
    try {
      for (const p of toDelete) {
        delStmt.run([p]);
      }
    } finally {
      delStmt.free();
    }

    return toDelete.length;
  }

  close(): void {
    if (this.db) {
      this.persist();
      this.db.close();
      this.db = null;
    }
  }
}
