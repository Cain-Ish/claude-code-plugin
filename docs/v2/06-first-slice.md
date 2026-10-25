# v2 first slice: the walking skeleton

**Status:** draft, from the locked set in [DECISIONS.md](DECISIONS.md) and the architecture in
[04-architecture.md](04-architecture.md). It is built after the concept phase's gate, and measured by the eval in
[05-eval-plan.md](05-eval-plan.md).

## Order (PM1: outcome before input)

0. **Two probes the phase gate found missing. Done 2026-10-22:** `clear` and `resume` arrive (3 of 3 each); the
   read hook does not reach subagents, so the labels hold for main-session reads only. Neither needed v2 code.
   - D12's nonce probe for `SessionStart` on `clear` and `resume` (3 runs each). The matcher then includes every
     source that arrives.
   - A plugin `PostToolUse` hook on a Read made inside an Explore and a general-purpose subagent: what reaches the
     subagent, and what reaches the main session. Until it passes, the labels are claimed for main-session reads only.
1. **The eval harness, re-baselined on Opus 5.5** (05-eval-plan.md, the last section). It needs no v2 code: it is
   D17's and D20's harnesses, plus answer assertions for D22's six investigation tasks. The thresholds are set from
   these runs, by D17's rule and its gap targets, before any v2 code is written.
2. **The skeleton** below. Nothing else.
3. **The v2 arm** on A1 and A2, against those thresholds. A release cites this run (PM1).

## What the skeleton is

| Surface | What it does | Outcome it serves (PM6) | Decision |
| --- | --- | --- | --- |
| `SessionStart` hook (startup, clear, resume, compact: D12 step 0), shell form once, then Node | the capture instruction; the document index | Capture; Consistency | D14, D22, D18 |
| `UserPromptSubmit` hook | the forced decision, at the first prompt and the first after each compaction | Consistency | D22 |
| `PostToolUse` hook after a Read of a `.project-map/` file | the unreviewed label (D14) and the re-find label (D16) on the entries just read | Freshness; trust (PM5) | D14, D16, D18 |
| onboarding command | builds the index from git's file list; checks Node and git | Onboarding | D15, D18 |

Not in the skeleton:
- D20's write-time net (deferred until a check source catches pattern rules);
- `SubagentStart`;
- any model call;
- MCP, agents and skills.

## Budget (PM8: units that cost)

| Unit | Budget | Grounded in |
| --- | --- | --- |
| Always-on bytes per session | 904 B plus the index; an index past 6 KB (P2's size) is measured before it ships | D13 re-locked, D22 |
| Bytes per forced decision | 227 B, at most once per epoch (the session's start, then after each compaction) | D22 |
| Added hook p95 at 8 concurrent sessions, Windows | at most 100 ms per hook; measured in 2a: 87 ms at session start (the index from git's file list, on P2), 49 ms or less for the others | D18 |
| Processes per hook event | 1 Node process; hooks spawn only `git` | D18 |
| Product lines (hooks, library, command; not tests or the harness) | at most 600 | D18's runtime prototype: 331 lines covering the guards, cache and labels |
| Surfaces | 3 hook events, 1 command, 0 agents, 0 MCP servers, 0 skills | D18, PM6 |

## Done means

- The v2 arm meets the thresholds on A1 and A2 as `05-eval-plan.md` sets them, per cell:
  - a gain where it sets a gain, cost cells included;
  - no worse only on the cells whose spread is at least their median.

  The exceptions are the expected misses in its one list. A miss elsewhere is recorded against the trigger it fires
  (for cost, D22's).
- Every hook is measured on Windows under 8 concurrent sessions against its budget (PM3).
- The map stays readable and correctable with the plugin off (PM4). The skeleton keeps no cache (2a), so the map's
  plain files are its only state in the repo.

## Step 2 in four commits (2026-10-25)

2a, the skeleton; 2b, the harnesses' v2 arm, loading the plugin with `--plugin-dir` as a user would; 2c, the v2 arm
on A1; 2d, on A2. The expected-miss list is registered in 2c, before any v2 run.

### 2a: the skeleton's check (pre-registered 2026-10-25, before any code)

- **What is built:** `plugin/`, holding `.claude-plugin/plugin.json`, `hooks/hooks.json`, a library and one entry
  script under `scripts/`, and `commands/onboard.md`. No marketplace file until a release.
- **Surfaces:** exactly 3 hook events, 1 command, 0 agents, 0 MCP servers, 0 skills:
  - `SessionStart` on `startup`, `clear`, `resume` and `compact`;
  - `UserPromptSubmit`;
  - `PostToolUse` matched on `Read`.
- **Product lines:** at most 600 non-blank lines under `plugin/`, tests and the bench excluded. Counted in the commit.
- **Texts, verbatim, asserted by the self-test:**
  - D14's capture instruction (904 B, sha256 `8aa72396af72`);
  - D22's index first line;
  - D22's forced decision (227 B);
  - D14's label `unreviewed, not yet committed` and D16's `unverified quote, captured <date>`;
  - D18's missing-Node message, from its shell-form wrapper.
- **Behaviour, by an assert-based self-test in a temporary git repo:**
  - *The index:* tracked document files (`.md`, `.mdx`, `.markdown`, `.txt`, `.rst`, any case), grouped by directory,
    plus untracked files under `.project-map/`. Untracked documents elsewhere and non-documents are left out.
  - *The forced decision:* emitted once per epoch. Every `SessionStart` source starts an epoch, held as a marker file
    in the OS temp folder keyed by the session id; nothing is written in the repo.
  - *The read labels:* on a Read of a `.project-map/` file, an entry its `HEAD` version holds gets no D14 label, one it
    does not hold gets it, and outside git every entry gets it. A Read of any other file exits with no output.
- **Smoke:** pinned CLI 2.1.305, `--plugin-dir`, Haiku, not counted. One session in a temporary repo with one
  document and a `.project-map/captured.md` holding one committed and one uncommitted entry. It must quote:
  - the index's first sentence;
  - the forced text;
  - after it Reads the map file, the labels the hook added.

  This also settles whether exec form with `${CLAUDE_PLUGIN_ROOT}` inside `args` works in a plugin's `hooks.json`.
  If it does not, attempt 2 is a shell-form string.
- **Load:** on Windows, on a worktree of P2 at its pinned commit (189 documents, the largest index), 200 calls per
  hook at 1 and 8 concurrent, against an empty Node process. The four calls measured are session start, the prompt
  hook, a Read of a non-map file (the frequent fast exit), and a Read of a map file.
  - *Pass:* each hook's added p95 at 8 concurrent is at most 100 ms (D18).
- **The cache, decided by that number:**
  - If session start passes with the index built from `git ls-files` every time, `.project-map/.cache/` is not built,
    and 04's row is corrected with the number.
  - If it fails, a cache is attempt 2.
- **Out of scope:**
  - *D16's re-find.* Under the frozen capture instruction no captured entry carries a `verified` line, so every entry
    is unverifiable, and the re-find would never run. D16's trigger "unverifiable entries exceed 5% of a repo" fires
    by construction. The smoke records it, and D16 is the next decision after 2a. The skeleton labels such entries as
    unverified with their date, the rule D16 sets for them, so none is delivered as current.
  - D20's net, the harness arm (2b), and the v2 runs (2c, 2d).

### 2a: result (2026-10-25): pass on attempt 2

- **Built:** `plugin/` with 3 hook events, 1 command, and no agents, skills or MCP servers, in 143 product lines.
- **Self-test:** `plugin/test/selftest.mjs` passes. It covers the texts (the instruction's hash and bytes, the forced
  text's 227 B, the index line, the labels), the surfaces, and each hook run as a process in a temporary repo.
- **Smoke** (`plugin/test/smoke.mjs`, pinned CLI 2.1.305, Haiku):
  - *Attempt 1 failed* on the index item. Asked for "the first sentence of the document index", the session quoted
    the index line's second sentence. That sentence exists only in the hook's output, but the condition was not met.
  - *Attempt 2 passed*, asking for the sentence that begins "IMPORTANT: Prefer retrieval-led" (D22's own smoke
    wording). All three items were quoted word for word.
  - All three hooks returned exit 0, with the plugin loaded as `second-brain@inline` through `--plugin-dir`.
  - Exec form with `${CLAUDE_PLUGIN_ROOT}` inside `args` works in a plugin's `hooks.json`.
- **Load** (`plugin/test/bench.mjs`, Windows, a worktree of P2 at its pinned commit with one uncommitted map file:
  190 documents in 46 directories, a 6,108 B index; 200 calls per hook, paired with an empty Node process; wall clock
  only, no in-process time). Added p95 at 8 concurrent, then at 1:

  | Hook | At 8 concurrent | At 1 |
  | --- | --- | --- |
  | Session start | 87.3 ms | 47.2 ms |
  | Prompt | 37.0 ms | 5.5 ms |
  | Read of another file | 26.2 ms | 6.7 ms |
  | Read of a map file | 49.1 ms | 28.7 ms |

  No call failed. Every hook is under 100 ms, so no cache is built (04 corrected).
- **D16's trigger fired** as expected: 2 of 2 captured entries in the smoke were unverifiable. D16 is reopened in the
  ledger, and it is the next decision.

### 2b: the harnesses' v2 arm (pre-registered 2026-10-25, before any code)

- **`eval.mjs` (A1):** both its CLI calls, the session and the epoch's `--version`, start the binary named by
  `D17_CLAUDE` (default `claude`), as `native.mjs` does with its config. A1's v2 arm itself belongs to 2c, since its
  design (how the map reaches T and N) is a choice to register there.
- **`native.mjs` (A2):** arms `sba`, `sbn` and `sbmc` are the M1 arms `a`, `n` and `mc` plus the plugin, loaded by
  `--plugin-dir`. Nothing else changes. On top of the base arm's checks, a run is valid only if:
  - the init event lists the plugin;
  - its session-start output arrived once per epoch (1 in `sba`; 2 in `sbn` and `sbmc`, at startup and compact);
  - the forced decision arrived once per epoch (1 or 2).
- **Smoke 1** (`native.mjs smoke`, Haiku, not counted): `sbn` on R0 build is valid by those checks. This is the first
  time the compact source and the re-forced decision are seen through the CLI.
- **Smoke 2** (`plugin/test/smoke.mjs`, Haiku): the onboarding command, run as `/second-brain:onboard`, reports the
  index's documents and directories.
- **Pass:** both smokes pass. No baseline record is touched or re-run.

### 2b: result (2026-10-25): pass

- **`eval.mjs`** starts `D17_CLAUDE` at both CLI calls.
- **`native.mjs`** has arms `sba`, `sbn` and `sbmc`, with the three checks.
- **Smoke 1** (`sbn`, R0 build, Haiku): valid. Turn results were 3 of 3. The plugin was listed, its session-start
  output arrived 2 times (startup, then compact), and the forced decision arrived 2 times. So the compact source and
  the re-forced decision work through the CLI.
- **Smoke 2:** `/second-brain:onboard` reported "2 documents in 2 directories", so `${CLAUDE_PLUGIN_ROOT}` also works
  in a command's `!` line. The first smoke passed again beside it.
- No baseline record was touched.

### 2c: A1's v2 arm and the expected-miss list (pre-registered 2026-10-25, before any v2 run)

- **The arm (`V2` in `eval.mjs`):**
  - One run starts with H1 to H3, once, in `repo-H`, with the plugin (`--plugin-dir`) and auto memory as in M1.
  - After H3 the harness commits `repo-H`'s `.project-map/`, as the user commits the map with the work (D14).
  - Then T and N run twice, each in a fresh copy of the fixture holding that committed map:
    - *same person:* plus a copy of H's auto memory, as in M1;
    - *second person:* the map only, with auto memory off.
- **Which variant gates:**
  - Both variants are scored against M1's A1 thresholds above.
  - The second-person variant is the one a release cites (PM1), because it is the gap M1 cannot close (05, Arms).
- **Capture:** C1 to C4 are scored on `.project-map/` after H3, as in M2. In the same-person variant, the auto memory
  store's bytes are reported and not scored: a decision kept there but not in the map is a v2 capture miss.
- **Failure chain:**
  - *not kept:* the C item fails on the map.
  - *not loaded:* T read no `.project-map/` file before its first write of `UserAvatar.tsx`.
  - *ignored:* the map was read and the decision not followed.
- **Always-on bytes:** in T, the bytes of the plugin's session-start `additionalContext` plus the forced text's, taken
  from the `hook_response` events. They are compared with the budget row above.
- **Valid run:**
  - every session ends with a success result on the planned model;
  - in every session, the plugin is listed, and its session-start output and its forced decision each arrived once
    (no compaction in A1);
  - in the same-person variant, no memory write was refused.
- **Epoch:** for `V2`, `eval.mjs`'s epoch also hashes `plugin/`. `native.mjs` does the same for the `sb` arms before
  2d. A plugin change between runs is a new epoch.
- **Runs:**
  - Opus 5.5 on the pinned CLI 2.1.305: `D17_CLAUDE` is the pinned binary, `D17_MODEL=claude-opus-5-5`,
    `D17_TAG=-opus`.
  - The pilot (run 1) is checked before runs 2 to 10: its record must carry CLI 2.1.305 and the plugin hash. Its cost
    is reported in a progress note.
- **The expected-miss list.** The one list is 05's ("Recorded before the v2 arm runs", phase gate, before the
  re-baseline):
  - expected misses: P1 R2 and P2 R4;
  - expected risk: cost in document-heavy repos, D22's first trigger.

  Added 2026-10-25, from the Opus thresholds and before any v2 run, are three cells the rule makes unreachable:
  - R0-knowledge, files read before the first write: below 1, from a median of 18 and a spread of 17;
  - P2 plan, output tokens: below 300, from 2,860;
  - P2 build, output tokens: below 1,397, from 64,926.

  A1 adds none: no A1 bar is near zero.

  *Correction (2026-10-25, while A1's runs 2 to 10 ran, before any A2 v2 run):* this section first gave its own list,
  leaving out 05's P2 R4. It now cites 05's list. A1's part is empty either way, so no v2 result bears on the
  correction.
- **Misses outside the list:**
  - Orientation and cost misses are recorded against D22's triggers (06; 04's Cost weakness). They are not excused.
  - Any other miss is recorded against the trigger it fires.

### 2d: A2's v2 arm (pre-registered 2026-10-25, before any A2 v2 run)

- **Arms, as each task's M1 arm plus the plugin:**
  - `sbmc` for P1 build;
  - `sbn` for P2 build and R0 build;
  - `sba` for P2 plan and the six investigation tasks.
- **Setup:** Opus 5.5 on the pinned CLI 2.1.305, the web on, Bash off. 10 valid runs per task. Invalid runs are
  replaced, up to 2 per task. A run cut off by a usage limit re-runs under its own number. One chain per task, since
  the harness rewrites a task's results file after each run.
- **Valid run:** the base arm's checks plus 2b's three plugin checks.
- **Epoch:** `native.mjs` hashes the plugin's product files as `eval.mjs` does, so both name the same plugin. A
  plugin change between runs is a new epoch.
- **The verdict (`native.mjs verdict`, written and committed before the first pilot):**
  - It summarises the `sb` arms as `rebase` summarised M1, with the same median.
  - Then, per task and cell, D17's rule as the thresholds set it:
    - a rule passes in at least M1's count of runs (8 where M1 had 0);
    - a gain cell's median is below M1's median minus its spread;
    - a no-gain cell's median is at most median plus spread.
  - Cells on 05's list are marked. Stopped sessions are counted both ways.
  - Output: counts only, in `V2-D19-scale/results/verdict-opus.json`.
- **D22's investigation clause** ("a rule in scope is missed … on an investigation task") is settled by this verdict
  on the six investigation tasks: any failed cell there, outside 05's list, fires it. 2e does not score them again.
- **Order:**
  - The pilots launch only after 2c's result is written and no D22 trigger fired, or one that fired is handled.
  - Pilot: one run per task, cost reported in a progress note with the projected total. The re-baseline's A2 cost
    345.67 USD-equivalent for 100 runs; usage limits, not USD, are the gate.
- **Not in 2d:** 05's added shapes (a vague first prompt, two compactions, a task switch). They are 2e, with their own
  registration and D22's trigger as the scorer.

### 2e: the added shapes (pre-registered 2026-10-25, before any run)

- **What:** 05's three shapes, each on the three build tasks, with the plugin and the task's own `sb` arm (`sbmc` for
  P1, `sbn` for P2 and R0):
  - *Vague.* Turn 1 is a vague prompt that names a symptom only. Turn 2 is the task's own prompt. No compaction, so
    one epoch.
  - *Two compactions.* The standard turns with a second compaction: investigate; `/compact`; "List the files you will
    change and why. Do not edit anything yet."; `/compact`; "Now make the change." Three epochs.
  - *Task switch.* Turn 1 is the repo's first other task in the config's order (P1-skills, P2 plan, R0-knowledge).
    Then the build task's standard three turns follow in the same session. Two epochs: startup and the compaction.
    The build's own first turn gets no forced decision, which is the untested friction in 04.
- **Runs:** 5 sessions per shape and task, as in D22's checks, so 45 sessions. Invalid runs are replaced, up to 2 per
  cell. Cut-offs re-run under their own number.
- **Scope:** a rule is in scope when 2d's standard arm held it, followed in at least 8 of its 10 runs. That is D20's
  "held: fails in at most 1 of 5", scaled, and the same figure as 05's target. D22's `o0` scope cannot serve, because
  D22 never ran R0 build.
- **Scorer:**
  - D20's checks, on the build task's final files.
  - A rule in scope is missed in a shape when it fails in 2 or more of the shape's 5 runs (D20's rule).
  - A miss in the vague or two-compaction shape fires D22's trigger. A miss in the task switch is recorded against
    04's friction weakness, under D22.
  - The comparison is v2 in the shape against v2 in the standard shape. No M1 exists in these shapes.
  - Stopped sessions are read both ways.
- **Valid run:** the base checks, plus the plugin listed, plus a session start and a forced decision once per epoch
  (1 plus the number of compactions).
- **The vague prompts:**
  - A fresh agent writes one per build task. It is given only the build task's prompt and the repo at its pinned
    commit. It is told not to open `DECISIONS.md`, `docs/v2/research/` (its input aside), probe results or the task's
    rules and checks.
  - Each prompt names a symptom a user might notice, not the change.
  - Mechanical check: no `must` or `mustNot` token of the task's rules appears in it.
  - The prompts are kept in the private config, and their sha256 is recorded here before any run.
- **Not in 2e:** an automatic compaction inside a turn. 05 adds it once a check shows it can be forced headless; that
  check comes first, as its own step.
- **Order:** 2e's runs follow 2d's verdict, because the scope comes from 2d.
- **The vague prompts, frozen (2026-10-25, before any shape run).**
  - Three prompts of 2 sentences each, in the private config's `vague` field, sha256 `5b9190695e86`. The hash is over
    the JSON of [id, prompt] pairs in the order P1, P2, R0.
  - The field sits outside the tasks, so the build tasks' input hashes still equal their baselines.
  - *Written by a fresh agent*, given only the three build prompts (extracted to a private file) and the repos at their
    pinned commits. It reports opening nothing else under `docs/` and searching for no rule. That is its own report,
    not a check.
  - *Mechanical check:* none of the 33 `must` and `mustNot` tokens of the three tasks' rules appears in its prompt.
  - *The agent's own caveat:* P1's prompt ("when I only want a small team") points at the task's limit more than the
    other two do. Recorded, not changed.
- **Shape smokes (2026-10-25, Haiku, R0 build, not counted):** all three valid. Session starts and forced decisions
  per session: vague 1 and 1, two compactions 3 and 3, task switch 2 and 2. In the switch, the build's own first turn
  got no forced decision, by design.

### 2c: result (2026-10-25): A1 scored, gains on capture and following, misses on T5, orientation and cost

**Runs:** 10 of 10 valid, in one epoch: CLI 2.1.305, Opus 5.5, inputs `108861b749cb`, plugin `a6d0217666ec`. Total
12.75 USD-equivalent for 70 sessions. Scored by `eval.mjs --summary` against M1's Opus thresholds.

| Cell | M1 | Bar | v2, second person | v2, same person |
| --- | --- | --- | --- | --- |
| C1, C3, C4 | 10, 10, 10 | 10 | 10, 10, 10 | 10, 10, 10 |
| C2 (the avatar spec captured) | 2 | 2 | **10** | **10** |
| T1, T2, T4 (final and at the first write) | 10, 10, 10 | 10 | 10, 10, 10 | 10, 10, 10 |
| T3 (the spec followed) | 0 | 8 | **10** | **10** |
| T5 (sources named in the reply) | 0 | 8 | **0, miss** | **0, miss** |
| N1, N2, N3 | 10, 10, 10 | 10 | 10, 10, 10 | **9**, 10, **9**: misses |
| Tool calls before the first write | 12 (spread 5) | below 7 | 12: no gain | 12: no gain |
| Files read before it | 10.5 (spread 5) | below 5.5 | 11: no gain | 11: no gain |
| T tokens, all kinds | 129,365 (63,070) | below 66,295 | 133,699: no gain | 112,552: no gain |
| T output tokens | 3,621 (1,220) | below 2,401 | 4,078: no gain | 4,226: no gain |
| T USD | 0.189 (0.061) | below 0.128 | 0.201: no gain | 0.217: no gain |
| Always-on bytes | 450 | budget | 1,340, within 904 B + index + 227 B | 1,340 |

- **What v2 gains:**
  - The designer's spec is kept (C2: 10 against 2) and followed before the first write (T3: 10 against 0).
  - It reaches a second person through the committed map. M1 cannot do that, because auto memory is per user.
  - Every decision was followed in all 20 T sessions: none was "not kept", "not loaded" or "ignored".
- **The misses, each recorded against what it fires:**
  - *T5, 0 of 10.* Nothing in the skeleton asks Claude to name the decisions it followed and their sources. D20
    left this open ("A1 item (5), measured by D17. It is not decided here"), so no decision owns it. Under rule 9,
    the charter's acceptance item (5) is not met. It needs a decision of its own (V2-D23) before a release.
  - *Orientation and cost: no gain.* Every cell sits under M1's no-worse ceiling (tool calls 17, files 15.5, tokens
    192,435, output 4,841, USD 0.250), so D22's first trigger did not fire. The charter's "fewer tokens and steps
    than the same task without the plugin" does not hold on A1. The forced decision reads the documents, and the
    reads match native's. Recorded against D22 as a measured result, not an excused cell.
  - *Same person, N1 and N3 at 9 of 10.* In one run the neighbour component took the avatar's rules (over-application),
    and in one run a file sat outside its folder. The released variant (second person) passes both, 10 of 10.
- **No D22 trigger fired,** so 2d's pilots may launch (2d's order).
- **06's "done means" is not met on A1.** It asks for a gain on every gain cell, cost included, and A1 misses T5,
  orientation and the three cost cells. The gains above are the result; the slice is not "done" on A1.
- **The same person ran on the map.** Auto memory stayed empty in 9 of 10 runs (run 7 wrote 2 files): with the
  capture instruction active, the map took the decisions auto memory would have kept. So the two variants differ
  little, and the same person's N1 and N3 (9 of 10) are run-to-run variance more than a memory effect.
- **T5, read before any decision on it** (an observation; the frozen scorer and its 0 of 10 stand):
  - H1's prompt gives the folder decision as "a decision from today's team meeting" and never names a lead
    developer. The map entries quote that source as given ("team meeting, relayed by the user"). T5's scorer asks
    the reply to name "the developer or lead".
  - Of the 20 T replies, 20 name the PM or client, 14 the designer, 16 the map, and 0 a developer or lead.
  - 14 of 20 name all three sources as the fixture states them (the meeting or the user, the designer, the PM or
    client): 8 of 10 for the second person, 6 of 10 for the same person.
  - Whether T5 measures charter item (5) is V2-D23's question, settled before 2d's runs, in case its answer changes
    the plugin and with it the plugin hash.
