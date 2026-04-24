import fs from "fs";
import path from "path";

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

interface StoredEntry {
  path: string;
  title: string;
  content: string;
  category: string;
  lastModified: number;
  indexedAt: number;
  embedding: number[];
}

interface VectorStore {
  version: number;
  entries: StoredEntry[];
}

function cosineSimilarity(a: Float32Array, b: number[]): number {
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

export class VectorDB {
  private storePath: string;
  private store: VectorStore;

  constructor(knowledgeDir: string) {
    const dbDir = path.join(knowledgeDir, ".embeddings");
    fs.mkdirSync(dbDir, { recursive: true });
    this.storePath = path.join(dbDir, "vectors.json");
    this.store = this.load();
  }

  private load(): VectorStore {
    if (fs.existsSync(this.storePath)) {
      try {
        const data = fs.readFileSync(this.storePath, "utf-8");
        return JSON.parse(data);
      } catch {
        return { version: 1, entries: [] };
      }
    }
    return { version: 1, entries: [] };
  }

  private save(): void {
    const tmpPath = this.storePath + ".tmp";
    fs.writeFileSync(tmpPath, JSON.stringify(this.store), "utf-8");
    fs.renameSync(tmpPath, this.storePath);
  }

  isIndexed(filePath: string, lastModified: number): boolean {
    const entry = this.store.entries.find((e) => e.path === filePath);
    return entry !== undefined && entry.lastModified >= lastModified;
  }

  upsertPage(page: WikiPage, embedding: Float32Array): void {
    const idx = this.store.entries.findIndex((e) => e.path === page.path);
    const entry: StoredEntry = {
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
    } else {
      this.store.entries.push(entry);
    }

    this.save();
  }

  search(queryEmbedding: Float32Array, limit: number = 5, category?: string): SearchResult[] {
    let candidates = this.store.entries;
    if (category) {
      candidates = candidates.filter((e) => e.category === category);
    }

    const scored = candidates.map((entry) => ({
      entry,
      score: cosineSimilarity(queryEmbedding, entry.embedding),
    }));

    scored.sort((a, b) => b.score - a.score);

    return scored.slice(0, limit).map((s) => ({
      path: s.entry.path,
      title: s.entry.title,
      excerpt: s.entry.content.slice(0, 500),
      category: s.entry.category,
      score: s.score,
    }));
  }

  getStats(): { totalPages: number; categories: Record<string, number>; lastIndexed: string | null } {
    const categories: Record<string, number> = {};
    let maxIndexed = 0;

    for (const entry of this.store.entries) {
      categories[entry.category] = (categories[entry.category] || 0) + 1;
      if (entry.indexedAt > maxIndexed) maxIndexed = entry.indexedAt;
    }

    return {
      totalPages: this.store.entries.length,
      categories,
      lastIndexed: maxIndexed > 0 ? new Date(maxIndexed).toISOString() : null,
    };
  }

  removeStale(existingPaths: Set<string>): number {
    const before = this.store.entries.length;
    this.store.entries = this.store.entries.filter((e) => existingPaths.has(e.path));
    const removed = before - this.store.entries.length;
    if (removed > 0) this.save();
    return removed;
  }
}
