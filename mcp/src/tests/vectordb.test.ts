import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "fs";
import path from "path";
import os from "os";
import { VectorDB } from "../vectordb.js";
import initSqlJs from "sql.js";

let counter = 0;
function freshDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), `vectordb-test-${counter++}-`));
}

function fakeEmbedding(seed: number, dims = 64): Float32Array {
  const emb = new Float32Array(dims);
  for (let i = 0; i < dims; i++) {
    emb[i] = Math.sin(seed * (i + 1) * 0.1);
  }
  const norm = Math.sqrt(emb.reduce((s, v) => s + v * v, 0));
  if (norm > 0) for (let i = 0; i < dims; i++) emb[i] /= norm;
  return emb;
}

describe("VectorDB", () => {
  let dir: string;
  let db: VectorDB;

  before(async () => {
    dir = freshDir();
    db = new VectorDB(dir);
    await db.ready();
  });

  after(() => { db?.close(); });

  it("creates SQLite database file on init", () => {
    assert.ok(fs.existsSync(path.join(dir, ".embeddings", "vectors.db")));
  });

  it("upsertPage + isIndexed round-trip", () => {
    const now = Date.now();
    db.upsertPage(
      { path: "wiki/test.md", title: "Test", content: "hello world", category: "wiki", lastModified: now },
      fakeEmbedding(1)
    );
    assert.ok(db.isIndexed("wiki/test.md", now));
    assert.ok(db.isIndexed("wiki/test.md", now - 1000));
    assert.ok(!db.isIndexed("wiki/test.md", now + 1000));
    assert.ok(!db.isIndexed("wiki/nonexistent.md", now));
  });

  it("search returns results sorted by score", () => {
    db.upsertPage(
      { path: "wiki/a.md", title: "Alpha", content: "alpha content", category: "wiki", lastModified: Date.now() },
      fakeEmbedding(10)
    );
    db.upsertPage(
      { path: "wiki/b.md", title: "Beta", content: "beta content", category: "wiki", lastModified: Date.now() },
      fakeEmbedding(99)
    );
    const results = db.search(fakeEmbedding(10), 10, undefined, 0.0);
    assert.ok(results.length >= 2);
    for (let i = 1; i < results.length; i++) {
      assert.ok(results[i - 1].score >= results[i].score, "results should be descending by score");
    }
  });

  it("search filters by category", () => {
    db.upsertPage(
      { path: "sessions/s.md", title: "S", content: "session", category: "sessions", lastModified: Date.now() },
      fakeEmbedding(50)
    );
    const wikiOnly = db.search(fakeEmbedding(1), 100, "wiki", 0.0);
    assert.ok(wikiOnly.every(r => r.category === "wiki"));
    const sessOnly = db.search(fakeEmbedding(50), 100, "sessions", 0.0);
    assert.ok(sessOnly.length >= 1);
    assert.ok(sessOnly.every(r => r.category === "sessions"));
  });

  it("search with queryText uses BM25 hybrid scoring", () => {
    db.upsertPage(
      { path: "wiki/auth.md", title: "Authentication", content: "JWT tokens OAuth authentication flow", category: "wiki", lastModified: Date.now() },
      fakeEmbedding(5)
    );
    const results = db.search(fakeEmbedding(5), 10, undefined, 0.0, "authentication JWT");
    assert.ok(results.length >= 1);
  });

  it("recordAccess increments and updateAccessCount works", () => {
    db.upsertPage(
      { path: "wiki/hot.md", title: "Hot", content: "popular page", category: "wiki", lastModified: Date.now() },
      fakeEmbedding(3)
    );
    db.recordAccess(["wiki/hot.md"]);
    db.recordAccess(["wiki/hot.md"]);
    assert.ok(db.updateAccessCount("wiki/hot.md", 0));
    assert.ok(!db.updateAccessCount("wiki/nonexistent.md", 1));
  });

  it("access-count boost: higher count ranks higher with equal similarity", async () => {
    const boostDir = freshDir();
    const boostDb = new VectorDB(boostDir);
    await boostDb.ready();
    const sharedEmb = fakeEmbedding(42);
    boostDb.upsertPage(
      { path: "wiki/popular.md", title: "Popular", content: "xyz unique content popular", category: "wiki", lastModified: Date.now() },
      sharedEmb
    );
    boostDb.upsertPage(
      { path: "wiki/unpopular.md", title: "Unpopular", content: "xyz unique content unpopular", category: "wiki", lastModified: Date.now() },
      sharedEmb
    );
    for (let i = 0; i < 10; i++) boostDb.recordAccess(["wiki/popular.md"]);
    const results = boostDb.search(sharedEmb, 2, undefined, 0.0, "xyz unique content");
    const popularIdx = results.findIndex(r => r.path === "wiki/popular.md");
    const unpopularIdx = results.findIndex(r => r.path === "wiki/unpopular.md");
    assert.ok(popularIdx >= 0 && unpopularIdx >= 0, "both pages should appear");
    assert.ok(popularIdx < unpopularIdx, "popular page should rank higher");
    boostDb.close();
  });

  it("removeStale removes unlisted paths", () => {
    db.upsertPage(
      { path: "wiki/keep-me.md", title: "Keep", content: "keep", category: "wiki", lastModified: Date.now() },
      fakeEmbedding(11)
    );
    db.upsertPage(
      { path: "wiki/remove-me.md", title: "Remove", content: "remove", category: "wiki", lastModified: Date.now() },
      fakeEmbedding(12)
    );
    const existing = new Set<string>();
    const all = db.search(fakeEmbedding(1), 100, undefined, 0.0);
    for (const r of all) {
      if (r.path !== "wiki/remove-me.md") existing.add(r.path);
    }
    const removed = db.removeStale(existing);
    assert.ok(removed >= 1);
    assert.ok(!db.isIndexed("wiki/remove-me.md", 0));
    assert.ok(db.isIndexed("wiki/keep-me.md", 0));
  });

  it("getStats aggregates correctly", () => {
    const stats = db.getStats();
    assert.ok(stats.totalPages > 0);
    assert.ok("wiki" in stats.categories);
    assert.ok(stats.lastIndexed !== null);
  });

  it("search respects minScore filter", () => {
    const results = db.search(fakeEmbedding(9999), 5, undefined, 0.99);
    assert.equal(results.length, 0);
  });

  it("migrates vectors.json to SQLite", async () => {
    const migDir = freshDir();
    const embDir = path.join(migDir, ".embeddings");
    fs.mkdirSync(embDir, { recursive: true });
    const fixture = {
      entries: [{
        path: "wiki/migrated.md", title: "Migrated", content: "from json",
        category: "wiki", lastModified: Date.now() - 10000, indexedAt: Date.now() - 10000,
        embedding: Array.from(fakeEmbedding(50)),
      }],
    };
    fs.writeFileSync(path.join(embDir, "vectors.json"), JSON.stringify(fixture));
    const db2 = new VectorDB(migDir);
    await db2.ready();
    assert.ok(db2.isIndexed("wiki/migrated.md", 0));
    assert.ok(fs.existsSync(path.join(embDir, "vectors.json.migrated")));
    assert.ok(!fs.existsSync(path.join(embDir, "vectors.json")));
    assert.equal(db2.getStats().totalPages, 1);
    db2.close();
  });

  it("rejects corrupted embedding blobs", async () => {
    const corruptDir = freshDir();
    const db3 = new VectorDB(corruptDir);
    await db3.ready();
    db3.upsertPage(
      { path: "wiki/good.md", title: "Good", content: "valid page", category: "wiki", lastModified: Date.now() },
      fakeEmbedding(70)
    );
    db3.close();
    // Inject a corrupt blob (5 bytes — not divisible by 4) directly via SQL
    const SQL = await initSqlJs();
    const dbPath = path.join(corruptDir, ".embeddings", "vectors.db");
    const buf = fs.readFileSync(dbPath);
    const rawDb = new SQL.Database(buf);
    rawDb.run(
      "INSERT OR REPLACE INTO pages (path, title, content, category, lastModified, indexedAt, embedding, accessCount, lastAccessed) VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL)",
      ["wiki/corrupt.md", "Corrupt", "corrupt page", "wiki", Date.now(), Date.now(), new Uint8Array([1, 2, 3, 4, 5])]
    );
    const exported = rawDb.export();
    fs.writeFileSync(dbPath, Buffer.from(exported));
    rawDb.close();

    const db4 = new VectorDB(corruptDir);
    await db4.ready();
    assert.throws(() => {
      db4.search(fakeEmbedding(70), 10, undefined, 0.0);
    }, /Invalid embedding blob size/);
    db4.close();
  });

  it("reopens existing SQLite database", async () => {
    const reopenDir = freshDir();
    const db1 = new VectorDB(reopenDir);
    await db1.ready();
    db1.upsertPage(
      { path: "wiki/persist.md", title: "Persist", content: "test", category: "wiki", lastModified: Date.now() },
      fakeEmbedding(60)
    );
    db1.close();
    const db2 = new VectorDB(reopenDir);
    await db2.ready();
    assert.ok(db2.isIndexed("wiki/persist.md", 0));
    assert.equal(db2.getStats().totalPages, 1);
    db2.close();
  });
});
