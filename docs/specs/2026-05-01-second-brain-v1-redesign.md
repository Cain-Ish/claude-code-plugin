# second-brain v1.0 redesign

**Status:** design-approved (awaiting user spec review)
**Date:** 2026-05-01
**Brainstorming session:** 2026-05-01 (this document)
**Adversarial review:** 3 independent reviewers — code-review, quality-reviewer, doubt — findings synthesized into the corrections below.
**Supersedes:** the 0.x reflection→critic→learnings pipeline.

## Context

The 0.x line of the second-brain plugin built sophisticated plumbing — friction logs, reflection queues, critic gates, drift detectors, persona-evolution — but the user's lived experience was three concrete failures:

1. **Random information accumulating.** The reflection→critic pipeline saved trivia. A zero-friction session this morning queued five reflections.
2. **Context bloat at SessionStart.** Every session opens with persona.md (90 lines) + `.learnings-hot.md` + quality-rules.md + the MEMORY.md index + 5 system reminders before the user has typed.
3. **Categories the user actually wants are not first-class.** The user listed five things Claude should remember: project structure, concepts, planned end results, issues faced, dedicated approach with the user. None of them have a clean home today.

The redesign re-grounds the plugin on what's actually retrievable, condensed, and bounded — closer to Karpathy's "LLM Wiki" compiler model and MemGPT's tiered memory than to the 0.x reflection pipeline.

## Design constraints (locked during brainstorming)

1. **Read budget:** ~500 tokens auto-loaded at SessionStart. Everything else queried on demand.
2. **Write trigger:** PROJECT.md is continuously maintained; everything else is explicit-only. No autonomous critic-gated extraction.
3. **Migration:** Hybrid — wipe runtime noise, keep the four curated wiki pages (`2026-04-27-skill-bash-no-placeholder-sub.md`, `2026-04-27-user-config-placeholder-unreliable.md`, `2026-04-27-second-brain-cross-platform-fixes.md`, `second-brain-plugin.md`).

## Storage layout

### Hot tier (auto-loaded, ~500 tokens cap)

```
~/.second-brain/
├── USER.md                    # ≤30 lines — user's immutable preferences and dedicated approach
├── projects/
│   └── <repo-slug>/
│       └── PROJECT.md          # ≤90 lines total via per-section caps
└── index.txt                   # JSONL: {slug, name, last_session_iso, hot_byte_count}
```

**`USER.md`** holds global preferences that apply across every repo: code style, communication, anti-patterns to avoid, retrieval discipline. The current `persona.md` content folds in here, much condensed. Updated only when user says "remember this for me globally" (via the `pin_to_user` MCP tool).

**`PROJECT.md`** uses a fixed 6-section template with explicit per-section caps:

```markdown
# PROJECT: <name>

## Goal
<≤5 lines — what this repo is building, the end state we're aiming at>

## State
<≤15 lines — current sprint / where we left off / what's next>

## Conventions
<≤10 lines — negotiated working style for THIS repo (brainstorm-first, fail-loud, ≤500-line skills, etc.)>

## Recent decisions
<≤5 entries, each ≤3 lines, each tagged [active|resolved|stale]>

## Open blockers
<unbounded but each entry tagged [active|resolved|stale]; status drives archival>

## Cross-references
<≤3 wiki page slugs relevant to this project — Claude reads them on first relevant message>

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

A Stop-hook subagent runs at session end and may update PROJECT.md, but **only if at least one of these is true** (baseline = the PROJECT.md state at SessionStart, captured by the SessionStart hook into `~/.second-brain/.session-baseline-<slug>.md`):

- `Goal` section text differs from baseline.
- `State` section word-count delta from baseline is >20%.
- A new entry was added under `Open blockers` during the session (detected by Claude proposing one in the transcript or via `pin_to_project`).
- An explicit `[decision]` marker was emitted in the session transcript.

If none of these fire, the hook is a no-op and deletes the baseline file. This is a boolean guard, not an LLM-judging critic — it cannot save random information because it cannot save anything that doesn't tie to a structural change against a known baseline.

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

Hard cap at 500 tokens; if exceeded, the hook trims `State` and `Recent decisions` first, never `Conventions` or `Goal`. Logs a warning to `friction-log.jsonl` (kept as a debug-only log, not a memory feed).

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

### MCP tools: 4 (down from current set)

- `knowledge_search(query: string, scope?: "concepts"|"issues"|"entities"|"learnings"): {candidates: [{path: string, score: number, first_lines: string}]}` — no server-side LLM call; Claude synthesizes from candidates client-side.
- `pin_to_user(text: string): {ok: bool, line_added: string}`
- `pin_to_project(text: string): {ok: bool, line_added: string, project_slug: string}`
- `archive_to_wiki(source_section: "decisions"|"blockers", entry_id: string, target_category: "decisions"|"issues"): {ok: bool, archived_path: string}`

### Hooks: 3

- `SessionStart`: load hot tier (USER.md + active PROJECT.md + index.txt). ~500 token budget.
- `Stop`: hard-predicate check; if true, run subagent to update PROJECT.md and run resolved-entry auto-archive.
- `PreCompact`: same as Stop (snapshot before compaction).

### Scripts gone

- `log-friction.sh`, `drift-detect.sh`, `smart-context.sh`, `extract-learnings.sh`, `budget-context.sh`, the reflection-queue logic in `pre-compact.sh`/`post-compact.sh`, the critic-log.jsonl pipeline.

### Scripts kept (simplified)

- `lib.sh` — core utilities, much shorter without reflection helpers.
- `session-load.sh` — now just reads hot tier and outputs to context. No nudge text.
- `ensure-dirs.sh` — creates `~/.second-brain/projects/<slug>/` skeletons.
- `validate-plugin.sh` — keep, fix the two cosmetic WARN findings (Stop[0] / UserPromptSubmit[0] declaring `matcher` they ignore).

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
