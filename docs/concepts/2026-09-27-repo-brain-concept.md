# Repo Brain concept v2 — the developer's expanded knowledge, delivered where it is used

**Status: APPROVED 2026-09-28.** Reviewed by `devils-advocate` (21 findings folded, §11). User decisions: approve as
written; D2 stays strict now (§6 option A; option B is decided with S1 data); first step S0, starting with the B7
probes. Amends `docs/plans/2026-09-24-repo-brain.md` (see its "Amendment 2026-09-28").

Built from 5 read-only audits of this repo, 2 primary-source research passes, 2 adversarial reviews and 3 live
arrival probes (session `71420c56`), then re-verified on 2026-09-28 against `main` d6067fd (0.54.0 merged via
PR #107; installed runtime 0.54.0): B3 and the B4 runtime/embeddings gap are resolved; B1, B2, B5, B6 and the ruler
still hold; B7 is new; CI lost its Linux lane (§2). Research sources: `docs/researchs/2026-09-27-sources/` (local;
`docs/researchs/` is gitignored). Audit evidence is summarized in §2 with file:line references.

---

## 0. Bottom line

1. **The concept is right and mostly already named.** The user's "expanded developer knowledge" (code map, designs,
   goals, where-docs-live, backlog, session info, native md memory, context between agents, focus, rules) is the
   constitution's five classes plus two delivery needs (between agents, across compaction). What is missing is not
   storage. It is **delivery that arrives** and **a ruler that can see it**.
2. **Hooks are cancelled under load, so pushed memory often never arrives (B7, the largest finding).** Across the last
   25 sessions the SessionStart render was cancelled in 8 sessions (avg 52 s against a 15-20 s timeout), per-prompt
   retrieval 9 times, and PreToolUse guards dozens of times (5 s timeouts; up to 306 s). The heavy multi-agent
   sessions this user runs are exactly where it happens. Three shipped paths are also still broken on `main`:
   auto-mode and workflow subagent reports never reach capture (B1), the SubagentStart card misses its 5 s timeout
   under load (B2), and the stop gate accepts review evidence that is not verification (B6, borrow-ledger V1).
   Resolved since 2026-09-27: the `## Plan` header (B3) and the stale runtime (B4; the existing degraded-search
   banner fired once, then missed because its trigger cannot see a package that will not import and because the
   render hook itself was cancelled).
3. **The only surfaces with evidence of arrival are native.** Claude Code's `MEMORY.md` index reached every
   general-purpose and plugin subagent probed; the plugin's card reached 1 of 3. The only non-zero use signal is
   model-initiated pull (13 pulls vs 0 reads of 45 pushed items).
4. **Design stance after the adversarial review:** no agent bus, no new ledger store, no generated pages before
   freshness exists. Fix integrity, run the with/without experiment, then spend bytes only where arrival and use are
   measured.
5. **External evidence points the same way** (research-D): generated repo overviews did not help agents (−0.5 to
   −2% success, +20-23% cost; arXiv 2602.11988); a task-tested 3,000-char guide of procedures and file pointers did
   (+4.7 points, all from reaching the right file; arXiv 2606.20512); a passive compressed index beat a skill the
   model had to choose to invoke (100% vs 53%; Vercel); the one auto-memory that grew stores facts with code
   citations and verifies them before use (GitHub Copilot Memory). So: **a routing index, not a tour; anchors, not
   prose; verify before inject.**
6. **One decision belongs to the user (§6):** whether D2 ("the KB is the only home") stays strict, or allows one
   pointer-only block in native `MEMORY.md`, the channel that demonstrably reaches subagents and survives compaction.

---

## 1. The user's concept in memory terms

| # | User element | Constitution class | Meaning for design |
|---|---|---|---|
| U1 | Repo structure, code map | 3 code map | Orientation without grep; blast radius |
| U2 | Architecture designs, HLDs | 2 architecture | Pointers to the docs that own the design + checkable claims |
| U3 | End goals of the repo | 2 (direction) | Goal, non-goals, time-boxed priorities |
| U4 | Where all other information lives | 3 (+2) | A doc map: every tracked doc, its kind, what fact it owns |
| U5 | Backlog | 2 (direction) + 4 (open work) | Now/next in `## Plan`; long backlog by pointer to its owning docs |
| U6 | Important session info | 4 session recap | Handoff, outcomes, lessons |
| U7 | Native md memory in the KB | 1, 4, 5 | One knowledge set, not two unlinked copies |
| U8 | Context passing between agents | 5 delivery | Subagents receive the repo's memory for their task |
| U9 | Not losing focus | 4 + 5 | Goal and open work survive compaction and long runs |
| U10 | Rules, conventions, lessons | 5 + 4 | Hard rules enforced; conventions and lessons on touch |

"Context between agents" is read as **memory delivery into subagents**, not an inter-agent message bus: the
constitution's scope rule excludes orchestration (`CONSTITUTION.md:55-59`), and a sibling-results channel lets a
web-reading agent inject into a sibling that holds Write/Bash (adversarial review, lens 5).

---

## 2. What is true today (verified)

### Broken paths (fix first)

| Id | Finding | Evidence |
|---|---|---|
| B1 | Auto-mode (CLI ≥2.1.271) subagent reports travel in `SubagentHandback.tool_input.message`; capture reads only `last_assistant_message`. All 8 `sub-*` archives this session hold the closing line only (445-3489 B; one handback was 13,966 B). **Workflow subagents** end on a `StructuredOutput` call with no text, so HOOK-5 (`:102-107`) drops their 12-65 KB reports. The `sub-*` store sits at its global cap (50/50, `lib.sh:1503`). This is the second silent blackout of subagent capture (the first, fixed in 0.45.0, ran unnoticed for weeks), and nothing alarms on it | `scripts/subagent-capture.sh:38,102-107`; `~/.second-brain/transcripts/sub-*_2026-09-27.txt`; review #2, #12 |
| B2 | SubagentStart role card: 0 log rows for 5 parallel Phase-1 dispatches and for 2 of 3 parallel probes; when emitted, arrival confirmed in `ecc:code-explorer`, denied by `ecc:architect`. `protocol-guard.sh subagent` takes **1.4-2.2 s on a quiet machine (1 or 6 parallel)** but 3.6-14.5 s under concurrent-session load, against a 5 s timeout: load-dependent misses, not every dispatch. A killed hook leaves no row (`hook-timer.sh` writes only after the child returns), and a malformed payload is logged as a misleading `no-agent-type` (parse error hidden by `2>/dev/null`) | `audit-log.jsonl` `gate=role-card` rows 11:39-11:47; timing runs 2026-09-27/28; review #16 |
| B3 | ~~Live `PROJECT.md:13` `## Plan (spec v2 …)` untracked because `merge_plan` matched only `^## Plan$`~~ **Resolved in 0.54.0**: every reader and writer matches `^## Plan( \|$)` with a first-header latch; a missing Plan is scaffolded before the footer | `84156c2`, `5d32dea`, `c976439`; `scripts/merge-project-update.sh:671,833,935,990` |
| B4 | ~~Installed 0.53.0; embeddings fail~~ **Resolved 2026-09-28**: 0.54.0 installed; `@huggingface/transformers` resolvable (installed 16:18; last `script:embeddings` failure 14:17). **Residual:** a degraded-search banner already exists (`session-load.sh:1363-1409`) and fired once (09-26, session 82918385). It then missed for two reasons: its `[ ! -d …/transformers ]` trigger cannot see a package directory that exists but will not import (171 of 183 errors were that shape), and the render hook itself was cancelled (B7) | `error-log.jsonl` `script:embeddings` 2026-09-25..28; review #9, #14, #18 |
| B6 | Stop gate (borrow-ledger V1, still open on `main`): review/skill evidence is read from the whole transcript; only the Bash path is windowed after the last edit. **Windowing alone does not close it** (reproduced): post-edit prose ("run /review before merging", or the gate's own block reason paraphrased) and substring skill matches (`sb-validation-and-qa` on "qa") still pass, and edits made through Bash are invisible to the tool-name edit detector | `scripts/stop-verify-gate.sh:110` (windowed) vs `:130-146` (not), `:43-71`, `:256`; review #3, #4 |
| B7 | **Hook cancellation under load.** `hook_cancelled` attachments in the last 25 transcripts: SessionStart render (`hook-timer` → `session-load.sh`) 9 in 8 sessions (avg 52 s, max 159 s; timeout 15-20 s); `discover-installed.sh` 12 sessions (avg 34 s; timeout 10 s); `protocol-guard card` 6; UserPromptSubmit 9 (avg 38 s; timeout 25 s); PreToolUse guards 5 s timeouts, cancelled 20-58 times each (symlink-guard 45, flow-guard 20; max 306 s); Stop 37. `hook_cancelled` covers timeouts and interrupts alike, and whether a cancelled PreToolUse guard lets the tool run (fail-open) is unverified | session transcripts `~/.claude/projects/…/*.jsonl` (25 newest, 2026-09-24..28); aggregation script in the session scratchpad |
| B5 | Role card is imperative and chosen by agent type, not job: a research dispatch was told "write the test first"; its "HARD" lines are plugin self-protection rules, not repo rules (no `projects/*/rules.json` exists) | `scripts/protocol-guard.sh:299-400`; research-E §0 |

### Arrival probe (2026-09-27 11:47, haiku, no tools, verbatim quotes checked)

| Agent type | Card emitted | Card arrived | Native `MEMORY.md` index arrived |
|---|---|---|---|
| Explore | no log row | no | no |
| general-purpose | no log row | no | **yes** |
| `ecc:code-explorer` (plugin agent) | ok | **yes** | **yes** |
| `ecc:architect` (earlier dispatch) | ok | no (self-report) | yes |

### The ruler cannot see delivery

- value-loop over the surviving window: 3 sessions, `injected=45 read=0 pulled=13`. The audit log holds ~17 h
  (rotation), so no trend exists.
- The numerator scans the parent transcript only (`scripts/stop-extract.sh:177`); subagent JIT counts in the
  denominator; the JIT seen-set is per session, so siblings consume each other's items
  (`protocol-guard.sh:471-487,535`).
- JIT renders the lesson inline (`protocol-guard.sh:496-500`), so use never needs a fetch: `read=0` is structural.
- Per-prompt retrieval costs 2.5-4.4 s per prompt (`persona-context.sh` latency rows) against 0 measured reads.

### Coverage and state

- Doc map exists (`mcp/src/tools/doc-sources.ts`) but this repo's config is `[".claude/skills"]`: 30 of 156 tracked
  `.md` files; `docs/`, `CONSTITUTION.md`, `README.md` are absent. Native memory dir is rejected by the
  `within(projectRoot)` check (`doc-sources.ts:65-72`).
- Code map: ts/js/py only (`codemap/scan-sources.ts:60-68`): 79 of 193 ts/js, 0 of 285 `.sh`; only the most recently
  active repo is mapped per drainer tick (`brain-os-run.sh:117-128`).
- `PROJECT.md` (25.7 KB) is 10 markdown sections matched by exact header; no item ids; the pin path is uncapped (27
  decisions, 22 blockers). `pin_to_project` accepts only `blockers|decisions|conventions`: the model cannot write
  Plan, Handoff, Goal or Direction.
- Identity: basename slug; git-common-dir keying (0.52.0) applies only at linked-worktree roots; 35 `PROJECT.md`
  files include 18 witcherrpg shards and junk slugs; no merge tool.
- Three brains: hand-written `.claude/skills/sb-*` (deepest; rots — frontier/positioning/contract stale),
  native memory (36 files, 75 KB; never imported; 5/5 spot-checked topics duplicated in the wiki without links), and
  the KB (1068 pages; 150 `untrusted-derived`; 555 edges, 1 ever invalidated).
- A JIT lesson delivered during the review cited `validate-plugin.sh` R8 at lines 190-217; R8 is at 242-300 now.
  Stale knowledge is already being pushed.

### Changes on `main` since the first draft (2a550f3 → d6067fd) that constrain the plan

- **CI lost its Linux lane** (`.github/workflows/ci.yml` job `linux: if: false`, commit `f6d46d4`, "at the user's
  request to cut CI time"). It was the only lane running the full `run-all` and the only one on jq 1.7. CI now runs
  macOS (bash 3.2) and Windows (Git-Bash). Any slice here must run its touched tests under a local jq-1.7.1 shim
  before push (memory: jq 1.8 vs 1.7 `as` precedence).
- **`scripts/hook-timer.sh`** (latency wrapper that logs `{kind:"latency", hook, duration_ms, budget_warn}`) now wraps
  the SessionStart `compact` render (10 s) and PostCompact (30 s). It writes its row only after the child returns and
  sets no trap, so a killed hook leaves no row; miss detection needs a start marker (S0 B2).
- **Live `## Plan` is prose** (SHIPPED / QUEUED paragraphs, no checkbox items), so the 0.54.0 fix recognizes the header
  but tracks no items for this repo yet. `## Direction` is still absent from the live `PROJECT.md`.

### Platform facts that constrain the design

| Fact | Status | Source |
|---|---|---|
| Invoked skill bodies are re-attached after compaction with their **original rendered** content (5K tokens each, 25K total) | documented | code.claude.com/docs/en/skills |
| Skill `!`command`` output is substituted at render time; subject to permission rules (outside auto mode needs `allowed-tools`) | documented | same |
| Skill `paths:` = "loads automatically when working with matching files": eligibility vs body injection is ambiguous | probe needed | same |
| PreToolUse inside a subagent carries `agent_id` and `agent_type` | documented | /docs/en/hooks |
| `additionalContext` > 10,000 chars is replaced by a file and a 2,000-char preview; inject facts, not imperatives | documented | research-E |
| Only SessionStart(`compact`) output is re-added after compaction; other hook context is summarized | documented | research-E |
| Plugins cannot ship an always-loaded `CLAUDE.md` (`claude plugin validate` warns) | documented | /docs/en/plugins |
| Subagent `memory:` frontmatter exists (user/project/local scopes, own `MEMORY.md`) | documented | /docs/en/sub-agents |
| The compaction summarizer follows a `## Compact Instructions` block found in context: a one-line instruction injected from SessionStart, UserPromptSubmit or CLAUDE.md appeared in 6/6 summaries, 0/2 without it (CLI 2.1.284, headless, manual `/compact`). A third party saw 0/7 on 2.1.246 when asking for a restructured summary; unresolved, so every real compaction is checked at PostCompact | probe + binary string | research-F |
| PreCompact takes `trigger` + `custom_instructions` and can only block; it has no `additionalContext`. PostCompact gets `compact_summary`, no decision control. The wiki page `sessionstart-compact-reinject-probe-2026-09` wrongly says their context reaches the model | documented + probe | research-F |
| Task tools are off by default on Opus 5.5 (on up to Opus 4.7 / Sonnet 4.6 / Haiku 4.5); `/goal` conditions and the session recap (`system/away_summary`, ≤400 chars, model-written) are readable from the transcript | documented + probe | research-F |
| Claude Code sends the context-editing beta and clears old tool results client-side ("microcompact"); plugins cannot configure it; re-read metrics must exclude forced re-reads | binary strings | research-F |

### How this user actually works (research-F, this machine, 30 days)

0 real compactions in 69 sessions of this repo (auto-compaction fires near 967K tokens); heavy sessions peak at
173K-871K tokens; about 42 tool calls per human prompt; exact repeated tool calls 0-1%. Focus loss here is decay
inside very long contexts (lost state and decisions), not loops and not compaction. External evidence agrees: agent
derailment correlates weakly with context fill (Vending-Bench, r=0.167) and starts when the agent misreads its own
state; restating the user's earlier turns recovers 15-20% of multi-turn loss (Laban et al.); compliance with standing
instructions decays about 5.6% per generated function regardless of CLAUDE.md layout (arXiv 2605.10039).

---

## 3. The model: four layers over the five classes

A senior developer holds four kinds of knowledge. Each layer names its class, its home, and how it arrives.

| Layer | Question | Content | Classes | Home (no new content stores; derived caches are named in §7) | Arrives via |
|---|---|---|---|---|---|
| **L0 Atlas** | Where is it? | Repo identity; code-map hubs (incl. shell entry points and hooks); doc map of every tracked doc with `kind` and owned facts; a **routing table** ("for X, look at Y") checked against real tasks; pointers to design docs, goals, backlog sources. Never a prose tour of the repo | 3, 2 | `doc-sources.json` (default-on, repo-wide), `codemap/`, `## Goal`/`## Direction` | Compressed pipe-delimited head in the repo card, startup + compact (bytes moved from `USER.md`); pull (`knowledge_search`, `code_map`) |
| **L1 Knowledge** | Why and how? | Decisions with rejected branch; design/contract claims; lessons (error→fix, dead ends); conventions; playbooks. Every claim may carry an anchor that is re-verified | 1, 2, 4, 5 | Wiki (typed ai-blocks), `.claude/skills` and native memory **indexed by pointer** | JIT on path touch (fresh items only); pull; brief |
| **L2 State** | What now? | Goal, direction, now/next work, handoff, blockers | 2, 4 | `PROJECT.md` (kept); item ids inline `[#id]`; long backlog by pointer to its owning docs | Repo card; compact card; brief |
| **L3 Brief** | What is this task? | Precomputed from L0-L2 for the current task: goal (verbatim), open items, repo HARD rules, path-matched fresh lessons, return format | 5 | Derived cache per session; nothing new persisted | SubagentStart (reliability fixed); PreToolUse(`Agent`) hint for Plan; skill render (§6) |

Between L2 and L3 sits the **Session Working-Context record (SWC, §7.9)**: a per-session view compiled by hooks from
what already exists (goal, current step, this session's decisions with reasons, open items, files in play,
verification state, agent results). It is what the model loses when a very long context decays, and what the compact
card, the subagent brief and the next session's Handoff are rendered from. Hooks derive it; the model writes only
through `pin_to_project`.

The working agreement (class 5) is the one class with machine enforcement: it runs through every layer (hard rules
enforced at PreToolUse, conventions in L1, the protocol in L3).

**Not in the model** (adversarial review; `CONSTITUTION.md:55-59,128-133`): a sibling-results bus, promotion of raw
agent output into L1/L2, a typed JSONL ledger replacing `PROJECT.md`, generated contract pages before freshness
checks exist.

---

## 4. Delivery channels ranked by evidence

| Rank | Channel | Evidence of arrival and use | Survives compaction | Reaches subagents |
|---|---|---|---|---|
| 1 | Native `MEMORY.md` index | Arrived in 3/4 probed agents; the user's own lessons live here | yes | g-p and plugin agents; not Explore |
| 2 | Model-initiated pull (`knowledge_*`, `code_*`, `episodic_*`) | 13 pulls in 3 sessions: the only non-zero signal | n/a | yes (tools available) |
| 3 | Invoked skill body (plugin skill with `!` render) | Documented; unmeasured. Frozen at first render, so only for data that cannot go stale | yes, frozen at first render | via `skills:` preload only |
| 4 | SessionStart(`compact`) lean card | Probe: fires and survives (CLI 2.1.283); startup render cancelled in 8 of 25 sessions (B7) | it is the re-injection | no |
| 5 | SubagentStart card | Intermittent emission under load; arrival 1 of 3 when checked | no | sometimes; never Plan |
| 6 | UserPromptSubmit per-prompt retrieval | 0 reads; 2.5-4.4 s per prompt; cancelled 9 times (B7) | summarized away | no |
| 7 | JIT on Read/Edit | Inline; unmeasurable today; one stale lesson observed | summarized away | yes (shares parent seen-set) |
| 8 | Summarizer steering (`## Compact Instructions` in the startup and compact cards) | Probe 6/6 vs 0/2; conflicting third-party result | shapes the summary itself | no |
| 9 | PostToolBatch recitation at context-fill thresholds | Unproven; the only channel that reaches the model mid-task without a user prompt | summarized away | unknown (probe) |

Design rule: **a push channel earns bytes only after it shows arrival (probe) and use (experiment).**

Two external results temper this table. Vercel measured a skill that had to be chosen going uninvoked in 56% of
runs, while the same content as a passive index passed 100%: model choice is the weak link, so rank 3 is a
backstop, not a primary channel. And `read=0` may be a property of the ruler (inline JIT, parent-only scan), not
proof that injection fails; S1 answers that with outcomes instead of fetches.

### The buddy: the visible two-way channel (user, 2026-09-29)

The buddy is not a summarizer. It shows the user the traffic between Claude and second-brain as it happens:
Claude's asks (second-brain MCP calls), second-brain's answers and pushes (tool responses, repo card, JIT lessons,
per-prompt retrieval, role cards), and persona-skill use (`second-brain:*` skills, by Claude or the user). Every event
is written by a hook or the plugin itself into `.buddy/<sid>.log.jsonl`; the statusline renders it. **Zero model
tokens:** the per-prompt `buddy_react` ask (~95 input tokens that accumulate, ~55 output tokens and one extra model
round trip per prompt, measured 2026-09-29) and the event feed into Claude's context are removed; `buddy_react` stays
as an optional tool that is never requested. Event text is display-only and scrubbed; it never reaches the model.

---

## 5. Slices (revised), each with a pre-registered number

**S0 — Integrity (≈1-2 days).** Restore what is shipped and make its failures visible. No new surface.
- B7 first (it decides whether any push can be measured, and it is a safety defect):
  - **Probe results (2026-09-28, CLI 2.1.283, headless):** a PreToolUse deny hook that answers after its 3 s timeout
    is reported `outcome:"cancelled"`, `exit_code:1`, and the Write **runs** (control: the same deny answered at once
    blocks it). All 301 classifiable `hook_cancelled` rows in the 25 newest transcripts sit at or over their configured
    timeout (0 early cancels), so they are timeout kills: about 217 PreToolUse guard runs failed open in 4 heavy
    sessions. Quiet-machine cost per Edit: `persona-tool-guard` (via `hook-timer`) 1.5 s, `symlink-guard` 1.6 s, the
    other three 0.1-0.2 s, so 5 s leaves about 3x headroom. This breaks "PreToolUse guards fail SAFE"
    (`sb-change-control` §9 rule 1) and is the top fix of S0.
  - Fix order: (1) a dependency-free fast path first in every deny guard, deciding the dangerous cases (credential
    and plugin-state targets, symlink escapes) before sourcing `lib.sh` or spawning jq; (2) cut `persona-tool-guard`
    and `symlink-guard` to < 300 ms on a quiet machine (profile: `lib.sh` sourcing, `realpath`/`cygpath`/jq spawns;
    cached effective rules); (3) only then consider longer timeouts or merging the five Write/Edit hooks into one
    process. RED: a guard fixture under an artificial slowdown still denies the dangerous case within 1 s.
  - Ruler: at Stop, count this session's `hook_cancelled` attachments from the transcript already being read and log
    one `gate=hook-cancelled` row per hook (event, script, count, max ms). No new hook.
  - SessionStart: move `discover-installed.sh` (34 s avg when cancelled, 10 s timeout) off the startup path and cut the
    render's cost the same way.
  - *Success:* zero guard fail-opens in the slowdown fixture; zero SessionStart render cancellations and < 1% guard
    cancellations over 10 sessions of the user's normal multi-agent load.
- B1: prefer the last `SubagentHandback` message from the subagent's own transcript (already read); capture a
  workflow agent's `StructuredOutput` input (capped, DATA-bannered) or log `reason=structured-output`; log handback
  and archived lengths on every capture and raise an `sb_log_error` row when a handback exists but the archive is
  shorter (the alarm the first blackout lacked); keep a per-session retention floor under the global cap.
  *As shipped in 0.54.1:* the capture logs payload length and the archive write's `archive_rc`, and archived payload
  lines are quoted `> ` so a forged `USER:` line cannot be indexed as a user message. The shorter-archive alarm and
  the retention floor are **deferred to S2**: S0's first alarm compared the selection with itself and was deleted
  (devils-advocate, 2026-09-30). The real alarm needs `sb_archive_subagent_result` to return the bytes it wrote. The
  floor needs a session-keyed eviction order in both the sub-prune and `sb_prune_transcripts` (extracted first, then
  other sessions' unmined files, then the archiving session's beyond K, with a loud hard ceiling). About 40 lines and
  2 spawns per SubagentStop.
- B2: reliability only. Precompute the per-tier card at SessionStart so SubagentStart does one file read; write a
  start marker before work and pair it with the end row, so a start without an end is a counted miss (`hook-timer.sh`
  cannot log a kill); a malformed payload logs `reason=bad-payload`. Target < 1 s at 6 parallel under load.
- B3: done in 0.54.0.
- B4 residual: no new banner. Widen the existing one (`session-load.sh:1363-1409`): trigger on an import failure (a
  recent `script:embeddings` error row), cover wiki `bm25-only`, and log each banner emission so a miss is visible.
- B6: drop assistant-prose evidence entirely; window Skill calls after the last edit and match an exact allowlist of
  verification skills; detect edits by worktree fingerprint (shared with S1b's V2), not tool names. RED cases: prose
  mentioning `/review` after the edit → block; `sb-validation-and-qa` → block; a `sed -i` edit after the tests → block.
- B5 moves to S3 (gated on S1): SubagentStart carries only `agent_id`/`agent_type`, never the dispatch description
  (docs; probe on CLI 2.1.283: the per-agent `meta.json` is written after the hook), so "job-shaped" has no input in
  S0. S0 keeps only the facts-not-commands rewording of the existing per-type card.
- Ruler: value-loop counts subagent transcripts; seen-set keyed by `agent_id`; gate rows kept ≥30 days outside the
  audit rotation.
- *Success:* the B7 numbers above; a nonce card arrives in Explore, general-purpose and a plugin agent (headless probe,
  arrival not row count); `sub-*` archives hold the report text for handback and workflow agents.

**SB — Buddy as a hook-driven event layer (after S0; independent of S1).** Events at 0 model tokens:
- Claude → brain and brain → Claude: PostToolUse on `mcp__plugin_second-brain_*` (added to the existing observation
  hook's matcher, no new script) writes one event per call: the tool and a short form of the query, and the answer
  (hit count and top slug, "pinned", "fetched <slug>"). Skills: PostToolUse on `Skill` for `second-brain:*`; a
  `/second-brain:*` prompt is detected in UserPromptSubmit in-process. SubagentStart: one builtin append when a role
  card is delivered.
- Remove the per-prompt ask and the event feed from `persona-context.sh`; `buddy_react`'s description says optional.
- Renderer: new kinds `asked` / `answered` / `skill` with the existing priority rules (gate alerts first).
- *Success:* 0 buddy bytes injected per prompt; 0 extra round trips; every second-brain MCP call and persona-skill use
  produces exactly one event (fixture per tool); hook p95 unchanged.

**S1 — The experiment (≈1 day + runs).** The critic's falsification test, before any new delivery.
- 12 incident-derived tasks (R8 location, jq 1.7 `as` precedence, exec bits, CRLF, stale bundle, Plan header, …);
  headless `claude -p`, `--setting-sources project`, detached worktree at a pre-fix commit; 3 reps per arm.
- Arms (design spec: session scratchpad `s1/`, tasks self-tested: every gold answer scores correct, all 24 wrong
  answers fail, no prompt leaks an answer token):
  - **A** plugin fully on (`--plugin-dir`, a pinned copy of `plugin/` at a commit where dist-current passes).
  - **B** same copy with a patched `hooks.json` that removes every push hook (SessionStart startup/compact render,
    protocol card, UserPromptSubmit, SubagentStart, PostCompact) and keeps the guards and MCP pull. Env switches
    cannot do this: `SB_REPO_CARD=off` restores the larger PROJECT.md render (cap 1800 → 3000 B), no switch turns
    off the startup block, and `SB_PERSONA_GATE=off` also disables two guards.
  - **C** plugin off; one static block rendered offline by the plugin's own scripts (never hand-written, which
    would write the answers in).
  - **D** plugin off, no block: the floor. The repo's 36 project skills (`sb-*`) load in every arm and hold many
    answers; without D, "A ≈ B" cannot be told apart from "the tasks are saturated".
- Controls: `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` in all arms (verified to override); `--setting-sources project`
  (drops user plugins); `ENABLE_CLAUDEAI_MCP_SERVERS=false`; environment scrubbed of `CLAUDE*`/`SB_*` (a leaked
  `SB_NESTED_SPAWN` would silently turn A into B); a pinned model id; one fresh detached worktree per run from a
  history-pruned template; seeded shuffle; per-run sandbox brain copied from snapshots frozen before any task text
  existed, plus a canary and a leak guard (this session's transcripts contain the answers).
- Metrics: correct (required tokens anywhere, forbidden tokens on the `ANSWER:` line), tool calls before the first
  correct file, time to first correct file, cost, delivery evidence (hook responses, `hook_cancelled` attachments,
  sandbox `gate=jit` rows). An arm-A run whose render hook was cancelled is reported separately: under B7 it measures
  cancellation, not memory.
- *Pre-registered:* a task passes at ≥2/3 reps. Push is falsified if Δtasks(A,B) < 2 and the median tool-call
  reduction < 10%. Native surfaces dominate if C's pass rate ≥ A's. A task is saturated if B and D both pass 3/3;
  ≥6 saturated tasks → inconclusive (rerun without project skills). Harm: A ≥2/3 below D on any task.
- Budget: smoke run 9 runs (≈20 min), full run 144 runs (≈2-3 h at concurrency 3, ≤2 A/B at once because hooks are
  cancelled under load, B2/B7). S1 runs after S0's B7 fix, or its arm A measures the cancellation rate.

**S2 — Atlas and state write paths.** Only what S1 supports.
- Doc map default-on for the repo (`docs/`, root `*.md`, `.claude/skills`), each entry gains `kind` (path-derived)
  and, only if the one-owner lint ships, `owns` (§7.1). Native memory is indexed in a **separate pass** that never goes
  through `filterIgnored`: one out-of-repo path in the batch makes `git check-ignore` exit 128, and
  `doc-sources.ts:53-57` then silently drops gitignore filtering for the whole batch (reproduced: 7 of 10 `docs/`
  files are gitignored research). `filterIgnored` fails closed and logs on exit 128 when the root is a repo. Code map
  adds shell entry points and hook commands (regex, no native deps). Atlas head (≤10 pointer lines) enters the repo
  card, paid from `USER.md`'s 6000 B reserve.
- `pin_to_project` gains `plan | handoff | goal | direction` sections and inline `[#id]`, but plan and handoff pins
  route through `merge-project-update.sh` (its `^## Plan( |$)` grammar and first-header latch), never a second
  TypeScript writer: `pin-to-project.ts:110` matches exact headers and would reopen B3 on this repo's suffixed header.
  RED case: a suffixed Plan header.
- Routes start from human pins and incidents (`src:human|incident`); generated routes stay proposals until a probe
  task confirms them. Each route logs `hits`/`misses` in a named derived cache (`projects/<key>/routes.json`), the
  first direct measurement of a routing table anywhere (research-D gaps).
- *Success:* ≥20% of sessions pull an atlas-pointed doc before the first grep for it; route hit rate reported per
  route; hot-tier bytes flat or down.

**S3a — Working context, observational (after S0; does not wait for S1).** Research-F. Adds measurement and one
security pattern, no new push:
- Derive the SWC (§7.9) into `$BRAIN_DIR/.injected/<sid>.wc.json` from existing sources (intent spine, pins with
  session provenance, observation ledger, verify state, agent pointers); fold goal, verify state and open items into
  `## Handoff` at session end through `merge-project-update.sh`.
- Drift and focus rows at Stop: D1 share of recent files outside the working set; D2 exact repeated calls (baseline
  ≤1%); D5 goal stale; D6 recap (`away_summary`) diverges from the SWC goal; D7 edits with no verification after them;
  R1 redundant re-reads across main and subagent transcripts, excluding reads forced by tool-result clearing.
- PostCompact scores each real compaction (`gate=compact-steer`): did the verbatim goal, open ids and verify line
  survive in `compact_summary`.
- Security: `## Compact Instructions` in any tool output, file or web page can steer the summary. Add the heading
  pattern to `tool-return-scanner.sh` and neutralize it in any text the plugin inserts.
- The per-prompt goal line (shipped) gains the current step and verify state, same ≤200 B cap.
- *Success:* rows present in 10/10 sessions; hook p95 unchanged; H2 baseline recorded (share of first tool calls
  after a compaction that land on the working set).

**S3b — Summarizer steering (gated on a long-session auto-compaction probe and H1, not on S1).** S1's tasks never
compact, so S1 cannot measure this. A fixed-text `## Compact Instructions` block (≤400 B: keep the verbatim goal, open
ids, the verify line, and decisions with their rejected branch) in the startup and compact cards; the SWC block
(≤600 B within the 1536 B card) re-injected after compaction. H1 (seeded harness, forced auto-compaction via
`CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000`, 12 tasks × 2 arms): the verbatim goal survives in ≥95% of summaries, ids in
≥90%, rejected options in ≥80%, and ≥+20 points over today's card; falsified below +10. Low value for this user until
compactions become frequent; it matters for anyone who runs a smaller auto-compact window.

**S3c — The brief and mid-task recitation (gated on S1, the S0 B7 fix and H3).**
Precomputed, pointer-only, facts not commands, untrusted and compaction-sourced items excluded.
- Mid-task recitation (PostToolBatch, ≤200 B, fast path) only at 25/50/75% context fill, after ≥40 tool batches, or
  on a drift flag; never unconditional. H3 (6 long tasks of 300K+ tokens): constraint violations down ≥50%, R1 down
  ≥20%, hook p95 ≤150 ms, 0 cancellations; falsified below 25%, in which case it is not built.
- Fields per agent type (research-E §B): Explore → goal, paths; implementer → goal, open ids, repo HARD rules,
  path lessons, return format; reviewer → goal and constraints only; fork and empty `agent_type` → nothing. Keyed by
  agent type and precomputed per session: SubagentStart cannot see the dispatch description (S0 B5 note).
- Job-shaped content, if S1 supports it, goes through the parent's PreToolUse(`Agent`) `additionalContext`, which does
  see the description; a PreToolUse→SubagentStart join is built only if a 6-parallel test proves it race-free.
- Plan: parent-side PreToolUse hint with the brief text to paste (no `updatedInput.prompt`, which would exceed the
  protocol lock).
- Post-compaction parent: ≤600 chars listing this session's agent reports by id, verdict enum, and archive path.
- *Success:* brief arrival ≥90% of dispatches (nonce); brief ids cited or paths used in ≥10% of reports; duplicate
  reads across concurrent siblings down (A/B).

**S4 — Freshness, then depth.**
- Anchors are designed fresh, not merged from `feat/wiki-claim-anchors` / stash `c86d60a`: the user asked on
  2026-08-22 for that work to be removed (69 `verify` lines were stripped then), and the stash is 107 commits behind
  `main`. The case for anchors now rests on a measured failure: a JIT lesson delivered 2026-09-27 cited
  `validate-plugin.sh` R8 at lines 190-217 when R8 sat at 242-300. The hook verifies before injecting
  (deterministic, ~20 ms per item, verdicts in a named sidecar cache, never in the page): pass → inject with an ok
  stamp; path exists but check fails → inject only "drifted: re-check <id>"; path gone → never inject.
- Retirement: by anchor death plus structural importance through the existing reversible forget path (manifest,
  restorable), never by disuse. The constitution bans usage-driven forgetting (`CONSTITUTION.md:124-127`;
  `wiki-forget-score.sh` removed usage and recency from eviction), and autonomy bans a human-confirm step: a
  `human|incident` rule whose anchor dies is demoted automatically and reversibly. Copilot's 28-day expiry is borrowed
  only as "stop auto-injecting an item that is never used", not as deletion.
- Refresh on HEAD move: `git diff --name-status -M` re-indexes changed docs, remaps renamed paths in routes and
  anchors, drops dead routes. Git and regex only.
- Native memory: indexed and linked (MinHash match to wiki pages), never written (D2).
- Only then: onboarding-generated design pages for repos with no design docs, each claim carrying `Sources:
  [path:a-b]`, capped at 3,000 chars, admitted only if removing it would change behaviour (BMAD admission test).
- *Success:* 0 stale anchors delivered over 10 sessions; duplicate lessons linked; per-item Useful/Misleading
  tagging from reports (Devin Session Insights) as the honest L1 measure.

Identity (rekey to a stable repo id, merge shards) is its own change, gated on a dry-run merge report over all 35
brains; not bundled with any slice.

### Borrow-ledger items (`docs/researchs/2026-09-26-borrow-ledger.md`): status on `main` and placement

The borrow ledger holds the MD-memory research (jaredrhod's AI Memory Vault) and the Cursor/pstack/gstack features.
Checked against `main` d6067fd on 2026-09-28.

| Item | Status on `main` | Placement in this concept |
|---|---|---|
| C1 compact re-inject · C2 PostCompact capture · C3 open-work carry/stale · C4 handoff provenance and drift | **Shipped in 0.54.0** (`session-load.sh --compact`, PostCompact → `## Plan`, `[carried]`/`[stale]`, `in_flight` + `rev-list --count` drift) | Baseline; C3's JSONL form stays deferred (§7.8) |
| C5 recovery line in a compaction-surviving channel (jaredrhod) | Not built | **§6 option A backstop, pointer only**: one static line in `using-second-brain` ("if the project card is not in context, Read `projects/<slug>/PROJECT.md` Goal / Handoff / Plan"). No `!` render of state: a `!` render is frozen at first invocation and re-attached after compaction, so it would replay a stale Handoff and Plan next to C1's fresh card. Existing tools only (the ledger's `handoff_get` is dropped: no new MCP tools); C1's `gate=compact-reinject` rows watch the primary path |
| C6 one line per session | Covered by `sessions-digest.jsonl` (SessionStart ≤800 B) | None |
| **V1** stop-gate evidence not windowed (confirmed bug, still open) | `stop-verify-gate.sh:130-146` scans the whole transcript for `/review` text and Skill calls; only the Bash path uses the after-last-edit window (`:110`) | **S0** (integrity, B6): windowing is not enough (review #3, #4). Drop the prose path, window Skill calls against an exact verification allowlist, detect edits by worktree fingerprint. RED cases: prose after the edit → block; substring skill match → block; Bash `sed -i` edit after tests → block |
| **V3** graded verdicts (VERIFIED / NOT VERIFIED / INCONCLUSIVE; live / test / type-check only) | Not built | **S1b** (below). One enum, defined once in `protocol.md` and referenced by the stop gate, the DO card and §7.5 (replacing today's READY / NOT READY) |
| **V2** evidence bound to exact content (worktree fingerprint before and after, FRESH / STALE / MISSING) | Not built | **S1b** |
| **E3** capture-quality filters (durable, decision-changing, lint-could-enforce → backlog, already covered) + demotion on negative signal | Not built | **S4**, next to retirement by provenance: the same admission test gates what extraction writes |
| **E4** per-turn injection byte ratchet | Not built | **S2** lock: moving `USER.md` bytes to the atlas head must not raise total injected bytes per turn |
| E1 with/without A/B | Not built | **S1** |
| F1 code map for shell and hook entry points | Not built | **S2** |
| C7 `/checkpoint` · E2 blinded transcript-graded evals · F2 task-shaped `job` pages · V5 shellcheck in CI | Not built (ledger: PILOT) | Deferred. E2 follows S1 on the same harness; F2 is piloted as a `playbooks` page (§7.7) for release gating |
| Redirect native `MEMORY.md` into the KB | Rejected in the ledger (MEMORY.md survives compaction) | Kept rejected; the narrower pointer-only block is §6 option B |

**S1b — Honest verification (V1 follow-up, V2, V3).** Independent of the push question, so it can run alongside S1.
The stop gate and the protocol/DO cards ask for a graded verdict instead of a bare READY; `sb-evidence` records
`{cmd hash, exit, worktree fingerprint before/after, pass/fail/skip counts}` so "this suite passed on this exact
content" is a checkable fact (the repo's own lessons: gate on exit codes, freeze the tree before attestation,
concurrent sessions). A script addition needs a surface-budget bump or a merge into `stop-verify-gate.sh`.
*Success:* every release run in 10 sessions carries a FRESH evidence row; zero STALE runs accepted as passing.

### How the slices relate to the queued plans (live `PROJECT.md` `## Plan`, 2026-09-28)

| Queued plan | Overlap with this concept | Resolution |
|---|---|---|
| **P3a Phase 4-5**: layer-5 code↔wiki edges; optional WASM tree-sitter tier | Code↔wiki edges are the L1 anchors of §7.6; a WASM parser is the non-native way past regex for the code map (§5 S2) | One workstream: S4 anchors land as P3a Phase 4 edges; WASM tree-sitter stays optional and is the only allowed parser beyond regex (no node-gyp) |
| **P6-quarantine**: dual-LLM summarizer/writer split, network deny-proxy | Any generated L1 page (S4), the native-memory index and captured agent reports (B1) are untrusted input to consolidation | P6-quarantine is a prerequisite for S4's generated pages; S0-S3 only index and point, never promote content |
| **P8 remainder**: LongMemEval recall suite, guard-liveness violation injection | S1 is an outcome eval; B2 is a liveness failure (a hook that silently stops delivering) | S1 runs as the first P8 outcome suite; SubagentStart arrival joins the guard-liveness checks |
| **P1.2**: skill-utilization telemetry (blocks P4.1) | D2 option A's skill backstop depends on the model invoking a skill (uninvoked 56% in Vercel's eval) | P1.2's counts measure option A's backstop; no separate counter |

---

## 6. Decision for the user: how strict is D2?

D2 (2026-09-24): the KB is the only home; nothing is written into `CLAUDE.md`, `.claude/rules` or native `MEMORY.md`.
The evidence now shows the plugin's own push rarely arrives, while native `MEMORY.md` does.

| Option | What it does | For | Against |
|---|---|---|---|
| **A. Keep D2; passive index + reliable hooks** (recommended first) | Atlas head as a compressed, pipe-delimited routing index in the repo card at startup and compact (passive, Vercel-shaped); hooks made reliable under load (S0 B7, B2); `using-second-brain` carries one pointer line as a backstop (no `!` state render, see the C5 row) | No new surface, no repo writes; the compact card already survives compaction; reversible | Depends on hooks finishing, which B7 shows they often do not under load; does not reach Explore/Plan; the backstop depends on model choice (uninvoked 56% in Vercel's eval) |
| B. Relax D2 narrowly | The plugin maintains one marked, pointer-only block (≤15 lines) in the repo's native `MEMORY.md`; everything else stays in the KB | The only channel proven to reach main + subagents and survive compaction | Machine edits in the user's own memory file; races with Claude's auto-memory writes; instruction-level authority for anything poisoned (mitigated by pointers only) |
| C. Compile into repo files | Generated, git-excluded `.claude/rules` or skills per repo | Native path loading | Repo pollution; rules carry instruction authority; rejected in D2 for poisoning risk |

Recommendation: **A now, decide B with S1 data** (run after S0's B7 fix). If arm C (static native block) beats arm
A, B is the evidence-backed move and needs a D2 amendment with a machine lock (pointer-only content, byte cap, marked
block, read-back check that human lines are untouched). External evidence favours passive indexes over model-chosen
retrieval either way. B differs from A in reaching subagents, surviving compaction, and **not depending on a hook
finishing** — B7 makes that last difference weigh more than it did when D2 was decided.

---

## 7. Schemas

### 7.1 Doc-map entry (the `doc-sources.ts` entry, unchanged, plus two fields; L0)
Existing fields stay as they are (`id, path, rel, gist, headings` (H2 and H3), `hash, mtime, size`;
`doc-sources.ts:29-32`; `knowledge-search.ts:222-230` reads `mtime`, `size`, `headings`). Added:
- `kind`, derived from the path: `{readme, constitution, plan, spec, design, adr, concept, research, runbook,
  playbook, skill, memory, changelog, other}`.
- `owns` (≤5 kebab keys, e.g. `surface-budget`, `release-gates`) only if the one-owner-per-key lint ships; it is the
  doc-ownership map that the hand-written `sb-docs-and-writing` keeps today.
Research-D's other fields (`title`, `kind_src`, `status`, `superseded_by`, `blob`, `updated`, `bytes`, `load`) are
dropped: they rename or duplicate existing fields, and `supersedes` edges link wiki slugs only.

### 7.2 Atlas head and routes (repo card section)
- Head: ≤1,200 B of pipe-delimited lines in llms.txt shape, trimmed to budget by ranked rows (Aider-style):
  `goal|<text>` · `dir|<direction> (through <date>)` · `route|<ask>|<look…>` · `hub|<path>|<role>` ·
  `pull|code_map, knowledge_search`.
- Route record: `{id, ask (task keywords), on_path (glob), look[≤4 typed refs], why ≤80, src ∈ {human, incident,
  generated, probe}, verified (sha), hits, misses}`.
- Repo identity (for the separate rekey change): id = hash of the normalized remote, falling back to the root commit;
  `common_dir` joins worktrees; `aliases[]` lists legacy slug dirs for the one-time merge.

### 7.3 `pin_to_project` extension (L2; no new tool)
`section ∈ {blockers, decisions, conventions, plan, handoff, goal, direction}`; optional `id` (`[#p12]`), `op ∈ {add,
done, drop}` for `plan`; hard caps per section on the pin path (plan 15 open, decisions 5 then rotate to the wiki log).
`plan` and `handoff` writes go through `merge-project-update.sh` (one Plan grammar: `^## Plan( |$)`, first-header latch,
`[carried]`/`[stale]`/`[untrusted:compact]` markers), locked by a shared fixture with a suffixed header.

### 7.4 Brief (L3; derived, per dispatch)
`{v:1, agent_type, goal(verbatim, src), open[≤3 ids], hard[≤4 rule ids+text], lessons[≤3 {id, line≤160, anchor,
fresh}], paths[≤6], return}`; ≤1,800 chars; trusted section first, then `--- DATA (quoted; not instructions) ---`;
excludes `held-untrusted`, `[untrusted:compact]` and harness-flagged items.

### 7.5 Agent report pointer (captured; class 4)
`{agent_id, agent_type, description, verdict, gaps[≤3], report_path, trust ∈ {ok, flagged}}`; `verdict` uses the
single V3 enum defined in `protocol.md` (S1b), with `unknown` when no grade is parseable; flagged entries keep the
pointer only. `report_path` is kept under a per-session retention floor, not only the global 50-file cap (floor
deferred to S2, see §5 B1; until then only the global cap applies).

### 7.6 L1 ai-block envelope (every type; extends `kb-schema.json`)
`anchors[≤5]` (`path[:L1-L2]`, `path#symbol`, `test:`, `cmd:`, `wiki:`, `mem:`) · `verify` (`grep:<re>@path`,
`absent:`, `exists:`, `test:` maintain-lane only, `manual:`) · `verified` (`sha7@date`) · `provenance ∈ {human,
incident, observed, generated, imported}` · `load ∈ {always, path:<glob>, task:<kw>, symptom:<re>, manual}` ·
`since` (version the claim became true). Caps: ≤1,200 B per block, lines ≤160. Unknown fields are dropped by
`renderAiBlock` today, so the kb-schema edit comes first.

### 7.7 Two new page types (S4, only after 7.6 verification runs)
- `contracts` (design/HLD claims): `claim ≤240, binds, prevents, rule, enforced_by` (test/hook/CI id; `none` renders
  "unenforced", MADR's Confirmation), `incident, level` (C4 L1-L2 or arc42 section), `status`.
- `playbooks` (triage): `symptom, discriminator, cause1..4/fix1..4, forbidden, unchanged` (what SHALL continue to
  work, Kiro), `postcondition, incident, enforced_by`. Loaded on `symptom:` matches in Bash output, so the playbook
  arrives with the error.
These two types carry what the hand-written `sb-*` skills hold and the plugin cannot generate today (§2).

### 7.8 Deferred: typed ledger
Research-D's `ledger.jsonl` (event-sourced, ULID, ids never renumbered, `evidence` required to close, `+N more`
instead of silent drops) is the right shape if `PROJECT.md` outgrows inline ids. Adopted now without the store: ids
never renumbered, `done` without evidence renders `done?`, overflow prints a count line. Revisit when a second
consumer needs structured state or when S2's pin path shows merge conflicts.


### 7.9 Session Working-Context record (SWC; derived cache `$BRAIN_DIR/.injected/<sid>.wc.json`)
`{v:1, goal{text≤170 verbatim, src ∈ goal-cmd|first-prompt|pin|handoff}, step{id, src}, decisions[≤4 {text, why,
rejected, id}], open[≤3 {text, src}], files[≤8 {path, actor ∈ main|agent_id, op ∈ read|edit}], verify{state ∈
green|red|stale|none, cmd, at, edits_since}, agents[≤5 {id, type, verdict, pointer}], ctx{tokens, compactions},
drift[flags D1-D7]}`. Sources in priority order: the user's `/goal` condition, the intent-spine first-prompt freeze, a
`goal` pin, a carried Handoff. Summaries, recaps and agent reports never populate goal, decision or step (untrusted).
Rendered into the compact card (≤600 B), the subagent brief (≤400 B, S3c) and the session-end Handoff.

---

## 8. Surface budget

Skills 17/17, agents 4/4, scripts 56/56, tests 168/168 (`.claude-plugin/surface-budget.json`); TypeScript is not
counted. Pay for any addition by: folding `track` into `setup` once the doc map is default-on; putting the
native-memory index into `import-host`; finishing the pending `review` → `status` merge; retiring the dead `capture`
skill (`user-invocable:false` + `disable-model-invocation:true`).

## 9. Do not build (additions to the 2026-09-24 list)

A sibling-results bus or dispatch registry visible to other agents; promotion of agent output into goal, decision or
constraint fields; a JSONL ledger replacing `PROJECT.md` (until 7.8's trigger); generated design pages without
anchors; prose repo tours or directory trees as context (research-D: they cost 20% and do not help); an
embeddings-built atlas; auto-memory without code anchors; unconditional per-tool-batch recitation (the shipped
per-prompt goal line stays: about 5 prompts per heavy session); LLM calls inside hooks; imperative wording in any
card, with one exception, the fixed-text `## Compact Instructions` block the summarizer is built to follow; compact
instructions written into CLAUDE.md; blocking auto-compaction; rendering recaps, summaries or agent reports into goal,
decision or step fields; a `!` skill render of volatile state (Goal, Handoff, Plan); forgetting or expiry driven by
disuse; a human-confirm step in retirement; merging the removed claim-anchor stash instead of designing anchors
fresh; a second degraded-search banner; a TypeScript Plan writer with its own header grammar; a second verdict
vocabulary.

## 10. Open probes

1. SubagentStart for Plan on the installed CLI (docs list Plan as a valid matcher; probe P1 failed twice).
2. Skill `paths:` semantics (eligibility vs body injection) for a plugin skill.
3. Does `${CLAUDE_PLUGIN_ROOT}` expand inside a skill `!` command; does the render survive compaction verbatim.
4. ~~SubagentStart hook wall time under parallel dispatch~~ Measured: 1.4-2.2 s on a quiet machine (1 or 6
   parallel), 3.6-14.5 s under concurrent-session load, against a 5 s timeout.
5. Interactive-mode compaction (the §8.8 precondition that 0.54.0 shipped without); now testable on the installed
   0.54.0 runtime.
6. ~~Does a timed-out PreToolUse guard let the tool run? Which share of cancellations are timeouts?~~ Answered
   2026-09-28: yes, it fails open (S0 B7 probe results); 301 of 301 classifiable cancellations are timeout kills.
7. Where the SessionStart render spends 15-159 s under load (spawn tax, lock waits, `discover-installed.sh`).
8. Long-session auto-compaction (forced window) and a second compaction: does summarizer steering hold (S3b gate)?
9. Interactive-mode summarizer steering, and the third-party "restructure" failure re-run on the installed CLI.
10. Does PostToolBatch fire inside subagents, and at what latency (S3c)?
11. Does the MCP server see `CLAUDE_CODE_SESSION_ID` (needed to stamp session provenance on pins for the SWC)?

---

## 11. Review record

`devils-advocate` run `wf_97710104-d6a` (2026-09-28, 53 agents, 0 errors) against this document on `main` d6067fd:
21 findings confirmed (14 medium, 7 low, none high), 27 dismissed. All 21 are folded in:

| Review # | Finding | Where it landed |
|---|---|---|
| 1, 13 | SubagentStart carries no dispatch description; B5 "job-shaped" has no input | S0 B5 note; S3 keyed by agent type; job shape via parent PreToolUse |
| 2, 12 | B1 misses workflow `StructuredOutput` reports; store at cap; no alarm for the second blackout | §2 B1; S0 B1 |
| 3, 4 | Windowing does not close V1; prose and substring skills still pass; Bash edits invisible | §2 B6; S0 B6; borrow V1 row |
| 5, 7, 11, 19 | C5 as a `!` render replays stale Goal/Handoff/Plan after compaction | Borrow C5 row; §6 option A; §4 rank 3; §9 |
| 6 | Disuse expiry and human confirm break two hard constraints | S4 retirement; §9 |
| 8 | "Merge the stash" ignores the 2026-08-22 removal | S4 anchors; §9 |
| 9, 14, 18 | A degraded-search banner exists; it missed (trigger + cancelled render) | §2 B4; S0 B4; §9 |
| 10 | A TS Plan writer would reopen B3 | S2; §7.3; §9 |
| 15, 17 | Native-memory path disables gitignore filtering; route counters had no store | S2; §3 header |
| 16 | B2 is load-dependent (1.4-2.2 s quiet); hook-timer cannot log a kill | §2 B2; S0 B2 |
| 20 | §7.1 renamed and duplicated DocEntry fields | §7.1 |
| 21 | Three verdict vocabularies | Borrow V3 row; §7.5; §9 |

Evidence gathered while folding the review, not raised by it: B7 (hook cancellation under load), from the
`hook_cancelled` attachments in the 25 newest session transcripts.

**Research F (2026-09-29)**, focus and working memory (`docs/researchs/2026-09-29-sources/research-F-*.md`, local):
added the compaction and native-memory platform facts and this user's usage numbers to §2, the SWC (§3, §7.9),
channels 8-9 (§4), the S3 split into S3a/S3b/S3c (§5), the §9 wording changes and probes 8-11 (§10). A wiki page
(`sessionstart-compact-reinject-probe-2026-09`) states that PreCompact/PostCompact context reaches the model; the probe
transcript shows it arrived only as hook-validation error text. It is corrected in the knowledge base.
