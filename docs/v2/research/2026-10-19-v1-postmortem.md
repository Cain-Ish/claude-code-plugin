# second-brain v1 post-mortem: why it did not deliver repo memory

Date 2026-10-19. Read-only analysis of `main`. The brief named HEAD `ea56cdc` (0.57.0, 1362 commits); the
checkout had moved one commit to `9718cee` (release 0.57.1, 1363 commits), the squash of the 0.57.0 re-audit
fixes. Code-size numbers are given at both commits; commit statistics cover the full history through `9718cee`.

The v2 goal: every session in a repo knows what its lead developer, PM and designer know (structure,
decisions, conventions, goals), at minimal token cost. This report asks why v1 did not get there. It does not
re-derive what the docs already say. It cites them and adds numbers:
`docs/concepts/2026-09-27-repo-brain-concept.md` (the committed version, called "concept" below), `CONSTITUTION.md`,
`docs/plans/2026-10-12-reaudit-0.57.0.md` ("reaudit"), `docs/plans/2026-09-24-repo-brain.md` ("repo-brain plan"),
`.claude/skills/sb-failure-archaeology`, `.claude/skills/sb-architecture-contract` and `.claude/skills/sb-change-control`.

Method and caveats:
- Commit classes come from conventional prefixes. Subsystem classes come from keyword matching on commit
  subjects, where the first match wins, so treat them as about ±10%.
- I counted process spawns by putting logging shims for 37 common binaries (jq, sed, awk, grep, tr, cygpath, git,
  node and others) on PATH. I ran each hook once with a scratch `BRAIN_DIR` on the development machine
  (Windows 11, Git Bash), with a warm cache and no other load. The counts are a lower bound: bash subshell forks
  (`$(…)`) are not counted, and on MSYS each one is an emulated fork.
- Numbers measured under load come from the reaudit and the concept. I keep them apart from my quiet-machine
  numbers.

---

## 1. Headline numbers

| Metric | Value | Source |
|---|---|---|
| Product's own success metric (injected item read later) | 0 of 83 (13 sessions); 0 of 47 non-ritual (09-24); 2 of 117 (09-05); injected 45, read 0, pulled 13 (09-28); 4% of offered pages ever read (10-05) | `CONSTITUTION.md:74-76`; deep audit header (branch `audit/2026-09-05-deep-audit`); concept §2 l.93; `a346615` body |
| Days between "read = 0" being recorded and the freeze | ≥60 (first recorded in `a335391`, 2026-08-20) | git |
| Outcome experiment (S1) | harness of 2,710 lines merged 2026-10-01 (`995191a`), **never run**: `plugin_commit` is still `"TBD-after-S0-merge"` | `tests/evals/s1/config.json:8`, `tests/evals/README.md:223-227` |
| Commits | 1363 in 172 days (92 active days); fix 448, feat 274, docs 127, test 94, release 77, merge ~152 | git |
| fix:feat ratio | 0.6 (May), 1.1 (Jun), 5.7 (Sep), **12.6 (Oct)** | §2.1 |
| Versions shipped | 234 distinct `plugin.json` versions; 77 `release:` commits; 9 releases on 2026-06-22 alone | git |
| Product code | 27,075 lines of bash (56 scripts; `lib.sh` 5,011) + 12,008 lines of TS. Tests: 41,987 lines of bash (168 files) + 15,371 lines of vitest, **1.45× the product** | §2.3 |
| Hooks | 11 events, 27 commands, all `bash` scripts; 24 MCP tools; ~214 `SB_*` env flags read by shipped code (253 in the flag catalog) | `hooks/hooks.json`, `mcp/src/server.ts` |
| Processes per Edit call | 8 hook commands → 10 bash + ≥42 external execs; about 1.5 s summed wall time on a quiet machine | §2.4 |
| Guards failing open under load | about 217 PreToolUse guard runs in 4 heavy sessions; allow path 5.2-9.5 s against a 5 s timeout (0.57.0) | concept §5 S0; reaudit l.4, l.99 |
| Who wrote it | 1 human author (two git identities); 1,059 of ~1,210 non-merge commits (87%) carry an AI-agent co-author trailer or session link; 100% in July, September and October, 75% in August | git |

---

## 2. Quantification

### 2.1 Commit mix

Whole history: fix 448 · feat 274 · merge ~152 · docs 127 · test 94 · chore 79 · release 77 · other 61 (pre-convention
April subjects) · build 18 · refactor 8 · ci 7 · perf 5 · misc 9.

| Month | Commits | feat | fix | test | release | fix:feat | fix-on-fix (narrow) |
|---|---|---|---|---|---|---|---|
| 2026-04 | 50 | 0 | 2 | 0 | 0 | n/a | 0 |
| 2026-05 | 267 | 100 | 56 | 5 | 1 | 0.6 | 23 |
| 2026-06 | 462 | 115 | 132 | 18 | 34 | 1.1 | 35 |
| 2026-07 | 71 | 19 | 19 | 1 | 24 | 1.0 | 8 |
| 2026-08 | 70 | 16 | 12 | 5 | 9 | 0.8 | 6 |
| 2026-09 | 135 | 11 | 63 | 17 | 6 | 5.7 | 19 |
| 2026-10 (1-19) | 307 | 13 | 164 | 48 | 3 | **12.6** | 35 |

Since the concept was approved on 2026-09-28, which said to run S1 "before any new delivery", there have been 190 fix
commits, 53 test, 13 feat, 5 release and 0 S1 runs. All 13 feat commits are capture, archive or diagnostics work
(drain cursors, secret scrub, int8 vectors). None is delivery.

**Fixes of previously shipped fixes** (448 fix commits, subject and body):
- Conservative: the terms again, regression, follow-up, half-done, reopen, still broken/open/present, corrects and
  sibling match **126 (28%)**.
- The brief's heuristic matches **235 (52%)**. It adds `re-` and any audit id (R1-…, F3, S2-1, H6-x, D0xx, SEC-x, B7,
  re-audit). `re-` over-matches words such as re-verify and re-run, so take this as an upper bound.
- By term: "again" 73, "regression" 47, "sibling" 16, "follow-up" 11.

**Where fixes landed** (keyword class, whole history / since 09-28): guards and security 111 / 62 · capture 86 / 56 ·
consolidation 48 / 15 · **delivery and retrieval 43 / 30** · build, test and portability 42 / 2 · storage 30 / 3 ·
persona 19 / 12 · review, routing and output style 18 / 0 · buddy 3 / 1 · other 48 / 17.

156 fix commits (35%) name a platform or shell class (Windows, MSYS, CRLF, cygpath, mawk, bash 3.2, macOS, 8.3,
portability, jq version). 83 (19%) name timeout, latency, spawn or fail-open. 198 (44%) name either.

### 2.2 Audit and remediation rounds

| # | When | Round | Findings | Shipped as |
|---|---|---|---|---|
| 1 | 2026-06-10 | Whole-plugin deep dive, waves R1-R9 | 9 waves; R3, R5.2 and R9 never closed | 0.24.37-0.24.50 |
| 2 | 2026-07-02 | 11-agent deep audit | 9 HIGH closed | 0.33.31 |
| 3 | 2026-09-05 | Deep audit (15 readers, adversarial verification) | 221 after dedup: 2 critical, 23 high, 64 medium, 84 low, 45 known. D025 (guard over its 5 s timeout, 14 of 2,267 runs) marked **wontfix** | 0.50.0, "107 findings fixed" |
| 4 | 2026-09-27/28 | Concept: 5 audits, 3 probes, devils-advocate | B1-B7, 21 review findings | S0, 0.54.1 |
| 5 | 2026-10-05 | Usage audit, branches `r1/*` (11) | 68% of injections on machine turns, 4% read, 122 of 124 foreign `claude -p` injected | 0.55.0 |
| 6 | 2026-10-06 | R2 capture, branches `r2/*` (12) | n/a | 0.56.0 |
| 7 | 2026-10-07/08 | R3 whole repo, 9 lenses, branches `fix/2026-10-0x-*` (14) | ~53 still present, then a 6-lens review (46: 3 blockers, 24 should, 19 nit) and 4 approach must-fixes | 0.57.0 |
| 8 | 2026-10-12 | Re-audit of 0.57.0, 9 reviewers, branches `q*` (10) | 58 unique (5 MUST, 32 should, 28 nice), then a review of the fixes (26, 2 MUST), then a re-review (0 MUST) | 0.57.1 |

That is six rounds in 45 days (rounds 3-8) and 47 fix branches in 8 days (10-05 to 10-12).

**Treadmill number:** of the 64 ledger rows the reaudit counts (l.3; 58 unique), 27 were introduced by 0.57.0, the remediation release itself,
and 11 more are tagged still-present (an earlier fix was incomplete). So 38 of 64 (59%) are defects the previous
remediation either created or failed to close. The reaudit's own SHOULD list is headed "new in 0.57.0 (half-done
fixes / regressions)" (reaudit l.13).

### 2.3 Size, surface and churn

| Area | at `ea56cdc` (0.57.0) | at `9718cee` (0.57.1) |
|---|---|---|
| `scripts/*.sh` | 26,881 | 27,075 |
| `scripts/lib.sh` | 5,102 | 5,011 |
| `hooks/` (json and notes) | 567 | 567 |
| `mcp/src` TS (no tests) | 11,973 | 12,008 |
| `mcp/src` `*.test.ts` | 15,053 | 15,371 |
| `tests/test-*.sh` | 41,386 | 41,987 |
| `mcp/dist` (committed bundles) | n/a | 21 files, 2.7 MB; 178 commits touch it |
| `plugin/` (generated install tree) | n/a | 148 files; 49 commits touch it |
| hook events / commands / MCP tools | 11 / 27 / 24 | 11 / 27 / 24 |

Growth during "integrity first", from 2026-09-28 (`d6067fd`) to 0.57.1:
- bash 18,138 → 27,075 (+49%)
- `lib.sh` 3,514 → 5,011 (+43%)
- bash tests 28,104 → 41,987 (+49%)
- TS 10,463 → 12,008 (+15%)

The surface budget did not move in that time (scripts 56, tests 168; `.claude-plugin/surface-budget.json`), because it
counts files, not lines or cost.

Longer trend for `lib.sh`: 1,869 (0.33.31, July) → 2,487 (0.47.0) → 3,462 (0.54.0) → 5,011.

Churn without bundles or `plugin/`: +195k / −74k lines over the whole history. Of the +41k since 09-28: tests +22.4k,
bash +13.6k, TS +2.3k.

### 2.4 Process cost per hot-path event

Quiet machine, warm cache, external execs per hook (lower bound; see method):

| Tool call | Hook commands that fire | bash processes | External execs | Summed wall time |
|---|---|---|---|---|
| Edit/Write | Pre: persona-tool-guard (via hook-timer), wiki-write-guard, symlink-guard, plan-first-nudge, protocol-guard pre (via hook-timer). Post: quality-gate, observe-tool-use, simplicity-gate | 10 | 42 (11+0+4+6+2+1+13+5) | ~1.5 s |
| Read | Pre: persona-tool-guard, protocol-guard pre. Post: tool-return-scanner, observe-tool-use | 6 | 34 | ~1.4 s |
| Bash | Pre: persona-tool-guard, flow-guard. Post: tool-return-scanner, observe-tool-use | 5 | 33 | ~1.3 s |

- Unit costs on the same machine: `bash -c :` 51 ms; `bash` that sources `lib.sh` 90 ms; `jq` 24 ms; `node` 63 ms;
  `cygpath` 23 ms.
- observe-tool-use alone spawns 13 processes per call, which matches reaudit H6-6 (l.82).
- The hook-timer wrapper adds one bash and one watchdog `sleep` (about 80 ms, +20% on persona-tool-guard). The first
  call with a cold cache took 22 execs and 728 ms.
- The concept counts about 42 tool calls per human prompt (§2 l.151). At that rate the plugin runs about **1,600
  processes and about 60 s of summed hook time per human prompt** on a quiet machine.
- Under load the reaudit measured **314 ms per spawn** (S3-3, l.55). One guard path costs about 11-12 processes, so
  under load the spawn cost alone approaches the 5 s guard timeout.

**Timeouts compared with measured latency** (concept §2 B7 l.79, §5 S0 l.221-238; reaudit l.4, l.99;
`sb-architecture-contract` §2):

| Hook | Timeout | Measured |
|---|---|---|
| SessionStart `session-load.sh` | 15 s | cancelled in 8 of 25 sessions, avg 52 s, max 159 s |
| SessionStart `discover-installed.sh` | 10 s | avg 34 s when cancelled. It also printed a 440,513 B catalog at every start until 2026-10-07, and none of it was injected (`scripts/discover-installed.sh:7`) |
| UserPromptSubmit `persona-context.sh` | 25 s | 2.5-4.4 s per prompt; cancelled 9 times (avg 38 s) |
| PreToolUse guards (6 commands) | 5 s each | quiet machine 0.05-0.5 s now (1.5-1.6 s at 0.54.0); under 9-agent load the allow path takes 7.7-14.3 s (0.56.0) and 5.2-9.5 s (0.57.0); cancelled 20-58 times each, max 306 s; 301 of 301 classifiable cancellations were timeout kills, and **the tool ran** (fail-open) |
| SubagentStart role card | 5 s | 1.4-2.2 s quiet, 3.6-14.5 s under load; arrived in 1 of 3 probed agents |
| PostCompact | 30 s | 31-54 s on a loaded box |
| Stop | 10-45 s | cancelled 37 times |

### 2.5 Surface outside the five memory classes

Product lines by area at 0.57.1 (bash + TS, no tests; the mapping is a judgment call):

| Area | Lines | Maps to a memory class? |
|---|---|---|
| Delivery, retrieval, storage (session-load, protocol-guard, persona-context, search, codemap, episodic, wiki validation) | 11,730 | yes (product) |
| Shared infrastructure (`lib.sh`, server, resolvers, locks, build and validate) | 7,729 | support |
| Capture (stop-extract, pre-compact, subagent-capture, drainer, merge-project-update, raw inbox) | 6,641 | yes (input) |
| Consolidation (dream, maintain, FORGET, cluster, MinHash, consolidate-writer) | 4,452 | storage upkeep |
| **Guards and security** (persona-tool-guard 1,936, symlink-guard 1,153, flow-guard 805, wiki-write-guard 848, tool-return-scanner, config-change-guard) | 5,309 | partly class 5 (repo hard rules); credential and egress guards: no |
| **Workflow gates** (stop-verify-gate, plan-first-nudge, quality-gate, simplicity-gate, sar-summary, verify) | 1,277 | protocol (class 5) vs generic review (no) |
| **Persona** (signals → USER.md, `persona_think` Opus advisor, stats and dismiss) | 935 | no; USER.md is per-user, not per-repo |
| **Buddy** (statusline, events, config) | 605 (+768 test lines; 28 commits, +7.2k/−2.9k churn; headline of 3 of 11 releases 0.49.0-0.57.1) | no |
| **Env catalog** (`discover-installed.sh`) | 491 | no |
| Telemetry (observe-tool-use, hook-timer, liveness) | 399 | support |

Non-memory or contested surface: about 8.6k of 39.6k product lines (22%; telemetry excluded as support), plus about 12k test lines (guards 7,507;
persona 3,915; buddy 768). It received 111 of 448 fixes (25%), and **3 of the re-audit's 5 MUSTs** landed there
(S2-1 guard 8.3 bypass, S3-1 learned guard rules as persistent injection, S7-1 `persona_think` refused for OAuth).
None of the 5 MUSTs is in delivery.

**Was the scope rule (`CONSTITUTION.md:55-59`) violated? Yes, and it was enforced once.**
- `00c1a51` (2026-08-20) deleted the team orchestration, code-review-deep and reviewer agents: skills 19→17, agents
  10→4.
- Model routing had already gone out with the cost-router in 0.35.x (archaeology undo row 10).
- After that cut, the buddy (0.51-0.54), the `/?` Opus advisor, the expansion of the credential ASK tier (0.56.0) and
  the output style (0.49.0) came back in.
- Class 5, "working agreement", was **added** to the constitution on 2026-09-24 (`e8d2144`), long after the guards
  existed (they were born in 0.21.0, archaeology era 4). The rule was widened to fit the surface rather than the
  surface being cut to fit the rule.
- The buddy and the credential/egress guards still map to no class.

### 2.6 What delivery evidence existed

- The only channel with evidence of arrival is native: `MEMORY.md` arrived in 3 of 4 probed agents, the plugin's
  card in 1 of 3 (concept §2 arrival table, §4 rank 1).
- The only non-zero use signal is pull initiated by the model: 13 pulls against 0 reads of 45 pushed items.
- The ruler could not see use. JIT renders inline, the numerator scans only the parent transcript, and the seen-set
  is shared across siblings (concept §2 l.93-99).
- The deep audit (09-05) measured "injection→read 2/117" and still triaged a guard timing out (D025) as wontfix.

---

## 3. Root causes, ranked

Ranking key: how much each cause explains the constitution's own failure metric (0 of 47 reads), and how directly it
blocks the v2 goal. Commit counts are evidence, not the ranking key.

### RC1. v1 built capture and storage before proving delivery, and never ran the outcome test

**Statement.** Capture, storage and consolidation were built for six months. No experiment ever tested whether
memory changes what Claude does. When the metric came back as zero, v1 kept building inputs.

**Evidence.**
- Feat commits by class: capture 57, consolidation 36, storage 29 (122 in total), against delivery 29 (of 274).
- `read=0` was recorded on 2026-08-20 (`a335391`: "83 injected … 0"). The constitution calls delivery "the product.
  Capture and storage are inputs to it" (`CONSTITUTION.md:26-29`), and concept §0.1 says "What is missing is not
  storage." The S1 with/without harness (2,710 lines) was merged on 10-01 and has never been run
  (`tests/evals/s1/config.json:8`).
- After it was merged: 3 releases, about 300 commits, and 13 feats, all capture or diagnostics.
- 0.54.0 "continuity across compaction" was built for a user with **0 real compactions in 69 sessions** (concept §2
  l.150).
- The borrow ledger (2026-09-26, §0.5) had already named a with/without A/B as "the cheapest way to learn". It is
  23 days later and the A/B has not run.

**v1 symptom.** 1,068 wiki pages, 555 edges (1 ever invalidated) and a 25.7 KB `PROJECT.md`, against 0-4% of
pushed items being read. Every "fix delivery" round moved bytes without moving the number.

**v2 rule.**
- *Eval first:* a with/without outcome eval (fixed task set; metric = tasks solved and tool calls before reaching the
  right file) exists and runs before any capture or storage code is written.
- *Gate:* it runs on every release. A feature merges only if its pre-registered delta is met, for example at least
  +2 tasks or at least 10% fewer tool calls.
- *Check:* `eval/report.json` is attached to every release commit, and CI fails if it is missing or older than HEAD.

### RC2. Delivery went through plugin push hooks instead of the channels the harness loads natively

**Statement.** D2 made the private KB "the only home" and forbade writing `CLAUDE.md`, `.claude/rules` and
`MEMORY.md` (`CONSTITUTION.md:34-37`; repo-brain plan l.46-51). v1 therefore had to push everything through
hooks, which are the least reliable channel.

**Evidence.**
- Native `MEMORY.md` arrived in 3 of 4 agents and the plugin card in 1 of 3. Native files survive compaction and
  reach subagents; hook context does neither (concept §4 table).
- The 08-20 plan proposed "delegate the hot tier to Claude Code's native memory" (`a335391`). D2 reversed it on
  09-24 as a "user directive". The concept's option B (a pointer-only `MEMORY.md` block) was deferred "with S1
  data", which never came.
- The repo's own (untracked) `.claude/CLAUDE.md` still routes decisions to the KB.
- The concept's own design rule: "a push channel earns bytes only after it shows arrival (probe) and use
  (experiment)" (§4 l.199). It was never met for any push channel.

**v1 symptom.** A delivery stack of SessionStart render, protocol card, role cards, per-prompt retrieval, JIT and a
compact card (≈11.7k lines including retrieval). Every layer depends on a hook finishing in time.

**v2 rule.**
- *Native first:* default delivery is repo files the harness loads natively: a routing index in `CLAUDE.md` or
  `AGENTS.md` (≤60 lines, pointers only), path-scoped rules, and skills.
- *Push needs proof:* a plugin hook may push only content a per-CLI-version nonce probe shows the native channel
  cannot carry, and only while the probe shows at least 90% arrival.
- *Check:* `probe/arrival.json` in CI.

### RC3. The hot path ran on bash under Git Bash, so the spawn cost made hooks miss their timeouts

**Statement.** 27 of 27 hook commands are bash scripts that fork jq, cygpath, git and tr. On the developer's own
platform, under his own multi-agent load, they exceed their timeouts and get cancelled. A cancelled push never
arrives, and a cancelled guard fails open.

**Evidence.**
- Per Edit: 10 bash processes, ≥42 execs and about 1.5 s on a quiet machine (§2.4). Under load the cost is 314 ms per
  spawn.
- Allow path 5.2-9.5 s against a 5 s timeout.
- About 217 guard runs failed open in 4 sessions. The SessionStart render was cancelled in 8 of 25 sessions.
- 35% of all fixes name a platform or shell class, and 19% name timeout, latency or fail-open (§2.1).
- 9 of the archaeology's 26 incident rows are shell or platform classes (§1-4, 10, 11, 14, 18, 19).
- `lib.sh` is 5,011 lines, and the hot-path hooks that source it pay about 90 ms per call before doing any work.
- Local `run-all` on Windows cannot finish: it was "stopped by the memory reaper at 36/168" (`9718cee` body). The
  Windows CI lane timeout went 25 → 40 → 55 min.

**v1 symptom.** B7. Guards that "fail safe" by contract (`sb-change-control` §9 rule 1) failed open in practice. The
deep audit's D025 was triaged wontfix. Months went into portability fixes (CRLF faucet with 121 jq call sites, 8.3
names, here-string hangs).

**v2 rule.**
- *Hook budget:* at most 1 hook per event, written in one compiled or `node` process with no shell and no jq
  subprocess.
- *Latency:* p95 ≤100 ms at 8 concurrent sessions on the Windows CI lane, enforced by a CI latency test that fails
  the build.
- *Scope:* no memory feature may need a PreToolUse hook.

### RC4. Knowledge lived in a single-user, machine-local KB outside the repo

**Statement.** The source of truth was `~/knowledge/wiki` plus `BRAIN_DIR/projects/<slug>/`. It is per machine, built
from one user's transcripts, never reviewed and never versioned with the code. Nobody else on a team can read it,
correct it or add to it, and when the plugin breaks, the decisions are invisible.

**Evidence.**
- `CONSTITUTION.md:24-26` ("Durable, portable, ours"); D2.
- Identity is a basename slug: 35 `PROJECT.md` files, of which 18 are shards of one repo plus junk slugs (concept §2
  l.111-112).
- There are three unlinked brains: 36 native memory files that were never imported, the hand-written `sb-*` skills,
  and the KB (concept §2 l.113-115).
- 51 tracked files cite KB-only wiki pages. Release bodies say "decision pinned" to a `PROJECT.md` that is not in git.
- `docs/researchs/` is gitignored (`.gitignore:54`), so even the borrow ledger and the research behind the concept are
  not in the repo.
- 1 human author. The only "team" was AI agents, 87% of commits.

**v1 symptom.** v1 structurally cannot meet the v2 goal ("what the lead / PM / designer know"): those people never
appear in the transcripts it mines. Knowledge rotted unseen. A JIT lesson cited `validate-plugin.sh` R8 at lines
190-217 when R8 was at 242-300 (concept §2 l.116).

**v2 rule.**
- *Source of truth:* repo knowledge is plain files versioned in the repo and changed by PR, so they are reviewable,
  attributable and shareable.
- *Cache only:* machine-local state is a cache that one command rebuilds from git.
- *Check:* a CI test deletes the cache, rebuilds it, and requires the outcome eval to score the same.

### RC5. The knowledge source was an LLM auto-extracting from transcripts, with no human in the loop

**Statement.** Every Stop ran an LLM extractor over raw transcripts and wrote the results into the injected set
automatically. That created a memory-poisoning surface, a large quarantine and upkeep machine, and content that no
human approved.

**Evidence.**
- Capture plus consolidation: 11.1k product lines (28%) plus about 19.5k test lines.
- The P6 dual-LLM quarantine (Stage A/B), the secret scrub, the tool-return scanner and `held-untrusted` gating all
  exist only because of auto-extraction.
- Re-audit MUST S3-1: learned rule candidates armed after 3 runs in one session, so an injected "SYSTEM: ignore
  previous instructions" reached the model on every `git status` (reaudit l.53).
- Deep-audit D109 (HIGH): untrusted text spliced into USER.md.
- 150 of 1,068 pages are `untrusted-derived`.
- The R1 incident: 169 extraction timeouts and a recursive self-spawn.
- 122 of 124 foreign `claude -p` children were injected.
- Persona-noise incident §25.

**v1 symptom.** A security treadmill: 111 guard and security fixes. Knowledge went stale with no way to check it.
Effort shifted from "is it used" to "is it safe to have written it".

**v2 rule.**
- *Propose only:* an LLM may propose knowledge (a diff or PR, or a `remember` command the user runs). Nothing reaches
  the delivered set without a human merge.
- *Anchors:* every delivered claim carries a code anchor (`path:line` or a symbol) that is re-verified before
  injection.
- *Check:* a lint fails on any delivered item with no anchor or a stale one. The target is 0.

### RC6. Scope crept beyond memory

**Statement.** Guards, workflow gates, a persona advisor, a statusline pet and an environment catalog grew inside a
memory plugin, and they took the reliability and review budget.

**Evidence.** About 8.6k of 39.6k lines (22%); 111 of 448 fixes; 3 of 5 re-audit MUSTs; buddy as the headline of 3
of 11 releases (0.49.0-0.57.1); class 5 added after the fact; scope cut once (`00c1a51`) and then regrown (§2.5).

**v1 symptom.**
- PreToolUse carries 6 commands, mostly security. Their latency is what fails open under load (RC3).
- The per-prompt buddy ask cost about 95 input tokens, 55 output tokens and an extra model round trip per prompt
  before it was removed (concept §4).

**v2 rule.**
- *Manifest:* every surface in the plugin manifest names one memory class and one outcome metric. Validation fails
  otherwise.
- *Out of scope:* security guards, quality gates, UI and advisors live in separate plugins.
- *Check:* a manifest lint in CI.

### RC7. Remediation followed finding lists, not deletion against an outcome

**Statement.** Each audit produced a list. Parallel agents fixed every item, which added code. The next audit found
the regressions. Nothing asked whether a subsystem should exist.

**Evidence.**
- 6 audit rounds in 45 days and 47 fix branches in 8 days (§2.2).
- 59% of re-audit rows were introduced by, or survived, the previous remediation.
- fix:feat ratio of 12.6 in October; between 126 (28%) and 235 (52%) fix-on-fix commits.
- During the "integrity" slice, bash grew 49% and `lib.sh` 43%.
- The agent fan-out used for fixing (7 parallel fixers, 9 reviewers) is itself the "9-agent load" under which the
  guards were measured failing (reaudit l.4).

**v1 symptom.** A plugin that was never stable long enough to run its own outcome test. S1 waited on "S0 done", and
S0 never ended.

**v2 rule.**
- *Keep or kill first:* a subsystem with ≥5 fix commits in 30 days, or any regression of an earlier fix, gets a keep
  or kill decision against its outcome metric before any further fix.
- *Delete when you can:* audit findings are closed by deletion where possible.
- *Check:* track the share of findings introduced by the previous release; a release over 10% is blocked.

### RC8. Governance measured proxies, not outcomes, and its locks froze wrong beliefs

**Statement.** The ratchets and gates measured file counts, test presence and structure. They let size and latency
grow unchecked and never touched delivery.

**Evidence.**
- The surface budget stayed flat at 56 scripts and 168 tests while bash and tests grew 49% (§2.3).
- 57k lines of tests (1.45× the product), yet "918 green tests hid a dead injection gate for the entire life of the
  feature" (`CONSTITUTION.md:140-143`). That gate threshold sat above its own mathematical ceiling (`a335391`).
- A test locked the compaction-matcher exclusion on a stale upstream belief, "do not fix the matcher back" (borrow
  ledger §0.1 and C1).
- 8 pre-push gates (repo-brain plan "Verification"). None of them measures use.

**v1 symptom.** Every gate green while the product metric sat at zero.

**v2 rule.**
- *Budget real costs:* LOC (for example ≤5k product lines for v2.0), processes per event, p95 latency, and injected
  tokens per session (for example ≤1.5k).
- *Outcome gate:* the outcome eval (RC1) is the only release-blocking quality gate beyond build and unit tests.
- *Locks expire:* every lock that encodes an external platform fact names its probe and is re-probed on each CLI
  version bump.

---

## 4. Candidates rejected or merged

| Candidate | Verdict | Why |
|---|---|---|
| Experiment S1 designed but never run | **Merged into RC1** | Supported: placeholder `plugin_commit`, no run in 18 days, 3 releases since. It is the sharpest instance of RC1, not a separate cause |
| Decisions stored where only a working plugin can read them (D2) | **Merged into RC4 and RC2** | Supported: 51 tracked files cite KB-only pages, `docs/researchs/` is gitignored, decisions are pinned outside git. It is one consequence of putting the source of truth outside the repo |
| Process overhead (surface budget, gates) treating symptoms | **Kept as RC8, ranked last** | Supported, but it failed to prevent the failure rather than causing it |
| Token bloat as a root cause | **Rejected** | The hot tier is capped at `BYTE_BUDGET=8000` / `HARD_CAP=9500` (`scripts/session-load.sh:835,1081`), about 2k tokens per session plus about 662 B per prompt. The 440 KB catalog was never injected by Claude Code. v1's cost was processes and latency, not tokens. The token problem was zero *use* per token, which is RC1 |
| Bad retrieval or ranking as the root | **Rejected as root** | The dead injection gate (`a335391`) was real, but after it was fixed reads stayed at 0-4%, and the 08-20 sample judged the content "genuinely good" (372 pages). Delivery and use failed, not ranking |
| "A Windows-only problem" | **Rejected as framing, folded into RC3** | macOS bash 3.2, BSD and mawk classes also shipped (archaeology classes 6, 18, 19). The cause is shell as the runtime; Windows amplifies it |
| Not enough testing | **Rejected** | Test lines are 1.45× the product, and tests and fixes keep growing. Tests checked mechanics, never outcomes (RC8) |

---

## 5. v2 rules (checklist)

| # | Rule | Measured by |
|---|---|---|
| 1 | A with/without outcome eval exists before any feature, runs every release, and a feature merges only if it hits its pre-registered delta | `eval/report.json` per release; CI fails if it is stale |
| 2 | Native, repo-resident channels first; a push hook needs ≥90% nonce arrival on the current CLI | arrival probe in CI per CLI version |
| 3 | At most 1 hook per event, one non-shell process, no jq; p95 ≤100 ms at 8 concurrent sessions on Windows; no memory feature on PreToolUse | CI latency test |
| 4 | Source of truth = files in the repo changed by PR; local state is a rebuildable cache | CI deletes the cache and re-runs the eval with an equal score |
| 5 | LLMs propose, humans merge; every delivered claim has a re-verified code anchor | anchor lint, 0 unanchored or stale |
| 6 | Every surface names one memory class and one outcome metric; no guards, UI or advisors | manifest lint |
| 7 | ≥5 fixes in 30 days or any regression → keep or kill before more fixes; ≤10% of findings introduced by the previous release | fix ledger in release notes |
| 8 | Budgets on LOC, processes per event, p95 and injected tokens, not file counts; platform locks re-probed per CLI | budget file checked in CI |

---

## 6. Reproduce

All commands run from the repo root in Git Bash.
- Commit mix: `git log --format='%s' | sed -E 's/^([a-zA-Z]+)(\([^)]*\))?!?:.*/\1/'`, then `sort | uniq -c`.
- Monthly table and fix-on-fix bounds: awk over `git log --format='@@@%h%x09%ad%x09%s%n%b' --date=short`.
- Release and audit rounds: `git log --grep='^release:'` bodies; `git show audit/2026-09-05-deep-audit:docs/audits/2026-09-05-deep-audit.md`;
  `docs/plans/2026-10-12-reaudit-0.57.0.md`.
- Sizes: `git ls-tree` plus `git show <sha>:<file> | wc -l` at `d6067fd`, `ea56cdc` and `9718cee`.
- Hooks: `jq '[.hooks[][] | .hooks[]] | length' hooks/hooks.json`; tools: `grep -c '^registerJsonTool(' mcp/src/server.ts`.
- Spawns: PATH shims that log each exec of 37 binaries, one hook run per script with a scratch `BRAIN_DIR` and a
  synthetic PreToolUse/PostToolUse payload; wall time is the average of 5 runs without shims.
