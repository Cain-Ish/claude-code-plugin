# SP-D — Bounded Retention (design)

- **Date:** 2026-06-05
- **Status:** spec → built (0.24.23), with SP-D4 (wiki-archive) deferred
- **Sub-project:** D of the autonomous-knowledge-loop roadmap (A ✅ · B ✅ · C ✅ · D retention · E project-continuity)
- **Grounded by:** the 2026-06-05 SP-D discovery (live footprint · current retention · prune-safety by reversibility).

## Verdict — hygiene, not disk pressure

Live `~/.second-brain/` is 575M, but **519M (90%) is `vector-deps/`** — the content-hash-gated embedding runtime that is *replaced, never appended*. The genuinely-growing footprint is ~32M, and it is **entirely regenerable**: ~16M of dead embedding-cache vectors (66% of keys had no live exchange) + ~16M of abandoned `*.bak`/`*.tgz` snapshots. So SP-D is **correctness, not reclaim**: plug the one true unbounded leak, and do it where deletion can never cost knowledge.

## The policy splits on reversibility

| Class | Recommendation | Why |
|---|---|---|
| Embeddings-cache (stale vectors) | **GC on** — drop entries with no live exchange | Regenerable from transcripts; the only unbounded leak. Zero knowledge risk. |
| `*.bak`/`*.tgz` snapshots | **TTL 14d** (recent kept) | One-shot dead weight. |
| Dream archives (terminal staging) | **keep-last-N (5), config-driven** | Terminal + already applied on accept. |
| Transcripts | **NEVER prune on extraction** | The raw re-extraction + episodic source. |
| **Wiki-archive** | **OFF (`ttl=0`)** — *deferred* | The **irreversible sole copy** of FORGET'd pages + the auto-restore source. Pruning destroys knowledge AND breaks auto-restore. |
| episodic-index | **leave alone** | Single rebuildable file, no per-row terminal state. |

## Built (0.24.23)

**`scripts/sb-prune-archives.sh`** — deterministic, content-free, zero-credential. Run as **step 4 of `maintain-deterministic.sh`**, so it inherits the `auto_improve` hard-gate + the drainer's CLAUDECODE-refuse/defer/single-flight guards + the `.last-maintain` throttle — **no new timer, no new credential surface**. Does exactly two things:
- **(a) Embeddings-cache GC** (`retention.embeddings_cache_gc`, default on) — rewrites `.embeddings-cache.json` keeping only `episodic:<id>` entries whose id is in the live `episodic-index.json` exchange set (+ the transient `concept-*`). Atomic `jq … > tmp && mv`; lossless (a missed vector re-embeds on next search).
- **(b) `*.bak`/`*.tgz`/`*.pre-rebuild-*` prune** (`retention.bak_ttl_days`, default 14) — `find -mtime` past the TTL; recent backups survive.

**`scripts/dream-snapshot.sh`** — the create-time count-cap is now **config-driven** (`retention.dream_keep_count`, default 5) and still terminal-only (deletes only `archived_at`-stamped dreams, oldest-first; never pending/running/completed-unreviewed). This bound is **always-on** (every dream create), independent of `auto_improve`.

**`config.json`** — `ensure-dirs.sh` seeds a self-documenting `retention` block (values = today's caps, so absent keys fall back identically via `sb_config_get`). `wiki_archive_ttl_days: 0` = NEVER.

## Deferred (SP-D4 — irreversible, operator-verified)

The **wiki-archive TTL** is NOT implemented. It is the one irreversible delete: it destroys the sole copy of a forgotten page and silently disables auto-restore (which hard-requires the file). When built, it must be `ttl=0` default, ≥90–180d when enabled, append a `purged` event, and ship with a reconcile lint that warns on net-archived-but-missing-file zombies — and it needs a human to confirm "is this the right thing to forget forever." The `wiki_archive_ttl_days` key is seeded (off) as the placeholder. Also deferred (minor): `.extraction-state.jsonl` compaction + `error-log.jsonl` rotation.

## Verification

- **Linux-CI:** `test-sb-prune-archives.sh` — GC keeps live + concept, drops dead, honours the off switch; `.bak` recent-kept/old-pruned; transcripts + episodic-index never touched; a code-line guard that the wiki-archive is never operated on. `test-config-reader.sh` — the seeded retention block (wiki-archive off, GC on). `test-dream-lifecycle.sh` — the keep-count cap still bounds (default 5), terminal-only.
- **Operator (Pi):** with `auto_improve:true`, an idle-window drain reclaims the ~16M dead cache keys + old `.bak`/`.tgz`; the live wiki + transcripts + wiki-archive are untouched.

## Rollout

Additive; gated; version bump + migration row. No MCP change. With `auto_improve:false` (the seed) the GC never runs; the dream cap is byte-equivalent to the prior hardcoded-5 behaviour.
