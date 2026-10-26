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
| Bytes per forced decision | 227 B, at most once per epoch (the session's start, then after each compaction). D22's rethink-4 attempt adds 255 B on each later prompt of an epoch, kept only if its check passes | D22 |
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
- **Correction to the T5 observation above (2026-10-25, V2-D23).** The "14 of 20" counted any reply holding "the user",
  which every UserAvatar reply does. Under the faithful T5f (`meeting`, `developer` or `lead`; the designer; the PM or
  client), v2's attempt-1 replies score 1 of 10 (same person) and 0 of 10 (second person), and M1 scores 0. The frozen
  T5 (0 of 10) was never in question. 2c's attempt 1 is kept in `results/V2-opus-attempt1.json`. Attempt 2 runs on
  the plugin with D23's line.

### 2c, attempt 2 (2026-10-25, after V2-D23): A1's result as a release cites it

Plugin `497ba915e987` (the naming line added). 10 of 10 valid, one epoch, 13.13 USD. Attempt 1 stays in
`results/V2-opus-attempt1.json`.

| Cell | M1 | Bar | v2, second person | v2, same person |
| --- | --- | --- | --- | --- |
| C1 to C4 | 10, 2, 10, 10 | 10, 2, 10, 10 | 10, 10, 10, 10 | 10, 10, 10, 10 |
| T1 to T4 (final and at the first write) | 10, 10, 0, 10 | 10, 10, 8, 10 | all 10 | all 10 |
| T5f (D23) | 0 | 8 | **10** | **10** |
| T5 (frozen) | 0 | 8 | 0 | 0 |
| N1 to N3 | 10, 10, 10 | 10 | 10, 10, 10 | 10, 10, 10 |
| Over-attribution (D23) | — | at most 1 | 0 | 0 |
| Tool calls / files read before the first write | 12 / 10.5 | below 7 / below 5.5 | 12 / 11: no gain | 11.5 / 10.5: no gain |
| T tokens / output / USD | 129,365 / 3,621 / 0.189 | below 66,295 / 2,401 / 0.128 | 133,724 / 4,326 / 0.203: no gain | 138,378 / 4,392 / 0.222: no gain |
| Always-on bytes | 450 | budget | 1,553 (904 + index + 212 + 227) | 1,553 |

- **Every pass item now meets its bar,** T5f included. A1 item (5) is met.
- **"Done means" is still not met on A1:** orientation and the three cost cells show no gain. Each sits under M1's
  no-worse ceiling, so D22's trigger did not fire. This is the cost charted in the charter's dated line.
- 2d's pilots run on this plugin.

### 2d: pilot gate (2026-10-25)

- **All 10 pilots valid**, one epoch: CLI 2.1.305, Opus 5.5, plugin `497ba915e987`. The plugin's output arrived once
  per epoch: 2 session starts and 2 forced decisions in the three-turn tasks, 1 and 1 in the one-turn tasks.
- **Cost: 40.24 USD-equivalent.**
  - Per task (v2 pilot against M1's median): P1 build 2.17 / 1.69; P2 build 7.57 / 5.17; R0 build 3.50 / 2.87;
    P2 plan 0.57 / 0.12; R0-knowledge 8.42 / 3.85; R0-buddy 0.54 / 0.52; P1-skills 1.96 / 3.80; P1-weekly
    3.74 / 5.11; P2-crafting 3.13 / 1.12; P2-systems 8.62 / 6.32.
  - Projected at 10 runs per task: about 400 USD-equivalent, against the re-baseline's 345.67.
  - One run each says nothing about the medians the verdict uses, but the cost risk on 05's list shows already.
- Runs 2 to 10 follow in four chains, one per repo, plus P2-systems alone. Usage limits, not USD, are the gate.

### 2d: result (2026-10-25): gains on build and plan rules, little on investigation; D22's trigger fired

**Runs:** 100 of 100 valid, in one epoch: CLI 2.1.305, Opus 5.5, plugin `497ba915e987`. Each task's input hash equals
its M1 baseline's. Total 324.52 USD-equivalent, against M1's 345.67. Scored by `native.mjs verdict` into
[`V2-D19-scale/results/verdict-opus.json`](probes/V2-D19-scale/results/verdict-opus.json).

**Rules (count of 10, v2 / bar; L: on 05's list):**

| Task | Passes | Misses |
| --- | --- | --- |
| P1 build | R1, R3, R4, R5 10; **R6 10 / 8** (M1 0) | R2 3 / 6 (L) |
| P2 build | all, incl. **R4 10 / 6** (L), **R5 9 / 3**, **R6 10 / 7**, **R7 7 / 1** | none |
| R0 build | R1, R2a, R2b 10; R4 9 / 9 | R3, R5, R7 9 / 10; R6 0 / 8 |
| P2 plan | **P1 9 / 5**, P3b 10, **P4 8 / 3**, **P5 10 / 6** | P3a 9 / 10 |
| R0-knowledge | A1, A5, A6 10 | A2 1 / 8, A3 0 / 8, A4 2 / 4 |
| R0-buddy | B1, B3, B4, B5 10 | B2 8 / 10 |
| P1-skills | S1 6 / 6 | S2 0 / 8, S3 9 / 10, S4 0 / 8, S5 2 / 8 |
| P1-weekly | **W2 10 / 3**, **W3 7 / 4**, W4 10, W5 9 / 8 | W1 0 / 1 |
| P2-crafting | C1, C5 10; C2 6 / 6; **C3 10 / 8** (M1 0); **C6 6 / 2** | C4 1 / 8 |
| P2-systems | E2 6 / 6, **E3 9 / 8**, **E4 9 / 7**, E5 10 | E1 8 / 9 |

- 41 of the 57 rule cells outside 05's list pass. v2 is above M1's count in 17 cells and below it in 9.
- Build and plan rules: 20 of 25. Investigation assertions: 21 of 32.
- The cells M1 never reached on investigation tasks stay unreached (A3, S2, S4, C4). The route does not bring Claude
  to them.

**Measures:**
- Orientation fails its gain bar on the build tasks, where v2 reads more before writing than M1 does (P2 build: 175
  calls and 42 files, against 145 and 36).
- Cost is mixed: lower than M1's median on four tasks, higher on six.
- **P2 plan is above M1's no-worse ceiling** on files read (6 against 4) and cost (0.457 against 0.379 USD).

**What fires:**
- **D22's first trigger:** "the first slice's eval puts v2 above M1's no-worse ceiling on a task" (P2 plan).
- **D22's investigation clause:** a cell is missed on an investigation task, outside 05's list (2d's registration).
- So D22 is reopened. 2e's runs wait for it (rule 1), since its shapes would measure a route under reopen.
- **"Done means" is not met on A2.**

**What holds:**
- The route is a clear gain on the build and plan rules of the two repos with prose rules (P1, P2).
- R0 build's R6 (0 of 8) and its one-run misses, and the investigation tasks, are where it is not.

### 2f: installed from a local marketplace, checked live (pre-registered 2026-10-26, before any install)

The user's request: install the plugin the way a user would, through a marketplace at this local checkout, and check
that it works as intended.

- **Built:** `.claude-plugin/marketplace.json` at the repo root. Marketplace `second-brain-v2`, holding one plugin,
  `second-brain`, from `./plugin`.
  - v1's marketplace is named `second-brain`.
  - v1 is not registered, installed or enabled at the user level (checked on 2026-10-26), so nothing clashes.
- **Where:**
  - A fresh scratch git repo, holding one document and a map file with one committed and one uncommitted entry, as
    in 2a's smoke.
  - The user's installed CLI (2.1.309 at registration), not the eval's pinned 2.1.305.
  - The marketplace and the plugin both at project scope, so the user's other sessions are untouched.
- **Install check:**
  - `claude plugin marketplace add <checkout> --scope project` succeeds;
  - `claude plugin install second-brain@second-brain-v2 --scope project` succeeds;
  - the plugin shows as installed and enabled in that project;
  - the installed product files hash to the eval's plugin hash (`497ba915e987`), so the eval measured what installs.
- **Live check:** sessions in the scratch repo with the installed plugin, with no `--plugin-dir`. All three must hold:
  1. *Delivery* (Haiku, 2a's smoke prompt):
     - the init event lists the plugin;
     - the session quotes word for word the index's first sentence, the forced decision, and the labels after it
       reads the map file;
     - session start also carries D23's line.
  2. *Onboarding:* `/second-brain:onboard` reports the index's documents and directories.
  3. *Capture* (Opus, the user's model): told a decision for the project in passing, the session writes it to
     `.project-map/captured.md` as an entry with a `source` line.
- **Then the user's own check:** an interactive session in one of their repos, following the checklist written into
  this section once the live check passes.
- **Pass:** the install check and all three live checks hold. A failure is a 2f attempt, fixed and run again.
- **Not in 2f:** macOS and Linux, and the missing-Node path on an installed copy.

### 2f: result (2026-10-26): pass

- **Install check:**
  - the marketplace was added and the plugin installed, both at project scope in a scratch repo;
  - `claude plugin details` lists 3 hooks and the onboard command (counted as a skill);
  - the cached copy's product files hash to `497ba915e987`, the plugin the eval measured.
- **Live checks** (`plugin/test/live.mjs`, the user's CLI 2.1.309, the plugin as `second-brain@second-brain-v2`):
  1. *Delivery:* the index's first sentence, the forced decision and both map labels were quoted word for word. D23's
     line arrived at session start.
  2. *Onboarding:* `/second-brain:onboard` reported "2 documents in 2 directories".
  3. *Capture (Opus):* told in passing that the tech lead decided every API handler logs its request id, the session
     wrote a correct entry (source "the tech lead", dated) and named the decisions it followed. It also pointed out
     the other entry still awaiting review.
- **Observations, not misses:**
  - D23's line adds "recorded decisions followed: none" even to replies where nothing applies, such as the onboarding
    reply. It is harmless, but noisy.
  - `claude plugin details` reports the hooks as having "no model context cost". Their output does reach the model:
    1,553 B per session on A1.
- **The user's own check, in one of their repos.** Use a branch or a scratch clone; `<v2 checkout>` is the local path
  of this branch.
  1. `claude plugin marketplace add <v2 checkout> --scope project`, then
     `claude plugin install second-brain@second-brain-v2 --scope project`.
  2. Start `claude` in that repo and give it a real task. Its first reply should state yes or no per document
     directory, then read the yes ones before changing anything.
  3. `/second-brain:onboard` reports the documents and directories.
  4. State a decision in passing ("from now on …"). An entry with a source should appear in
     `.project-map/captured.md`, uncommitted in `git diff`.
  5. Ask Claude to read that file. The new entry is labelled "unreviewed, not yet committed".
  6. After `/compact`, the next prompt gets the forced decision again.
  7. At the end of a change, Claude names the decisions it followed and their sources.
  8. To remove: `claude plugin uninstall second-brain@second-brain-v2 --scope project`, then
     `claude plugin marketplace remove second-brain-v2`.
- **The user's own check, closing counts (2026-10-26).** These are counts only, sent by the session that ran the
  checklist in one of the user's repos. It ran one epoch, about 150 tool calls in all.
  - *Install:* local scope. The installed copy hashes to `497ba915e987`, with an empty diff against the checkout, on
    CLI 2.1.310.
  - *Resume* (`claude --continue`): the forced decision arrived once, on the first prompt after the resume, even
    though that prompt was a bare request to continue. There was no duplicate. This is D12's `resume` cell, in real
    use.
  - *Index:* 10 directories and 78 documents, before any `/second-brain:onboard`.
    - 7 of the 10 directories were marked yes: 72 documents, about 1.55 MB.
    - Claude deferred the rest until the work reaches them. Per directory, in index order (documents, marked, read in
      full or in part):

      | Dir | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
      | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
      | Documents | 30 | 1 | 1 | 4 | 1 | 3 | 1 | 1 | 34 | 1 |
      | Marked | yes | yes | no | yes | yes | no | yes | yes | yes | no |
      | Read | 6 | 1 | 0 | 3 | 1 | 0 | 1 | 0 | 3 | 0 |

    - 15 of the 72 were read, 12 of them by choice. Two in directory 1 arrived through the repo's own path-scoped
      rules, and one in directory 4 was already loaded as project instructions. In directory 9, all three reads were
      section ranges of large files.
    - Every small yes directory was read in full except one (directory 8, 1 document). The two large ones got 6 of 30
      and 3 of 34.
    - The index count is 77 here and 78 in the session's first message. Both are as sent.
    - This is the mechanism 2d and 2e found, now in real use: the decision is per directory, so large directories are
      marked yes whole, and the read that follows is partial.
    - The index is under P2's 45 directories, so D22's size trigger does not fire.
  - *Before the first write in the repo:* about 85 tool calls, with 11 documents and about 10 code files read. The
    first write was a report. A document read because its directory was marked yes framed the work.
  - *Writes:* 2 files changed in the repo: a new report, and one index line in the project's instruction file.
  - *Capture (items 4 and 5):* 0 entries, 0 labels; `.project-map/` was never created. The task was a one-off
    investigation and report, and nobody stated a project rule or decision in passing. That is one data point on
    capture during an investigation task.
  - *Naming (item 7, D23):* the final reply ended with a decisions-followed line naming 6 decisions, each with its
    source document as that document gives it. There were 0 invented sources and no "none" line. The interim status
    replies carried no such line.
  - *Hooks:* no errors and no visible slow start. The repo's own path-scoped rule files also arrived unasked, when
    matching code was read (native).
  - *Untested:* `/compact` (item 6), since the owner did not compact and context was ample. Uninstall (item 8) was not
    run, since the owner has not asked to remove the plugin.
- **A validity correction during 2e's runs (2026-10-26, disclosed).**
  - P1 build's task-switch run 1 was marked invalid for "wrote in the investigation turn".
  - The write was `.project-map/captured.md`: the plugin's capture instruction at work while the first task's question
    was being answered. No code was changed in that turn.
  - That check exists to keep code changes out of an investigation turn. For the plugin's arms, writes under
    `.project-map/` no longer count toward it.
  - Saved runs are re-checked with `native.mjs revalidate`, from their streams, with no re-run.
  - No rule score and no pass condition changes.
- **A second validity correction (2026-10-26, disclosed).**
  - The registration says the no-write check runs "up to the last turn that says not to edit". The code checked every
    turn from the start. In the task switch, that included the first task, which has no no-edit instruction. The vague
    shape's first turn had already been left out for exactly that reason.
  - Now the window covers only the turns that say not to edit: in the task switch, the build's investigation turn.
  - R0 build's switch run 3 had subagent scratch writes during the first task, so it is revalidated.
  - Run 2 wrote during the build's investigation turn (a subagent's probe script outside the repo). It stays invalid
    and is replaced under its own number, the first of the two replacements allowed per cell.

### 2e: result (2026-10-26): P1 holds in every shape, P2 misses in all three; D22's trigger fired

**Runs:** 45 of 45 valid, in one epoch: CLI 2.1.305, Opus 5.5, plugin `497ba915e987`. Scored by `native.mjs verdict`
(its `shapes` section) into [`V2-D19-scale/results/verdict-opus.json`](probes/V2-D19-scale/results/verdict-opus.json).
- Cut-offs, re-run under their own numbers: 12 on 2026-10-25 (the usage limit) and 1 on 2026-10-26 (P2's switch
  run 5, whose session ended with no result).
- One replacement: R0's switch run 2 (above). No cell used its second.
- Revalidated under the two corrections above: P1's switch runs 1 and 4, R0's switch runs 3 and 4. All 45 were
  re-checked from their streams under the committed code before the verdict.
- Stopped sessions: 0 of 45, so the two readings agree.

**Scope** (rules 2d's standard arm followed in at least 8 of 10): P1 R1 and R3 to R6 (R2 is out, at 3); P2 R1 to R6
(R7 is out, at 7); R0 R1, R2a, R2b, R3, R4, R5 and R7 (R6 is out, at 0).

**Failed runs of 5 per rule in scope (bold: missed, 2 or more):**

| Task | Vague first prompt | Two compactions | Task switch |
| --- | --- | --- | --- |
| P1 build | none | none | none |
| P2 build | **R4 2**, **R5 4** | R5 1, **R6 2** | **R4 2**, **R5 3** |
| R0 build | R3, R4, R5, R7 1 each (one run) | none | **R3, R4, R5, R7 2 each** (the same two runs) |

**What fires:**
- **D22's trigger** "a rule in scope is missed on a vague first prompt or in a session with more than one compaction":
  P2's R4 and R5 in the vague shape, and P2's R6 in two compactions.
- **The task switch:** P2's R4 and R5 and R0's R3, R4, R5 and R7 are recorded against 04's friction weakness, under
  D22, as registered.

**The misses, split** (from each run's stream and written files; a diagnosis beside the registered result, not a
re-score):
- *Selection, 1 cell: P2's R5 in the vague shape.*
  - The rule's source document was never read in 4 of 5 runs; one run met it by Grep.
  - In all 5 runs, the first turn's triage marked its directory yes. The session then read other documents in that
    directory, chosen by the symptom.
  - The task's own prompt, in turn 2, gets no forced decision (the shape has one epoch), so nothing sends Claude back.
  - In 2d's standard arm, the same document was read in the first turn in 9 of 10 runs.
  - This is 2d's mechanism again: in a large directory, the yes line leads to a few files, chosen by the prompt at
    hand.
- *A read before the compaction only, 1 cell: P2's R5 in the task switch* (corrected 2026-10-26: first filed under
  following).
  - R5's document was read in every switch run, but during the first task, before the compaction.
  - After the compaction, the re-forced decision marked its directory yes in every run. The 2 runs that re-read the
    document then passed, and the 3 that did not re-read it failed.
  - In 2d's standard arm, a read before the compaction was enough: 8 of 8 such runs passed. There, the read belonged
    to the same task.
  - The compaction summary does not explain the split: it kept R5 in 2 of the 3 failing runs.
- *Following, 3 cells: P2's R4 (vague), R6 (two compactions) and R4 (task switch).*
  - The rule's source was in context: both come from the root instruction file, which stays loaded across a
    compaction.
  - The written files break the rule: a required pattern is absent, or the forbidden one is present.
  - R4 is the judgment rule on 05's list, listed for a compaction. The task switch has one, so its R4 miss is the
    listed one. The vague shape has none, so the list does not cover it there. 2e's scorer has no list exemption, so
    both count.
- *Nothing to apply to, 4 cells: R0 in the task switch, runs 1 and 4.*
  - Both runs put the SessionEnd handler into an existing hook script instead of adding a new one, and left the
    surface budget file alone.
  - R3 to R5 check a new script, so they selected no file. R7 checks the budget file.
  - By the sources' own text, neither run broke these rules. No new top-level file was added, so no budget bump was
    due. The added lines append with `printf`, as R5 requires.
  - The same design appears in 1 of 10 standard runs and in the vague shape's one failing run.
  - As registered, these are misses. As diagnosed, they are the scorer's limit (checks written for one design): a Fog
    item for D17, not evidence about the route.

**Cost** (an observation: 2e registered no cost measure, and no M1 runs in these shapes). Median USD-equivalent per
run, vague / two compactions / switch, against the standard arm:
- P1 2.23 / 2.47 / 3.22, against 1.85;
- P2 4.24 / 6.94 / 5.21, against 6.25;
- R0 2.20 / 3.89 / 8.82, against 3.18.

The task switch includes the first task's work. The 45 valid runs total 195.36 USD-equivalent.

**What holds:**
- P1 holds every rule in scope in all three shapes.
- R0 holds in the vague shape and in two compactions.
- No shape made a session stop to ask.
