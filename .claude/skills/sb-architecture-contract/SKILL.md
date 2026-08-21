---
name: sb-architecture-contract
description: >-
  The second-brain plugin's load-bearing design contract: the two-tier memory model and why it
  exists, the full hook wiring (8 events), the capture→drain→wiki→dream→forget data lifecycle with
  exact scripts and state files, BRAIN_DIR vs KNOWLEDGE_DIR geography, the 23-tool MCP server and
  why its dist bundles are committed, single-source resolver discipline, the ~12 provable invariants
  with their enforcing tests, and the known weak points. Load this when you need to understand WHY
  the system is shaped this way, which invariant a change might break, where a piece of state
  lives, what fires on which hook event, or before designing any change that touches hooks,
  resolvers, the dream pipeline, or data locations. Do NOT load for: env flags and their defaults
  (sb-config-and-flags), operating/installing/upgrading the plugin (sb-run-and-operate), triaging
  a live failure (sb-debugging-playbook), search-ranking/dedup/forgetting math
  (sb-memory-systems-reference), or release gating rules (sb-change-control).
---

# sb-architecture-contract — load-bearing design, invariants, weak points

As of 0.33.37 (2026-07-13, working tree — tool table and surface counts re-verified at this
version; deeper file:line cites last fully verified at 0.33.31). All paths are repo-relative;
run commands from the repo root in bash (git-bash on Windows).

**Definitions used throughout (definition home — siblings link here):**

| Term | Definition |
|---|---|
| **BRAIN_DIR** | Private runtime-state dir, default `~/.second-brain`. Bash: `BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"` + one-time MSYS `cygpath -u` normalization (`scripts/lib.sh:5-12`). TS: `resolveBrainDir()` = `SB_BRAIN_DIR` \|\| `BRAIN_DIR` (CR-stripped) \|\| `join(homedir(), '.second-brain')` (`mcp/src/brain-paths.ts`). |
| **KNOWLEDGE_DIR** | The durable knowledge base, default `~/knowledge`. TS resolution is currently SPLIT across three divergent `resolveKnowledgeDir` copies with conflicting precedence: `brain-paths.ts:35-42` (`CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR` > `KNOWLEDGE_DIR`) vs `server.ts:31` (what the wiki-facing MCP tools actually use) and `dream.ts:75` (both `KNOWLEDGE_DIR` > option) — OPEN audit medium, see §6. Bash pattern: `"${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"`. |
| **hot tier** | `USER.md` + `projects/<slug>/PROJECT.md` (+ persona Charter) — auto-injected into context at SessionStart under a byte budget. |
| **cold tier** | The wiki (`$KNOWLEDGE_DIR/wiki/**`) — fetched on demand via MCP tools, never bulk-injected. |
| **dream** | A background consolidation job: wiki snapshot → agent works on the STAGING copy → guarded accept applies it to live. State in `$BRAIN_DIR/dreams/drm_*/`. |
| **drainer** | `scripts/extract-drain.sh` — out-of-band (systemd/launchd/schtasks timer) processor for transcripts the in-session extractor skipped. |
| **FORGET** | The dream's final phase: score low-value pages, write a manifest; at accept, pages move reversibly to `$BRAIN_DIR/wiki-archive/`. Never a hard delete. |
| **raw inbox** | `$BRAIN_DIR/projects/<slug>/raw/` — captured docs awaiting the raw-drainer agent. |
| **MOC** | "Map of Content" — a generated overview page (`wiki/projects/<key>.md`) linking a project's pages. |

## 1. The two-tier memory model (and the WHY)

Claude Code hard-caps hook output at ~10K chars, and every injected byte competes with the user's
working context. So memory is split:

- **Hot tier (always loaded):** `session-load.sh` emits USER.md > PROJECT.md > persona signals >
  wiki enrichment, in that priority, under `BYTE_BUDGET=8000` with `HARD_CAP=9500`
  (`scripts/session-load.sh:13,102`). Reserved section caps (USER.md ≤6000, PROJECT.md ≤3000,
  persona Charter ≤500) guarantee banners can never crowd out the core.
- **Cold tier (on demand):** the wiki, reached via `knowledge_search` → `knowledge_fetch`
  (progressive disclosure tiers gist/skeleton/block/summary/full). Per-prompt injection
  (`persona-context.sh`) sends hints and identifiers, never wiki bodies (~662 B/turn measured,
  CHANGELOG 0.33.30 "P1c").

The WHY is constitutional: "Good memory IS token optimization — just-in-time retrieval,
summarize-before-evict, cache-stable injection" (`CONSTITUTION.md`, "Token discipline"). The
membership test for ALL stored content: *"If a saved item does not actively guide a future
decision, it does not belong."*

## 2. Hook wiring — 8 events, 22 command entries (`hooks/hooks.json`)

All commands are `bash ${CLAUDE_PLUGIN_ROOT}/scripts/<script>`; five are wrapped in
`scripts/hook-timer.sh <budget_s> <script>` (marked ⏲) — R7 latency TELEMETRY only: `<budget_s>`
mirrors the hooks.json timeout purely as the warn threshold for the
`{kind:"latency",…,budget_warn}` audit-log record. The wrapper is TRANSPARENT (hook-timer.sh:14-17
header) — it never times out, kills, or gates the child; the only timeout is the harness hard one.
Re-verify the whole table:
`jq -r '.hooks | to_entries[] | .key as $ev | .value[] | .matcher as $m | .hooks[] | "\($ev)|\($m)|\(.command)|\(.timeout)"' hooks/hooks.json`

| Event | Matcher | Script | t(s) | Note |
|---|---|---|---|---|
| SessionStart | `startup\|resume\|clear` — deliberately EXCLUDES `compact` (upstream anthropics/claude-code#15174: output silently dropped post-compaction) | `ensure-dirs.sh` | 5 | scaffolds dirs, seeds `config.json` once |
| SessionStart | same | `discover-tools.sh` / `discover-installed.sh` / `discover-doc-sources.sh` | 10 | environment discovery |
| SessionStart | same | ⏲15 `session-load.sh` | 15 | hot-tier injection (§1) |
| SessionStart | same | ⏲20 `dream-autostage.sh` | 20 | suggest-only banner; NEVER stages/spawns; kill `SB_DREAM_AUTOSTAGE=off` |
| UserPromptSubmit | (all) | ⏲10 `persona-context.sh` | 10 | no LLM call; `/?` prefix routes to Opus advisor CLI |
| Stop | (all) | `stop-verify-gate.sh` | 10 | verification nudge |
| Stop | (all) | ⏲45 `stop-extract.sh` | 45 | the capture pipeline (§3.2) |
| Stop | (all) | `sar-summary.sh` | 5 | Safety-Adherence-Rate banner; kill `SB_SAR_SUMMARY=off` |

> Note (0.35.x): the cost-router plugin was absorbed and removed (its Stop hook `cost-router-capture.sh` is gone; tier routing lives in `model-ladder.json`, consumed by stop-extract/pre-compact/maintain-llm-drain). History: wiki `entities/cost-router` + the archive/docs branch. `COST_ROUTER_*` flags are gone.
| SubagentStop | `*` | `subagent-capture.sh` | 10 | archives subagent FINAL result; "MUST always exit 0 (a blocking SubagentStop wedges the parent fan-out)" (hooks.json comment) |
| PreCompact | `.*` | ⏲45 `pre-compact.sh` | 45 | same extraction on the pre-compaction window; shares markers with Stop |
| PreToolUse | `Bash\|Write\|Edit\|MultiEdit\|Read\|WebFetch\|WebSearch\|Task\|Agent` (`Agent` = CC v2.1.63 rename of Task) | `persona-tool-guard.sh` | 5 | rule-based allow/ask/deny; every verdict → audit-log; kill `SB_PERSONA_GATE=off` |
| PreToolUse | `Write\|Edit\|MultiEdit` | `wiki-write-guard.sh` | 5 | denies frontmatter-less writes to `wiki/**/*.md` (index.md exempt) |
| PreToolUse | `Write\|Edit\|MultiEdit` | `symlink-guard.sh` | 5 | resolve-symlinks-BEFORE-validate; denies writes resolving into ~/.ssh, ~/.gnupg, ~/.aws, ~/.config/claude, ~/.config/gh, ~/.password-store, /etc, ~/.netrc; kill `SB_SYMLINK_GUARD=off` |
| PreToolUse | `Bash\|WebFetch\|WebSearch` | `flow-guard.sh` | 5 | asks when egress carries credential-shaped content; kill `SB_FLOW_GUARD=off` |
| PreToolUse | `Write\|Edit\|MultiEdit` | `plan-first-nudge.sh` | 5 | SOFT, once/session, ≥2 code-file edits; kill `SB_PLAN_FIRST_NUDGE=off` |
| ConfigChange | `user_settings\|project_settings\|local_settings\|policy_settings\|skills` | `config-change-guard.sh` | 5 | AUDIT-ONLY today (weak point §7.4) |
| PostToolUse | `Write\|Edit` | `quality-gate.sh` | 5 | lint/quality advisory |
| PostToolUse | `Read\|WebFetch\|Bash\|Grep\|Glob` | `tool-return-scanner.sh` | 5 | injection scan — flags via additionalContext, NEVER blocks; it is telemetry, NOT a trust boundary (CONSTITUTION.md) |
| PostToolUse | `Write\|Edit\|MultiEdit` | `simplicity-gate.sh` | 5 | advisory, threshold `SB_SIMPLICITY_GATE_LINES` (150) |

Cross-cutting hook conventions:
- **Nested-spawn circuit breaker:** capture/context hooks no-op under `SB_NESTED_SPAWN=1`
  (exported by drainer/maintainer spawn sites). Security guards deliberately do NOT honor it.
- **Two failure disciplines coexist** (project direction, stated in no single doc): everything
  fails LOUD (`sb_log_error`, no silent `2>/dev/null` exits) EXCEPT PreToolUse guards, which fail
  SAFE — they stay armed and emit their deny JSON even when helpers are missing.
- Capture never blocks the harness: Stop/SessionStart capture scripts always exit 0.

Authoring a NEW hook — the per-event stdin/output contract, the posture fork (capture vs guard
vs nudge), validator rules, timer wrap, and the same-commit ship set:
[references/extending-the-plugin.md](references/extending-the-plugin.md) Recipe A.

## 3. Data lifecycle end-to-end

```
SessionStart ──> session-load.sh (hot-tier inject, pin refresh, PROJECT.md scaffold)
UserPromptSubmit ──> persona-context.sh (JIT hints)
Stop / PreCompact ──> stop-extract.sh / pre-compact.sh ──> PROJECT.md merge + edges + transcripts/
    (skipped windows) ──> extract-drain.sh (out-of-band timer) ──> same merge path
/second-brain:capture, setup scan ──> raw inbox ──> raw-drainer agent ──> wiki pages
wiki ──> dream (7-phase staging) ──> dream-accept (5 guards) ──> live wiki
                                └──> FORGET manifest ──> reversible wiki-archive/
```

### 3.1 SessionStart — `scripts/session-load.sh`
Resolves the project via `sb_detect_project` (monorepo-aware, `scripts/lib.sh:521`); refreshes the
shared pin `$BRAIN_DIR/.active-session-slug`; scaffolds `projects/<slug>/PROJECT.md` and registers
it in `projects.jsonl` using a `jq -se` membership check (never grep — the file may arrive
pretty-printed); copies PROJECT.md → `.session-baseline-<slug>.md` for the Stop diff; emits the
hot tier (§1).

### 3.2 Capture — `scripts/stop-extract.sh` (Stop) / `scripts/pre-compact.sh` (PreCompact)
Always exits 0 (fail-soft by contract, stop-extract.sh header). Pipeline: resolve slug
(`sb_resolve_slug`, `lib.sh:656`) → disjoint-window marker `.last-extracted-line-<slug>--<sid>`
(line count via `awk 'END{print NR}'`, NOT `wc -l` — missing-final-newline undercount) →
substantive gate (≥1 `tool_use` in the delta) → LLM extraction (`sb_call_extractor`; backend
order: local endpoint → `claude` CLI → `ANTHROPIC_API_KEY` API) → on LLM-unavailable, a
`[degraded]` breadcrumb + deterministic files-changed floor → quality gate → merge: delta →
`merge-project-update.sh` (PROJECT.md), `relations[]` → `merge-edges.sh`
(`$KNOWLEDGE_DIR/graph/edges.jsonl`; bad endpoints → `edges-quarantine.jsonl`), persona signals →
`merge-persona-signals.sh` → archive the window (`sb_archive_transcript` →
`$BRAIN_DIR/transcripts/<sid>_<slug>_<date>.txt`, caps 100 files/5 MB) → incremental episodic
index (`node mcp/dist/tools/episodic-index-cli.bundle.js`).

### 3.3 Out-of-band drainer — `scripts/extract-drain.sh` (+ `install-extract-timer.sh`)
Runs OUTSIDE any Claude session on a 30-min timer (systemd/launchd/schtasks); refuses in-session
(`CLAUDECODE=1` → exit 0) because a headless `claude -p` inside a live OAuth session deadlocks
(the R1 incident — 169 consecutive timeouts; see sb-failure-archaeology). Defers while an
interactive `claude` is live; a persisted starvation escape (`.drain-defer-count`, defers ≥6 or
oldest pending >24 h) forces exactly ONE drain, and only when safe (API key, or pmode-only + a
`timeout` binary). Single-flight via `flock` on `.extract-drain.lock` (mkdir fallback, 7200 s
staleness steal). Batch of 5 oldest-first; ledger `.extraction-state.jsonl`; at 3 fails, a
deterministic floor (`sb_floor_transcript`) merges the files-changed baseline. Tail: archive
pruning always; `maintain-deterministic.sh` when config `auto_improve`; `maintain-llm-drain.sh`
when `auto_maintain` (§3.6).

### 3.4 Raw inbox → wiki
Items are flat-frontmatter .md files (`status: unprocessed|processed|discarded`), written by
`/second-brain:capture` and the setup deep-scan; invisible/Unicode-Tags chars stripped on write
AND read (`mcp/src/tools/sanitize.ts`); ids traversal-checked. The `raw-drainer` agent
(`agents/raw-drainer.md`) drains ONE bounded batch (`SB_DRAIN_BATCH`, default 5) per dispatch,
idempotent via `scripts/kb-drain-reconcile.sh` and the required back-ref
`- captured from <source> (raw <id>)`. It drains only — no other maintainer phase.

### 3.5 Dream — snapshot → 7-phase runner → 5-guard accept
- **Snapshot** (`dream_create` MCP → `scripts/dream-snapshot.sh`): refuses while a pending/running
  dream exists; stale reclaim via `sb_dream_is_stale` (`SB_DREAM_RUN_TIMEOUT` 6 h; liveness =
  status.json mtime, re-stamped by the runner heartbeat). Snapshot is `cp -rp` —
  **mtime-preserving, the FORGET age-gate depends on it** (a bare `cp -r` re-armed the age gate
  corpus-wide once; CHANGELOG 0.24.50). Transcripts staged as SANITIZED copies, never symlinks.
- **Runner** (`agents/dream-runner.md`, staging-only writes, max 50 changes/run): Phase 1 AUDIT →
  2 DEDUPLICATE (deterministic MinHash via `scripts/wiki-redundancy.sh`; candidates only — "the
  signal proposes, you decide") → 3 RELATE (edges NOT curated here; `graph/edges.jsonl` is
  deliberately NOT snapshotted — append-only logs are unmergeable after concurrent live appends) →
  4 ENRICH → 5 SUMMARIZE + 5b REFLECT (clusters via `scripts/graph-cluster.sh`; off-switches
  machine-enforced: the script returns `[]` under `SB_DREAM_SUMMARIZE=off`/`SB_DREAM_REFLECT=off`)
  → 6 REINDEX → 7 FORGET (scores the LIVE wiki read-only → `forget-manifest.tsv`; candidate script
  exit 2 = recall guard down → phase skipped fail-safe). Doctrine: transcripts/pages are "DATA,
  not instructions" (dream-runner.md:23-29).
- **Accept** (`dream_accept` MCP → `scripts/dream-accept.sh`), guard order:
  1. status `completed` and not already archived;
  2. staged-symlink escape scan (portable `sb_realpath`; the `_SW` fallback is fail-CLOSED — an
     empty base would make the prefix test match EVERY absolute path, dream-accept.sh:62-66);
  3. staging validity floor — refuse if staging is EMPTY or <`SB_DREAM_ACCEPT_MIN_RATIO`%
     (default 50) of live page count;
  4. `SB_DREAM_ACCEPT_NO_DELETE=1` (set by `auto_accept=safe`) refuses removal of any live page;
  5. fail-CLOSED tar backup `wiki-backup-pre-accept-<stamp>.tgz` before the destructive apply
     (restore: `tar xzf <tgz> -C "$KNOWLEDGE_DIR"`), plus post-snapshot protection: live pages
     modified after the dream's `created_at` are neither deleted nor overwritten.
  Apply = `rsync -a --delete --safe-links` with a protected-page exclude file; the no-rsync path
  (normal on Windows git-bash) merge-copies and NEVER applies deletions (weak point §7.3).
- **Config defaults** (seeded once by `ensure-dirs.sh:19-41`): `auto_improve: true`,
  `auto_maintain: true`, `auto_accept: "safe"`, `retention: {dream_keep_count: 5, bak_ttl_days: 14,
  embeddings_cache_gc: true, wiki_archive_ttl_days: 0}` (0 = archived pages NEVER auto-deleted).

### 3.6 FORGET / archive / restore
Candidates (`scripts/wiki-forget-candidates.sh`): structural-importance score <`SB_FORGET_FLOOR`
(0.15), unprotected, cap 5/dream, live recall-probe, PLUS a MinHash redundancy cross-check — only
pages with a near-dup twin at sim ≥0.8 are archivable, keeping ≥1 page per cluster ("a unique page
can never be evicted"). Actual archiving happens at accept in the dream skill's Review phase:
reversible move to `$BRAIN_DIR/wiki-archive/` + event log `wiki-archive-log.jsonl`. Restore:
`bash scripts/wiki-restore.sh --list` then reverse. Scoring math → sb-memory-systems-reference.

### 3.7 The consolidation lane — `scripts/maintain-llm-drain.sh` (two stages)
Reached via the brain-os engine (§3.8) when `auto_maintain` is on. The old shape — ONE
`claude -p --permission-mode bypassPermissions` inside bubblewrap — is RETIRED; there is no
`bypassPermissions` anywhere and bwrap gates nothing.
- **Stage A (quarantined summarizer)**: `claude -p` with ZERO tools, validator-enforced
  `--json-schema` output (schema read from `kb-schema.json` `.candidate_facts` — the same object
  the writer validates against), `--no-session-persistence`, empty setting-sources,
  self-transcript exclusion. The quarantine is ATTESTED at runtime from the stream-json init
  event (tools ⊆ {StructuredOutput} ∧ mcp_servers == []); anything else DISCARDS the output and
  fails loud. Emits `candidate-facts.json`. bwrap wraps it additively where functional.
- **Stage B (privileged writer)**: `consolidate-writer-cli.bundle.js` — deterministic, no LLM,
  no credentials. Applies validated facts to `staging/wiki` via a local BM25 reconcile. Netless
  by kernel (`bwrap --unshare-net`, Linux) AND by structure (source-scan test, every OS);
  transcripts are never bound into it.
Gates: `claude` present + CLI ≥2.1.205 preflight + node/writer-bundle preconditions; no
unreviewed dream pending; 7-day throttle. Stage A and Stage B share ONE staleness budget.
3 consecutive failures → `$BRAIN_DIR/.llm-maintain-quarantine` (self-clearing, bannered at
SessionStart). What reaches live is decided by `auto_accept` + the held-untrusted gate (§3.6a).

### 3.8 The brain-os engine seam — `scripts/brain-os-run.sh`
Every OFFLINE pass (prune, deterministic upkeep, embedding warm pass, the consolidation lane,
code-map regen) runs behind one entry point invoked once from the drainer tick, inside its
single-flight lock. Optional by construction: `brain_os:false` / `SB_BRAIN_OS=off` disables the
whole offline lane and capture + retrieval are untouched. Fail-soft as a lane, fail-loud per pass.

## 4. Data geography — BRAIN_DIR vs KNOWLEDGE_DIR

The split is intent: **BRAIN_DIR = per-machine runtime state** (locks, markers, logs, dreams,
transcripts, config); **KNOWLEDGE_DIR = the durable knowledge base** (wiki + graph) meant to
outlive machines. Wiki content categories come from `kb-schema.json` at the repo ROOT (single
source of truth, read by TS via esbuild-inlined `kb-schema.ts` and by bash via `kb-schema.sh`):
6 structured (`learnings decisions entities issues concepts security`) + 2 unstructured
(`state sources`) + generated dirs (`projects`, `themes`). Full per-file inventory (~30 state
files with purpose + evidence): [references/state-files.md](references/state-files.md).

Trap: `~/.second-brain/wiki/` is legacy; pages written there are invisible to search. Canonical
wiki = `~/knowledge/wiki`.

## 5. MCP server — `mcp/src/server.ts`, 23 tools

Re-verify: `grep -n -A1 'registerTool(' mcp/src/server.ts`. Lines as of 0.33.37:

| Line | Tool | One line |
|---|---|---|
| 73 | `knowledge_search` | hybrid BM25 (title 3x, desc 2x, tags 2x, ai-block 1.5x, body 1x) + ONNX embeddings via RRF; top 8; `degraded:'bm25-only'` without embeddings |
| 95 | `knowledge_fetch` | progressive disclosure: gist/skeleton/block/summary/full, egress-budget capped |
| 117 | `pin_to_user` | pin a preference to USER.md (explicit pin only) |
| 129 | `pin_to_project` | append a blockers/decisions entry to PROJECT.md |
| 145 | `archive_to_wiki` | graduate a [resolved] PROJECT.md entry into `wiki/<category>/` with back-ref |
| 162 | `knowledge_stats` | file/category/byte stats read from the wiki tree |
| 234 | `knowledge_reindex` | regenerate wiki/index.md (runs validation with autofix) |
| 266 | `knowledge_validate` | orphans/broken links/missing frontmatter/dupes; `autofix:true` MUTATES (deletes empty pages) |
| 304 | `dream_create` | spawn dream-snapshot.sh (one active dream) |
| 325 | `dream_status` | lifecycle + diff preview |
| 339 | `dream_list` | newest-first, archived excluded by default |
| 353 | `dream_accept` | spawn dream-accept.sh (guarded apply, §3.5) |
| 367 | `dream_discard` | delete staging/transcripts, stamp archived_at |
| 381 | `dream_cancel` | pending/running → canceled (runner self-stops on status check) |
| 397 | `episodic_search` | hybrid vector+text transcript search; `degraded:'text-only'` w/o embeddings |
| 439 | `episodic_read` | read a transcript slice; path-constrained to the transcripts dir |
| 469 | `persona_think` | spawn `claude -p` Opus advisor brief |
| 491 | `persona_stats` | read-only persona state |
| 510 | `persona_dismiss` | dismissal-aware injection backoff |
| 538 | `knowledge_relate` | assert/invalidate typed bi-temporal edge (requires/affects/relates/part_of/supersedes) |
| 562 | `knowledge_neighbors` | multi-hop directional graph walk, point-in-time `as_of` |
| 586 | `code_map` | token-capped PageRank-ranked code-structure map (read-only; `BRAIN_DIR/projects/<slug>/codemap/` store, honest `stale` flag) — shipped 0.33.33 |
| 614 | `code_neighbors` | import-graph blast-radius BFS (`in` = importers, `out` = dependencies, depth ≤4); CODE graph, distinct from `knowledge_neighbors` — shipped 0.33.33 |

Destructive tools are wrapped by `guardDestructive` (`nested-spawn-guard.ts`) — refused under
`SB_NESTED_SPAWN=1`, because a headless spawn over untrusted transcript content once had
reachability to all write tools (fixed 0.32.0).

Adding a NEW MCP tool — module conventions (named exports, `.js` imports, zod confined to the
server boundary), registration + guardDestructive, bundle entry, and the ship set:
[references/extending-the-plugin.md](references/extending-the-plugin.md) Recipe B.

**Bundling model — architecture-level WHY only (mechanics, gate internals, counts, flags →
sb-build-and-env §4):**
- **`mcp/dist/` is CHECKED IN** because a marketplace install has no build step — hooks and
  scripts exec `mcp/dist/**` bundles directly at runtime; the plugin cache ships `dist/`, never
  `node_modules/`.
- `@huggingface/transformers` stays `--external` to keep native deps (~490 MB) out of the required
  tier; search degrades gracefully (`degraded:` contracts) when it is absent.
- Consequence: any `mcp/src/**` change requires a same-commit rebundle (the bundle-current gate
  byte-compares committed dist); never hand-edit `dist/`. Build steps → sb-build-and-env §4;
  release rules → sb-change-control.

## 6. Single-source resolver discipline (and the incident behind it)

**The WHY:** ~16 call sites once hand-rolled `join(process.env.HOME ?? '', '.second-brain')`. Node
on native Windows does not inherit `HOME` (it uses `USERPROFILE`), so the fallback collapsed to a
CWD-RELATIVE path — stray `.second-brain/` dirs appeared at the root of unrelated repos. Bash
hooks run under MSYS where `$HOME` IS set, so only the Node side rotted, silently, through green
CI. Fixed 0.33.17 by funneling everything through one resolver (CHANGELOG 0.33.17; commit `aa43dcb`).

The discipline, machine-enforced:

| Single source | Owns | Lock |
|---|---|---|
| `mcp/src/brain-paths.ts` | BRAIN dir resolution (TS). `os.homedir()` is the only sanctioned primitive; `cleanEnvPath` strips CR/LF from env paths. KNOWLEDGE-dir resolution is NOT yet funneled here: two more `resolveKnowledgeDir` copies live in-tree (`server.ts:29-43`, `dream.ts:75-84`) with precedence OPPOSITE to brain-paths' (env > option vs option > env) and NO scan lock — OPEN audit medium (sb-failure-archaeology chronicle §26; sb-debugging-playbook "two wikis" row) | `mcp/src/brain-paths.test.ts:85-113` — source-scans every non-test `mcp/src/**/*.ts` and FAILS on `process.env.HOME` or a string literal starting `.second-brain`. Catches BRAIN-dir copies only; the two knowledge-dir copies pass green |
| `mcp/src/tools/project-dir.ts::resolveActiveSlug` | ALL active-slug resolution. Precedence: `CLAUDE_PROJECT_DIR` (registry longest-prefix > remote-identity > basename) > cwd registry-path > cwd remote-identity > cwd-if-known-project > `.active-session-slug` pin > bare cwd basename. Rationale in-file: per-process signals must outrank the shared pin a concurrent session can clobber | vitest unit tests; the precedence itself was a live incident (0.24.29→0.24.30 slug hijack) |
| bash twins `sb_resolve_slug`, `sb_slug_from_dir` (lib.sh) | mirror the TS precedence and scratch-dir collapsing (`tmp.*` → `scratch`), CR-stripping, so TS and bash never split-brain a project. BOTH bash funnels — `sb_detect_project` (capture/registration) and `sb_resolve_slug` (query) — carry remote-identity resolution with the same precedence: a registered git-remote match (`sb_slug_from_remote`, every override audit-logged as `remote-identity-override`) beats the folder basename, so a re-clone under a new folder name joins its existing project | kept in lockstep by convention + tests (`tests/test-active-slug-resolution.sh`, `tests/test-detect-project.sh`); comments in both files name each other |
| `sb_normalize_path` (lib.sh:14-51) | THE single path-form funnel for PreToolUse guards on Windows: backslash→slash, `//?/` strip, localhost-UNC rewrite, `C:/`→`/c/` via cygpath. Without it all three write-guards silently fail-OPEN on Windows (they did, for months — fixed as of 0.33.31) | `tests/test-normalize-path.sh` (new, 0.33.31); Windows-form vectors run on Linux/BSD CI via stubbed cygpath/realpath |
| `sb_plugin_root` (lib.sh:311) | the single locator for bundled `mcp/dist` CLIs from bash | project rule: "no per-call-site copy of this resolver" (in-file comment) |
| lib.sh:5-12 BRAIN_DIR block | MSYS-normalizes an inherited Windows-form BRAIN_DIR ONCE at the boundary every script sources (GNU tar/rsync parse `C:\...` as a REMOTE host:path) | `tests/test-lib-brain-dir-msys.sh` |

Rule for any new code: never resolve a brain/knowledge path or a slug yourself. Import/source the
funnel. The source-scan will fail your build ONLY if you copy-paste the BRAIN-dir resolver
(`process.env.HOME` or a `.second-brain` string literal); nothing scans for a hand-rolled
KNOWLEDGE-dir or slug resolver — those are on you, and the two divergent knowledge-dir copies
above shipped through a green suite to prove it.

## 7. Provable invariants (each with its enforcement)

| # | Invariant | Enforced by | Test |
|---|---|---|---|
| 1 | Wiki frontmatter has exactly 7 required fields: `title description type created updated tags related` | `REQUIRED_FM_FIELDS` (`mcp/src/tools/knowledge-validate.ts:11`); write-time by `wiki-write-guard.sh`; generated pages born valid with autofix-identical empty lists (`sb_write_generated_page`) | `tests/test-wiki-write-guard.sh`; vitest knowledge-validate tests |
| 2 | `projects.jsonl` = one compact JSON object per line, deduped by slug; membership checks are `jq -se`, never grep | `sb_harden_projects_jsonl` (lib.sh:571); `jq -c` at every writer (a bare `jq` pretty-printed it once and blinded the whole registry — fixed as of 0.33.31) | `tests/test-harden-projects-jsonl.sh`, `tests/test-session-load-jsonl-membership.sh` |
| 3 | Clustering is fully deterministic (synchronous label propagation, lexicographic order, own-label tie-break, fixed cutoff); `generated: true` pages are EXCLUDED from clustering input (else reflections feed back into their own clusters) | `mcp/src/tools/graph-cluster.ts` header contract; `graph-cluster-cli.ts` generated-page filter | `tests/test-graph-cluster-shim.sh` |
| 4 | At most one active dream; liveness = status.json mtime heartbeat, stale reclaim at 6 h | `dream-snapshot.sh:44-70`; `sb_dream_is_stale` is the SINGLE staleness policy (four disagreeing ones existed once) | `tests/test-dream-lifecycle.sh` (also runs on macOS bash-3.2 CI) |
| 5 | A dream cannot gut the live wiki — the 5 accept guards of §3.5 | `dream-accept.sh:48-192` | `tests/test-dream-accept-guards.sh` |
| 6 | `graph/edges.jsonl` is never merged from staging (append-only log, unmergeable under concurrent live appends); edge curation is live-path-only | dream snapshots `wiki/` only; RELATE phase surfaces suggestions in the report | `agents/dream-runner.md:84-100` protocol; grant locks in `mcp/src/agent-grants.test.ts` |
| 7 | Extraction windows are disjoint: session-keyed markers `<slug>--<sid>` shared by Stop + PreCompact, advanced never cleared (a marker reset once re-archived one session 18×) | `lib.sh` marker helpers; `pre-compact.sh` shares the marker | `tests/test-stop-extract.sh` (Test 8: marker created, advances to TOTAL_LINES, rerun does NOT re-archive) + `tests/test-extract-drain.sh` (30-day marker GC, extract-drain.sh:301). `test-transcript-archive.sh` covers only the archive caps/metadata half of §3.2, NOT markers |
| 8 | Capture never blocks the harness: capture/context hooks and the drainer always exit 0; SubagentStop must exit 0 | in-script contracts (stop-extract.sh header; hooks.json SubagentStop comment) | `tests/test-stop-extract.sh` (Tests 4-6: garbage LLM output / missing transcript / malformed stdin each MUST exit 0) + `tests/test-subagent-capture.sh` (every case asserts "must always exit 0") |
| 9 | FORGET is reversible and fail-safe: recall-guard-down → exit 2 → phase skipped; archive = move + JSONL log; `auto_accept=safe` refuses FORGET dreams; archive TTL defaults to never | `wiki-forget-candidates.sh`; `sb_auto_accept_decision` (lib.sh); `ensure-dirs.sh` seed | `tests/test-dream-accept-guards.sh`; forget-score tests |
| 10 | Untrusted input is DATA, not instructions — and mechanically backed: transcripts staged as sanitized copies, raw items sanitized write+read, ids/slugs traversal-checked (incl. attacker-influenceable transcript headers) | `sanitize.ts`, `raw-inbox.ts`, `lib.sh` slug sanitizers; agent grant allowlists | `mcp/src/agent-grants.test.ts` (greps the agent markdown — prose promises get machine locks here) |
| 11 | Two log channels with distinct rotation: `error-log.jsonl` (512 KB → newest 1000) vs `audit-log.jsonl` (5000 lines/5 MiB → oldest half dropped); `gate=*` breadcrumbs route to audit, not error | `sb_log_error`/`sb_log_audit` (lib.sh:171-306) | `tests/test-log-hygiene.sh` (R6b: `gate=`/ec-0 routes to audit-log not error-log; a failing `gate=` line stays an error; error-log rotates at 512 KB keeping the newest tail; the trace path applies the audit-log's own rotation) |
| 12 | PreToolUse guards compare paths through `sb_normalize_path` — path-form parity on Windows (without it, guards fail-OPEN there) | lib.sh:14-51 funnel + minimal inline fallback in each guard so it stays armed if lib.sh fails to source | `tests/test-normalize-path.sh`, `tests/test-symlink-guard.sh`, `tests/test-persona-tool-guard.sh` |

Also machine-enforced governance (details → sb-change-control): the surface-budget ratchet —
live counts (skills 18 / agents 9 / scripts 52 / tests 157, all at budget exactly as of 0.33.37)
may not grow past `.claude-plugin/surface-budget.json` without a same-commit bump; enforced by
`scripts/validate-plugin.sh` R8 (:191-218). CONSTITUTION.md points at R8 correctly as of 0.43.0 (it
previously named a phantom `tests/test-surface-budget.sh` — defect closed).

## 8. Known weak points (stated plainly)

1. **`auto_maintain` was historically fragile and Linux-gated.** Since slice 1 (2026-07-30) the
   spawn is the quarantined zero-tool Stage A summarizer — cross-platform, bwrap demoted to
   ADDITIVE Linux defense (no longer a gate; no bypassPermissions anywhere). The systemd
   `RestrictNamespaces=true` incident (100% silent failure, fixed 0.24.41 with preflight +
   quarantine) remains the cautionary history. Unattended consolidation on Windows/macOS is now
   structurally possible but stays OFF until the arm-gates + scheduling slices land
   (campaign slices 2-5; macOS additionally needs launchd OAuth-token injection).
2. **No Windows CI lane** while Windows git-bash is the primary dev platform. `ci.yml` has only
   `linux` and `macos` jobs; CI also runs embeddings-disabled/offline, so the embedding/RRF path
   is only exercised locally. Every Windows bug class in the archaeology shipped through green CI.
3. **Windows/no-rsync accept never applies DEDUPLICATE deletions.** The merge-copy fallback
   announces "dream deletions were NOT applied" — staging-side removals wait for an
   rsync-equipped accept. FORGET is the exception since 2026-07-30: the forget-manifest is now
   applied by `dream-accept.sh` itself (a reversible `mv` to `wiki-archive/`, re-score guarded),
   so it works on every accept path on every OS, rsync or not.
4. **ConfigChange guard is audit-only** — records to audit-log, blocks nothing
   (`config-change-guard.sh`; "future iteration may add deny logic").
5. **P6 dual-LLM quarantine split: BUILT (Stage A + Stage B + arm-gates), scheduling not flipped.**
   Stage A is the quarantined zero-tool summarizer (attested at runtime, fail-loud); Stage B is
   `consolidate-writer-cli.bundle.js` — deterministic, no LLM, netless by kernel (bwrap
   `--unshare-net`, Linux) AND by structure (source-scan test, every OS), with transcripts never
   bound into it. Untrusted-only NEW pages are held at accept behind an explicit confirm, and
   `auto_accept=safe` refuses those dreams outright. What remains is OPERATIONAL, not
   architectural: the per-OS scheduling flips and the V4 hands-off validation. The maintainer
   3-strike file `.llm-maintain-quarantine` and the edge quarantine
   `graph/edges-quarantine.jsonl` remain separate, working mechanisms. Accepted residual: the
   model-API channel (see wiki `decisions/cross-platform-autonomy-architecture.md`).
6. **Drainer starvation under always-on interactive OAuth use.** The escape only fires when SAFE
   (API key, or `SB_DRAIN_DEFER_PMODE_ONLY=1` + a timeout binary); pure-OAuth boxes with a held
   lock keep deferring and rely on the SessionStart drain-health banner.
7. **jq-on-Windows CRLF class.** jq 1.8.1 stdout is text-mode on Windows (`\n`→`\r\n`); every jq
   read boundary needs `tr -d '\r'` and line-oriented writes need `-c`. Class guard:
   `tests/test-jq-crlf-windows.sh` (stubbed Windows jq on Linux CI). New jq call sites are the
   most likely place to reintroduce it.
8. **SessionStart output is dropped after compaction** (upstream anthropics/claude-code#15174) —
   worked around by excluding `compact` from the matcher; do not "fix" the matcher back.
9. **`ln -s` deep-copies on MSYS** (winsymlinks default). Use
   `node fs.symlinkSync(target, link, 'junction')` for directory links; ln-s-gated tests silently
   skip on Windows — the skip once hid ~3 GB of duplication (0.33.7).

## When NOT to use this skill

- Flag/env-var reference, defaults, add-a-flag checklist → **sb-config-and-flags**
- Install/upgrade/operate commands, auth modes, user-facing surface → **sb-run-and-operate**
- A live failure to triage → **sb-debugging-playbook**; its history → **sb-failure-archaeology**
- Ranking/dedup/clustering/forgetting math and the injection-security model as theory →
  **sb-memory-systems-reference**
- Release/change gating, what the validators check → **sb-change-control**
- Building/rebuilding the dev environment → **sb-build-and-env**

## Provenance and maintenance

Derived from the working tree at 0.33.31 (2026-07-05, HEAD `6fba312`); §5 tool table + surface
counts + version stamps re-verified 2026-07-13 at 0.33.37. Sources: `hooks/hooks.json`,
`scripts/lib.sh`, `scripts/session-load.sh`, `scripts/stop-extract.sh`, `scripts/extract-drain.sh`,
`scripts/dream-snapshot.sh`, `scripts/dream-accept.sh`, `scripts/maintain-llm-drain.sh`,
`scripts/wiki-forget-candidates.sh`, `scripts/ensure-dirs.sh`, `scripts/validate-plugin.sh`,
`scripts/hook-timer.sh`, `agents/dream-runner.md`, `agents/raw-drainer.md`, `mcp/src/server.ts`,
`mcp/src/brain-paths.ts`, `mcp/src/brain-paths.test.ts`, `mcp/src/tools/project-dir.ts`,
`mcp/src/tools/graph-cluster.ts`, `mcp/src/tools/knowledge-validate.ts`, `mcp/src/tools/dream.ts`,
`mcp/package.json`, `kb-schema.json`, `.claude-plugin/surface-budget.json`, `tests/test-stop-extract.sh`,
`tests/test-extract-drain.sh`, `CONSTITUTION.md`, `archive/docs:CHANGELOG.md`, `.github/workflows/ci.yml`.

Volatile facts — re-verify before trusting a stale copy of this skill:

```bash
jq -r .version .claude-plugin/plugin.json                      # plugin version (was 0.33.31)
jq -r '.hooks | keys | length' hooks/hooks.json                # hook events (was 8)
jq '[.hooks[][] | .hooks[]] | length' hooks/hooks.json         # hook command entries (was 22)
grep -c 'registerTool(' mcp/src/server.ts                      # MCP tools (was 23)
grep -rn 'function resolveKnowledgeDir' mcp/src --include='*.ts'  # >1 hit = two-wikis split still open
cat .claude-plugin/surface-budget.json                                    # budget (skills 18/agents 9/scripts 52/tests 157)
ls tests/test-*.sh | wc -l                                      # live test count (was 157)
grep -n 'REQUIRED_FM_FIELDS' mcp/src/tools/knowledge-validate.ts  # 7 frontmatter fields
jq -r '.structured_types, .unstructured_types' kb-schema.json   # wiki categories (6+2)
grep -n 'SB_DREAM_ACCEPT_MIN_RATIO' scripts/dream-accept.sh     # accept floor default (was 50)
grep -rni .dual-llm\|quarantine. mcp/src scripts || echo "P6 still plan-queued"  # plan doc: archive/docs
```

If any command's output disagrees with this file, trust the repo and update this skill.
