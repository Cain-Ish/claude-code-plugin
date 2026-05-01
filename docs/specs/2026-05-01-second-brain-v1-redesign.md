# second-brain v1.0 redesign

**Status:** design-approved, post-doubt revisions applied
**Date:** 2026-05-01
**Brainstorming session:** 2026-05-01 (this document)
**Adversarial review (pre-spec, agent dispatch):** 3 independent reviewers — code-review, quality-reviewer, doubt-style — findings synthesized into Section 1 corrections.
**Adversarial review (post-spec, real `/second-brain:doubt` runs):**
- *Run #1 (ad-hoc on the spec):* 9 vectors / 7 drilled / 8 confirmed ISSUEs + 1 disputed + 2 FRAGILE. Logged at `~/.second-brain/doubt-history.jsonl` 2026-05-01T11:52:28Z. **3 CRITICAL fixes applied below:** Stop-hook predicate transcript-detection arm dropped; hot-tier token math reworked from 500 to 700/800 cap with shown arithmetic; `quality-gate.sh` retained as PostToolUse hook. **4 WARNINGs applied:** auto-memory boundary subsection, Open blockers in trim order, full MCP tool migration table, full script verdict table.
- *Run #2 (`--layer learning` against current 0.7.0 plumbing):* 7 vectors / 7 drilled / 8 confirmed (1 over-prune flagged + reopened as Finding #8). All findings VALIDATE the spec's diagnosis: friction-keyword false positives, orphan snapshots from `lib.sh:151,177`, legacy queue not cleaned by 0.6.6→0.7.0 migration, critic gate never executed in production (no `critic-log.jsonl`), pipeline not actually "automatic," 100× cost-vs-value, silent-dropout in `extract-learnings.sh:18`. The 1.0.0 migration's wholesale wipe of `.reflection-context/` naturally fixes the orphan-snapshot bug.
**Supersedes:** the 0.x reflection→critic→learnings pipeline.

## Context

The 0.x line of the second-brain plugin built sophisticated plumbing — friction logs, reflection queues, critic gates, drift detectors, persona-evolution — but the user's lived experience was three concrete failures:

1. **Random information accumulating.** The reflection→critic pipeline saved trivia. A zero-friction session this morning queued five reflections.
2. **Context bloat at SessionStart.** Every session opens with persona.md (90 lines) + `.learnings-hot.md` + quality-rules.md + the MEMORY.md index + 5 system reminders before the user has typed.
3. **Categories the user actually wants are not first-class.** The user listed five things Claude should remember: project structure, concepts, planned end results, issues faced, dedicated approach with the user. None of them have a clean home today.

The redesign re-grounds the plugin on what's actually retrievable, condensed, and bounded — closer to Karpathy's "LLM Wiki" compiler model and MemGPT's tiered memory than to the 0.x reflection pipeline.

## Design constraints (locked during brainstorming)

1. **Read budget:** ~700 tokens auto-loaded at SessionStart, hard cap 800. Everything else queried on demand. (Math shown in the Hot tier section below — original aspiration was 500, but the section caps the user wants do not fit; 700 is the honest number.)
2. **Write trigger:** PROJECT.md is continuously maintained; everything else is explicit-only. No autonomous critic-gated extraction.
3. **Migration:** Hybrid — wipe runtime noise, keep the four curated wiki pages (`2026-04-27-skill-bash-no-placeholder-sub.md`, `2026-04-27-user-config-placeholder-unreliable.md`, `2026-04-27-second-brain-cross-platform-fixes.md`, `second-brain-plugin.md`).

## Storage layout

### Hot tier (auto-loaded, ~700 token target / 800 token hard cap)

```
~/.second-brain/
├── USER.md                    # ≤15 lines — user's immutable preferences and dedicated approach
├── projects/
│   └── <repo-slug>/
│       └── PROJECT.md          # ≤40 lines total via per-section caps
└── index.txt                   # JSONL: {slug, name, last_session_iso, hot_byte_count}
```

**Token math (at ~12 tokens/line average):**
- USER.md ≤15 lines × 12 = ~180 tokens
- PROJECT.md ≤40 lines × 12 = ~480 tokens
- index.txt 1 line × 30 = ~30 tokens (only the active project's line is included in context — not the full file)
- Total target: ~690 tokens; hard cap 800 tokens. Trim order in the Read surfaces section below.

**`USER.md`** holds global preferences that apply across every repo: code style, communication, anti-patterns to avoid, retrieval discipline. The current `persona.md` content folds in here, much condensed (90 lines → 15). Updated only when user says "remember this for me globally" (via the `pin_to_user` MCP tool).

**Boundary with Claude Code's built-in auto-memory:** Claude Code already maintains `~/.claude/projects/<slug>/memory/MEMORY.md` and individual feedback files for each project. To avoid two stores reacting to the same "remember this" trigger:

- USER.md is *plugin-scoped*: it holds preferences relevant to the second-brain plugin's behavior (retrieval discipline, when to write to wiki, how often to query, etc.).
- Claude Code's auto-memory remains the canonical store for general user preferences and project-specific feedback.
- The `pin_to_user` MCP tool only fires on the explicit phrasing "pin this to my second-brain" or `/second-brain:pin`. Plain "remember this" continues to write to Claude Code's auto-memory, untouched.

**`PROJECT.md`** uses a fixed 6-section template with explicit per-section caps (sums to ≤40 lines total):

```markdown
# PROJECT: <name>

## Goal
<≤3 lines — what this repo is building, the end state we're aiming at>

## State
<≤8 lines — current sprint / where we left off / what's next>

## Conventions
<≤5 lines — negotiated working style for THIS repo (brainstorm-first, fail-loud, ≤500-line skills, etc.)>

## Recent decisions
<≤3 entries, each ≤2 lines, each tagged [active|resolved|stale]>

## Open blockers
<≤15 lines target; each entry tagged [active|resolved|stale]; status drives archival; trim rule defined in Read surfaces>

## Cross-references
<≤3 wiki page slugs relevant to this project — auto-loaded with PROJECT.md so Claude has them in context>

<!-- last_updated: 2026-05-01T12:00:00Z -->
<!-- last_queried_wiki: 2026-04-30 -->
```

The `Conventions` section is the home for what the doubt review called "user-approach has no slot." It's per-repo because conventions are repo-specific (a backend service repo has different conventions than a marketing site).

The `Cross-references` section is the retrieval nudge — it ensures concept pages are not write-only. When Claude loads PROJECT.md and sees `Cross-references: [counting-pipeline-redundant-fallback, second-brain-plugin]`, it knows to query those when topic-relevant.

The `last_queried_wiki` timestamp is the "what I might not know" nudge — if it has been a week since Claude last queried the cold tier on this project, that is a signal to query before assuming.

**`index.txt`** is a JSONL listing: `{"slug": "claude-code-plugin", "name": "second-brain", "last_session_iso": "2026-05-01T11:00:00Z", "hot_byte_count": 1842}`. One line per project. Written by the `setup` skill on `init` and by the Stop hook on session save.

### Cold tier (queried via `knowledge_search`, no auto-load)

```
~/knowledge/
├── index.md                    # human-readable catalog (existing)
├── log.md                      # chronological operations log (existing)
└── wiki/
    ├── concepts/               # cross-project ideas, patterns, frameworks
    ├── decisions/<repo-slug>/  # archived PROJECT.md decision entries (status=resolved)
    ├── issues/<repo-slug>/     # archived PROJECT.md blocker entries (status=resolved)
    ├── entities/               # tools, libraries, services
    └── learnings/              # explicit user-requested learnings
```

`decisions/<repo-slug>/` and `issues/<repo-slug>/` are *separate* archive targets. The 0.x design proposal collapsed both into `wiki/issues/`, which the code-review caught as taxonomy-corrupting.

## Write discipline

### Continuous (PROJECT.md only, gated by hard predicate)

A Stop-hook subagent runs at session end and may update PROJECT.md, but **only if at least one of these is true** — all conditions are detectable by `diff` against the baseline (the PROJECT.md state at SessionStart, captured by the SessionStart hook into `~/.second-brain/.session-baseline-<slug>.md`):

- `Goal` section text differs from baseline (line-diff non-empty).
- `State` section word-count delta from baseline is >20%.
- `Open blockers` section line count differs from baseline (a new entry must arrive via the `pin_to_project` MCP call, which writes it to PROJECT.md immediately — so the structural diff catches it without reading the transcript).
- A `[decision]` marker line is present in current PROJECT.md that was not in baseline.

All four conditions are pure structural diffs against the baseline file — no transcript reading, no LLM judgment, no natural-language detection. If none fire, the hook is a no-op and deletes the baseline file. This is a boolean guard, not an LLM-judging critic — it cannot save random information because it cannot save anything that doesn't tie to a structural change against a known baseline.

The subagent's diff is bounded to ≤10 lines per section it touches. Per-section caps prevent the file from saturating with low-signal entries.

### Explicit (everything in `~/knowledge/wiki/`)

The wiki is only written when the user explicitly says so, via three MCP tools:

- `pin_to_user(text)` — writes a line to `USER.md` (e.g. "remember this preference for me globally").
- `pin_to_project(text)` — writes to active `PROJECT.md`.
- `archive_to_wiki(source_section, target_category, content)` — moves an entry from PROJECT.md to wiki cold tier; called when Claude detects status=resolved on an entry, OR explicitly by the user.

There is no autonomous critic deciding what is wiki-worthy.

### Auto-archive (status-tagged, not recency-tagged)

Each PROJECT.md `Recent decisions` and `Open blockers` entry has a status tag: `[active|resolved|stale]`.

- **Resolved** entries auto-move out of PROJECT.md on the next Stop hook into the appropriate wiki cold tier (`wiki/decisions/<slug>/` for decisions, `wiki/issues/<slug>/` for blockers), with a one-line back-reference left in PROJECT.md until the section overflows.
- **Active** entries never auto-archive regardless of age. A 3-week-old open blocker stays hot.
- **Stale** entries (no update >30 days, status not changed) get a `?` marker but stay hot until the user reviews.

This addresses the doubt-review finding "auto-archive by recency loses long-running blockers."

## Read surfaces

### SessionStart hook

Loads:
- `~/.second-brain/USER.md`
- `~/.second-brain/projects/<active-slug>/PROJECT.md` (resolved via cwd)
- `~/.second-brain/index.txt` (1-line summary)

Hard cap at 800 tokens. Trim order if exceeded:

1. **Open blockers** — drop `[resolved]` entries first (they're already auto-archiving), then `[stale]`, then the *oldest* `[active]` entry (with a `?` marker left in PROJECT.md so the user knows context is degraded).
2. **Recent decisions** — drop `[resolved]` then `[stale]` then oldest `[active]`.
3. **State** — truncate to 4 lines (keeping the most recent).

Never trim `Conventions` or `Goal`. Logs a warning to `friction-log.jsonl` (kept as a debug-only log, not a memory feed).

No persona auto-load. No `.learnings-hot.md`. No reflection queue processing on startup.

### `knowledge_search` MCP tool — v1 retrieval primitive

**For v1, no embeddings, no server-side LLM.** Implementation:

1. Take the query terms; tokenize.
2. Run `ripgrep` over filenames + first 10 lines of each `.md` in `~/knowledge/wiki/`, scoped optionally by `scope` parameter (`concepts | issues | entities | learnings`).
3. Score by token-overlap, return top 5 paths + first-paragraph snippets (≤200 chars each).
4. Claude (the calling client) receives the candidate set, decides which 1-2 files to read in full, and synthesizes a paragraph-length answer in its own response to the user.

The MCP server itself does **not** call any LLM and does **not** author summaries. The "synthesized summary, not chunks" property is achieved client-side: the tool returns enough structured candidates that Claude can write a synthesis directly, instead of dumping raw matched text into the response. The tool's return shape is `{candidates: [{path, score, first_lines}]}`, not `{summary: string}`.

This is cheap (no index to maintain), fast (ripgrep on a few hundred markdown files is milliseconds), deterministic (same query = same results), and trivial to debug.

Embedding-based search is a v2 nice-to-have — not v1 scope. The MemPalace independent code review confirmed embeddings (specifically ChromaDB defaults) drive most of the headline benchmark numbers, not the architecture; we don't need to ship that complexity in v1.

## Plugin surface changes

### Skills: 14 → 7 (8 dropped, 6 kept-and-simplified, 1 rebuilt)

| Skill | Verdict | Notes |
|---|---|---|
| `setup` | Keep | Now scaffolds USER.md + per-repo PROJECT.md + index.txt. |
| `upgrade` | Keep | Future migrations. The 0.6.6→0.7.0 path is the template; 0.7→1.0 will be the next migration this skill executes. |
| `status` | Keep | Reports byte counts, age, last update. No reflection metrics. |
| `query` | Keep | Wraps `knowledge_search`. Returns synthesized summaries. |
| `lint` | Keep, smaller | Orphans + dead wiki-links + broken cross-references in PROJECT.md. Drop content rules. |
| `improve` | Rebuild | New job: prompt user with up to 3 grounded candidates of "should I remember this from this session?" Per-candidate accept/reject/edit. No autonomous critic. |
| `doubt` | Keep | Earned its keep — used on this very design. |
| `import-host` | Keep | One-shot tool to import existing CLAUDE.md / .cursorrules into USER.md/PROJECT.md scaffolds. |
| `browse` | Drop | `query` covers it. |
| `drift-check` | Drop | Persona is now manually-edited USER.md. |
| `graph` | Drop | Already deprecated in 0.7.0. |
| `ingest` | Drop for v1 | Karpathy raw/→wiki/ compile is interesting but out of scope. |
| `regress` | Drop | Tied to learnings testing. |
| `review` | Drop | Redundant with `/everything-claude-code:code-review`. |

### MCP tools: 5 in, 4 out (was 4 — `knowledge-base` server v0.2.0)

**Current tools (per `mcp/src/server.ts`):** `knowledge_search` (line 134), `knowledge_index` (line 258), `knowledge_stats` (line 313), `knowledge_feedback` (line 363).

**v1.0 tool surface:**

| Tool | Verdict | Notes |
|---|---|---|
| `knowledge_search` | **Rebuild** | New shape: `{candidates: [{path, score, first_lines}]}`. No server-side LLM call. Backend changes from sqlite-vec to ripgrep over filenames + first 10 lines. |
| `knowledge_index` | **Remove** | No embedding index in v1; nothing to maintain. Re-introduce in v2 if embeddings come back. |
| `knowledge_stats` | **Keep** | Used by `/status` skill — page counts per category, last-update timestamps. No change needed. |
| `knowledge_feedback` | **Remove** | Was tied to learnings.md decay tracking (hits/last_used meta). New design has no auto-decay. |
| `pin_to_user` | **Add** | `(text: string) → {ok, line_added}` — explicit user-instructed write to USER.md. Only fires on the explicit phrasing "pin to my second-brain" or via `/second-brain:pin` (does NOT trigger on plain "remember this" — that's Claude Code's auto-memory). |
| `pin_to_project` | **Add** | `(text: string) → {ok, line_added, project_slug}` — explicit write to active PROJECT.md. Same trigger discipline as `pin_to_user`. |
| `archive_to_wiki` | **Add** | `(source_section: "decisions"\|"blockers", entry_id, target_category: "decisions"\|"issues") → {ok, archived_path}` — moves a resolved entry from PROJECT.md to wiki cold tier. |

**Migration check:** before shipping v1.0, grep all skills/hooks/scripts for `knowledge_index` and `knowledge_feedback`; any caller must be updated or removed. Validator step in upgrade skill verifies no orphaned references.

### Hooks: 4 (down from 7)

- `SessionStart`: load hot tier (USER.md + active PROJECT.md + index.txt line for active project). ~700 token target / 800 cap. Also captures the SessionStart baseline of PROJECT.md to `~/.second-brain/.session-baseline-<slug>.md` for the Stop-hook predicate.
- `Stop`: hard-predicate check; if true, run subagent to update PROJECT.md and run resolved-entry auto-archive.
- `PreCompact`: same as Stop (snapshot before compaction).
- `PostToolUse` (matcher: `Write|Edit`): runs `quality-gate.sh` — write-time code-quality enforcer, orthogonal to the reflection pipeline. Surfaces issues directly to Claude immediately after a code write. Kept because it provides real-time feedback that the rest of the new design intentionally does not (the new design is read-side-and-archive; quality-gate is write-side and runs every Write/Edit).

**Hook events removed (3 of 7):**
- `UserPromptSubmit` (was running `log-friction.sh`/`smart-context.sh` — both removed; friction-log retained as debug-only).
- `PostCompact` (was running `post-compact.sh` reflection-queue logic — removed).
- `SubagentStop` (was running `post-maintainer.sh` for the knowledge-maintainer agent — moved into the maintainer agent's own logic; the hook isn't needed).

### Scripts: full migration verdict

All 18 current scripts in `scripts/*.sh`, with explicit verdict:

| Script | Verdict | Reason / new role |
|---|---|---|
| `lib.sh` | **Keep, simplified** | Core utilities. Drop the `sb_count_friction`, `sb_count_drift`, `sb_write_reflection`, `sb_collect_session_data` helpers; keep `sb_require_jq`, `sb_safe_json_array`, `sb_log_error`, `sb_parse_input`, file-locking primitives. |
| `session-load.sh` | **Keep, simplified** | Reads hot tier (USER.md + active PROJECT.md + index.txt active line) into context. Captures SessionStart baseline of PROJECT.md to `.session-baseline-<slug>.md` for the Stop-hook predicate. No nudge text. |
| `ensure-dirs.sh` | **Keep** | Creates `~/.second-brain/projects/<slug>/` and `~/knowledge/wiki/{concepts,decisions,issues,entities,learnings}/` skeletons. |
| `validate-plugin.sh` | **Keep** | Plugin validator. Fix the 2 cosmetic WARNs (Stop[0]/UserPromptSubmit[0] matchers). |
| `quality-gate.sh` | **Keep** | PostToolUse `Write\|Edit` write-time code-quality enforcer. Orthogonal to reflection pipeline. |
| `pre-compact.sh` | **Keep, rebuilt** | New role: same Stop-hook predicate logic (boolean diff against baseline) before compaction. Drop the reflection-queue write. |
| `discover-tools.sh` | **Keep, simplified** | Populates `~/.second-brain/tool-registry.json` for the `/status` skill. |
| `stop-hook-predicate.sh` | **NEW** | Implements the 4-condition boolean diff for the Stop hook. Called from Stop hook entry. |
| `extract-learnings.sh` | **Drop** | Reflection pipeline removed. |
| `log-friction.sh` | **Drop** | UserPromptSubmit hook removed; friction-log retained as debug-only sink. |
| `smart-context.sh` | **Drop** | UserPromptSubmit context-injection removed. |
| `drift-detect.sh` | **Drop** | Persona drift detector — replaced by manual USER.md curation. |
| `post-compact.sh` | **Drop** | Reflection-queue post-processing removed. |
| `post-maintainer.sh` | **Drop** | SubagentStop hook removed; maintainer agent self-completes. |
| `pre-clear.sh` | **Drop** | Reflection-clear hook removed. |
| `budget-context.sh` | **Drop** | Context-budget tracking removed. |
| `decay-learnings.sh` | **Drop** | learnings.md decay machinery removed (no auto-extraction). |
| `compile-graph.sh` | **Drop** | Graph layer deprecated in 0.7.0 (already a no-op). |
| `validate-proposal.sh` | **Drop** | Reflection-proposal validator. |

**Net:** 8 keep (one rebuilt), 1 new, 11 drop. Final count: 9 scripts in `scripts/*.sh` (down from 18).

## Migration plan (0.7.0 → 1.0.0)

The `upgrade` skill runs:

1. **Wipe runtime state:** delete `.pending-reflections.jsonl`, `.reflection-context/`, `.learnings-hot.md`, `.compact-count`, `friction-log.jsonl`, `drift-log.jsonl`, `error-log.jsonl`, `critic-log.jsonl`, `doubt-history.jsonl`, `regressions/`.
2. **Reset `learnings.md`:** keep the existing single entry (counting-pipeline-redundant-fallback) — it's a real durable pattern. Remove the meta-tag tracking footer; the new design doesn't decay.
3. **Migrate persona content:** read existing `persona.md` (90 lines), prompt user to confirm a condensed ≤30-line `USER.md`. Auto-include the 3 feedback memories from `~/.claude/projects/.../memory/` (brainstorm-first, skill-size, fail-loud) as the seed Conventions for the claude-code-plugin project.
4. **Scaffold first PROJECT.md:** create `~/.second-brain/projects/claude-code-plugin/PROJECT.md` with Goal/State seeded from the user's stated context.
5. **Keep curated wiki:** the 4 existing pages stay in `~/knowledge/wiki/` untouched.
6. **Update marker:** `~/.second-brain/.installed-version` → `1.0.0`.

Migration is reversible — keep a `~/.second-brain/.0.7.0-backup/` tarball of all wiped files for 30 days.

## Verification

End-to-end test plan after implementation:

1. **SessionStart budget:** open a fresh session in `claude-code-plugin`; measure SessionStart context output. Must be <500 tokens. (`wc -c` on the session-load.sh output.)
2. **Hot-tier round trip:** in a session, say "remember that I prefer X" → check `pin_to_user` runs and USER.md gets the line; new session loads it.
3. **Stop-hook predicate:** in a no-friction session that doesn't change Goal/State/blockers/decisions, confirm PROJECT.md was NOT modified at session end (the original failure mode).
4. **Stop-hook predicate-true:** in a session where the user adds an open blocker, confirm PROJECT.md updated with the new entry tagged `[active]`.
5. **Auto-archive on resolve:** mark an Open blocker `[resolved]` mid-session; confirm next Stop hook moves it to `wiki/issues/<slug>/` with a one-line back-ref left in PROJECT.md.
6. **Auto-archive does NOT run on `[active]` old:** check that a 3-week-old `[active]` blocker stays in PROJECT.md across multiple sessions.
7. **`knowledge_search` returns synthesized summaries:** call with "counting pipeline fallback" → should return summary referencing the existing learning page, not raw chunks.
8. **Cross-references nudge:** populate Cross-references with one wiki slug; confirm Claude pulls it on first relevant message in the next session.
9. **Migration reversibility:** run `upgrade`, check `.0.7.0-backup/` exists; verify a manual rollback is possible.

## Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| Stop-hook predicate is too narrow → real changes missed | Medium | Log every session's predicate evaluation to `friction-log.jsonl` (debug); review weekly for false negatives. |
| `knowledge_search` ripgrep noisy on large wikis | Low | Wiki is small (4 curated pages today); revisit if it grows >100 pages. |
| Multi-project sessions confuse PROJECT.md routing | Medium | `index.txt` carries last-active slug; if cwd changes mid-session, log warning and prompt user. |
| User refuses to use `pin_to_user` and just expects auto-capture | High | UX: `improve` skill at session-end offers up to 3 candidate pins for explicit accept. |
| Karpathy compiler temptation creep — desire to add `ingest` back | Low | Document explicitly: out of v1 scope. Re-evaluate in 6 months based on real usage. |

## Out of scope for v1

- Embedding-based semantic search (v2).
- Karpathy raw/→wiki/ compile (v2 if usage demands).
- Persona drift auto-detection (deliberately replaced by manual USER.md curation).
- Episodic-memory-style verbatim conversation archive (orthogonal feature; could be added as a separate plugin).
- Visual graph view (deprecated in 0.7.0; not coming back).

## Next steps after spec approval

Per the brainstorming flow, the next step is to invoke the `superpowers:writing-plans` skill to produce an implementation plan from this spec. The plan will sequence the migration, the script rewrites, the MCP tool changes, and the skill cuts/rebuilds into ordered work items.
