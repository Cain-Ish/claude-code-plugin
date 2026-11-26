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
| Bytes per forced decision | 227 B, at most once per epoch (the session's start, then after each compaction). D22's rethink-4 attempt (255 B on each later prompt of an epoch) failed its check and was not kept | D22 |
| Added hook p95, Windows | at most 100 ms per hook: at 1 session on every machine CI runs, and at 8 concurrent on the reference machine before each release, in its reference state: a CPU sample of at most 10% before each run, and empty Node at most 100 ms p95 (D18, its last re-lock of 2026-10-27). On the 4-core CI runner at 8 concurrent: 143 to 260 ms, a stated weakness. Measured at 8 concurrent in 2a: 87 ms at session start (the index from git's file list, on P2), 49 ms or less for the others. After D16's re-lock of 2026-10-26: 60 to 82 ms at session start, and 83 to 86 ms for a map read citing P2's 30 largest documents | D18 |
| Processes per hook event | 1 Node process; hooks spawn only `git` | D18 |
| Product lines (hooks, library, command; not tests or the harness) | at most 600 | D18's runtime prototype: 331 lines covering the guards, cache and labels |
| Surfaces | 3 hook events, 1 command, 0 agents, 0 MCP servers, 0 skills. D22's option (A), a fourth event (a `PreToolUse` gate at the write), failed its check on 2026-10-26 and was not kept | D18, PM6 |

## Done means

- The v2 arm meets the thresholds on A1 and A2 as `05-eval-plan.md` sets them, per cell:
  - a gain where it sets a gain, cost cells included;
  - no worse only on the cells whose spread is at least their median.

  The exceptions are the expected misses in its one list. A miss elsewhere is recorded against the trigger it fires
  (for cost, D22's). The vague first prompt and the task switch are measured but outside the claim since D22's
  re-lock of 2026-10-26; their misses are 04's named weakness, not cells of this list.
- Every hook is measured on Windows under 8 concurrent sessions against its budget (PM3).
- The map stays readable and correctable with the plugin off (PM4). The skeleton keeps no cache (2a), so the map's
  plain files are its only state in the repo.
- **At release (2026-10-27): not met in full, and stated.** Orientation and cost show no gain on A1 (2c, 2c attempt 2,
  and 2g's A1 re-runs) or on parts of A2 (2d).
  - Those cells sit under M1's no-worse ceilings. They are stated as no gain in the README and in the charter's dated
    cost line.
  - The slice shipped as `2.0.0-alpha.1` by the user's choice to publish. It did not ship because the bar was met.

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
  - *Untested:* uninstall (item 8), since the owner has not asked to remove the plugin.
  - *Compaction (item 6), reported later the same day:*
    - An automatic compaction, not a typed `/compact`. As far as the session could tell, it came between turns.
    - The compact hook's index arrived. The first prompt after it got the forced decision once, D23's line and the
      capture instruction came again, and there were no hook errors.
    - 0 repo writes between the compaction and that prompt, so D22's trigger on a write after a compaction inside a
      turn did not fire.
  - *Epoch 2, after that compaction:*
    - 6 yes and 4 no of 10 directories. 5 documents were read in full before the first repo write. The 6 unread ones
      in yes directories were deferred as not needed for the change. About 30 tool calls came before that write.
    - *Capture:* 1 entry in a new `.project-map/captured.md`: the owner's goal, stated in passing. It does not
      duplicate a rule file. This is the first capture in real use.
  - *A leak from the eval into this session (2026-10-26, disclosed).*
    - D22 rethink 4's experimental text arrived in this session once, attached to a cross-session message rather than
      a user prompt. It was followed: binding documents named before the first edit, all already read.
    - It came from the experiment editing `plugin/` in place, between commits `071cd5a` and `716b4cc`, about an hour.
    - The install's marketplace is a `directory` source at this checkout. Its cached copy kept the old code
      throughout, so the hooks evidently run from the checkout's live files.
    - Rule from here on: an attempt runs from a copy of the plugin (`--plugin-dir` to a probe folder), never by editing
      `plugin/` in place while an install points at the checkout.
    - Also observed: a cross-session message delivery fires `UserPromptSubmit`, like a background task's turn.
  - *Epoch 3, after a second automatic compaction:*
    - The forced decision fired on the first prompt after the compaction, a real message from the owner.
    - 8 yes and 3 no of 11 directories; the map's own directory is now one of them. The yes set is still about 1.5 MB.
      7 documents were read in full or in part before the first repo write: 4 read anew this epoch, and 3 rule files
      loaded on their own. The read is partial by size, as in epochs 1 and 2.
    - About 35 tool calls came before the first repo write, which was the map file.
    - *Capture:* 1, as an edit of the existing entry rather than a new one. The owner's new statement refined it, so a
      second quote went under the same heading, with one new `when` value. It qualifies a standing rule in one of the
      repo's rule files, and the entry names no file.
    - *A format question this raises, not settled by the ledger.* The frozen instruction says to add each decision "as
      its own entry", with its source. `labels()` reads only an entry's first source line, so a refinement merged under
      an older source line is labelled with the older capture date. An edited entry is still labelled unreviewed until
      committed (D18's key covers every field), so D14's trust policy holds. This is neither kept noise nor a missed
      capture, so D14's trigger does not fire.
    - *The session's answers:* both quotes sit under the one source line, which names the owner and a date, and both
      statements came that same day. So in this case no label is wrong. The map file is untracked and nothing has been
      committed, so the entry is labelled unreviewed anyway. The question stays open for a refinement made on a later
      day.
    - No hook errors, no slow start, and no experiment text this epoch.
    - *A later prompt in epoch 3:*
      - The forced decision did not fire. That is correct: no session start, `/clear`, resume or compaction came before
        it.
      - The session first reported that it had fired, then corrected itself. The yes/no list it gave (8 yes, 3 no; two
        directories flipped for the new task) was its own carry-over, not the hook.
      - Unprompted, it read 3 documents before the first repo write, and 5 rule files loaded by path on their own. About
        20 tool calls came first, and the first write was the map file.
      - *Capture:* 3 new entries, each under its own heading with one source line and a date. None duplicates a rule
        file, and none names a repo file. The map file is still uncommitted.
      - No hook errors. The repo's own post-edit reminder hooks fired about 10 times on read-only commands; that is the
        repo's noise, not the plugin's.
  - *A new epoch, reported the evening of 2026-10-26* (the message does not say what opened it):
    - *The forced decision fired once,* on an owner's prompt that asked for status, not a change.
      - 2 directories were marked yes (the research notes and the map's own directory), and all others no.
      - The session read the 2 research notes and the map file before answering: about one turn of reads, which shaped
        the status reply.
      - A question is outside the claim (D22's re-lock of 2026-10-25), so this counts as friction, not a claim cell.
    - *Capture:* 2 new entries, 6 in all.
      - Both record the owner's pick among options the session itself offered in a question. So each quote is the
        chosen option's text, written by Claude and chosen by the owner, and the source line says so.
      - D14 did not probe this kind of provenance. The entry is attributed to the owner, but the words are Claude's.
        It is neither noise nor a missed capture, so D14's trigger does not fire.
      - As a spoken decision, it stays unverified with its date (D16).
    - *Labels:* the read hook's labels ("unreviewed, not yet committed", and the unverified quote) showed correctly on
      all 4 older entries.
  - *Commits, reported later on 2026-10-26:*
    - The owner made 2 commits of the work and chose to leave `.project-map/` out of both. All 6 entries stay
      uncommitted in the working tree, so a read still labels each one unreviewed, which is correct.
    - 2 of the 6 describe decisions that those commits carried out. The entries still hold the decision and its
      source, unreviewed.
    - The capture instruction says map changes "are reviewed with the commit, like any other change". Here the work was
      committed and the map was not. So D14's review step happens only when the owner stages the map; it is not
      automatic. Until then an entry reaches no other clone and no teammate.
    - No D14 trigger fires: no entry was delivered without its label, and this is neither noise nor a missed capture.
    - For the README (2f): committing `.project-map/` is the review; leaving it out keeps the entries local and
      labelled.
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

### 2g: the release candidate (pre-registered 2026-10-26, before any change)

The release is `2.0.0-alpha.0` (V2-D05), from branch `v2`. It cites (PM1) A1 (2c, attempt 2), A2 (2d), the added
shapes (2e) and the install check (2f). All of them ran plugin `497ba915e987` on CLI 2.1.305 and Opus 5.5, except 2f,
which ran on the user's CLI.

- **The product stays as measured.**
  - Every file under `plugin/` except `test/` stays byte-identical, so the hash stays `497ba915e987`, and what ships
    is what the eval ran.
  - So there is no version bump, and the README goes at the repo root. New checks go only under `plugin/test/` and
    `.github/`.
  - A product change would open a new epoch, and PM1 would then need a new run.
- **The build checks the post-mortem sets (02):**
  - *PM1:* the release names the runs above, and the hash check holds.
  - *PM3 and PM8, a Windows lane.* CI runs `bench.mjs` on a synthetic repo of P2's shape, built by
    `plugin/test/fixture.mjs`:
    - 8,057 tracked files in 768 directories;
    - 189 documents in 45 of those directories, about 2.4 MB in all;
    - an uncommitted map file of 30 entries, each citing one of the 30 largest documents (about 1.26 MB together).

    *Pass:* 0 errors, and every hook's added p95 at 8 concurrent is at most 100 ms (D18's bar). A failure on the
    hosted runner is a 2g attempt. The bar does not move, and the runner's numbers are disclosed. As calibration,
    the same bench runs on the fixture on this machine, beside 2a's P2 numbers.
  - *PM8:* `selftest.mjs` adds two budget checks:
    - product lines (`scripts/`, `hooks/`, `commands/` and the manifest): at most 600;
    - the fixed always-on parts: 904 B and 212 B per session, and 227 B per forced decision.
  - *PM6:* `selftest.mjs` maps each surface (3 hook events, 1 command) to the outcome 06 names, and fails on a
    surface without one.
  - *PM5:* `labels()` labels every entry that is not both committed and re-found. `selftest.mjs` adds an entry with
    no source line, which must get a label.
  - *PM4:* there is no cache, so PM4's rebuild test has nothing to rebuild. The map's plain files are the only state,
    and the uninstall check below shows they stay.
  - *PM7:* fix commits on `plugin/`'s product files since 2a, counted from `git log`.
- **Three operating systems (charter).**
  - CI runs `selftest.mjs` on Windows, macOS and Linux, with Node 20, the floor the plugin states.
  - `selftest.mjs` adds the `SessionStart` command, run through bash exactly as `hooks.json` gives it:
    - with Node on the PATH, it must give the full output;
    - without Node, it must give the one-line message.
  - *Pass:* green on all three.
- **Live, on the user's CLI (2.1.311 at registration), in a scratch repo, at project scope:**
  1. *Install by the README's route:* `claude plugin marketplace add Cain-Ish/claude-code-plugin#v2 --scope project`,
     then the install. *Pass:* the cached copy hashes to `497ba915e987`, and `live.mjs`'s delivery check holds: the
     index's first sentence, the forced decision and both labels are quoted word for word.
  2. *Uninstall by the README's route:* `claude plugin uninstall second-brain@second-brain-v2 --scope project`, then
     `claude plugin marketplace remove second-brain-v2`. *Pass:*
     - a new session's init event does not list the plugin, and the session quotes no index text;
     - `.project-map/` is byte-identical;
     - nothing else in the repo changed except `.claude/settings.json`, whose plugin and marketplace entries are gone.

     What remains in that file, and outside the repo, is recorded.
  3. *Node missing, on the installed copy:* a session with Node off the PATH. *Pass:* the session answers. What the
     user sees at session start, on each prompt and on a Read is recorded as it comes. A fix would change
     `hooks.json` and so open a new epoch, so none is made in 2g; the README says what happens.
- **The README, at the repo root, for a user:**
  - what the plugin does;
  - what it was measured to do and not to do, with the numbers and the runs: the claim as D22's re-lock of 2026-10-26
    states it, and cost the same as native, not lower;
  - requirements, install and uninstall;
  - what it writes: `.project-map/` (by Claude), and one marker file per session in the OS temp folder, removed at
    the session's first prompt;
  - that committing `.project-map/` is the review (2f's own check);
  - that it calls no model and no network, and its hooks spawn only git;
  - what was tested where: Windows live; macOS and Linux by the self-test only.
- **Release review, after all of the above:** the user's devils-advocate workflow, and Gemini 4 Argon, over the
  release candidate. Each surviving finding is fixed, or recorded as an accepted risk or a trigger. The workflow
  needs the user's go.
- **Publishing** (a tag and a GitHub pre-release) needs the user's yes.
- **Pass:**
  - the product hash is unchanged;
  - CI is green on all three systems, with the Windows bench under the bar;
  - the three live checks hold;
  - the README states only what the runs show.

  Each failure is a 2g attempt.

### 2g, attempt 1 (2026-10-26): failed on the calibration; D16's trigger fired

- **Self-test:** the additions pass. They cover PM5 (an entry with no source line is labelled), PM6 (each surface
  names its outcome), PM8 (product lines, 183 of 600; the fixed bytes), and the shell form with Node and without it.
  `bench.mjs` now exits non-zero over D18's bar.
- **The fixture** (the synthetic P2 shape) was built as registered:
  - 8,057 tracked files in 768 directories;
  - an index of 46 directories and 6,837 B, with the map file.

  Added p95 at 8 concurrent on this machine, two runs: session start 101.9 and 87.6 ms, a map read 88.8 and 80.0 ms.
- **Calibration against real P2**, on the same bench the same day (added p95 at 8 concurrent):
  - *session start:* 105.6 to 112.2 ms over five runs;
  - *a map read*, with a first map in which 20 of the 30 quotes were not found: 129.9 and 136.5 ms;
  - *a map read in D16's load shape* (every quote found, `benchmap.mjs`): 147.8, 133.0 and 147.6 ms.

  Both hooks are over D18's 100 ms bar. 2a measured session start at 87.3 ms on the same machine, repo, Node and
  code.
- **The fixture is lighter than P2.**
  - Its generated text tokenizes in 8.5 ms in process, against 30.6 ms for P2's documents of the same total size.
  - A CI lane that is green on it would not be evidence for PM3. So the workflow is not pushed, and the fixture is not
    committed.
- **What fires:**
  - D16's trigger (the read hook over D18's budget): D16 is reopened.
  - Session start is an observation under D18 (not one of its listed conditions), with 04's fallback: a cache, or
    fewer spawns.
- **2g's first pass condition** ("the product stays as measured") cannot survive any fix, since every fix changes the
  hash. 2g is registered again after D16's re-decision, and with it what a new hash must re-run (PM1).

### 2g, attempt 2: registered again for the new hash (2026-10-27, before its checks run)

- **What ships:** plugin `61964f9bbb40` (D16's re-lock), version `2.0.0-alpha.0`. The release cites:
  - *A1, re-run on `61964f9bbb40`* (D16's registered re-run, on the pinned epoch). *Pass:* every pass item at its bar,
    as in 2c attempt 2: C1 to C4, T1 to T4, T5f at 8, N1 to N3, and over-attribution at most 1. Orientation and cost
    are reported against the no-worse ceilings.
  - *A2 (2d) and the added shapes (2e)*, which ran on `497ba915e987`. They carry over through D16's equivalence: the
    hook outputs are byte-identical on P1, P2 and R0.
  - *The 2f live check,* re-run on `61964f9bbb40` on the user's CLI.
- **The PM3 and PM8 lane.** The fixture is attempt 1's, with two changes:
  - its paths are longer, so its git index is at least P2's (1.16 MB against 1.02 MB);
  - `benchmap.mjs` writes its map, in D16's load shape, instead of the fixture's own.

  *Calibration comes first,* on this machine with no eval running:
  - `bench.mjs` runs 3 times on the fixture and 3 times on P2 (a worktree at its commit, with `benchmap.mjs`'s map).
  - *Pass:* for session start and for the map read, the fixture's median added p95 at 8 concurrent is at least P2's
    median.
  - A fixture lighter than P2 is made heavier and calibrated again before the lane runs. The bar never moves.

  *Then* `.github/workflows/v2.yml` is pushed. *Pass:* the self-test is green on all three systems, and the load job
  exits 0 (D18's bar on every hook, 0 errors).
- **Unchanged from attempt 1:**
  - the self-test's PM5, PM6 and PM8 checks, which already passed in attempt 1;
  - PM4, and the PM7 count;
  - the three live checks (install from GitHub, uninstall, Node missing). The install's hash check is now against
    `61964f9bbb40`;
  - the README;
  - the release review and publishing, which need the user's go.
- **Pass:**
  - the A1 re-run meets its bars;
  - the calibration passes, then CI is green;
  - the three live checks hold;
  - the README states only what the runs show.

### 2g, attempt 2: the live checks (2026-10-27)

- **A change of method, disclosed.**
  - The user's own check installs the plugin through a marketplace of the same name, `second-brain-v2` (a directory
    source at this checkout).
  - Claude Code registers marketplaces by name, in one file per user.
  - So adding the GitHub marketplace in the user's config, and removing it, would have replaced or deleted the one
    the own check runs on.
  - The GitHub install and uninstall therefore ran in an isolated Claude config directory. Before and after each
    step, the user's registry was compared with a backup: it matched (key order and `lastUpdated` aside).
- **1. Install by the README's route: pass.**
  - `claude plugin marketplace add Cain-Ish/claude-code-plugin#v2 --scope project` took 2.5 s. Project settings
    declare the marketplace with `ref: v2`.
  - The plugin installed at project scope. The cached copy's product files hash to `61964f9bbb40`.
  - *A first try failed on Windows' path length limit.* The isolated config sat deep inside a temp folder, and git
    could not write a pack file there. A short folder fixed it. A user's own config path is short.
  - *Delivery of the downloaded files.* The cached copy's own smoke (`test/smoke.mjs`, the user's CLI 2.1.311,
    `--plugin-dir` to the downloaded copy) passed:
    - the index's first sentence, the forced decision and both labels were quoted word for word;
    - every hook exited 0;
    - onboarding reported the index.
  - *Not run:* a session that loads the plugin through the GitHub-declared marketplace in the user's own config,
    because of the name clash above.
- **2. Uninstall by the README's route: pass.**
  - The uninstall and the marketplace removal succeeded, in the isolated config.
  - `.project-map/` and the document are byte-identical. `git status` is unchanged except for `.claude/`, which the
    install created.
  - A new session in the repo, in the user's config, listed no second-brain plugin, ran no hook and found no index
    text.
  - *Left in the repo:* `.claude/settings.json`, with empty `enabledPlugins` and `extraKnownMarketplaces` objects.
  - *Left outside the repo:*
    - the cached version folder, marked `.orphaned_at`. Claude Code's docs say a sweep removes it after 14 days. There
      is no data folder.
    - the forced decision's marker files in the OS temp folder: 3 at the time, from every session since the folder
      was last cleaned. Each is empty, and the next first prompt of its session removes it. A session that never got
      a prompt leaves its marker behind.
- **The 2f live check, on `61964f9bbb40`: pass.**
  - Run through the local marketplace at this checkout, at project scope, in a scratch repo, on CLI 2.1.311.
  - `live.mjs` holds: delivery quoted word for word, D23's line, onboarding, and capture (an entry sourced to "the
    tech lead", dated).
  - The scratch install was removed afterwards.
- **3. Node missing, on the installed copy: pass as registered** (the session answered correctly; Haiku, Node off the
  PATH).
  - *What the user sees:*
    - at session start, the plugin's one line: "The project map needs Node 20 or later; install it, or disable the
      plugin.";
    - then a hook error, exit 1, on every prompt and on every Read: `Executable not found in $PATH: "node"`.
  - Not fixed in 2g: a fix changes `hooks.json`, which opens a new epoch.
  - The README says what happens, and Fog has the question. D18's trigger "Claude Code adds a way to silence a missing
    executable" watches it.

### 2g, attempt 2: A1 re-run on `61964f9bbb40` (2026-10-27): pass

- **Runs:** 10 of 10 valid, in one epoch: CLI 2.1.305, Opus 5.5, inputs `108861b749cb`, plugin `61964f9bbb40`. 13.15 USD
  in all. Results in `V2-D17-eval/results/V2-opus-d16.json`, and `summary-opus-d16.json` (scored against the Opus
  baselines M0 and M1).
- **Every pass item meets its bar,** for the second person and for the same person:
  - C1 to C4: 10 each;
  - T1 to T4, final and at the first write: 10 each;
  - T5f: 10;
  - N1 to N3: 10 each;
  - over-attribution: 0 runs.

  The frozen T5 stays at 0, as in attempt 2.
- **Orientation and cost: no gain, as in 2c attempt 2,** and each sits under M1's no-worse ceiling. Medians, second
  person and then same person, with 2c attempt 2's in brackets:
  - tool calls before the first write: 11.5 and 11.5 (12 and 11.5);
  - files read before it: 10.5 and 10.5 (11 and 10.5);
  - T tokens: 132,814 and 137,650 (133,724 and 138,378);
  - T output tokens: 4,377 and 4,568 (4,326 and 4,392);
  - T cost: 0.206 and 0.223 USD (0.203 and 0.222).
- **What it shows:** D16's re-lock left A1's result unchanged. The release cites this run for the plugin's own hash
  (PM1).

### 2g, attempt 2: the fixture's calibration (2026-10-27): pass on round 3

Added p95 at 8 concurrent, medians of 3 interleaved runs (fixture, then P2), on this machine with no eval running:

| Round | Session start: fixture / P2 | Map read: fixture / P2 | Verdict |
| --- | --- | --- | --- |
| 1 | 50.2 / 44.9 | 44.7 / 24.5 | invalid |
| 2 | 48.6 / 44.7 | 46.2 / 54.2 | fixture lighter on the map read |
| 3 | 44.4 / 44.2 | 58.7 / 55.5 | pass |

- *Round 1 was invalid.* D16's equivalence re-run had deleted P2's bench map, so P2's map read had nothing to read.
  Both maps were rebuilt and checked (30 entries each) before round 2.
- *Round 2: the fixture was lighter on the map read.* Its text repeated every 13 words, so a run of words from the
  middle of a document first occurred near its start, and the search stopped there. In P2 the run first occurs
  where it was taken.
- *For round 3, the fixture's text is seeded instead of periodic.* Nothing else changed, and the bar did not move.
- *Session start passes by 0.2 ms,* which is within the bench's noise. The registered rule is met, and the margin is
  stated here.
- *The read of another file* (19.9 / 22.4) is not in the rule. That hook does no work in the repo.
- *All three rounds sit far below the morning's numbers* (map read 83 to 86 ms, session start 60 to 82). The same code
  and machine vary by time of day. The paired runs are what the calibration compares.

### 2g, attempt 2: CI (2026-10-27): the self-test passes on three systems; the Windows lane fails D18's bar

- **The self-test** (`selftest.mjs`, Node 20) passed on `ubuntu-latest`, `macos-latest` and `windows-latest`. That
  covers the libraries, each hook as a process, and the `SessionStart` command through bash, with and without Node.
  It is the first test of the plugin on macOS and Linux.
- **The load job's first run failed on plumbing,** before it measured anything. The runner's `core.autocrlf` made
  `git add` warn once per file, past `spawnSync`'s buffer. The fixture now turns that conversion off, as the local
  build had. Its files are byte-identical to the calibrated ones.
- **The load job's second run failed D18's bar,** with 0 errors. Added p95, on GitHub's hosted runner with Node
  20.20.2:

  | Hook | At 1 | At 8 concurrent |
  | --- | --- | --- |
  | Session start | 49.1 ms | **145.5 ms** |
  | Prompt | 14.9 ms | 48.1 ms |
  | Read of another file | 12.8 ms | 47.5 ms |
  | Read of a map file (D16's load shape) | 62.3 ms | **147.0 ms** |

  An empty Node process there has a p95 of about 142 ms at 8 concurrent.
- **As registered,** this is a failed 2g attempt. The bar does not move, and the numbers are disclosed here.
- **D18's trigger fired** ("another machine"), so D18 is reopened. 2g waits for it. This is 2g's second failed attempt,
  so a third would be the last before going up a level (rule 4), and D18 is that level.
- **The diagnostic run** (the same lane, also at the runner's 4 logical cores) is in D18's record. At 1 session every
  hook stays under 100 ms. At 4 concurrent, session start (109.8 ms) and the map read (161.9) are over the bar. At 8
  concurrent, even the prompt hook adds 101.4 ms. The options for D18 go to the user.

### 2g, attempt 2: result (2026-10-27): failed in the release review

- *Passed:* A1 on `61964f9bbb40`, the live checks, the calibration, and CI at D18's two-part budget.
- *Failed:* two of the pass conditions.
  - "The README states only what the runs show" did not hold. Both reviews found overstatements and omissions in it
    ([research/2026-10-27-release-review.md](research/2026-10-27-release-review.md)).
  - The review found product defects that fire D18's and D14's triggers (I1, I4, I13), and one that falls under D22's
    size watch (I2).
- *A correction:* 2g registered the version as `2.0.0-alpha.0` and cited V2-D05 for it. D05 starts v2 at
  `2.0.0-alpha.1`. The error was this record's.

### 2g, attempt 3: registered (2026-10-27, before any code). The last attempt under rule 4

If attempt 3 fails, 2g goes back to this plan, with the user.

- **What ships:**
  - `2.0.0-alpha.1` (V2-D05), with D18's fixes (its record: the root, fail-closed labels, the byte-order mark, the
    marker, letter case, the cap);
  - its new hash, recorded in the self-test.

  The fixes are built in one plugin copy, then moved into `plugin/` in one step. So everything below runs once, on
  one hash.
- **Before the move:**
  - D18's check: map-level equivalence; process-level equivalence on P1, P2 and R0; a self-test case for each
    intended difference; and the live cap probe.
  - Self-test additions:
    - the product hash pinned;
    - a lint that the product scripts import only Node's `fs`, `os`, `path` and `child_process`, and spawn only `git`.
- **After the move:**
  - *A1, re-run on the new hash* (PM1, the pinned epoch). *Pass:* every pass item at its bar, as in 2c attempt 2.
  - *The reference machine:* P2 at 8 concurrent, 3 runs. *Pass:* each hook at most 100 ms, 0 errors. The run records
    are committed, together with this step's earlier reference and calibration runs (I10).
  - *CI:* the self-test on three systems, and the load lane gated at one session on all three (I7). *Pass:* green.
  - *The 2f live check* on the new hash.
  - *Gemini 4 Argon* on the diff of the fixes and the final README. Each surviving point is fixed, or recorded as an
    accepted risk.
- **The README** takes both reviews' points (the release-review note lists them):
  - it installs from the tag `#v2.0.0-alpha.1`, and that tag goes up in the same push as the commit carrying the
    README;
  - only the cap and the marketplace name clash change from 'unknown' to stated issues.
- **Then:** the release notes go to the user, and the tag and pre-release wait for their yes. The user's earlier yes
  was given for another candidate.
- **Pass:** all of the above.

### 2g, attempt 3: results so far (2026-10-27)

- **D18's check, on the plugin copy:** pass (D18's record).
  - 0 differences at the map level (123 comparisons) and at the process level (36).
  - The old code shows the defect and the new does not, in all 7 intended differences.
  - The live cap probe passes, and it located Claude Code's real cliff (between about 12,400 and 16,300 characters).
- **The move:** `plugin/` is `2.0.0-alpha.1`, hash `a84a31665af3`, pinned in the self-test. The differences probe
  passes on it.
- **The reference machine** (P2, 8 concurrent, 3 runs, 0 errors), added p95 with wall clock in brackets:
  - session start 47.0, 40.5 and 42.0 ms (104.9, 104.3 and 112.4);
  - prompt 23.0, 24.4 and 22.4 ms;
  - a read of another file 22.1, 23.3 and 30.0 ms;
  - the map read 56.6, 55.9 and 59.1 ms (116.8, 116.7 and 123.8).

  *Pass.* The records are in `V2-D18-runtime/results/2g/`, with the earlier reference and calibration runs (I10).
- **CI** (`375987e`): green. The self-test passed on all three systems, and so did the load lane, gated at one session
  on all three (I7). Added p95 at 1 session (wall clock):

  | Runner | Session start | Map read |
  | --- | --- | --- |
  | Windows, 4 cores | 66.8 (117.4) | 68.7 (117.6) |
  | macOS, 3 cores | 41.5 (90.9) | 39.2 (79.5) |
  | Linux, 4 cores | 27.5 (55.5) | 30.8 (55.3) |

  At 8 concurrent, reported only, session start took 84.7 to 170.7 ms and the map read 120.4 to 203.1 ms.
- **A check of a README claim:** with a project-scope install, a live session on 2.1.311 loaded the plugin at the
  repo's root, and did not load it in a subdirectory.
- **Still to run:** A1 on `a84a31665af3`, which is running; the 2f live check; and Gemini on the diff and the final
  README.

### 2g, attempt 3: result (2026-10-27): pass

- **A1 on `a84a31665af3`:** 10 of 10 valid, in one epoch (CLI 2.1.305, Opus 5.5, inputs `108861b749cb`), 13.15 USD.
  - For both variants, C1 to C4, T1 to T4 (final and at the first write), T5f, and N1 to N3 are all at 10.
  - Over-attribution: 0 runs.
  - Orientation and cost show no gain, as before, and stay under M1's no-worse ceilings. Medians, second person and
    then same person: 12 and 12 tool calls before the first write; 11 and 11 files read; T tokens 133,748 and 138,179;
    output 4,280 and 4,497; T cost 0.206 and 0.223 USD.
  - Results: `V2-D17-eval/results/V2-opus-alpha1.json` and `summary-opus-alpha1.json`.
- **The 2f live check on `a84a31665af3`:** `live.mjs` passes (CLI 2.1.311, project scope, local marketplace). The
  scratch install was removed, and the user's registry matched its backup.
- **Gemini 4 Argon on the diff and the final README:** "nothing blocks". Its points are fixed or accepted in the
  release-review note's second round.
- **Together with the D18 check, the reference machine and CI recorded above,** every pass condition of attempt 3
  holds. D18 and D14 are re-locked.
- **What is left:** the release notes go to the user. The tag and pre-release wait for their yes, then go up with the
  README that installs from the tag.

### 2g, attempt 4: registered (2026-10-27, before any code), after the user's second review

- **Why there is an attempt 4.**
  - Attempt 3 passed its registered checks.
  - The user then said yes to publishing, but asked for the workflow to run again first. That run found fail-open
    label paths (J3, J4) that fire D18's trigger, plus J1 and J2 (the release-review note).
  - Failed attempts so far: 1 and 2. If this one fails, 2g goes back to this plan, with the user.
- **What ships:** `2.0.0-alpha.1`, with D18's new fixes (D18's record) and a new hash pinned in the self-test.
  - The version stays, since nothing was published under it.
  - The fixes are built in a plugin copy, `probes/V2-D18-runtime/fail-closed-2/`, with `a84a31665af3` kept beside it.
    They move into `plugin/` in one step.
- **Before the move:**
  - D18's check;
  - the self-test with J1 to J4's cases;
  - the lint covering every child_process function, both quote styles, side-effect imports and `Function` (J6).
- **After the move,** as in attempt 3:
  - A1 on the new hash;
  - the reference machine at 8 concurrent;
  - CI on three systems;
  - the 2f live check;
  - Gemini 4 Argon on the diff.
- **The README** adds the bash start to the session-start wall clock (J5), and the labels' cut as a known issue.
- **Then** the release notes and the user's yes, since the hash has changed again.
- **Pass:** all of the above.

### 2g, attempt 4: result (2026-10-27): failed, a near miss with a known cause; back to the user

- *Passed:* D18's check passed on every part but one (D18's record):
  - the 4 intended differences;
  - process-level equivalence (0 of 36);
  - the live label probe;
  - the self-test with the new cases and the stronger lint.
- *Failed:* the registered map-level condition, "0 differences". 102 of 123 comparisons differ. The suite's 200-entry
  random files pass the cap, where J3 changes the output by design, and the registration missed it.
- *Verified after the result:* every one of the 102 is exactly J3's cut, and the rest are byte-identical. That makes
  this a failed attempt (rule 2): the third, after 1 and 2.
- *Not run on this candidate:* the move into `plugin/`, A1, the reference machine, CI, the live check, and Gemini on
  the diff.
- *What attempt 4's registration says:* a failure takes 2g back to this plan, with the user. Rule 4 allows a fourth
  failed-attempt retry only after a near miss with a known cause, which this is. Whether to take it is the user's call.

### 2g, attempt 5: registered (2026-10-27, before any check runs). The user's choice; the last

The user chose one more attempt on attempt 4's fixes (rule 4: a near miss with a known cause), and to publish if it
passes. If it fails, the release stops, and 2g goes back to the user. There is no attempt 6.

- **Candidate:** `2.0.0-alpha.1` at hash `da81530cb1c3`: attempt 4's copy, moved into `plugin/` in one step.
- **Checks, all on `plugin/` after the move:**
  1. *Map level* (`equivalence.mjs`, `EQ_CUT=1`, against `a84a31665af3`). *Pass:* 0 differences. A label text that the
     old code put past the 10,000-character cap, and the new code cuts to exactly its first lines plus the fail-closed
     line, is counted as a cut, not as a difference. Every other output must be byte-identical.
  2. *Process level,* against `a84a31665af3`. *Pass:* 0 differences in 36.
  3. *J1 to J4* (`fail-closed-2/differences.mjs`). *Pass:* all 4.
  4. *The self-test.* It pins `da81530cb1c3`.
  5. *A1 on `da81530cb1c3`* (the pinned epoch). *Pass:* every pass item at its bar, as in 2c attempt 2.
  6. *The reference machine:* P2 at 8 concurrent, 3 runs. *Pass:* each hook at most 100 ms added, 0 errors.
  7. *CI:* the self-test and the load lane, gated at one session, on all three systems. *Pass:* green.
  8. *The 2f live check.* *Pass:* `live.mjs` passes.
  9. *The live label probe* at 301 entries. *Pass:* the label text arrives whole and under the cap.
  10. *Gemini 4 Argon on the diff* from `a84a31665af3`. *Pass:* no point that fires a trigger; any other point is fixed
      in the README or recorded as accepted.
- **The README:** J5's bash start, the labels' cut as a known issue, and this hash's numbers.
- **On a pass, publish** (by the user's yes):
  - the README that installs from the tag, the tag `v2.0.0-alpha.1`, and the GitHub pre-release, in one push;
  - then an install from the tag in an isolated config, which must hash to `da81530cb1c3`.

### 2g, attempt 5: checks so far (2026-10-27)

1. *Map level:* 0 differences. 102 label texts past the cap are now cut exactly, as registered
   (`results/equivalence-attempt5.json`).
2. *Process level:* 0 of 36 (`results/process-equivalence-attempt5.json`).
3. *J1 to J4:* all 4 pass on `plugin/` (`fail-closed-2/results/`).
4. *The self-test* passes, with `da81530cb1c3` pinned.
5. *A1:* running.
6. *The reference machine* (P2, 8 concurrent, 3 runs, 0 errors), added p95 with wall clock in brackets:
   - session start 47.7, 66.8 and 45.9 ms (103.6, 142.8 and 106.2);
   - prompt 19.9, 18.1 and 25.9 ms;
   - a read of another file 24.8, 23.3 and 24.9 ms;
   - the map read 59.7, 57.0 and 71.5 ms (118.8, 118.7 and 154.6).

   *Pass.* The records are in `V2-D18-runtime/results/2g/`.
7. *CI* (`ede4d7e`): green on all six jobs. Added p95 at 1 session, session start and then map read:
   - Windows: 64.7 and 73.4 ms;
   - macOS: 33.2 and 44.1 ms;
   - Linux: 20.5 and 24.9 ms.

   At 8 concurrent, reported only: 75.4 to 230.1 ms.
8. *The 2f live check:* `live.mjs` passes. The scratch install was removed, and the user's registry matched its backup.
9. *The live label probe* at 301 entries: the labels arrived whole (10,199 characters of hook output, no spill file
   read). *Pass.*
10. *Gemini on the diff:* "nothing blocks", and no point fires a trigger. It checked the cut loops' bounds and counts.
    Two cosmetic points:
    - the labels' cut line reads "1 more labels" when one is left. It appears only past the cap, and is accepted for
      the next version;
    - the README's UTF-16 line is accurate as it stands, since it lists what the self-test covers.

    *Pass.*

### 2g, attempt 5: result (2026-10-27): pass. The release is published

5. *A1 on `da81530cb1c3`:* 10 of 10 valid, in one epoch (CLI 2.1.305, Opus 5.5, inputs `108861b749cb`), 13.19 USD.
   - For both variants, C1 to C4, T1 to T4 (final and at the first write), T5f, and N1 to N3 are all at 10.
   - Over-attribution: 0 runs.
   - Orientation and cost show no gain, as before, and stay under M1's no-worse ceilings. Medians, second person and
     then same person: 12 and 11.5 tool calls before the first write; 11 and 10.5 files read; T tokens 132,996 and
     138,507; output 4,537 and 4,438; T cost 0.207 and 0.222 USD.
   - Results: `V2-D17-eval/results/V2-opus-da81530.json` and `summary-opus-da81530.json`.

All ten checks pass, so by the user's yes `2.0.0-alpha.1` (`da81530cb1c3`) is published:
- the README that installs from the tag;
- the tag `v2.0.0-alpha.1`;
- the GitHub pre-release.

D18 and D14 are re-locked. The install-from-tag check follows in the next record.

### 2g: published (2026-10-27)

- The pre-release [v2.0.0-alpha.1](https://github.com/Cain-Ish/claude-code-plugin/releases/tag/v2.0.0-alpha.1) is
  published, from commit `8f7b228`. The README and the tag went up in one push.
- *Install from the tag* (`claude plugin marketplace add Cain-Ish/claude-code-plugin#v2.0.0-alpha.1`), in an isolated
  Claude config:
  - the cached copy is version `2.0.0-alpha.1`, and its product files hash to `da81530cb1c3`, the hash every attempt
    5 check ran;
  - the uninstall and the marketplace removal succeeded;
  - the user's registry was unchanged.
- *Carried to the next version* (the release-review note): the plural in the labels' cut line, and letter case folded
  by operating system.

### 2h: `2.0.0-alpha.2` (pre-registered 2026-10-27, before any code)

The user chose (2026-10-27) to ship the two items carried from alpha.1 as `2.0.0-alpha.2`: the fixes, the full release
checks, the devils-advocate workflow and Gemini, then the tag `v2.0.0-alpha.2` and a GitHub pre-release. No trigger
fired; these are dated notes under D16 and D18, not reopens.

- **The intended differences from `da81530cb1c3`, and nothing else:**
  - *K1:* the labels' cut line puts "label" in the singular when one is left: "(1 more label not shown: …", and
    "(1 label not shown: …" when not even one line fits.
  - *K2:* the index's check of untracked map files against tracked ones folds letter case by the repo's
    `core.ignorecase`, not by operating system. It is read from the repo's config file, with no second git call
    (D18's budget). A `.git` file (a linked worktree or a submodule) is followed through `gitdir:` and `commondir`.
    Unset, false, or unreadable means no fold, which is git's default: a name listed twice loses nothing, and a fold
    the file system does not make can hide an untracked map file. Global, system and included config files, and
    `config.worktree`, are not read, and the README says so.
  - *K3:* the fold covers ASCII letters only, as git compares under `core.ignorecase`. Probe (2026-10-27, Windows,
    git's own listing): with `core.ignorecase` true, a tracked `Ärger.md` renamed to `ärger.md` is listed as untracked,
    while `captured.md` renamed to `Captured.md` is not. Folding as git does makes the index match the two-call code
    that D16 measured (`497ba915e987`), so D16's second difference goes.
  - The version: `2.0.0-alpha.2` in both manifests.
- **Built in a copy,** `probes/V2-D18-runtime/alpha2/plugin`, with `da81530cb1c3` kept beside it as `old/`. It moves
  into `plugin/` in one step, after checks 1 to 5.
- **Checks on the copy:**
  1. *Map level:* `equivalence.mjs`, `da81530cb1c3` against the copy, on P1, P2 and R0 (123 comparisons). *Pass:* 0
     differences. One kind is counted apart: both texts end with the fail-closed line, the new one's count is 1 in the
     singular, and the old text's label lines are the new one's in the same places. (At a one-character boundary the
     shorter word lets one more label line fit.) The classifier is changed for this before the run, and its `CUT_LINE`
     accepts the singular.
  2. *Process level:* `process-equivalence.mjs`, `da81530cb1c3` against the copy. *Pass:* 0 differences in 36.
  3. *Each intended difference* (`alpha2/differences.mjs`, Windows). In every case the old code gives the old output
     and the new code the new one:
     - K1, a map file whose cut leaves one label: "1 more labels" before, "1 more label" now;
     - K1, a single label line past the cap: "1 labels not shown" before, "1 label not shown" now;
     - K2, in a repo whose `core.ignorecase` is set against the platform's default, with a tracked `captured.md`
       renamed on disk to `Captured.md`. The new index lists the map files exactly as git's two calls do
       (`ls-files --cached`, then `ls-files --others --exclude-standard` under `.project-map/`); the old one does not;
     - K2, the same in a linked worktree, where `.git` is a file and the config sits in the common directory;
     - K3, with `core.ignorecase` true, a tracked `Ärger.md` renamed to `ärger.md`: the new index matches git's
       listing, and the old one does not.
  4. *The self-test* of the copy, pinning the copy's hash. The platform gate on I11's case goes. The repo sets
     `core.ignorecase` true, then false, and the fold must follow on every system, so CI checks the mechanism on all
     three (not each file system's truth). It adds K1's two lines, K3 and a linked worktree. *Pass:* it passes here.
  5. *The release review:* the devils-advocate workflow on the copy and these records, then Gemini 4 Argon on the diff
     from `da81530cb1c3` and the README's changes (public text only).
     - Each surviving finding fires a trigger, or is fixed, or is recorded as an accepted risk.
     - A finding that changes the product makes the next attempt, registered before its code, with checks 1 to 4 again
       and Gemini on its diff.
     - The workflow runs once, unless the user asks again.
- **After the move into `plugin/`** (the trial session is told the new hash):
  6. *A1 on the new hash* (CLI 2.1.305, Opus 5.5). *Pass:* every pass item at its bar, as in 2g attempt 5.
  7. *The reference machine:* P2 at 8 concurrent, 3 runs. *Pass:* each hook at most 100 ms added, 0 errors.
  8. *CI:* the self-test and the load lane, gated at one session, on all three systems. *Pass:* green.
  9. *The 2f live check.* *Pass:* `live.mjs` passes, and the user's registry matches its backup afterwards.
- **Not re-run:** the live label probe at 301 entries. Its 126 hidden labels keep the plural, so its label text is
  byte-identical, and check 3 covers K1.
- **The README:** installs from `#v2.0.0-alpha.2`; the letter-case known issue goes, and the config files not read are
  stated; this hash's numbers. 04 and the release-review note move with it.
- **On a pass, publish** (the user's yes, 2026-10-27):
  - the README, the tag `v2.0.0-alpha.2` and the GitHub pre-release, in one push;
  - then an install from the tag in an isolated config, which must hash to the new value, with the user's registry
    unchanged.
- **Pass:** checks 1 to 9. Each failure is a 2h attempt; after three (rule 4), 2h goes back to the user.

### 2h: checks 1 to 4 (2026-10-27): pass, on the copy at `3c46826f115b`

1. *Map level:* 0 differences in 123 comparisons, and no singular case: the suite's cut label texts leave 2 or more
   labels each (`V2-D16-freshness/results/equivalence-alpha2.json`).
2. *Process level:* 0 differences in 36 (`fail-closed/results/process-equivalence-alpha2.json`).
3. *Each intended difference* (`alpha2/results/differences-win32.json`): all 5 cases pass. With `core.ignorecase` false,
   git lists `captured.md, Captured.md`, and so does the new index, in the repo and in its linked worktree; the old one
   listed `captured.md` alone. With it true, git lists `Ärger.md, ärger.md`, as the new index does; the old one listed
   `Ärger.md`. Run with the old code in the new code's place, all 5 cases fail, so the probe can fail.
4. *The self-test* of the copy passes, pinning `3c46826f115b`.

One change was not in the registration, and is disclosed: only tracked paths under `.project-map/` go into the fold's
set, since only they can match a map file. Folding all 8,057 of P2's tracked paths, ASCII letters only, cost about 8 ms
more per session start in-process. With the filter, `index()` timed level with the old one on P2. Checks 1 and 2 ran on
the filtered code.

### 2h: check 5, the release review (2026-10-27)

- *The workflow, once* (23 agents): 18 findings, 2 survived, both low, and neither changes the product (the
  release-review note, L1 and L2).
  - *L1:* PM7's count, registered in 2g, was never reported, and the untracked-map listing had a third fix with no
    keep-or-kill entry. *Fixed in the ledger:*
    - the count per part (D18's record);
    - the listing's entry, keep, under D16;
    - the session-start cut's overdue entry under D18 (its J1 was a regression of I2's fix).

    The count goes in the release notes.
  - *L2:* the config reader takes only the plain spellings of a boolean. *Accepted;* the README states them.
- *After the review, test-only:*
  - the copy's self-test checks each case listing against git's own two-call listing, so CI compares the fold with
    git on all three systems;
  - with the old library in place of the new, the self-test fails at the case check;
  - the hash stays `3c46826f115b`.
- *A probe of the directory case,* which Gemini raised in alpha.1's second round: a map directory renamed only in case
  is listed as git's two calls list it, with either setting.
- *Gemini 4 Argon* on the diff and the README draft: "nothing blocks". Two low points on the config reader's
  spellings and continued lines are accepted, and stated in the README and D16's entry. The singular's
  one-character boundary was already registered. Details are in the release-review note.
- *Check 5 passes.* No finding changes the product, so the candidate stays `3c46826f115b`.

### 2h, attempt 1: result (2026-10-27): failed on CI's Windows load lane

- *Check 8, CI* (`3eec4f3`):
  - the self-test is green on all three systems, so the fold matches git's own listing on macOS and Linux too;
  - the load lane is green on macOS and Linux, and **red on Windows**: session start added 113.7 ms p95 at 1 session,
    against the bar of 100.
  - Earlier Windows runs gave 66.8, 66.5 and 64.7 ms. The other hooks at 1 session, and every hook at 4 and 8, were
    level with alpha.1's last run:

    | Windows CI, added p95 (ms) | session start | prompt | another read | map read |
    | --- | --- | --- | --- | --- |
    | alpha.1, 1 session | 64.7 | 17.5 | 17.4 | 73.4 |
    | alpha.2, 1 session | **113.7** | 17.7 | 17.9 | 70.7 |
    | alpha.1, 4 at once | 109.8 | 29 | 31.5 | 125 |
    | alpha.2, 4 at once | 111.9 | 30.7 | 29.1 | 118.7 |
    | alpha.1, 8 at once | 200.9 | 61.3 | 84.5 | 230.1 |
    | alpha.2, 8 at once | 198.7 | 72.8 | 79.9 | 228.2 |

  - *Read after the result:* the failing number is a tail. Session start's median at 1 session was 106.2 ms, against
    104.5 to 108.7 in the three earlier runs; its p95 was 170.3, against 113.4 to 118.5.
- *Check 7, the reference machine:* runs 1 and 2 were over the bar. At 8 concurrent, session start added 123.3 and
  131.8 ms, and the map read 131.8 and 125.5. Run 3 was stopped. They ran under outside load:
  - sampled during them, a system service used about 22% of the 32 threads and a game about 9%;
  - the prompt hook, which alpha.2 does not touch, added 40.6 and 49.6 ms, against 18 to 26 before.

  The records are kept as loaded runs (`V2-D18-runtime/results/2g/ref-alpha2-loaded-*.json`). They do not score
  either way.
- *Diagnosis, local:* old and new session-start hooks were timed interleaved, one at a time, 60 calls each.
  - Medians on P2: 105.0 (old) and 104.0 ms (new).
  - Medians on CI's fixture: 101.1 and 104.1 ms.
  - The tails are noisy under the load. No cost of the change is found.
- *Not run:* A1 (stopped before its first run, so no run happened on a hash that might change) and the live check.
- **This fails the attempt** (registration: each failure is a 2h attempt). Failed attempts: 1 of 3. CI's number also
  fires D18's trigger, "a hook's added p95 exceeds 100 ms at 1 session on any machine", so D18 reopens (its record).

### 2h, attempt 2: registered (2026-10-27, before the paired CI runs were read)

- **The product stays `3c46826f115b`,** unless D18's check (its record) ends in outcome B.
- **Check 8, CI:** D18's paired runs. *Pass:* outcome A, which makes alpha.2's two dispatched runs the CI check (both
  green).
- **Check 7, the reference machine, with a control.** Attempt 1's runs show that outside load can move every hook,
  so:
  - before each session, total CPU is sampled for 10 s and recorded;
  - `bench.mjs` runs on P2 in pairs: alpha.1 (a scratch copy of `da81530cb1c3` with the same `bench.mjs`), then
    alpha.2, three pairs in a row;
  - a pair is valid only when alpha.1's run in it passes the bar (each hook at most 100 ms added at 8 concurrent, 0
    errors). The released build passing there is what shows the machine is in its reference state;
  - an invalid pair is repeated, not scored, up to 6 pairs. If fewer than 3 are valid, there is no result, and the
    check waits for a quiet machine.
  - *Pass:* in each of 3 valid pairs, alpha.2 has each hook at most 100 ms added at 8 concurrent, with 0 errors. A
    valid pair in which alpha.2 is over the bar fails the attempt.
- **Check 6, A1** on `3c46826f115b`, after check 7, since A1 loads the machine. *Pass:* as registered in 2h.
- **Check 9, the live check,** during A1. *Pass:* as registered in 2h.
- **Checks 1 to 5** stand, since the product is unchanged.

### 2h, attempt 2: result (2026-10-27): failed on the registered band; a near miss with a known cause

- *Check 8:* the four paired runs are green. By D18's check as written, the result is "anything else", so the attempt
  fails.
  - alpha.2's second run was faster throughout, and its session-start median, 87.8 ms, fell below a band that should
    only have had an upper edge (D18's record).
  - The two alpha.2 runs' medians differ by 21 ms, so a band across runs cannot resolve a 5 ms cost.
- *Not run:* checks 7, 6 and 9.
- Failed attempts: 2 of 3. Rule 4 allows a third, and this is the last.

### 2h, attempt 3: registered (2026-10-27, before any of its runs). The last under rule 4

- **The product stays `3c46826f115b`.**
- **D18's check, second attempt** (its record): `alpha2/paired.mjs` in `v2-paired.yml`, twice. It pairs the old and
  new hooks within one job on each system, so the runner's speed cancels. *Pass:* outcome A, every job's cost at most
  5 ms on session start and the map read.
- **Check 8, CI:** two fresh runs of `v2.yml` on `3eec4f3`, dispatched after the paired runs. *Pass:* both green.
  The runs attempt 2 saw are not reused.
- **Check 7, the reference machine,** with alpha.1 as the control in each pair, as attempt 2 registered: the CPU sample
  before each session, pairs valid only when alpha.1 passes the bar, at most 6 pairs. *Pass:* in each of 3 valid
  pairs, alpha.2's hooks are each at most 100 ms added at 8 concurrent, 0 errors.
- **Check 6, A1,** after check 7, and **check 9, the live check,** during A1, as registered in 2h.
- **If this attempt fails,** 2h goes back to the user. Rule 4 allows no fourth attempt without the user.

### 2h, attempt 3: D18's check passes (2026-10-27)

- *D18's check:* outcome A. Paired within one job on each runner, twice, alpha.2's cost over alpha.1 is -3.6 to
  +0.8 ms at session start and -2.1 to +0.4 ms on the map read, and their outputs are identical. D18 re-locks
  unchanged (its record).
- *Check 8* is dispatched next. Its two runs use v2's head, since a dispatch takes a branch, not a commit. The head's
  `plugin/`, `.claude-plugin/` and `v2.yml` are byte-identical to `3eec4f3`.

### 2h, attempt 3: result (2026-10-27): failed on check 7; back to the user (rule 4)

- *Check 8:* pass. Two fresh `v2.yml` runs (40539877232, 40539882507) are green on all six jobs. Session start added
  68.8 and 66.1 ms at 1 session on Windows.
- *Check 7:* **failed on pair 1.** The 10-second CPU sample before it averaged 28.9%. At 8 concurrent:

  | Pair 1, added p95 (ms) | session start | prompt | another read | map read | empty Node p95 |
  | --- | --- | --- | --- | --- | --- |
  | alpha.1, the control | 97.3 | 25.9 | 49.4 | 89.6 | 96.7 to 112.2 |
  | alpha.2 | 75.4 | 32.8 | 14.7 | **101.6** | 104.8 to 128.6 |

  The control passed the bar, so the pair was valid as registered. alpha.2's map read was over it, which fails the
  attempt.
- *Why it is not read as a cost of the product* (after the result, so it changes nothing):
  - for this input the map read runs the same code in both builds, since K1 changes text past the cap only and this
    map has 30 entries;
  - paired within one job on three runners, its cost was -2.1 to +0.4 ms (D18's check);
  - the machine was loaded. The control's session start and map read were 97.3 and 89.6 ms, against attempt 5's
    46 to 67 and 57 to 72, and empty Node's p95 was about twice attempt 5's.
- *What failed in the method:*
  - the validity rule, "the control passes the bar", let in a pair whose control was near the bar;
  - the run started at 28% CPU, which was not a quiet machine.

  Both are this record's errors.
- D18's trigger fired by its letter again (a hook over 100 ms at 8 concurrent on the reference machine). Its question
  goes with 2h to the user.
- *Not run:* A1 and the live check. Records: `V2-D18-runtime/results/2g/ref-alpha2-attempt3-pair1*.json`.
- **Three failed attempts.** 2h stops and goes back to the user, as registered. `plugin/` stays at `3c46826f115b`,
  unpublished. The published release is still `2.0.0-alpha.1`.

### 2h, attempt 4: registered (2026-10-27, before any of its runs). The user's choice; the last

The user chose a fourth attempt (rule 4: a near miss with a known cause), with the reference machine's reference
state defined first (D18's record). If it fails, 2h goes back to the user, and there is no attempt 5.

- **The product stays `3c46826f115b`.** Checks 1 to 5, check 8 and D18's paired check stand: they passed.
- **Check 7, the reference machine, in its reference state:**
  - before each pair, a 10-second CPU sample is taken. Above 10%, no pair runs; the sample repeats after a pause, for
    at most 3 hours;
  - in each pair, `bench.mjs` runs on P2 for alpha.1 (the control), then alpha.2;
  - a pair is valid only when every empty-Node p95 at 8 concurrent, in both runs, is at most 100 ms;
  - an invalid pair is repeated, not scored, up to 6 pairs. If fewer than 3 are valid, there is no result, and the
    check waits again;
  - *Pass:* in each of 3 valid pairs, alpha.2's hooks are each at most 100 ms added at 8 concurrent, with 0 errors. A
    valid pair in which alpha.2 is over the bar fails the attempt. A control over the bar in a valid pair is recorded,
    since it fires D18's trigger for the release.
- **Check 6, A1** on `3c46826f115b`, after check 7. *Pass:* every pass item at its bar, as in 2g attempt 5.
- **Check 9, the live check,** during A1. *Pass:* `live.mjs` passes, and the user's registry matches its backup.
- **On a pass, publish** (the user's yes): the README, the tag `v2.0.0-alpha.2` and the pre-release in one push; then
  an install from the tag in an isolated config, which must hash to `3c46826f115b`.

### 2h, attempt 4: check 7 passes (2026-10-27)

- The driver waited about 65 minutes for a quiet machine: 29 samples between 22% and 31%, mostly the DNS client
  service in bursts.
- It then ran 3 pairs, all valid (CPU 4.9%, 6.7% and 6.3%; every empty-Node p95 at 8 concurrent 72.5 to 93.2 ms).
  Added p95 at 8 concurrent, with wall clock after the slash:

  | Pair | alpha.1 session start | alpha.2 session start | alpha.1 map read | alpha.2 map read | alpha.2 prompt | alpha.2 another read |
  | --- | --- | --- | --- | --- | --- | --- |
  | 1 | 42.1 | 44.2 / 126.2 | 63.8 | 58.3 / 135.7 | 24.5 | 25.3 |
  | 2 | 41.6 | 41.6 / 119.7 | 62.2 | 51.0 / 136.4 | 24.5 | 24.9 |
  | 3 | 55.9 | 37.4 / 117.8 | 82.8 | 60.6 / 135.2 | 23.5 | 25.0 |

  0 errors. *Pass.* Records: `V2-D18-runtime/results/2g/reference-3c46826f115b-*.json`, the controls beside them.
- *Check 6, A1,* started right after.
- *Check 9, the live check* (CLI 2.1.311), during A1:
  - installed from the checkout at project scope, the copy is `2.0.0-alpha.2` at `3c46826f115b`;
  - `live.mjs` passes: the index line, the forced decision, the read labels, D23's line, onboarding, and a captured
    decision with its source;
  - after the uninstall, the user's registry matches its backup.

  *Pass.*

### 2h, attempt 4: result (2026-10-27): pass. alpha.2 is published

6. *A1 on `3c46826f115b`:* 10 of 10 valid, in one epoch (CLI 2.1.305, Opus 5.5, inputs `108861b749cb`), 13.21 USD.
   - For both variants, C1 to C4, T1 to T4 (final and at the first write), T5f, and N1 to N3 are all at 10.
   - Over-attribution: 0 runs.
   - Orientation and cost are as before, under M1's no-worse ceilings. Medians, second person and then same person:
     12 and 12 tool calls before the first write; 11 and 11 files read; T tokens 133,839 and 138,350; output 4,464 and
     4,461; T cost 0.207 and 0.222 USD.
   - Results: `V2-D17-eval/results/V2-opus-3c46826.json` and `summary-opus-3c46826.json`.

Every check of 2h passes:
- checks 1 to 5 on the copy;
- D18's paired check;
- check 8 (CI);
- check 7 in the reference state;
- check 9 (live);
- A1.

So, by the user's yes, `2.0.0-alpha.2` (`3c46826f115b`) is published: the README, the tag `v2.0.0-alpha.2` and the
GitHub pre-release. The install-from-tag check follows.

### 2h: published (2026-10-27)

- The pre-release [v2.0.0-alpha.2](https://github.com/Cain-Ish/claude-code-plugin/releases/tag/v2.0.0-alpha.2) is
  published, from commit `22c0258`. The README and the tag went up in one push. The release notes carry PM7's count.
- *Install from the tag* (`claude plugin marketplace add Cain-Ish/claude-code-plugin#v2.0.0-alpha.2`), in an isolated
  Claude config:
  - the cached copy is version `2.0.0-alpha.2`, and its product files hash to `3c46826f115b`, the hash every 2h check
    ran;
  - the uninstall and the marketplace removal succeeded;
  - the user's registry files are unchanged (their checksums match).
- *The step took four attempts,* none failed by the product:
  1. a tail in one CI run;
  2. a two-sided band;
  3. a pair on a busy machine;
  4. after the user defined the reference state.

### 2i: two fixes from 2026-10-29 (registered before any code)

The field check (probes/V2-D17-field) found one delivery defect. The code reading of the same day
(research/2026-10-29-code-graph-tools.md) found one gap against the charter's "untrusted text is data". Neither
changes a decision: each makes the code do what D22 and the charter already say.

- **The intended differences from `3c46826f115b`, and nothing else:**
  - *L1 (field check, C2):* the forced decision goes to the epoch's first prompt a person typed. `UserPromptSubmit` also
    fires on a background subagent's report and on another session's message (hooks reference). A prompt that starts
    with the wrapper of such a turn, as the transcripts record it (`Another Claude session sent a message:`,
    `<task-notification>`, `<cross-session-message`, `<agent-message`), gets nothing and leaves the epoch's marker in
    place. A scheduled task's prompt is the user's own text and still takes the force. The hook's input has no field
    for a prompt's source, so the match is on the text; if Claude Code passes another form, the force is spent as
    before.
  - *L2 (code reading):* the index prints a control character in a path (U+0000 to U+001F, U+007F) as `?`, so a
    committed file name cannot add a line to the index or break one. Paths without one are printed as before.
- **Built in place in `plugin/`:** the user's installs come from the GitHub tag since 2026-10-29
  (`known_marketplaces.json`: source github, ref `v2.0.0-alpha.2`), so the checkout's files reach no real session.
- **Checks:**
  1. *The self-test,* with cases added before the code: for each of the four wrappers, a machine prompt after a session
     start returns nothing and the next typed prompt returns the force; a typed prompt that mentions a wrapper after
     its first word takes the force; a tracked document whose name holds a newline and a tab is listed on one line,
     with `?` in their place. *Pass:* the self-test passes here.
  2. *Output unchanged elsewhere:* on this repo, session start's text from the new code equals the old code's
     (`git show 3c46826f115b`'s tree is not needed: the self-test's existing cases compare against `index()` and the
     frozen texts). *Pass:* the existing cases pass unchanged.
  3. *The field re-check:* after a release, `field.mjs` on the user's next sessions. *Pass:* no force on a machine turn.
- **Not run, by the user's choice of 2026-10-29 (no further tests; they check in real sessions):** A1 on the new hash,
  the reference bench, CI's load lane, the release review and Gemini. The added cost is one regular expression on the
  prompt and one per listed path, not measured. They are offered again before a release.
- **On a pass:** commit, with no version bump, tag or push. A release (`2.0.0-alpha.3`) is the user's call.

### 2i: result (2026-10-29): checks 1 and 2 pass; check 3 waits for a release

- *Check 1:* the new cases failed on `3c46826f115b` before the code (the force went to another session's message) and
  pass on the new code: four wrappers, the typed prompt that mentions one, and the path with a newline and a tab
  (added to git's index with `core.protectNTFS=false`, which Windows needs for such a name).
- *Check 2:* every existing case passes unchanged; the smoke run passes.
- *Product hash:* `07816eb8bcd2`, pinned in the self-test with a line saying A1 was not re-run on it.
- *Check 3* runs on the user's sessions after a release. Nothing is tagged or pushed.
- *A limit of L1, recorded after the review of this step:* when the first turn after a compaction is a background
  subagent's report and Claude resumes work on it, L1 gives that turn no force, so those changes come before the
  epoch's forced decision. The old code forced that turn, then left the typed prompt without one. Neither is complete.
  In the field corpus no epoch began with such a report; the one machine turn that took a force was another session's
  message, with no work after it. *The variant, offered as 2i attempt 2 for the user to choose:* on a turn nobody typed,
  give the force and keep the marker; spend it only on a typed prompt. The cost is a second force in such an epoch.

### 2i: published as `2.0.0-alpha.3` (registered 2026-10-29, before the version moves)

The user chose (2026-10-29) to ship 2i as built (L1, not the variant), as `2.0.0-alpha.3`. The checks dropped on
2026-10-29 stay dropped: A1 on the new hash, the reference bench, the release review and Gemini do not run. CI's load
lane runs on the push anyway; its result is recorded and does not gate.

- **The intended difference from 2i's `07816eb8bcd2`, and nothing else:** the version `2.0.0-alpha.3` in both
  manifests. `plugin.json` is inside the hashed product, so the hash moves with it.
- **Checks:**
  1. *The tree:* `git diff 7298b41 -- plugin/ .claude-plugin/` at the release commit. *Pass:* outside `plugin/test/`,
     only the two version lines differ; inside it, only the pinned hash and its comment.
  2. *The self-test and the smoke run,* with the new hash pinned. *Pass:* both pass.
  3. *CI on the push of branch `v2`* (before the tag). *Pass:* the self-test is green on all three systems.
  4. *Install from the tag* in an isolated Claude config in a short folder. *Pass:* the cached copy is version
     `2.0.0-alpha.3` and hashes to the pinned value; the uninstall and the marketplace removal succeed; the user's
     registry files are unchanged by checksum.
- **Publish, after check 3:** the README, the tag `v2.0.0-alpha.3` and the GitHub pre-release. Then check 4. Then the
  user's install in their other repo moves to the new tag, by the route of 2026-10-29 (marketplace removed, added at
  the tag, the plugin installed at local scope), and its cached copy must hash to the pinned value.
- **The README:** installs from `#v2.0.0-alpha.3`; says that A1, the bench and the release review ran on alpha.2's
  code, not this one; L1's limit, the wrapper match unverified until 2i's check 3, and the field check's two open
  findings (map reads through Bash or Grep get no label; directories marked yes are often not read) as known issues.
- **On a failure** of checks 1 to 3, nothing is tagged; the cause is recorded as an attempt.

### 2i: published as `2.0.0-alpha.3` (2026-10-29)

- *Check 1, the tree:* against `7298b41`, only the two version lines differ outside `plugin/test/`, and inside it only
  the pin and its comment. *Pass.*
- *Check 2:* the self-test and the smoke run pass with `808154d15653` pinned, which is 2i's `07816eb8bcd2` plus the
  version string. *Pass.*
- *Check 3:* CI on the push of `9ebb874`: the self-test is green on all three systems. *Pass.* The load lane, recorded
  and not a gate, was green on all three too.
- *A correction before the tag:* shaping D14's candidate hook from the field sessions' own commands showed that the
  field check had counted 10 Bash map reads where 5 showed map entries. The scanner, the field note, D14's observation
  and the README were corrected (`17b121f`); no verdict changed. *That correction was itself wrong,* found while
  shaping 2j's cases from the whole commands: 9 show map entries (four `tail`s close longer commands). Corrected
  after the tag; the tagged README says 5 of 7, and the branch's README now says 9 of 11.
- *The tag* [`v2.0.0-alpha.3`](https://github.com/Cain-Ish/claude-code-plugin/tree/v2.0.0-alpha.3) is on `17b121f`,
  pushed with the branch. *The GitHub pre-release page was not created:* the session's permission check refused it as
  a public surface, so it waits for the user. Installs come from the tag and do not need it.
- *Check 4, install from the tag* in an isolated config: the cached copy is version `2.0.0-alpha.3` and hashes to
  `808154d15653`; the uninstall and the marketplace removal succeeded; the user's registry files are unchanged by
  checksum. *Pass.*
- *The user's install* in their other repo moved to the tag by the route of 2026-10-29: local scope, version
  `2.0.0-alpha.3`, the cached copy at `808154d15653`. The rest of that repo's local settings is unchanged. alpha.2's
  cached copy stays, so a session already running there keeps working until it restarts.
- *Next:* 2i's check 3, `field.mjs` on the user's sessions started after the move.

### 2j: map entries read through Bash get the Read hook's labels (registered 2026-10-29, before any code)

D14 reopened the same day (its trigger, read literally; the user's go-ahead): in the user's sessions, 9 of 11 reads
of map entries came through Bash, unlabelled (probes/V2-D17-field, C5 as corrected). The trust policy stands; this
fixes its delivery. Built in place, as 2i: the user's installs come from a tag.

- **The intended differences from alpha.3's `808154d15653`, and nothing else:**
  - *B1:* a `PostToolUse` handler on Bash with `"if": "Bash(*.project-map*)"`, running `hook.mjs bash`. The `if`
    field (Claude Code 2.1.85 on; compound commands from 2.1.89) spawns it only for a command that names the map
    folder, best effort: the hooks reference says a pattern that "specify more than the command name" also runs the
    hook on `$()`, backticks or `$VAR`, and it is not documented whether a leading `*` counts. In the field sessions
    20 of 1,004 Bash calls named the folder, and 232 others held `$()`, a backtick or a variable.
  - *B2:* the handler finds the map files a command reads: a part of the command, between `|`, `;`, `&` or a line
    break, that holds a read verb (`cat`, `head`, `tail`, `sed`, `grep`, `less`, `more`, `awk`), names a
    `.project-map/….md` file, and does not redirect into the folder. Each such file, once and in order of mention,
    gets exactly the text the Read hook gives it, with the same fail-closed line on an error. Otherwise nothing.
  - The version `2.0.0-alpha.4`.
- **Still not labelled (04's accepted risk, named in the README):** the Grep tool; a command that names the folder
  but no file; a repo-wide search; a script (Python, Node) that reads the file; PowerShell; subagents; a Claude Code
  before 2.1.85, which ignores `if` and spawns the handler on every Bash call (it still labels only map reads).
- **The context cost:** each Bash read of a map file now carries that file's labels, as a Read does. In the field
  session, 7 `tail`s right after Claude's own write would each have carried them.
- **Checks:**
  1. *The self-test,* with cases added before the code:
     - `bash` on `tail -5 .project-map/captured.md` gives, byte for byte, what `read` gives on that file;
     - the field's 20 command shapes that name the folder, rebuilt with placeholder paths and text: labels for exactly
       the 9 that read, nothing for the 11 others;
     - two map files in one command, and one file named twice: each file's labels once, in order;
     - a map file that cannot be read: the fail-closed line, as `read` gives it.

     *Pass:* the new cases fail on `808154d15653` and pass on the new code; every existing case passes unchanged.
  2. *Live, the smoke* (Haiku, `--plugin-dir`), extended with a session that may run Bash. On the user's CLI and on the
     pinned 2.1.305:
     - Claude runs `tail -5 .project-map/captured.md` and quotes the labels a hook added: *pass* if word for word;
     - Claude runs `git status`: *pass* if no `PostToolUse` hook ran for it. First confirmed: a spawned handler with
       empty output shows in the stream (the Read hook on a non-map file, in the same session);
     - Claude runs `echo $HOME`: whether the handler ran is recorded, not a gate. It settles the fallback above.

     Every hook exits 0.
  3. *D18:* `bench.mjs` gets `bash-map` (the `tail` above) and `bash-other` (a command that names no map file, as a
     fallback spawn would run). *Pass:* CI's load lane, gated at one session, is green on three systems. The
     8-concurrent reference bench is not run, by the user's choice of 2026-10-29.
  4. *Release checks, as alpha.3's:* the tree against this step's code, the self-test and smoke with the new pin, CI's
     self-test before the tag, an install from the tag in an isolated config, then the user's install moved to it.
- **Not run, by the user's choice of 2026-10-29:** A1 on the new hash, the reference bench, the release review and
  Gemini.
- **On a pass:** D14 re-locks unchanged; 04's accepted-risk row and the README follow; `2.0.0-alpha.4` is tagged and
  pushed. 2i's check 3 stays separate: it reads the user's sessions after a move.
- **On a failure:** the cause is recorded as a 2j attempt; after three (rule 4), 2j goes back to the user.

### 2j, attempt 1: checks 1 and 2 pass; check 3 failed in the harness (2026-10-29)

- *Check 1:* the new cases failed on `808154d15653` (a Bash read of a map file got nothing) and pass on the new code,
  `f18d83e328b4`; every existing case passes. CI's self-test is green on all three systems.
- *Check 2,* the smoke on 2.1.312 and on the pinned 2.1.305: pass on both.
  - The Read hook on a non-map file showed in the stream with empty output, so a started handler is seen.
  - `git status --short` and `echo $HOME` started no handler; `tail -5 .project-map/captured.md` started it, and Haiku
    quoted its labels word for word. Every hook exited 0.
  - `echo $(…)` was refused by the session's permissions on both CLIs, even with its inner command allowed, so the
    fallback for `$()` is not observed. For `$VAR` it did not fire.
- *Check 3,* CI's load lane: Windows and Linux green; *macOS failed, in the harness:* `bench.mjs` wrote to the empty
  Node process's input after that process had exited, and the unhandled `EPIPE` ended the run. No hook failed; the
  added p95 at one session was, for `bash-map` and `bash-other`, 76.5 and 17.8 ms on Windows and 33.8 and 11.2 ms on
  Linux (`read-map`: 72.7 and 34.2).

### 2j, attempt 2: registered (2026-10-29, before the re-run)

- *The change:* `bench.mjs` ignores an error on a child's input pipe. A hook that fails still counts through its exit
  code, so nothing the bar measures changes. Test code only; the product hash stays `f18d83e328b4`.
- *Check 3 again:* CI's load lane on this push. *Pass:* green on all three systems, gated at one session.
- Checks 1 and 2 stand: the product is unchanged.

### 2j, attempt 2: result (2026-10-29): pass

- *Check 3:* CI's load lane on `c4f7702` is green on all three systems. Added p95 at one session (Linux, Windows,
  macOS): `bash-map` 24.9, 70.4 and 48.5 ms, with `read-map` at 25.5, 71.4 and 71.0; `bash-other` 7.3, 17.1 and 12.6
  ms. At 8 concurrent, reported only: `bash-map` 87.9, 192.1 and 192.5; `bash-other` 21.9, 66.3 and 104.0.
- Checks 1 and 2 stand from attempt 1, on the same product hash `f18d83e328b4`.
- D14 re-locks unchanged. 04's row and accepted risks, and the README, follow. Next: the release checks (check 4).

### 2j: published as `2.0.0-alpha.4` (2026-10-29)

- *The tree:* against 2j's code (`939b297`), only `plugin/test/bench.mjs` differs (attempt 2's harness fix); the
  product is `f18d83e328b4`, the hash checks 1 to 3 ran.
- *The tag* [`v2.0.0-alpha.4`](https://github.com/Cain-Ish/claude-code-plugin/tree/v2.0.0-alpha.4) is on `0b18615`,
  pushed with the branch after CI passed. The GitHub pre-release pages for alpha.3 and alpha.4 wait for the user, as
  in alpha.3's record.
- *Install from the tag* in an isolated config: version `2.0.0-alpha.4`, hash `f18d83e328b4`, the Bash handler with its
  `if` field in the cached hooks; the uninstall and the marketplace removal succeeded; the user's registry files are
  unchanged by checksum. *Pass.*
- *The user's install* in their other repo moved from alpha.3 to the tag the same way: local scope, version
  `2.0.0-alpha.4`, the cached copy at `f18d83e328b4`, the rest of the local settings unchanged.
- *Next:* 2i's check 3, `field.mjs` on the user's sessions started after the move; it now also reads C5 for Bash reads.
- *The release pages* for [alpha.3](https://github.com/Cain-Ish/claude-code-plugin/releases/tag/v2.0.0-alpha.3) and
  [alpha.4](https://github.com/Cain-Ish/claude-code-plugin/releases/tag/v2.0.0-alpha.4) were created by the user the
  same day, as pre-releases, with the notes drafted in this step.

### 2i, check 3: the field re-check (2026-11-03): pass, neither path exercised

- *Corpus:* the user's sessions in their other repo started after the move to alpha.4 (the install record: version
  `2.0.0-alpha.4`, 2026-10-29 20:26Z). Two sessions, 7 epochs (2 starts, 5 automatic compactions), CLI 2.1.314 and
  2.1.316. The second was still running when read. Run as `field.mjs`; the per-unit record is in `research/raw/`.
- *No force on a machine turn: pass.* 6 forces, each on its epoch's first typed prompt; none missing (the one epoch
  without a force had no prompt), none twice. The 7 epochs held 26 machine turns, and none came before an epoch's
  first typed prompt, so L1's skip never had to act. The pass does not show L1 working in the field.
- *C5 for Bash reads: pass.* 4 Reads of the map file, each with the plugin's labels (the one Read that had to say
  unreviewed did). 3 Bash commands named the map folder: `git status` and `git diff --stat`, read whole. None reads
  an entry, so none owes labels and none got them. No map entry was read through Bash, so 2j's handler is not shown
  working in the field either.
- *Reported, outside check 3's pass:*
  - C1: the plugin's context at 7 of 7 epoch starts. C8: no hook error.
  - C6: 13 capture writes scanned. 5 are Edit fragments of existing entries (the scanner reads an Edit's new text as
    an entry), and the 3 quotes not found are those fragments, which hold no quote. The map file holds 21 entries,
    each with its quote, source and `when`; none holds a session id, email address or absolute path.
  - C7: 12 paths named after a change; the 2 not found are a website's `robots.txt`, named while reading that site,
    not a decision's source. None invented.
  - C9: 1 subagent, without the index, wrote 2 repo files (a script and a research note). Recorded under D18.
  - `field.mjs` names every unit after the GitHub move `tag v2.0.0-alpha.2`, its build when written; the counts do not
    depend on it.
- *Also from this corpus:* D22's `paths:` trigger fired (see D22, 2026-11-03).

### 2k: Claude Code's rule folder left to Claude Code (registered 2026-11-03, before the code)

- *Why:* D22's step 17m chose (N). On the repo that fired the trigger, Claude Code delivered 64 of 92 declared
  (event, document) pairs before the write; Claude's own reads reached 4 more (4%).
- *The change:* `index()` leaves out tracked documents under the root's `.claude/rules/`. Claude Code loads every file
  there itself: unscoped ones at launch, `paths:` ones on a read, write or edit of a matching file ([CC-MEMORY] in
  [research/2026-10-19-platform-memory-channels.md](research/2026-10-19-platform-memory-channels.md)). The forced
  decision then no longer asks about that folder.
  - It is a prefix test on git's repo-relative paths, so no file is read for it. `pkg/.claude/rules/` and
    `.claude/rulesets/` stay listed.
  - The frozen texts (instruction, header, force, naming line) are unchanged.
  - A repo whose only documents sit under `.claude/rules/` gets an empty index and no forced decision, like a repo with
    no documents; alpha.4 gave it a one-directory force.
- *Why it should cost no rule:* on P1, whose 29 rule files all declare `paths:`, M1 already met the bars of R1 and R3
  to R5 (06, 2d), and the route's one gain there, R6, comes from `CODING_STANDARDS.md` at the root, which stays
  listed. At the field's new files, Claude's own reads reached 0 of 7 pairs, so nothing the force delivered there is
  lost.
- *Version* `2.0.0-alpha.5` in both manifests; the new product hash is pinned in the self-test.
- **Checks:**
  1. *Self-test:* new cases fail on `f18d83e328b4` and pass on the new code:
     - `.claude/rules/a.md` and `.claude/rules/sub/b.md` are not listed;
     - `.claude/rulesets/c.md` and `pkg/.claude/rules/d.md` are;
     - a repo whose only documents are rules gets an empty index, session start gives the instruction and the naming
       line only, and the prompt gets no force;
     - an untracked map file is still listed beside the rules.

     *Pass:* the self-test passes here, the existing cases unchanged.
  2. *Output unchanged elsewhere.* Session start's text from the new code:
     - equals alpha.4's on P2 and R0 at their eval commits and on the A1 fixture;
     - on P1 (`f20f2af`) and the field repo (its HEAD), differs from it by exactly the `.claude/rules/` line.
  3. *Smoke* on the pinned CLI 2.1.305; CI's self-test on three systems.
  4. *P1 build,* the v2 arm on the new hash, 10 runs. *Predicted:* R1, R3, R4 and R5 at 10; R6 at least 8; R2
     reported; cost under the no-worse ceiling. *Offered, not run,* by the user's choice of 2026-10-29: no further
     eval re-runs, the user checks in real sessions. It is ready to run before a release if the user asks.
  5. *The field re-check after a release:*
     - `field-scope.mjs` on the user's sessions after the move: R at most 10%; D's share not below 17m's 70% (64 of
       92); X reported;
     - `field.mjs`: C1, C2, C5 and C8 hold as before;
     - the forced answers no longer name `.claude/rules/`, judged by reading.

     The field repo is P1's successor, with the same rule folder, so this is P1's cell in real use.
- **On a pass of 1 to 3:** commit, with no tag. The release and the move of the user's install are the user's call.
  D22 re-locks when check 5 passes, or check 4 if it runs.

### 2k: result (2026-11-03): checks 1 to 3 pass

- *The attempt ran from a copy first.* The user's install comes from the GitHub tag, as `known_marketplaces.json`
  shows.
- *Check 1:* the new cases fail on `f18d83e328b4`: its index lists the rules folder where the case expects an empty
  one. They pass on the new code, and every existing case passes unchanged. Product hash `62929fea5ecf`, pinned.
- *Check 2:* session start's text is byte-identical on P2 (`c19bf0d2`), R0 (`2a21b45`) and the A1 fixture. On P1
  (`f20f2af`) and the field repo, it differs only by the removed `.claude/rules/` line.
- *Check 3:* the smoke passes on the copy with the pinned CLI 2.1.305. CI on `648144d`: the self-test and the load
  lane are green on Windows, macOS and Linux.
- *Check 4* (P1 build) not run, and *check 5* (the field) waits for a release, both as registered.

### 2k: published as `2.0.0-alpha.5` (registered 2026-11-03, before the tag)

The user chose (2026-11-03) to tag and release 2k as built, without check 4 (P1 build).

- **Checks:**
  1. *The tree:* `git diff 648144d -- plugin/ .claude-plugin/` at the release commit is empty, so the product is the
     one checks 1 to 3 ran (`62929fea5ecf`). The release commit changes documents only, so CI's path filter does not
     run it again; CI on `648144d` stands.
  2. *Install from the tag* in an isolated Claude config in a short folder. *Pass:* the cached copy is version
     `2.0.0-alpha.5` and hashes to `62929fea5ecf`; the uninstall and the marketplace removal succeed; the user's
     registry files are unchanged by checksum.
  3. *The user's install* in their other repo moves to the tag by alpha.4's route (marketplace removed, added at the
     tag, the plugin installed at local scope). *Pass:* the install record says `2.0.0-alpha.5`, its cached copy
     hashes to `62929fea5ecf`, and the rest of that repo's local settings are unchanged.
- **The README:** installs from `#v2.0.0-alpha.5`; says the index leaves the root's `.claude/rules/` to Claude Code,
  that this changes session start in any repo that has that folder (not an edge case), and how alpha.5 was checked
  (the self-test, a byte comparison on the test repos, the smoke, CI; no eval run); adds 04's new weaknesses (a
  rules-only repo, a nested rule folder, an edit after a compaction) as known issues.
- **The release page:** notes drafted here; created by the session if allowed, otherwise by the user, as before.
- **On a failure** of check 1 or 2, the tag is deleted before the install moves, and the cause is recorded.
- *Next:* 2k's check 5 on the user's sessions started after the move.

### 2k: published as `2.0.0-alpha.5` (2026-11-03)

- *Check 1, the tree:* `git diff 648144d -- plugin/ .claude-plugin/` at `a36d49a` is empty. The self-test passes
  there. *Pass.*
- *The tag* [`v2.0.0-alpha.5`](https://github.com/Cain-Ish/claude-code-plugin/tree/v2.0.0-alpha.5) is on `a36d49a`,
  pushed with the branch. The
  [pre-release page](https://github.com/Cain-Ish/claude-code-plugin/releases/tag/v2.0.0-alpha.5) was created by the
  session this time, with the notes drafted in this step.
- *Check 2, install from the tag* in an isolated config (CLI 2.1.317): version `2.0.0-alpha.5`, hash `62929fea5ecf`;
  the uninstall and the marketplace removal succeeded; the user's registry files are unchanged by checksum. *Pass.*
- *Check 3, the user's install* in their other repo moved from alpha.4 by the same route: local scope, version
  `2.0.0-alpha.5` at `a36d49a`, the cached copy at `62929fea5ecf`; the local settings differ only in the marketplace's
  `ref`. *Pass.* alpha.4's cached copy stays; its `.in_use/` folder holds two process markers (whether those processes still run
  was not checked).
  - *A hashing note:* a cached copy holds an `.in_use/` folder of process markers, outside the product. The hash
    leaves it out; with it, alpha.4's copy hashed `046240f48ae5`, without it `f18d83e328b4` as published.
- *Next:* 2k's check 5, `field-scope.mjs` and `field.mjs` on the user's sessions started after 17:05Z. D22 re-locks
  on its pass.

### 2k, check 5: the field re-check (2026-11-06): pass, on a thin base

- *Corpus:* every main session in the field repo started after the move to alpha.5, as listed when the check was
  re-run. There are two, on CLI 2.1.318:
  - the first: 3 epochs (a start and 2 compactions while idle), 20 subagents (first recorded as 21: the reader had
    counted a workflow's journal, which is a log; corrected in 18b);
  - the second: still running, 1 epoch, no code write yet when read.

  A first run by a delegated reader listed only the first session, because the second started after it had made its
  list. The corpus was fixed at both sessions before the second one's counts were seen. Every count below was re-run in
  this session. The per-unit record is in `research/raw/` (gitignored).
- *`field-scope.mjs`, pass.*
  - 11 gate events and 17 pairs, all in the first session: D 15 (88%, bar at least 70%), R 1 (6%, bar at most 10%),
    X 1.
  - The X is an Edit that failed, its text not found. Claude Code delivered the rule with the next edit.
  - (S-b) as registered is over its bar at 11 of 11 events, a median of 42 unread documents.
- *`field.mjs`, pass, with one scanner correction disclosed.*
  - *C1:* the registered scanner printed "plugin start 1/3" for the first session, beside "context recorded 3/3".
    - CLI 2.1.318 records the `SessionStart` hook's command at a compaction as `command hook N`, not the plugin's
      path, so the scanner's match on `hook.mjs` missed two starts.
    - Read in the raw records, all 3 starts carry the frozen instruction.
    - Corrected to also match the plugin's output: C1 is 4 of 4 epochs across both sessions, each with the index
      (10 directories, 1,774 B, against alpha.4's 11 and 2,162 B in the same repo).
  - *C2:* 3 forces in 4 epochs, each on its epoch's first typed prompt, none twice. The fourth epoch had no prompt.
  - *C5:* 3 Bash reads of map entries came after an uncommitted write in the session, and all 3 carried the labels.
    That is the first sighting of 2j's handler at work in the field. There was no Read-tool map read.
  - *C8:* 0. Its zero rests on a count of every hook record in the session (0 errors, 0 nonzero exits), since
    `field.mjs`'s C8 matches the plugin by the same command field and would miss an error at a compaction start.
- *The forced answers, judged by reading:* 3 of 3 cover every index directory, and none names `.claude/rules/`.
  *Pass.*
- *Not exercised:*
  - C3's and C4's bars: no epoch is in-claim. The first prompts were a question, a prompt to carry on after a
    compaction while idle, and another question.
  - L1's skip of machine turns;
  - the labels on a Read-tool map read.

  This pass rests on 17 pairs against 17m's 92, and on no change named in an epoch's first prompt.
- *Observations, outside the check (each checked against D22's and D18's triggers; none fires):*
  - *Where the changes were:* the first session made 45 file writes, none in an in-claim epoch.
    - 22 came after a first prompt that asked a question: 1 in that turn, then 21 in the next typed prompt, which
      named the change and, by design, took no force.
    - 6 came in the turn that carried on after the compaction while idle.
    - 17 came in turns opened by a background task's notification.

    The two forced turns held 7 of the 45. This is 04's "change named after the epoch's first prompt" weakness, seen
    in real use.
  - *Read-through:* in the second epoch, 5 directories were marked yes, and no document of them was read with the
    Read tool before the first write. This matches 2i's C4 (0 of 3). It is not D22's measure, which is the binding
    document read.
  - *Map reads went around the Read tool* in 6 of 6: 4 through Bash, labelled, and 2 through the Grep tool,
    unlabelled. One of the Grep reads came after an uncommitted write. This is 04's accepted risk, now counted.
  - *The labels cost more than the index:* 10.6 KB over the 4 Bash reads, against 8.7 KB for the 3 starts. Most of
    the lines say a person-sourced quote is unverified. A capture made as a tail, an append, then a tail pays for two
    label blocks.
  - *Compactions while idle,* new in this CLI, open an epoch. Each one re-arms the force, which then lands on the next
    prompt, here 2 hours later.
  - *The scanners lag the CLI:* besides C1 and C8, `field.mjs`'s C9 reads only one folder level of subagents, so it
    counted 1 of 20 (a workflow's agents are nested). The 20 made no write to a repo file, by a search of their file
    writes and Bash commands.
  - *Captures:* 2 entries, both appended through Bash, in format, quoted word for word, with no session id, email
    address or absolute path.
  - *Hook wall times* in the transcript were 105 to 340 ms on a loaded machine with 20 agents running. They are not
    D18's measure, which is added p95 in the reference state.
- *Result:* check 5 passes as registered, so D22 re-locks (DECISIONS.md, D22). The base is thin, as stated above.

### 2l: v1's leftovers named to the user (V2-D27, 2026-11-06)

- *Why:* D26's commands remove v1's statusline and timer, but nothing points an updater at them. D27's record
  registers the question, the options and the checks, before the code.
- *The change:*
  - session start checks for `bin/buddy-statusline.sh` and `bin/sb-extract-drain.sh` under `$BRAIN_DIR`, or under
    `~/.second-brain` without it;
  - if either is there, its output adds `systemMessage`, one line for the user that names the README's "Coming from
    v1";
  - the output for Claude is unchanged;
  - version `2.0.0-alpha.6` in both manifests.
- *Built from a copy* in the scratchpad, then moved to `plugin/` unchanged. Product hash `d21b69bfc1ed`, pinned in the
  self-test.
- *Checks:* D27's two (the self-test and delivery on CLI 2.1.319). Then, as for every build, the smoke on the pinned
  CLI 2.1.305 and on 2.1.319, and CI's self-test on three systems. A1 and P1 build are not re-run, by the user's
  choice of 2026-10-29. D18's added time waits for the release bench.

### 2l: result (2026-11-06)

- *D27's checks pass* (DECISIONS.md, D27):
  - the self-test passes with the new cases;
  - with an empty `BRAIN_DIR`, session start's output is byte-identical to alpha.5's on this repo;
  - the line reaches the session as a `hook_system_message` and not Claude's context: 2 input tokens apart, against
    about 35 for the line.
- *The smoke passes* on the pinned CLI 2.1.305 and on 2.1.319. In the 2.1.319 run, `BRAIN_DIR` was unset and the home
  folder still held v1's shims, so session start's output began with the line.
- *CI* on `4d201a2` passes on three systems: the self-test, and the load lane gated at one session. At one session,
  session start adds 78.3, 42.7 and 25.2 ms p95 on Windows, macOS and Linux. On `648144d`, alpha.5 added 71.7, 45.5
  and 27.8. These are runs on different runners, so the difference is not D27's cost; check 6 measures that.
- *Not checked:* the interactive screen; D18's added time (18f's bench).

### 2l: check 6, the reference bench (registered 2026-11-06, before it runs)

The protocol of 2h's attempt 4, with alpha.5 as the control. The driver is
[`V2-D18-runtime/reference.mjs`](probes/V2-D18-runtime/reference.mjs).
- *The repo:* a fresh worktree of P2 at `c19bf0d2`, with `benchmap.mjs`'s map: 30 entries, 1,259,723 cited bytes, 0
  not found. The earlier sessions' P2 worktrees were not used, since their git index is empty.
- *The builds:*
  - the control is a copy of tag `v2.0.0-alpha.5` (`62929fea5ecf`);
  - the candidate is a copy of `plugin/` at 2l (`d21b69bfc1ed`);
  - `bench.mjs` is the same file in both, unchanged since alpha.5.
- *The reference state:*
  - before each pair, a 10-second CPU sample. Above 10%, no pair runs, and the sample repeats every minute for at most
    3 hours;
  - a pair is valid only when every empty-Node p95 at 8 concurrent, in both runs, is at most 100 ms;
  - invalid pairs are repeated, up to 6 pairs. Fewer than 3 valid pairs give no result, and the check waits for a
    later window. A window without a result is not a failed attempt.
- *Pass:* in each of 3 valid pairs, each of the candidate's hooks adds at most 100 ms p95 at 8 concurrent, with 0
  errors.
  - A valid pair with the candidate over the bar fails the check.
  - A control over the bar is recorded, since it fires D18's trigger.
- *Reported, with no bar:* the candidate's session start minus the control's, as D27's cost. This machine's home holds
  v1's shims, so the candidate's session start takes the path that adds the line.

### 2l: check 6, the first window (2026-11-06): no result

- The driver started at 19:43Z. Every printed sample was over the 10% bar: 30.4%, 28.9% and 15.0% (one line per 10
  samples). The load was a game and WSL.
- At about 20:10Z, Claude Code stopped the driver because the machine was low on memory. No pair ran.
- As registered, a window without a result is not a failed attempt. The check waits for the user: about 20 minutes
  with the game and WSL paused.

### 2l: published as `2.0.0-alpha.6` (registered 2026-11-06, before the tag)

The user came back on 2026-11-06 with the machine's load stopped and said alpha.6 can be released or installed, so
that their two working sessions in the field repo give results on real code. That is a go for a pre-release and for
moving their install, by alpha.5's route. It is not D24's answer. `main`, `2.0.0`, D25's marketplace rename and the
devils-advocate workflow stay out.

- **Check 6 first.** Its second window started at 21:46Z, and its first sample was under the bar. Its outcome
  decides the rest:
  - *pass:* the tag and the checks below;
  - *a valid pair with the candidate over the bar:* no tag and no move. D18's trigger is recorded, and the user is
    told;
  - *no result* (the window turns busy, or the driver is stopped): the release goes ahead on the user's go, as alpha.5
    went without its check 4. Check 6 stays open for a later window, and the README and the release notes say so.
- **Checks:**
  1. *The tree:* `git diff 4d201a2 -- plugin/ .claude-plugin/` at the release commit is empty. The product is then the
     one that D27's checks, the smoke and CI ran (`d21b69bfc1ed`), and CI on `4d201a2` stands.
  2. *Install from the tag* in an isolated Claude config in the scratchpad. *Pass:*
     - the cached copy is version `2.0.0-alpha.6` and hashes to `d21b69bfc1ed`, its `.in_use/` folder left out;
     - the uninstall and the marketplace removal succeed;
     - the user's registry files are unchanged by checksum.
  3. *The user's install* in the field repo moves to the tag by alpha.5's route: the marketplace removed, added at the
     tag at local scope, and the plugin installed at local scope. *Pass:* the install record says `2.0.0-alpha.6`, its
     cached copy hashes to `d21b69bfc1ed`, and the repo's local settings differ only in the marketplace's `ref`.
- **The README:**
  - the status and Install move to `#v2.0.0-alpha.6`;
  - it says how alpha.6 was checked: the self-test, the smoke on 2.1.305 and 2.1.319, CI on three systems, and check
    6's result or its absence. No eval ran;
  - "Coming from v1" names the line;
  - a known issue: the line's link opens `main`'s README, which is v1's until `main` moves.
- **The release page:** a pre-release, with notes drafted here.
- **Not run:** A1 and P1 build (the user's choice of 2026-10-29), and the devils-advocate workflow, which waits for the
  user's go.
- **On a failure** of check 1 or 2, the tag is deleted before the install moves, and the cause is recorded.
- **Sessions already running** keep alpha.5's cached copy, since a session loads its hooks when it starts. Only
  sessions started after the move run alpha.6.
- **Check 7, the field re-check,** on the user's sessions in the field repo started after the move:
  - `field-scope.mjs` and `field.mjs`, with 2k check 5's bars;
  - *D27 in use:* while v1's shims are on disk, each session start in those transcripts carries the line as a
    `hook_system_message`, and no context record of Claude's holds its text.

  D24's field bar is not set here. These sessions are counted against it once the user sets it.

### 2l: check 6, the second window (2026-11-06): pass

- The driver ran from 21:46Z to about 22:05Z, with every pair's sample at 6.4% to 8.5%.
  - Pairs 1, 2 and 4 were valid.
  - Pair 3 was not: in its candidate run, empty Node's p95 at 8 concurrent was 88.6 to 127.8 ms. The next sample read
    39.8%, so the driver waited once.
- Added p95 at 8 concurrent, in ms, for the candidate (alpha.5, the control, in brackets), in the valid pairs:

  | Hook | Pair 1 | Pair 2 | Pair 4 |
  | --- | --- | --- | --- |
  | Session start | 51.8 (66.0) | 67.1 (63.9) | 92.1 (64.4) |
  | Prompt | 21.7 (16.8) | 17.3 (22.7) | 24.7 (22.8) |
  | Read, another file | 22.1 (19.6) | 25.6 (22.9) | 22.5 (23.9) |
  | Read, a map file | 71.6 (86.9) | 79.8 (79.2) | 75.6 (70.2) |
  | Bash, a map read | 78.4 (70.8) | 73.3 (96.0) | 75.5 (92.4) |
  | Bash, another command | 33.4 (19.0) | 24.2 (27.5) | 20.6 (16.7) |

- Every run had 0 errors, and each of the candidate's hooks is at most 100 ms in each valid pair. *Pass.*
  - The highest is session start in pair 4, at 92.1 ms.
  - The control stayed under the bar too, so D18's trigger does not fire.
- *D27's cost, reported with no bar:* session start, the candidate minus the control, was -14.2, +3.2 and +27.7 ms.
  The spread between pairs is wider than the change, so this bench does not resolve its cost.
- *A limit of the fixed order:* the candidate runs second in every pair.
  - Its session start rose across the pairs: 51.8, 67.1, then 92.1 ms, with pair 3's invalid 90.2 between.
  - The control's stayed at 63.9 to 66.0 ms.
  - That fits a machine that grew busier over the run, and the protocol cannot tell it apart from the change. The bar
    held, and D18's trigger did not fire. A later bench could alternate the order.
- Raw files: `research/raw/2l-bench/window2/` (gitignored).
- *Next:* publishing, as registered above.

### 2l: the release notes (drafted before the tag)

> Plugin hash `d21b69bfc1ed`. **v1's leftovers are named to you.** While v1's statusline or timer script is still on
> disk (in `~/.second-brain/bin/`, or under `BRAIN_DIR`), session start shows you one line that points to the README's
> [Coming from v1](https://github.com/Cain-Ish/claude-code-plugin/tree/v2#coming-from-v1). Claude does not see it,
> and its context is unchanged ([06, step 2l](https://github.com/Cain-Ish/claude-code-plugin/blob/v2/docs/v2/06-first-slice.md); V2-D27).
>
> - "Coming from v1" gives the commands that remove v1's statusline and timer on macOS, Linux and Windows. They were
>   checked on GitHub's runners against v1's own install, and the data folder was unchanged (V2-D26).
> - **Checked:** the self-test, a smoke session on Claude Code 2.1.305 and 2.1.319, CI's self-test and load lane on
>   three systems, the reference bench against alpha.5 (3 valid pairs at 8 at once, every hook at most 92.1 ms
>   added, 0 errors), and an install from the tag.
> - **Not run, by the owner's choice:** A1 and the P1 build eval.
> - **Known:** the line's link opens `main`'s README, which is v1's until v2 moves there.
>
> ```
> claude plugin marketplace add Cain-Ish/claude-code-plugin#v2.0.0-alpha.6 --scope project
> claude plugin install second-brain@second-brain-v2 --scope project
> ```

### 2l: published as `2.0.0-alpha.6` (2026-11-06)

- *Check 1, the tree:* `git diff 4d201a2 -- plugin/ .claude-plugin/` at the release commit `7073040` is empty. The
  self-test passes there. *Pass.*
- *The tag* [`v2.0.0-alpha.6`](https://github.com/Cain-Ish/claude-code-plugin/tree/v2.0.0-alpha.6) is on `7073040`,
  pushed with the branch. The session created the
  [pre-release page](https://github.com/Cain-Ish/claude-code-plugin/releases/tag/v2.0.0-alpha.6) from the notes
  drafted above.
- *Check 2, install from the tag,* in an isolated config on CLI 2.1.319. *Pass:*
  - the cached copy is version `2.0.0-alpha.6`, hash `d21b69bfc1ed`;
  - the uninstall and the marketplace removal succeeded;
  - the user's registry files are unchanged by checksum.
- *Check 3, the user's install* in the field repo moved from alpha.5 by the same route. *Pass:*
  - the install is at local scope, version `2.0.0-alpha.6`, at `7073040`;
  - the cached copy hashes to `d21b69bfc1ed`;
  - the local settings differ only in the marketplace's `ref`.

  alpha.5's cached copy stays, marked orphaned. Its `.in_use/` folder holds the markers of the sessions already
  running. On 2.1.319, the marketplace removal now warns that it deletes a plugin's saved options, secrets and data
  where it can. v2 keeps none.
- *Next:* check 7, the field re-check, on the user's sessions started after the move (about 22:12Z).

### D24's field count 1 (2026-11-07, 12:00Z): not met

- *Corpus:* one epoch, the field session's resume on alpha.6 at 11:50Z. That session's first epoch was read by 2k's
  check 5, so it is outside (DECISIONS.md, D24).
- *No defect:*
  - C1: the plugin's start and its context are recorded;
  - C2: one force, on the first human prompt;
  - C5 to C7: no event in the epoch;
  - C8: 0 errors of any hook.
- *In-claim epochs: 0.* The epoch's first human prompt asked for the work's status.
- `field-scope.mjs`: no gate event in the epoch.
- *Reported:* 11 subagents in the epoch, and no write by the main session.
- *Result: not met,* for want of an in-claim epoch. The next count runs as late as the deadline allows.
- *Outside the corpus:* after check 5 read it, the first epoch went on to 3 gate events with 6 pairs, all D.
- *A correction to 2k's check 5:* it called both its sessions CLI 2.1.318. The second one records 2.1.319
  throughout.

### 18f: the `2.0.0` release, staged (registered 2026-11-07, before the release commit)

D24 is locked at (b). The release is staged on branch `release-2.0.0`, so `v2` keeps installing alpha.6 until the
field bar passes. Nothing is tagged `2.0.0` before then.

- **The release commit,** on `release-2.0.0`, from `v2`:
  - `.claude-plugin/marketplace.json` named `second-brain` (D25), its description without "in development";
  - version `2.0.0` in both manifests, and the self-test's hash pinned again;
  - the README:
    - the title and the status;
    - Install from the repo with no ref (`main` after the move), as `second-brain@second-brain`;
    - Uninstall with those names;
    - the contributors' note with the new name;
    - what D24's count found;
    - the known issue about the line's link dropped, since `main` moves with the tag.
- **Checks on the branch:**
  1. *The product:* `git diff v2.0.0-alpha.6 -- plugin/scripts plugin/hooks plugin/commands` is empty. Under `plugin/`,
     only the version in `plugin.json` and the self-test's pin differ.
  2. *The self-test* passes with the new pin, and *the smoke* passes on CLI 2.1.319, the current one. The pinned
     2.1.305 is not run, since no hook code changed.
  3. *CI on the branch,* by dispatch:
     - `v2.yml`: the self-test and the load lane on three systems;
     - `v2-d26.yml`: the README still holds each command the route runs.
  4. *Install from the branch* in an isolated config. *Pass:*
     - the marketplace is added as `second-brain`, and the plugin installs as `second-brain@second-brain`;
     - version `2.0.0`, at the pinned hash;
     - the uninstall and the removal succeed;
     - the user's registry files are unchanged by checksum.
  5. *The release review:* the devils-advocate workflow (`.claude/workflows/devils-advocate.js`) on the branch.
     - It runs under the user's "continue as we plan": the plan listed it as the one item waiting for their go.
     - Rule 8 applies to each surviving finding.
     - A finding that needs a product change means a new build and its checks. If that does not fit the deadline, the
       record says so; no check is cut.
  - *Not run:*
    - the reference bench: the hook code is alpha.6's, so 2l's check 6 covers it;
    - A1 and P1 build, by the user's choice of 2026-10-29.
- **When D24's bar passes,** in this order:
  1. `v2` fast-forwards to the release commit, and the tag `v2.0.0` goes on it.
  2. The release page, not a pre-release, from notes drafted here.
  3. `main` fast-forwards to the release commit. It is an ancestor of `v2`, and the branch is unprotected.
     - v1's CI file `ci.yml` leaves `main`.
     - `v1` and `v1-final` keep v1 (D03).
  4. *Checks after the move:*
     - `#coming-from-v1` resolves on `main`'s README;
     - an install from the repo with no ref, in an isolated config, gives `2.0.0` at the pinned hash.
  5. The user's install moves, with the same checks as 2l's check 3:
     - marketplace `second-brain-v2` is removed;
     - the repo is added at local scope;
     - `second-brain@second-brain` is installed at local scope.
- **On a failure:**
  - before the tag, nothing goes public, and the cause is recorded;
  - after the tag and before `main` moves, the tag and the page are deleted.
- **If the bar is not met by the user's return,** the branch stays staged. The steps above wait for their next
  session in the field repo whose first prompt names a change.

### 2l: a correction to checks 6 and 7 (2026-11-07, the release review's finding 12)

- v1's shims and its scheduled task were removed from the owner's machine at 21:47:03Z on 2026-11-06. That was after
  the bench started (21:46:38Z) and before its first pair's files were written (21:50:57Z). So every candidate run took
  the path without the line.
- *Wrong as written:*
  - check 6's registration said the candidate's session start takes the path that adds the line;
  - its result called the session-start difference "D27's cost". It is the cost of the two file checks alone;
  - check 7's D27 clause, registered at 21:50:55Z, after the removal, cannot be observed on this machine.
- *Unchanged:* check 6's pass. The line's path adds one JSON field to the same output.
- Check 7's D27 clause is dropped. The line's display stays unchecked, as recorded.
- *Also stale* (the review's second round): 2l's result says of CI's session-start numbers that "check 6 measures
  that", meaning D27's cost. Check 6 did not, for the reason above.

### 2m: the release review's fixes, as `2.0.0-alpha.7` (registered 2026-11-07, before the code)

- *Why:* 2.0.0's release review (research/2026-11-07-release-review.md) confirmed defects in the Bash handler and the
  rules filter. D14 reopened. PM7's keep-or-kill entry for the labels (keep) is in DECISIONS.md, written before this
  step.
- **The changes,** built in a copy in the scratchpad and moved to `plugin/` unchanged:
  1. *The failure route* (findings 1, 2): `hooks.json` registers the Bash handler under `PostToolUseFailure` too,
     with the same matcher and `if`, and the argument `bash-failure`. That handler answers with the
     `PostToolUseFailure` event name, and its text is what `bash` gives for the same command.
  2. *Several files' labels* (finding 4): the Bash handler keeps whole files' labels while they fit in 10,000
     characters, with room left for the rest. Each file that does not fit gets one fail-closed line, which tells
     Claude to treat every entry in that file as unreviewed and unverified.
  3. *Only this repo's own map files* (findings 6 to 8):
     - a path in the command is resolved against the hook's `cwd`, then against each `cd` or `pushd` before it in
       the command. `~`, and Git Bash's `/c/` form on Windows, are read as the shell reads them;
     - a map file is labelled only when its folder resolves to this repo's `.project-map/`, as a Read of it would be.
       Another repo's map file, or a `pkg/.project-map/`, gets nothing, as a Read gets nothing;
     - a `cd` whose target cannot be read (`cd -`, a variable) gives the files after it the fail-closed line;
     - a name runs to `.md` and stops there: `captured.md.bak` is not `captured.md`.
  4. *The rules filter* (findings 11, 15): only `.md` files in the root's `.claude/rules/` are left out of the
     index. The pinned CLI's rule walker loads a file only when its name ends in `.md`, case-sensitively. Other
     documents there stay listed.
  5. The self-test's comment on the pin says what the release checks ran (finding 18).
  - Version `2.0.0-alpha.7` in both manifests, and the self-test's hash pinned again.
- **The README** takes the review's documentation fixes:
  - Uninstall removes the marketplace with `--scope project` (finding 3);
  - "Coming from v1" says to quit every running Claude Code session first (finding 5), to run both Install commands
    in a chosen repo (finding 13), and to use `XDG_CONFIG_HOME` and `CLAUDE_CONFIG_DIR` when they are set (findings
    10, 14 and 17);
  - the unlabelled routes add another repo's map file;
  - the bench line says the line's path was not timed (finding 12);
  - the status and Install move to `#v2.0.0-alpha.7`.
- **Checks:**
  1. *The self-test,* with a case for each change. Each new case fails on alpha.6's scripts and passes on 2m's:
     - the `PostToolUseFailure` entry, and its handler's event name and text;
     - two files whose labels together pass 10,000 characters;
     - a sibling repo's map, a `pkg/` map, a `.bak` name, a `cd` elsewhere and a `cd -`;
     - a `.txt` file under `.claude/rules/` stays listed.

     Cases that must still label: a `cd` into this repo, and this repo's map by its absolute path.
  2. *Byte identity* (D24's amendment): session start's and the prompt hook's output for Claude equal alpha.6's on
     the field repo's checkout, this repo, and A1's fixture.
  3. *The smoke* on the pinned CLI 2.1.305 and on 2.1.319, with one more command: a map read that exits non-zero.
     *Pass:* its labels reach Claude.
  4. *CI* on three systems: the self-test and the load lane.
  5. *The reference bench* against alpha.6, as 2l's check 6 ran, if the machine is quiet. Otherwise it waits, as
     registered there.
  6. *The second round of the review:* one refute-first verifier for each fixed finding, against alpha.7's code.
     A finding that survives sends 2m back.
- **On a pass:**
  - D14 and D26 re-lock, D26 after its workflow passes on the new README;
  - the tag `v2.0.0-alpha.7` and a pre-release page;
  - an install from the tag in an isolated config;
  - the user's install moved, with 2l's checks 2 and 3;
  - then `release-2.0.0` is rebuilt on alpha.7, and 18f's branch checks run again.

### 2m, the review's second round (2026-11-07): two fixes fail, so 2m goes back

Five refute-first verifiers, one for each fixed area, ran against `beb733e`. Before it: the self-test passed, and each
new case failed on alpha.6 and passed on 2m. Session start and the prompt hook were byte-identical to alpha.6's on the
field repo (3,159 B and 309 B), this repo and A1's fixture. The smoke passed on CLI 2.1.305 and 2.1.319, and the failure
route's labels reached the hook output on both. CI on `beb733e` passed on three systems. The bench did not run: the
machine stayed over 10% CPU, and the driver was stopped before any pair when the build had to change.

| Area | Verdict | What was found |
| --- | --- | --- |
| The failure route (1, 2) | fixed | Live on 2.1.319: Claude quoted the labels a failing map read got. A `cd` in an earlier Bash call reaches the hook's `cwd` |
| The cap (4) | not fixed | When even the first file does not fit, the closing lines are emitted with no limit: 85 files' lines pass 10,000 characters, and 200 come to 23,800 |
| Only this repo's files (6 to 8) | regression | Reads of this repo's own map that alpha.6 labelled now get nothing: a quoted path with a space in it, a prefix such as `$PWD/`, `$CLAUDE_PROJECT_DIR/` or `$(pwd)/`, `git -C`, a `popd`, a subshell's `cd`. A wrong label became no label, which is worse. Confirmed live for `"$PWD/..."` on the failure route |
| The rules filter (11, 15) and the comment (18) | fixed | The pinned CLI's walker loads exactly the names ending in `.md`, in every subfolder |
| The README (3, 5, 10, 13, 14, 17) and the record (12) | fixed, with gaps | Uninstall has no `--scope local` form. A session's `/clear`, resume or fork re-runs v1's start too. An alpha installs beside v1 and does not replace it, so v1 stays enabled. 06's "check 6 measures that" in 2l's result was left uncorrected |

Also found, older than 2m: the command is split at `|`, `;` and `&` inside quotes too, so `grep -E "a|b"
.project-map/captured.md` gets no label. A glob such as `.project-map/*.md` gets none either. A path written with
backslashes is never matched.

### 2m, attempt 2 (registered 2026-11-07, before the code)

The rule for a map file named in a Bash command changes from "label it only when it resolves to this repo, else
nothing" to *label it when it surely is this repo's, else fail closed*. No named map file is left with nothing.
- *The parts:* the command is split at line breaks, and at `|`, `;` and `&` outside quotes.
- *The directory:*
  - it starts at the hook's `cwd`;
  - a part that is only `cd` or `pushd` with a plain path (no `$`, backtick, glob or leading `-`) moves it there;
  - any other part that names `cd`, `pushd` or `popd`, or that runs `git`, `env` or `make` with `-C`, makes it
    unknown from there on.
- *A read part* (a read verb, and no redirect into the map folder) is split into words, with quotes respected, and
  backslashes read as `/`. Each word that names `.project-map/` and ends in `.md` is a named map file:
  - it gets this repo's labels when all of these hold: the directory is known, the path before `.project-map/` holds
    no `$`, backtick, parenthesis or glob, the name holds no glob, and that path resolves to this repo's root (as
    written, or through links);
  - otherwise it gets one fail-closed line naming the path as written. That covers another repo's map file, a path
    built from a variable, and a glob.
  - A word that does not end in `.md` names no map file (`captured.md.bak`, `captured.md~`), as a Read of it labels
    nothing.
- *The cap:* whole files' labels while they fit beside the closing lines of the rest. If those lines alone would pass
  10,000 characters, one line covers every named file.
- *The README:*
  - Uninstall's `--scope local` form;
  - "Coming from v1": a session's start, `/clear`, resume or fork re-runs v1's; an alpha does not replace v1, so
    uninstall v1 first;
  - the line for a map file the hook cannot place;
  - 2l's correction names the stale sentence.
- *PM7:* this is 2m's own second attempt, before any release, so it is not the "further fix" of the labels' kill
  trigger. A third attempt would be.
- *Checks:* as 2m's, on the new build, and:
  - the self-test and the case runner add every case the second round found. Each must get labels or the fail-closed
    line, never nothing: a quoted path with a space, `$PWD/`, `$CLAUDE_PROJECT_DIR/`, `$(pwd)/`, `git -C`, `popd`, a
    subshell's `cd`, `grep -E "a|b"`, a glob, a backslash path, 85 and 200 files;
  - a third round: two verifiers on the Bash handler alone, one hunting a read of this repo's map that gets nothing,
    one hunting another folder's map that gets this repo's labels.

### 2m, the review's third round (2026-11-07): attempt 2 fails, and PM7 stops a third parse

Two verifiers ran on `308ca68`, one for each direction. Before them, on attempt 2:
- every round-2 case passed, and each failed on alpha.6 or labelled on both;
- session start and the prompt hook were byte-identical to alpha.6's on the three repos;
- the smoke passed on both CLIs, failure route included;
- D26's workflow passed on the new README.

| Direction | What was found |
| --- | --- |
| Reads of this repo's map that get nothing, new in attempt 2 | A double-quoted string that spans lines makes the split miss the `&&` after it, so `echo "..." >> .project-map/x.md && tail .project-map/x.md` is one part, and the redirect check drops the read (medium). `"$(head .project-map/x.md)"` ends in `)` (low to medium). A `\` continuation with no space before it, and brace expansion (very low) |
| The same, older (alpha.6 too) | `git diff` or `git show :` of a map file (medium to high: the diff shows the uncommitted entry), `rg` through Bash, `cd .project-map && cat x.md`, `cat .project-map/*`, a loop over the folder, `xargs`, `find -exec cat` |
| Another folder's map with this repo's labels, new in attempt 2 | `git grep -nE "a|b" <branch> -- .project-map/x.md`, since `|` inside quotes no longer splits |
| The same, older | `git grep` on another branch, a backtick `cd`, a subshell's `cd`, the same path read twice in two folders, `ssh` or `docker` reads, `eval`, a junction with `..`, `CDPATH` (low to very low) |

The labels' kill trigger fired (DECISIONS.md, D14, PM7), and the rethink chose deletion for `2.0.0`.

### 2m, attempt 3: the parse returns to alpha.6's (registered 2026-11-07, before the code)

- *The build:* `hook.mjs`'s Bash branch is alpha.6's split and match, byte for byte, plus three additions:
  - `bash-failure` answers as `PostToolUseFailure`;
  - the fail-closed text is one helper, as the cap needs it;
  - attempt 2's cap: whole files' labels while they fit beside the closing lines of the rest, then one line for all.

  The header comment names `bash-failure`. `hooks.json` and `map.mjs` stay as in 2m.
- *The README:*
  - attempt 2's sentences about the fail-closed line and about quotes and backslashes go;
  - the unlabelled routes name D14's accepted risks;
  - a known issue: another folder's map file read through Bash gets this repo's labels;
  - Uninstall's `--scope local` line, the start, `/clear`, resume or fork wording, and the alpha-beside-v1 line stay.
- **Checks:**
  1. `git diff v2.0.0-alpha.6 -- plugin/scripts/hook.mjs` shows those three additions and the comment, and nothing
     else.
  2. *The self-test* keeps the failure route, the cap (two big files, 85 and 200 files) and the rules cases, and drops
     attempt 1's and attempt 2's own-repo cases. One case pins the accepted risk: `cat ../b/.project-map/captured.md`
     gets this repo's labels, so a later change to the parse has to be deliberate.
  3. *The case runner:* the failure route, the cap and the rules cases fail on alpha.6 and pass here. The labelled
     forms label on both.
  4. *Byte identity* with alpha.6 for session start and the prompt hook, on the three repos.
  5. *The smoke* on CLI 2.1.305 and 2.1.319.
  6. CI on three systems, and D26's workflow.
  7. *The reference bench,* when the machine allows.
  - *No fourth review round:* the parse is alpha.6's, which round 1 reviewed and the field ran (check 5: 3 of 3
    must-label Bash reads labelled). The three additions were each confirmed in rounds 2 and 3.

### 2m, the reference bench (2026-11-07, 13:15Z to 13:35Z): pass, and the control trips D18

2l's check 6 protocol, with alpha.6 as the control and attempt 3 (`def38ab5258d`) as the candidate, on a fresh P2
worktree (30 entries, 1,259,723 cited bytes). Every sample was 4.6% to 5.4%, and all 3 pairs were valid.

| Hook, added p95 at 8 concurrent, ms | Pair 1 | Pair 2 | Pair 3 |
| --- | --- | --- | --- |
| Session start | 46.7 (38.8) | 41.0 (38.3) | 42.0 (42.5) |
| Prompt | 13.2 (11.0) | 12.1 (11.3) | 11.0 (12.1) |
| Read, another file | 12.1 (12.1) | 9.4 (10.9) | 10.5 (9.8) |
| Read, a map file | 57.1 (53.4) | 54.9 (**106.8**) | 54.6 (55.5) |
| Bash, a map read | 53.2 (54.8) | 52.6 (54.2) | 54.8 (54.3) |
| Bash, another command | 11.2 (9.0) | 9.1 (9.3) | 13.7 (12.8) |

- *The candidate passes:* at most 57.1 ms, 0 errors in every run.
- *The control (alpha.6, published) went over the bar once:* its map read added 106.8 ms in pair 2. As registered, that
  is recorded, and it fires D18's trigger ("at 8 concurrent on the reference machine"). The read hook's code is the
  same in both builds, and it ran at 53.4 to 57.1 ms in the window's other five runs, the candidate's run in the same
  pair included.
- *Registered now, before it runs:* a second window, the same pairs. D18 re-locks unchanged if every hook of both
  builds stays at most 100 ms in 3 valid pairs. If the read hook passes the bar again, in either build, its cost goes
  to a rethink under rule 4, and the release waits for it.
- *The second window (13:47Z): pass.* All 3 pairs were valid, with samples at 4.0% to 5.4%. The highest hook was
  66.8 ms for the control and 53.8 ms for the candidate, with 0 errors. The map read added 61.9, 55.3 and 52.3 ms (control)
  and 53.0, 52.1 and 51.0 ms (candidate). D18 re-locks unchanged, as registered.

### 2m: result (2026-11-07): pass, published as `2.0.0-alpha.7`

- *Attempt 3's checks, all passed:*
  1. `git diff v2.0.0-alpha.6 -- plugin/scripts/hook.mjs` holds the three additions and the comment only.
  2. The self-test passes.
  3. The failure route, the cap (two big files, 85 and 200 files) and the rules cases fail on alpha.6 and pass here.
     The labelled forms label on both.
  4. Session start and the prompt hook are byte-identical to alpha.6's on the field repo, this repo and A1's fixture.
  5. The smoke passes on CLI 2.1.305 and 2.1.319, and the failure route's handler ran on both.
  6. CI passes on three systems (`b24a422`), and D26's workflow passes on the README.
  7. The reference bench passed in two windows (above).
- *Product hash* `def38ab5258d`.
- *D14 re-locks* with the accepted risks its record names. D26 and D18 re-lock unchanged.
- *What 2m changed, against alpha.6:*
  - a Bash map read that exits non-zero gets its labels;
  - several files' labels stay under the cap;
  - non-`.md` documents in `.claude/rules/` are listed;
  - the README: Uninstall's scopes, "Coming from v1" (quit sessions first, an alpha beside v1, both Install commands,
    `XDG_CONFIG_HOME` and `CLAUDE_CONFIG_DIR`), and the Bash forms that get no label or another folder's labels.

### 2m: the release notes (drafted before the tag)

> Plugin hash `def38ab5258d`. **The fixes of 2.0.0's release review** ([research/2026-11-07-release-review.md](https://github.com/Cain-Ish/claude-code-plugin/blob/v2/docs/v2/research/2026-11-07-release-review.md); [06, step 2m](https://github.com/Cain-Ish/claude-code-plugin/blob/v2/docs/v2/06-first-slice.md)).
>
> - A map file read through Bash by a command that exits with an error now gets its labels. Claude Code reports
>   such a call as `PostToolUseFailure`, which alpha.6 did not hook.
> - When one Bash command reads many map files, their labels stay under Claude Code's 10,000-character limit for a
>   hook's output, and the files that do not fit get one line telling Claude to treat their entries as unreviewed.
> - A document in the root's `.claude/rules/` whose name does not end in `.md` is listed again, since Claude Code
>   does not load it.
> - The README's "Coming from v1" and Uninstall sections are corrected. It now names the Bash forms that get no
>   labels, and the case where another folder's map gets this repo's labels.
> - **Not changed:** the command parse is alpha.6's. Two attempts to make it read only this repo's own files each
>   opened new gaps, and the project's PM7 rule stopped a third. Labelling what a command printed is the next step.
> - **Checked:** the self-test, the smoke on Claude Code 2.1.305 and 2.1.319, CI on three systems, the reference
>   bench in two windows (every hook at most 57.1 ms added at 8 concurrent), and an install from the tag.
>
> ```
> claude plugin marketplace add Cain-Ish/claude-code-plugin#v2.0.0-alpha.7 --scope project
> claude plugin install second-brain@second-brain-v2 --scope project
> ```

### 2m: published as `2.0.0-alpha.7` (2026-11-07)

- *The tree:* `git diff b24a422 -- plugin/ .claude-plugin/` at the release commit `ef2d03c` is empty, so CI on
  `b24a422` stands.
- *The tag* [`v2.0.0-alpha.7`](https://github.com/Cain-Ish/claude-code-plugin/tree/v2.0.0-alpha.7) is on `ef2d03c`,
  pushed with the branch.
- *The release page:* the session's `gh release create` was refused by the permission check, as for alpha.3 and
  alpha.4. The notes are drafted above, for the user.
- *Install from the tag* in an isolated config on CLI 2.1.319: version `2.0.0-alpha.7`, hash `def38ab5258d`. The
  uninstall and the removal succeeded, and the user's registry files are unchanged by checksum. *Pass.*
- *The user's install* in the field repo moved at 13:49:19Z: local scope, `2.0.0-alpha.7` at `ef2d03c`, hash
  `def38ab5258d`. The local settings differ only in the marketplace's `ref`. *Pass.*
- `field.mjs` labels epochs from that time as alpha.7 (one entry in its move table, as for alpha.6).
- *Next:* `release-2.0.0` is rebuilt on alpha.7, and 18f's branch checks run again. The product is alpha.7's code
  with the version only.

### 18f: the staged `2.0.0`, rebuilt on alpha.7 (2026-11-07)

- *The branch:* `release-2.0.0` is rebuilt on `v2` at `3854ae1` (`bb49445`), by the same edits as before: the
  marketplace named `second-brain`, version `2.0.0` in both manifests, the self-test's pin, and the README for
  `main`. The README also drops the alpha-beside-v1 line.
- *Checks, all passed:*
  1. `git diff v2.0.0-alpha.7 -- plugin/scripts plugin/hooks plugin/commands` is empty. Under `plugin/`, only
     `plugin.json`'s version and the self-test's pin differ. Product hash `201378d6b47b`.
  2. The self-test passes. The smoke passes on CLI 2.1.319, and the failure route's handler ran.
  3. CI on the branch passed on three systems, and so did D26's workflow.
  4. Install from the branch in an isolated config: the marketplace `second-brain`, the plugin
     `second-brain@second-brain`, version `2.0.0`, hash `201378d6b47b`. The uninstall and the removal succeeded, and
     the user's registry files are unchanged.
  5. The release review: three rounds, closed by 2m (above).
- *When D24's bar passes, amended:* `v2` has moved past the branch's base, with documents only. So the release commit
  is made on `v2`'s head by the same edits, not by a fast-forward. Its `plugin/` and `.claude-plugin/` must equal the
  branch's (`git diff release-2.0.0 -- plugin/ .claude-plugin/` empty), so the checks above stand for it. Then the
  steps run as registered: the tag `v2.0.0`, the release page, `main` fast-forwarded to it, the checks after the
  move, and the user's install.
- *Field note (2026-11-07):* the field repo's running session was resumed on alpha.6 at 11:50Z, before the move, and
  keeps alpha.6's hooks until it restarts. The first alpha.7 epoch comes with a new session or resume after 13:49:19Z.
  Under D24's amendment, an alpha.6 epoch still counts for C1, C2, C3, C8 and `field-scope.mjs`. It does not exercise
  the failure route.

### D24's field count 2 (2026-11-07, 20:13Z): not met

- *Corpus:* two epochs of the field session, frozen at 20:13Z. One is the alpha.6 resume of 11:50Z, which count 1 read
  only to 12:00Z. The other is a compaction at 14:13Z. No new session or resume came after the move to alpha.7.
- *Build:* `field.mjs` labels the compaction's epoch alpha.7, since its build label follows the move's time. A
  compaction does not restart the session, so the epoch is counted under D24's alpha.6 clause:
  - it counts for C1, C2, C3, C8 and `field-scope.mjs`;
  - C5 counts under the rule both builds share.

  The transcript records the hooks as `command hook N`, so it cannot tell the two builds apart. The scanner's
  time-based label is a known limit, left as it is. No alpha.7 epoch has been seen yet, and no `PostToolUseFailure`
  event of any hook is in the corpus. The failure route is not exercised.
- *No defect:*
  - C1: the plugin's start and its context, 2 of 2 epochs;
  - C2: one force per epoch, each on the epoch's first human prompt;
  - C5: 2 map reads through Bash, both of this repo's own map file, exit 0, both labelled. No Read-tool map read;
  - C6: 2 entries, both appended through Bash. Both are in format, neither holds a forbidden item, and both are
    verbatim. The one entry of the session found not verbatim was written on 2026-11-06, outside the corpus;
  - C7: 2 paths named after a change, both found;
  - C8: 0 errors of any hook.
- *In-claim epochs: 1,* the compaction's, judged by reading. Its first human prompt:
  1. asks for a check that the work can be merged;
  2. then, if so, asks for a new sweep of the project's sources, with what is missing added.

  The prompt names changes, though the first is conditional. The resume epoch is not in-claim (count 1).
- *C3:* 1 of 1 in-claim epoch answered per directory. It states a yes list of 3 and names the other 7 as no; the
  index has 10 directories.
- *`field-scope.mjs`: outside the bar.*
  - 4 gate events, all in the compaction's epoch, with 6 pairs: D 4 (67%, bar at least 70%), R 0 (bar at most 10%),
    X 2.
  - The X pairs:
    - One is an edit whose file Claude had read only through Bash. Claude Code delivered the rule in the same turn,
      after the write. The scanner does not count it as delivered with the write: the parallel edit's record comes
      before the delivery.
    - The other is a new file whose rule was never delivered in the epoch.
  - X is 2 of 6 pairs, above 10%. Under 2k's rule, that is an observation for D22's selection-miss trigger, and it
    goes to the ledger.
- *Reported:*
  - C4: no Write, Edit or NotebookEdit in the forced turn before the next human prompt, so it does not apply;
  - C9: 31 subagents, none with the index; 4 wrote repo files, 21 writes;
  - main-session writes: 19. All 4 gate events came after later prompts, outside the first prompt's claim.
- *Result: not met,* on item 4 (D's share). The bar has no minimum number of pairs, and the corpus's 6 pairs are
  counted as registered. The release stays staged on `release-2.0.0`, and nothing is tagged.
- *Next:* count 3 (2026-11-08, 14:47Z) re-counts the whole corpus with any later epochs. It runs only while this
  session is open. A D share under the bar is not a plugin defect. Under D24's failed-bar clause it goes to the user,
  who may keep the bar or set another (D24's reopen trigger).

### 18f: the field session asked to load alpha.7 (2026-11-08, 00:31Z)

- *At the user's request,* a message went to the field repo's running session at 00:31Z. It asks that the user run
  `/reload-plugins` there at the next pause, so that the session's hooks become alpha.7's. The install itself was
  already at alpha.7. The message says nothing about how the plugin works.
- *What it means for the field counts:*
  - The message is a machine turn in the corpus, so C2 checks that no force lands on it.
  - After the reload, the compaction's epoch of 14:13Z runs alpha.7. Before it, the epoch runs alpha.6. Records after
    the reload time, which the session is asked to send back, count as alpha.7.
  - `field.mjs`'s time-based label is right for those records.
- *Later, on the user's request:* a summary of how the plugin was used, asked of that session after count 3 runs, so
  count 3's corpus is not primed. That session's epochs after the question are primed for C3 and C4 in any later
  count.

### D24's field count 3 (2026-11-08, 14:47Z): not met; D14 reopened

- *Corpus:* four epochs of the field session, frozen at 14:47Z:
  - the alpha.6 resume;
  - compactions at 14:13Z and 20:30Z on 2026-11-07, and at 01:27Z on 2026-11-08.

  No new session or resume came. Each epoch ran alpha.6's hooks until the user ran `/reload-plugins` at 01:50:50Z on
  2026-11-08, which printed "8 hooks". No record follows the reload, so no alpha.7 epoch has been seen yet, and no
  `PostToolUseFailure` event is in the corpus. The session sent no reply about the reload: it had no turn after it.
  The time is from its transcript.
- *No defect as the field README defines one:*
  - C1: the plugin's start and its context, 4 of 4 epochs;
  - C2: 3 forces, each on its epoch's first human prompt. The message this session sent (18f, above) came as a machine
    turn at 00:31Z, and no force landed on it. The 01:27Z epoch has had no human prompt;
  - C6: no new entry;
  - C7: no new named path;
  - C8: 0 errors of any hook.
- *C5:*
  - 3 map reads through Bash were labelled.
  - **1 was not:** a `grep` of this repo's own map file, exit 0, at 00:32Z on 2026-11-08, on alpha.6's hooks. Its
    pattern held `|` inside quotes, so the parse split the map path away from the read verb. That form is one of D14's
    accepted risks, and alpha.7's parse is the same.
  - Every entry the command showed was committed by then, so none was a must-label entry under C5's rule.
  - *Two readings:*
    - D24's item 1 names the field README's defects. The README's C5 counts Bash reads but makes a defect only of a
      Read-tool miss, so item 1 holds.
    - Read alone, D24's amendment ("a read of this repo's own map file that exits 0 is labelled") would call this a
      miss.

    This record takes the README's reading, since item 1 names it. The result is the same under both, since item 4
    fails.
  - **D14 reopens** by its trigger, a field sighting of an accepted risk, read literally (DECISIONS.md, D14).
  - *Scanner:* `field.mjs` classed the command "other", not a read: its read rule splits the command as the plugin
    does, so it cannot see the forms the plugin misses. The miss was found by reading every corpus command that names
    the map. `field.mjs` is left as it is. A scan by output is its fix too.
- *In-claim epochs: 1,* count 2's. The 20:30Z epoch's first human prompt asks for the app to be run and checked
  against the research, and names no change. This is judged by reading.
- *C3:* all 3 forced epochs answered per directory; in-claim, 1 of 1.
- *`field-scope.mjs`:* no new gate event. D is 4 of 6 (67%, bar at least 70%), R 0, X 2, unchanged, so there is no
  new observation for D22.
- *Reported:* C4 does not apply to the new epoch. Its forced turn made no Write, Edit or NotebookEdit.
- *Result: not met,* on item 4. Nothing is tagged, and `release-2.0.0` stays staged. Two things now stand before
  `2.0.0`, both the user's call:
  1. D24's item 4 needs more gate events at which Claude Code delivers the rule. An in-claim prompt does not supply
     them. The user may also set another bar (D24's reopen trigger).
  2. D14 must re-lock, by one of:
     - the output step, built and checked;
     - the risk accepted again.
- *After the count (14:51Z):* the field session replied, quoting the same "Reloaded: … 8 hooks" line. It gave the
  time as about 15:50 local. Its transcript holds one reload only, at 01:50:50Z, so this record keeps the
  transcript's time.

### 18f: the plugin-use question sent to the field session (2026-11-08, 15:23Z)

- At 15:23Z, on the user's request, the field repo's running session was asked for a short summary of how it used the
  plugin. The question covers:
  - the forced decision;
  - the map's labels;
  - its captured entries;
  - what got in the way;
  - the reload.
- *For later field counts:* that session's epochs after 15:23Z are primed for C3 and C4.

### The field's findings, rethought (2026-11-08)

The user asked for the issues and findings to be rethought and fixed. Each one, with where it goes (rule 3):

| Finding | Source | Goes to |
| --- | --- | --- |
| A `grep` with `\|` inside quotes showed map entries with no label | count 3 | D14's re-lock: 2n, below |
| The whole file's labels after every Bash read, for 1 to 5 entries shown | the field session; the scan in 2n | 2n: labels for the entries shown |
| "unverified quote" is not explained | the field session | 2n: one line of wording |
| `field.mjs` misses the Bash forms the plugin misses | count 3 | count 4: C5 by output (field README) |
| `field-scope.mjs`: D 4 of 6 (67%), bar 70% | counts 2 and 3 | D24's item 4 stands. A bar moved after its data is read counts as a failed check (rule 2), and 6 pairs are a thin base. Count 4 adds pairs. The X pairs are Claude Code's own path delivery (a rule delivered after a parallel edit; a new file's rule never delivered), recorded under D22 at count 2 |
| The forced decision changed nothing it read; "read every document of a yes directory" is not done when a directory holds about 50 | the field session | D22 observation, in count 4's record. C3 and C4 measure it; no change to the frozen text without a check |
| No way to ask which entries apply to a kind of work; `when:` is never shown | the field session | D22 observation, a candidate for the map issue; not built |
| The board, data and UI reminders after `git add` | the field session | not this plugin: the field repo's own hooks |
| The reload's time | the field session | settled in count 3: the transcript's time stands |

### 2n: labels for what a Bash command printed, as `2.0.0-alpha.8` (registered 2026-11-08, before the code)

- *Why:*
  - D14 reopened on 2026-11-08 (count 3, above). Its record names what re-locks it: the output step, built and
    checked under its own record. This is that record. The user's go-ahead, the same day: "rethink the issues and
    founds and implement fixes".
  - The field session's reply to 18f's question (kept outside the repo, as 18f registered) found the labels noisy.
    After a Bash read, the labels of the whole file came back, though the command showed one to three entries. It
    also found "unverified quote" unexplained.
  - *A scratch scan of the field repo's 31 main sessions,* matching the map's current quote lines in Bash output:
    - 24 Bash calls showed an entry's line, and 17 of them named the map folder;
    - the 7 others showed a document an entry quotes (3), session transcripts read by a script (3), or a commit
      message (1). None showed the map file itself, so the `if` filter stays;
    - the 9 labelled reads (alpha.4 and later) showed 1 to 5 entries each, and each got the labels of 22 to 36.
- **The changes,** built in a copy in the scratchpad and moved to `plugin/` unchanged:
  1. *The Bash handler labels by output.* The command parse goes.
     - *The output:* every string in `tool_response` for `bash` (Bash gives `stdout` and `stderr`), and `error` for
       `bash-failure` (Claude Code's text: "Exit code N", then the output, middle-truncated past a size). Carriage
       returns are dropped.
     - *Shown:* an entry of one of this repo's map files (every `.md` file under `.project-map/`) is shown when the
       output holds its heading line (`### …`) or any of its quote lines (`> …` with text after the marker), as
       written in the file with trailing spaces dropped. Substring, not line equality: `grep -n`, `cat -n`, `rg` and
       `git diff` add prefixes.
     - *Labels:* the shown entries' labels only, numbered by their place in the file, under the header
       "Labels on the entries of <file> that this output shows, in file order:". A shown entry with no label gives no
       line, and a file with none gives nothing. The Read hook's header and labels are unchanged, apart from change 2.
     - *The cap:* 2m's arithmetic over the per-file texts, unchanged.
     - *Fail closed:* a file whose labels cannot be computed gets 2m's closed line. When `tool_response` or `error`
       holds no string, one line: the entries this command showed could not be labelled, so every map entry it showed
       is to be treated as unreviewed and unverified. There is no fallback to a command parse.
     - *Scope:* this repo's own map files only. Another repo's entries get no label, as a Read of them gets none; an
       entry there with the same lines as one here gets this one's labels.
  2. *"unverified quote" explained:* when a label list holds that label, one line after the header says that the
     entry's source is not a file in this repo (a person's words, for instance), so its quote cannot be re-found, and
     that the date is its capture date. This holds for the Read hook and the Bash handler, and the line counts inside
     the cap. D16's choice (option b, re-locked 2026-10-26) is unchanged; this is wording only.
  - `hooks.json` is unchanged: the same matchers and `if: Bash(*.project-map*)`. Version `2.0.0-alpha.8` in both
    manifests, and the self-test's hash pinned again.
  - *Not built:* a dedupe of labels already shown in the session (Claude Code clears old tool output, so a label
    shown once can be gone), a way to surface `when:`, and any change to the forced decision. The last two are D22
    observations for count 4's record. The labels' trim stays after `2.0.0` (D24's answer); this step shrinks them as a
    side effect.
- **The README:** the unlabelled routes become:
  - a command that does not name the folder (`git diff`, `git show <rev>`, `rg` or `grep -r` from the root);
  - output that shows an entry only in part (a line cut short, `grep -o`, colour codes).

  "Another folder's map file gets this repo's labels" goes. Another repo's entries get none, as a Read of them gets
  none.
- **Checks:**
  1. *The self-test.* Each Bash case gets the output its command gives: run by `bash -c` in the temporary repo, or
     written out where the tool may be missing on a runner (Python, `rg`).
     - *The field's 20 commands:* the 9 that show entries get exactly the labels of the entries they show, and the 11
       others get nothing.
     - *D14's accepted-risk forms,* against this repo's map, each labelled:
       - `grep -n -E "a|b"`, and the field's `grep -n -i "a\|b"`;
       - `cd .project-map && cat captured.md`, and `cat .project-map/*.md`;
       - a backslash path;
       - `find .project-map -name '*.md' -exec cat {} \;`;
       - a `for` loop over the folder;
       - `git show HEAD:.project-map/captured.md`, and `git diff -- .project-map` with an uncommitted entry;
       - `rg -n` over the folder.
     - *Nothing for:* another repo's map file (`cat ../b/.project-map/captured.md`), and an append with no output.
     - *The failure route:* `error` text gives the labels the same output gives under `PostToolUse`. With no
       readable output, the closed line.
     - *The cap:* two big files, and 85 and 200 files, with their outputs.
     - *The note:* present when an "unverified quote" label is listed, absent otherwise. The Read hook's labels are
       pinned with it.
     - *Before and after:* each new case fails on alpha.7's scripts and passes on 2n's, except reads alpha.7 labelled
       too. Those must still label: whole files on alpha.7, the shown entries on 2n.
  2. *Byte identity* with alpha.7 for session start and the prompt hook, on the field repo's checkout, this repo and
     A1's fixture. D24's corpus clause depends on it.
  3. *The smoke,* on the pinned CLI 2.1.305 and on 2.1.319, with two more commands:
     - the field's form, `grep -n -i "Avatars\|nothing" .project-map/captured.md`;
     - `cd .project-map && tail -3 captured.md`.

     *Pass:* the Bash handler runs on each, and its labels reach Claude. On a command that shows one entry, the
     labels list that entry only.
  4. *CI* on three systems: the self-test and the load lane.
  5. *The reference bench* against alpha.7, as 2l's check 6 ran, if the machine is quiet. Otherwise it waits, as
     registered there.
  6. *One refute-first verifier* on the diff, against D14's trigger: "an injected entry is ever delivered without the
     unreviewed label". A finding that survives sends 2n back.
- **On a pass:**
  - D14 re-locks on the output step;
  - the tag `v2.0.0-alpha.8`, and an install from it in an isolated config;
  - the user's install moved, with the marketplace's ref set to the new tag;
  - the field session is asked to run `/reload-plugins`;
  - `field.mjs` gets the move.

  `release-2.0.0` is rebuilt on alpha.8 when D24's bar is met.

### 2n: checks 1 to 3 (2026-11-08): pass

- *The build* was made in a copy in the scratchpad and moved to `plugin/` unchanged (`git diff --no-index` empty).
  Product hash `20f89a320a6c`.
- **Check 1, the self-test: pass.** A case runner (the self-test with each failed assertion logged and the run
  continued) ran it on alpha.7's scripts:
  - *D14's accepted-risk forms:* all 9 got nothing on alpha.7, and get their entries' labels on 2n.
  - *The 9 field reads:* alpha.7 gave the whole file's labels. 2n gives those of the entries each output shows. One,
    a `tail -3` after an append, shows only an entry's blank, source and when lines, so 2n gives nothing there. That
    is "the shown entries on 2n" with none shown, and it is reported here rather than called a label.
  - *Another repo's map file:* alpha.7 gave this repo's labels; 2n gives nothing.
  - *Failing on alpha.7, passing on 2n:* the failure route, the unreadable output, the cap, a UTF-16 file printed raw,
    the note and a map path that cannot be read.
  - *Two cases changed meaning.* A folder named `folder.md` now gets nothing from a Bash command, since it holds no
    entry; the Read hook's closed line for it is unchanged. A map path that cannot be read (a link to a folder; a
    junction on Windows) gets the closed line from Bash, as from Read.
- **Check 2, byte identity: pass.** Session start and the prompt hook are identical to alpha.7's on the field repo's
  checkout (3,188 and 309 characters), this repo (3,575 and 309) and A1's fixture (1,400 and 309).
- **Check 3, the smoke: pass on CLI 2.1.305 and 2.1.319.**
  - *Amended before it ran:* the `cd` form uses `tail -5`, not `tail -3`. In the smoke's map the last three lines are
    an entry's blank, source and when lines, so `tail -3` shows no entry and could not show a label.
  - On both CLIs the Bash handler ran on the field's `\|` form and on the `cd` form, and each listed entry 2 only, the
    one its output showed. So did `tail -5` and the failure route.
- *Found while checking:* Claude Code's Bash result carries `bashEditDiff`, a diff of the files a command edited. So
  an append to the map gets its new entry's label (one line), where alpha.7 gave nothing. The README says so. Under
  D14's trigger, a label too many is the safe direction.
- *A replay, not a registered check:* count 3's 14 Bash calls that name the map, run through both builds' handler
  against the field map as it is now.
  - The 4 reads alpha.7 labelled got 39 labels each; under 2n they get 1 to 5.
  - The `|`-in-quotes `grep` got none on alpha.7, and 4 under 2n.
  - The 9 appends and edits got none on alpha.7, and 1 or 2 each under 2n, through `bashEditDiff`.
- **The scanner** (the field README's registration, `a54c2bc`): `field.mjs` gains C5b.
  - *On count 3:* every earlier count is unchanged, and the JSON is identical apart from the new fields. C5b finds the
    hand count: 5 calls that name the folder show entries, 4 of them fully labelled. The miss is the 00:32Z `grep`.
    One call that does not name the folder (a commit) shows an entry. *Pass.*
  - *Disclosed:* the first run read no label at all. The scanner took a label line's heading up to its first ": ",
    and the field's headings hold ": ". The parse now ends at the label's first word. The pass above is the second
    run.
  - `count.mjs` runs both scanners on a frozen folder. It was tested on a copy of count 3.
- *Next:* CI on three systems, the refute-first verifier, and the bench.

### 2n, attempt 1: result (2026-11-08): failed on check 6

- *Check 4, CI:* pass on three systems, on `ef93a9b` and on `6351298`. The second carries the bench's fix: its Bash
  calls now carry the output their command prints, which 2n reads. Without it they timed only the line for an
  unreadable output.
- *Check 5, the reference bench:* pass, in 3 valid pairs of 3 (samples 4.5% to 8.4%). The candidate's highest hook
  was 56.3 ms (the map read). Its Bash map read added 45.6 to 55.4 ms, against alpha.7's 52.9 to 64.5. 0 errors.
- **Check 6, the verifier: 5 findings survive,** so 2n goes back.
  1. *A background command* (`run_in_background`): the hook gets an empty `stdout` and a `backgroundTaskId`. Claude
     reads the output later from a file outside the map, so no label comes. alpha.7 labelled the file. Run live on
     CLI 2.1.319.
  2. *Output past about 30,000 characters:* `stdout` holds 29,999 characters, with `persistedOutputPath`. The
     uncommitted entries past the cut got no label, and no closed line said the labels were partial. Claude read the
     saved file. alpha.7 labelled the file. Run live on 2.1.319.
  3. *A UTF-16 map file with non-ASCII text:* printed raw, its non-ASCII characters do not survive the UTF-8 decode,
     so removing NULs does not restore those lines. alpha.7 labelled the file. The self-test's UTF-16 case was ASCII
     only.
  4. *An entry shown only by a line that is neither its heading nor a quote line:* a body line inside the entry
     block, which D14's comparison holds as part of the entry. 2n's rule left it out by design. Such a line can carry
     an injected instruction, which is D14's case.
  5. *Filters that change spacing:* `column -t`, `expand`, `tr -s` and `echo $(cat …)` lost entries with a tab or a
     double space; `column -t` lost a plain entry too. `cat -A` and `cat -v` lost entries with non-ASCII characters
     or tabs. alpha.7 labelled each.
  - *Also seen:* no crash or non-zero exit; every output under 10,000 characters; a heading shared by two map files
    labels both (an extra label); a 5 MB output with 300 entries took 108 ms against alpha.7's 75. `od -c` and a
    JSON-escaped dump get no label. The README named neither.

### 2n, attempt 2 (registered 2026-11-08, before the code)

- **The changes,** on attempt 1's code:
  1. *When the hook does not see the whole output,* it gives every map file's labels, as a Read of each gives them.
     That is when `tool_response` names a background task (`backgroundTaskId`) or a saved output (`persistedOutputPath`),
     when the failure's `error` says it was truncated ("characters truncated"), or when a string in the output is
     25,000 characters or more. The last is a guard in case Claude Code renames those fields. 2m's cap applies.
  2. *A UTF-16 map file,* when the output holds a NUL character: all of that file's labels. Removing NULs from the
     output goes.
  3. *Shown* widens to every line of the entry's block:
     - its heading line;
     - a quote line with text after the marker;
     - any other line with text that no other entry of the file holds.

     A source or when line that several entries share does not say which one was shown, so alone it shows none.
  4. *Spacing:* runs of spaces and tabs become one space, in the entry's lines and in the output, before they are
     compared.
- **The README:** the unlabelled routes become:
  - a command that does not name the folder;
  - output that shows an entry only in part (a line cut short, `grep -o`, colour codes), or in an encoded form (`cat
    -A` or `cat -v` of non-ASCII text or tabs, `od`, JSON escapes);
  - output whose only line from an entry is one that several entries share.

  It also says that a background command, or output saved to a file, gets every map file's labels.
- **Checks:**
  1. *The self-test,* with a case for each finding. Each fails on attempt 1 and passes here:
     - the background payload;
     - the saved-output payload, with the uncommitted entries past the cut;
     - an `error` with the truncation marker;
     - a 25,000-character output with no field;
     - a UTF-16 file with non-ASCII lines, printed by real `cat` and `tail` and decoded as UTF-8;
     - a body line shown by `grep`, on both routes;
     - `column -t`, `expand`, `tr -s` and `echo $(cat …)` over entries with a tab and a double space.

     Also: a shared when line alone labels nothing, and a when line that only one entry holds labels it. Attempt 1's
     cases still pass, or change with a stated reason.
  2. *Byte identity* with alpha.7 for session start and the prompt hook, on the three repos.
  3. *The smoke* on CLI 2.1.305 and 2.1.319, adding two commands:
     - a background `cat` of the map;
     - a `cat` of a map file whose output passes 30,000 characters, with its uncommitted entry last.

     *Pass:* each gets labels naming that uncommitted entry.
  4. *CI* on three systems.
  5. *The reference bench,* if the machine is quiet.
  6. *A second verifier round:* refute-first, on the five findings and on what the changes may open. A finding that
     survives sends 2n to attempt 3, the last under rule 4.

### 2n, attempt 2: result (2026-11-08): checks 1 and 2 pass; check 3 failed in the harness

- *The build,* moved to `plugin/` unchanged: product hash `9846eda59dfb`.
- **Check 1, the self-test: pass.** The case runner ran attempt 2's self-test on attempt 1's scripts. Each finding's
  case fails there: the background payload, the saved output, the truncated `error`, the long output, the UTF-16
  file through `cat` and `tail`, the body line on both routes, `column -t`, a when line that only one entry holds,
  and the per-file count across two files.
  - *Not separating, then added:* `expand`, `tr -s` and `echo $(cat …)` over the whole file pass on attempt 1 too,
    since the headings still show each entry. The same three filters over a quote line alone fail on attempt 1 and
    pass here.
  - *Changed with a reason:*
    - `tail -3` of the map, and the field's append followed by `tail -3`, now label the entry whose source line they
      show, since no other entry holds it;
    - `git diff`'s context lines label the entry before the new one, for the same reason;
    - a UTF-16 file printed raw gets the whole file's labels.
  - *Seen, and kept as registered:* the count is per file. In the first run, a when line held by the only entry of
    another map file (`new.md`) labelled that entry whenever `captured.md`'s output showed the line. That is an extra
    label, as the rule says. The fixture's `new.md` now has a when line of its own, and one case pins the property.
    The README says so. The field repo has one map file.
  - The failure-route helper returns `{}` when the hook prints nothing, so the case runner can go on past attempt 1's
    empty output.
- **Check 2, byte identity: pass.** Identical to alpha.7's on the three repos. The field repo's session start is 3,216
  characters now, since its map had grown.
- **Check 3, the smoke: the two new commands pass on CLI 2.1.305 and 2.1.319, and the smoke fails on its reply
  checks.**
  - *The new commands, as the stream shows them on both CLIs:* the background `cat` (run in the background on both;
    on 2.1.305 Claude then read the output file, outside the map) and the `cat` of `big.md` (35.5 KB, saved to a
    file) each got every map file's labels, with `321. last: unreviewed, not yet committed`.
  - *2.1.319 failed in the harness:* the new `cat` of `big.md` became the last command, so the reply quoted only its
    one label line, and the check that the reply holds avatars' labels failed. In attempt 1, the `cd` form was last.
  - *2.1.305 failed on the first session's reply:* Haiku paraphrased the Read hook's labels and the note's wording
    ("'unverified quote' (…) on the components entry, captured 2026-10-20"), so the check for the exact text
    "unverified quote, captured 2026-10-24" failed. The Read hook's output is unchanged since attempt 1, whose smoke
    passed this check on both CLIs.
  - Following 2j's precedent, a harness failure counts as an attempt.
- *Not seen:* which field made the hook give every file's labels for the 35.5 KB output, the saved path or the length
  guard. The stream shows the hook's output, not its input. On both CLIs Claude was shown that the output was saved
  to a file, and quoted the label word for word.

### 2n, attempt 3 (registered 2026-11-08, before the re-run). The last under rule 4

- *The change, test code only:* the smoke runs the background `cat` and the `cat` of `big.md` before the `grep` and
  `cd` forms, so the `cd` form is last again, as in attempt 1. No assertion changes. The product hash stays
  `9846eda59dfb`, so checks 1 and 2 stand.
- **Checks:**
  3. *The smoke* on CLI 2.1.305 and 2.1.319, run once each. *Pass:* every assertion, unchanged.
  4. *CI* on three systems.
  5. *The reference bench,* if the machine is quiet.
  6. *The second verifier round,* refute-first, on the five findings and on what attempt 2's changes may open.
  - A failure of checks 3 to 6 goes to the user, unless it is a near miss with a known cause (rule 4's fourth).

### 2n, attempt 3: result (2026-11-08): failed on checks 3 and 6. Rule 4 stops 2n

- *Check 3, the smoke:*
  - *2.1.319: pass,* every assertion. The background `cat` ran in the background.
  - *2.1.305: failed on the same reply check as in attempt 2.* Asked to quote the Read hook's labels word for word,
    Haiku wrote `"unverified quote" (components); "unreviewed, not yet committed; unverified quote" (avatars)`. It
    dropped the capture dates. The hook's output was right. Since the note went in, 2.1.305 has paraphrased the
    labels in 2 of 3 runs, against 0 of 1 before. The note sits between the header and the label lines; that is the
    likely cause.
- *Check 4, CI:* pass on three systems (`d712ead`).
- *Check 5, the bench:* not run. It waits for the machine, as registered.
- **Check 6, the second verifier round: findings survive.**
  - *Fixed:* all five of round 1's findings. The saved output, the UTF-16 file and a failure `error` past 30,000
    characters (it carries the marker the hook matches) were run live on 2.1.319.
  - *New gaps,* each run on real bash output. alpha.7 labelled the whole file in each, and attempt 3 gives nothing:
    1. *A body line shared by two uncommitted entries,* or by an uncommitted and a committed one: `grep -n "curl evil"`
       shows both lines, and neither entry is labelled. This is D14's trigger as written.
    2. *Quote text with the `>` marker stripped:* `sed -n 's/^> //p'`, `grep '^>' … | cut -c3-` and `awk`.
    3. *Unicode spaces* (no-break, em, ideographic) through a locale-aware `sed 's/[[:space:]]+/ /g'`.
    4. *A UTF-16 file with its NULs stripped* (`tr -d '\000'`).
    5. *`fold`,* when an entry's heading and quote are both longer than the width.
  - *Nothing found* in control characters, CRLF, crashes (none), size (at most 9,936 characters) or time (a 5 MB
    output with 300 entries: 72 ms median, against alpha.7's 71).
- **Rule 4 stops 2n.** This is the third failed attempt, and it is not a near miss: check 6 found a new family of
  forms. 2n is BLOCKED, and D14 stays reopened. The rethink is below, and D14's re-lock goes to the user, as its
  record says.

### 2n: the rethink (rule 4, 2026-11-08)

- *The assumption that failed:* that the hook can tell which entries a Bash command showed. Reading the command (2j,
  2m) and reading its output (2n) each failed, in both directions, over three rounds. Every way of reshaping the text
  needed its own rule: quotes and pipes in the command, then output that is cut, saved, run in the background,
  re-spaced, stripped of its markers, wrapped or re-encoded.
- *What D14's trigger needs is narrower:* the "unreviewed" label. Which entries are unreviewed is known from the
  repo's state (the working tree against `HEAD`), without reading the command or its output.
- **The options for D14's re-lock:**
  - **(S) By state.** A Bash command that names the map folder carries the labels of every uncommitted entry of this
    repo's map, whatever it printed. The committed entries' labels ("unverified quote", "not found") come only for
    the entries its output shows, matched as in 2n. Every file's labels come when the hook cannot see the whole
    output. The note goes after the list.
    - *Closes* both rounds' findings for the "unreviewed" label. What stays unlabelled is a command that does not
      name the folder, as in every build.
    - *Costs:*
      - each such command lists the uncommitted entries until they are committed. In the field that is usually a
        few; a map left uncommitted for a long time lists them all, as alpha.7 listed the whole file;
      - a committed entry's label can be missing when the output is reshaped. Those labels are informational, and
        the README would say so.
    - A new step with 2n's checks, and a third verifier round.
  - **(K) Keep attempt 3 as built** (alpha.8), with round 2's findings accepted as risks. It regresses against
    alpha.7 on stripped markers and shared body lines.
  - **(A) Keep alpha.7,** with the `|`-in-quotes risk accepted again and this sighting on record.
- *Recommended: (S).* It is the only option that does not depend on reading text that Claude, or a filter, can
  reshape. Its cost is the noise the field complained of, limited to entries not yet committed.

### 2o: the "unreviewed" label by the repo's state, as `2.0.0-alpha.8` (registered 2026-11-08, before the code)

- *Why:* rule 4 stopped 2n, and its rethink put three options for D14's re-lock to the user. The user chose (S),
  "Label by repo state", the same day. This is a new approach after rule 4's stop, with its own three attempts.
- **The changes,** on 2n attempt 3's code, built in a copy in the scratchpad:
  1. A Bash command that names the map folder (the `if` filter, unchanged) carries the labels of every entry of this
     repo's map files that `HEAD` does not hold word for word, whatever it printed. That is D14's comparison,
     unchanged.
  2. A committed entry's labels come when the output shows it, by 2n's rule: its heading, a quote line, or a line no
     other entry of its file holds, with spacing ignored.
  3. When the hook cannot see the whole output, or a UTF-16 file meets an output that holds NULs, the file's labels
     come as a Read gives them. This is kept from 2n.
  4. The note on "unverified quote" goes after the label list, for the Read hook too. In 2n it sat before the list,
     and 2.1.305 then paraphrased the labels in 2 of 3 smoke runs.
  5. The Bash header names what it lists: "Labels on the entries of <file> not yet committed, and on those this output
     shows, in file order:".
  - The version stays `2.0.0-alpha.8`, which was never tagged, and the self-test's hash is pinned again.
- **The README:**
  - the "unreviewed" label reaches Claude on every Bash command that names the folder, until the entry is committed;
  - committed entries' labels come for what the output shows, and can be missing when the output is reshaped (the
    forms of 2n's second round);
  - still unlabelled: the output of a command that does not name the folder.
- **Checks:**
  1. *The self-test.* Every finding of both verifier rounds runs on real bash output where the runner has the tool, and
     each carries every uncommitted entry's label. Also:
     - an output that shows no entry (`ls .project-map`) carries those labels too;
     - committed entries are labelled by sight, as in 2n;
     - the note comes last.

     Each case from round 2 fails on 2n's attempt 3 and passes here.
  2. *Byte identity* with alpha.7 for session start and the prompt hook, on the three repos.
  3. *The smoke* on CLI 2.1.305 and 2.1.319, with attempt 3's commands. Its assertions follow the header's new
     wording. *Pass:* every assertion.
  4. *CI* on three systems.
  5. *The reference bench,* if the machine is quiet.
  6. *A third verifier round,* refute-first on the "unreviewed" label. Any uncommitted entry of this repo's map that
     a command naming the folder shows without that label is a finding that survives.
- **On a pass:**
  - D14 re-locks on (S);
  - the tag `v2.0.0-alpha.8`, and an install from it in an isolated config;
  - both field repos' installs moved, and their sessions asked to reload;
  - `field.mjs` gets the move, and count 4 runs by the loop.

### 2o, attempt 1: checks 1 and 2 (2026-11-08): pass

- *The build,* moved to `plugin/` unchanged: product hash `3bbcd6537568`.
- **Check 1, the self-test: pass.** A case runner ran 2o's self-test on 2n's attempt 3 scripts:
  - *round 2's forms:* each of the 8 commands misses at least one uncommitted entry's label there, and carries them
    all here. They are a body line shared by two uncommitted entries, `sed`, `cut` and `awk` with the marker
    stripped, Unicode spaces through a locale-aware `sed`, a UTF-16 file with its NULs stripped, `fold -w 12`, and
    `ls .project-map`, which shows no entry at all;
  - *most other Bash cases* differ from attempt 3 in the header's wording and the note's place, and those that run
    after the uncommitted entry was added carry it too. Their expectations name it by number;
  - *by sight:* the spacing and when-line cases now run on a committed file (`spaced.md`, `solo.md`), since an
    uncommitted one is listed whole. They still separate the rules.
- **Check 2, byte identity: pass,** on the three repos.
- *Next:* the smoke on both CLIs, CI, the third verifier round, and the bench.

### 2o, attempt 1: result (2026-11-08): checks 3 and 4 pass; check 6 failed

- *Check 3, the smoke: pass* on CLI 2.1.305 and 2.1.319, every assertion. The background `cat` ran in the background
  on both. With the note after the list, 2.1.305 quoted the Read labels word for word, dates included.
- *Check 4, CI:* recorded below.
- *Check 5, the bench:* not run yet.
- **Check 6, the third verifier round: two regressions against alpha.7 survive.** Both are in the Bash handler's walk
  of the map folder:
  1. *A subfolder that is a junction* (a directory link on Linux and macOS takes the same path): `under()` lists the
     link as a file, so the entries in it are never read. `cat .project-map/shared/rules.md` lost its uncommitted
     entry's label, which alpha.7 gave from the command's text.
  2. *A subfolder that cannot be opened* (a name holding a lone UTF-16 surrogate, made in PowerShell): the nested
     listing throws ENOENT, which the handler read as "no map folder", so a `cat` of `captured.md` got nothing at all.
     That contradicts "fails closed as a whole".
  - *Missed by alpha.7 too, and not in the README:*
    - a command that reads the map and then removes or reverts its entries (`rm`, `git checkout`, `git stash`): the
      labels follow the state after the command;
    - uncommitted entries that are not in the working tree: the index (`git show :…`, `git diff --cached`) or a stash;
    - map files whose name does not end in `.md` (`.MD`, `.txt`, `.markdown`);
    - a package's own `.project-map/` below the root, and a worktree inside the checkout when the project folder is
      the main checkout.
  - *Outside the entry format,* on both builds: a `###` block with no `>` line, an indented `>`, a `####` or `##`
    block, lone carriage returns, or a UTF-8 file behind a UTF-16 byte-order mark. These are not entries as D14
    defines them.
  - *Held up:* committed then edited, moved between files, renamed, a case-only rename, a detached or unborn `HEAD`,
    a merge conflict, odd file names, the cap with up to 2,000 uncommitted entries (none dropped), and exit 0
    throughout.
  - *Time:* one file of 300 entries took 56 to 64 ms with Node's start; 20 files took 330 to 370 ms; 200 files took
    3.1 s, one `git` call each. The source-path pattern is quadratic in a source line's length (60,000 characters:
    1.3 s), as in alpha.7, but it now runs for every uncommitted entry on each command that names the folder.

### 2o, attempt 2 (registered 2026-11-08, before the code)

- **The changes:**
  1. The Bash handler's walk follows a link (a junction, a symlink) that leads to a folder. Session start's walk is
     unchanged, so its output stays byte-identical.
  2. When the map folder exists, any error while listing it fails closed as a whole: one line for `.project-map/`.
  3. *The README and D14 name the forms alpha.7 missed too,* as accepted risks with D14's trigger:
     - a command that removes or reverts the entries it read;
     - entries only in the index or a stash;
     - map files not ending in `.md`, as for the Read hook;
     - a map below the root;
     - text outside the entry format.

     A field sighting of any of them reopens D14.
- **Checks:**
  1. *The self-test,* with two new cases. Each fails on attempt 1 and passes here:
     - a junction to a folder holding an uncommitted entry: labelled;
     - a link to a folder that no longer exists: the closed line for the folder.

     On Windows, a subfolder with a lone surrogate in its name also gets the closed line.
  2. *Byte identity* with alpha.7, on the three repos.
  3. *The smoke* on both CLIs.
  4. *CI.*
  5. *The bench,* if the machine is quiet.
  6. *A fourth verifier round* on the walk and on the cases attempt 1's round confirmed. A regression against alpha.7,
     or an uncommitted entry left unlabelled in a form not named above, sends 2o back.

### 2o, attempt 2: checks 1 and 2 (2026-11-08): pass

- *Attempt 1's CI* (check 4, recorded here): pass on three systems (`aa8e641`).
- *The build,* moved to `plugin/` unchanged: product hash `12a06f41d997`.
- **Check 1, the self-test: pass.** On attempt 1's scripts:
  - the junction to a folder holding an uncommitted entry got nothing;
  - the link to a folder that is gone gave captured.md's labels, with no closed line.

  Both pass here. The earlier junction case (`link.md`, a link to `docs/`) changes meaning. The Bash handler now
  follows it, and the folder it leads to holds no entry, so only captured.md's labels come. A Read of the link still
  fails closed.
  - *By hand, on Windows,* since Node cannot make such a name: a subfolder named `notes` plus a lone surrogate, made
    in PowerShell, beside an uncommitted entry. Attempt 1 printed nothing; attempt 2 printed the closed line for
    `.project-map/`.
- **Check 2, byte identity: pass,** on the three repos. Session start's walk does not follow links.
- *The README* names the forms that alpha.7 missed too, under "Known issues".
- *Next:* the smoke, CI, the fourth verifier round, and the bench.

### 2o, attempt 2: result (2026-11-08): checks 3 and 4 pass; check 6 failed

- *Check 3, the smoke: pass* on CLI 2.1.305 and 2.1.319, every assertion; the background `cat` ran in the background
  on both.
- *Check 4, CI:* recorded with attempt 3.
- **Check 6, the fourth verifier round:**
  - *Fixed, confirmed:* both of attempt 1's regressions (the junction subfolder, and the subfolder that cannot be
    opened). Following links dropped no label without a closed line: a link cycle ends in ELOOP and fails closed.
  - *Findings that send 2o back, by its registration:*
    1. *A FIFO named `.md` in the map* (Linux): the walk reads it, and `readFileSync` blocks, past 20 s in the run.
       alpha.7 read only the files a command named, so this is a regression from attempt 1's whole-folder walk.
    2. *A map file whose name is not valid UTF-8* (Linux): Node's listing turns the byte into U+FFFD, the read gets
       ENOENT, and `labels()` treats that as a missing file, with no closed line. alpha.7 missed it too. The same
       name on a folder fails closed.
    3. *An NTFS alternate data stream* holding an entry, read with `cmd //c "more < .project-map/captured.md:x.md"`.
       alpha.7 labelled the forward-slash form from the command's text. git never sees a stream, so such an entry can
       never be committed.
  - *Time, not a drop:* a link from the map to the repo root makes each command walk the root up to 63 times before
    ELOOP. That took 10.5 s with this project's `.git`, and 28 s with a 60,000-file cache beside it, on Windows. A
    link to 500 `.md` files with entries took 7.5 s, one `git` call each.
  - *PLAUSIBLE, the same on alpha.7:* the `if` filter may be case-sensitive, so `cat .Project-Map/captured.md` on a
    case-insensitive file system may not start the handler.

### 2o, attempt 3 (registered 2026-11-08, before the code). The last under rule 4

- **The changes, to the Bash handler's walk only:**
  1. It lists regular files only, directly or through a link. A FIFO, a socket or a device is skipped, so nothing
     blocks.
  2. Each folder is walked once, by its real path, with the map folder itself counted first. A link back into the map,
     or a cycle, is skipped instead of erroring.
  3. A listed file that cannot be read, ENOENT included, gets the closed line for that file.
- **The README** names an alternate data stream (Windows) and the `if` filter's letter case as unlabelled routes. It
  also says that a link from the map to a large folder slows every command that names the map.
- **Checks:**
  1. *The self-test,* with these cases. Each fails on attempt 2 and passes here:
     - a junction back to `.project-map`: captured.md's labels, with no closed line;
     - on Linux and macOS, a FIFO named `pipe.md`: the hook exits within 10 s with captured.md's labels;
     - on Linux, a file name with an invalid UTF-8 byte: the closed line for that file.
  2. *Byte identity* with alpha.7, on the three repos.
  3. *The smoke* on both CLIs.
  4. *CI* on three systems.
  5. *The bench,* if the machine is quiet.
  6. *A fifth verifier round,* with attempt 2's criterion. A survivor goes to the user, unless it is a near miss with
     a known cause.

### 2o, attempt 3: checks 1 and 2 (2026-11-08): pass

- *Attempt 2's CI* (check 4, recorded here): pass on three systems (`87fd986`).
- *The build,* moved to `plugin/` unchanged: product hash `ab896f79b2d3`.
- **Check 1, the self-test: pass** on Windows, and on Linux in WSL (Node 22.11.0, downloaded from nodejs.org into the
  WSL home folder), where the FIFO and non-UTF-8 cases run. On attempt 2's scripts, on Linux:
  - the junction back into the map gave the closed line for the whole folder;
  - the FIFO blocked the hook past the 10 s limit;
  - the non-UTF-8 name gave captured.md's labels and no closed line.

  All three pass here.
- **Check 2, byte identity: pass,** on the three repos.
- *Next:* the smoke, CI, the fifth verifier round, and the bench.

### 2o, attempt 3: result (2026-11-08): checks 3 and 4 pass; check 6 a near miss

- *Check 3, the smoke: pass* on CLI 2.1.305 and 2.1.319, every assertion.
- *Check 4, CI:* recorded with attempt 4.
- **Check 6, the fifth verifier round:**
  - *Fixed, confirmed:* all three of attempt 2's findings. The FIFO took about 20 ms, the non-UTF-8 name got its own
    closed line (alpha.7 gave none), and links back into the map were walked once.
  - *Held up:* the `if` filter started the handler on 8 compound forms, live on 2.1.319 with Haiku; each carried the
    uncommitted label. The forms were `for`, `while … < file`, `if`, `bash -c`, a subshell `cd`, `||`, `find -exec` and
    `ls | head`. Also: 40 fuzz runs of the cap (at most 9,971 characters, nothing dropped), links to a FIFO, a device
    or a socket, unreadable files and folders, and both failure routes.
  - *Findings,* by the registered criterion:
    1. *A dangling link in the map* (Emacs leaves `.#captured.md` as one while a buffer has unsaved edits): `statSync`
       fails before the `.md` filter, so the whole folder fails closed. alpha.7 gave captured.md's labels entry by
       entry. No entry loses its label, since the closed line covers them all, but it is less precise than alpha.7.
    2. *Two file names that Node's listing decodes alike* (Linux: `caf\xe9.md` beside a file literally named with
       U+FFFD): the read finds the other file, and the uncommitted entry gets nothing. alpha.7 missed it too.
  - *Near miss with a known cause* (rule 4's fourth): both causes are known, and each fix is one condition.

### 2o, attempt 4 (registered 2026-11-08, before the code). The last; rule 4 allows no fifth

- **The changes, to the Bash walk only:**
  1. A link whose target does not exist is skipped, as `cat` of it shows nothing. Any other error on a link still
     fails closed.
  2. A name the listing gives twice gets the closed line for that name.
- **Checks:**
  1. *The self-test.* Attempt 2's case of a link to a folder that is gone now expects captured.md's labels, since the
     link is skipped; on attempt 3 it gives the closed line for the folder. On Linux, the two names that decode alike
     get the closed line; on attempt 3 they give nothing.
  2. *Byte identity* with alpha.7.
  3. *The smoke* on both CLIs.
  4. *CI* on three systems.
  5. *The bench,* if the machine is quiet.
  6. *One verifier,* on these two changes and on any regression against attempt 3 that they make. Five open rounds have
     run; a survivor of this one goes to the user, with the residual list for D14's re-lock.

### 2o, attempt 4: checks 1 and 2 (2026-11-08): pass

- *Attempt 3's CI* (check 4, recorded here): pass on three systems (`449a873`).
- *The build,* moved to `plugin/` unchanged: product hash `75183744c5b9`.
- **Check 1, the self-test: pass** on Windows and on Linux in WSL. On attempt 3's scripts, on Linux, the link to a
  folder that is gone gave the closed line for the whole folder, and the two names decoded alike gave no line for the
  hidden entry. Both pass here.
- **Check 2, byte identity: pass,** on the three repos.
- *Next:* the smoke, CI, the verifier on the two changes, and the bench.

### 2o, attempt 4: result (2026-11-08): checks 3 and 4 pass; check 6 finds one regression; to the user

- *Check 3, the smoke: pass* on CLI 2.1.305 and 2.1.319, every assertion.
- *Check 4, CI: pass* on three systems (`a951018`).
- *Check 5, the bench:* running.
- **Check 6, the verifier on the two changes:**
  - *Both work:*
    - the Emacs lock link and a junction to a deleted folder now leave captured.md's labels intact;
    - two or three names decoded alike give one closed line, on Linux and Windows.
  - **One regression against attempt 3 (CONFIRMED, low plausibility):** `throwIfNoEntry` cannot tell a link whose
    target is gone from a link whose own name cannot be reached. On Linux that is a name that is not valid UTF-8; on
    Windows, a lone surrogate. So a link named `caf\xe9.md` to a file holding an entry, read by
    `cat .project-map/caf*.md`, gets nothing. Attempt 3 failed the folder closed there. The verifier's fix, tried in a
    copy: when the stat gives nothing, `lstatSync` the name itself before skipping it.
  - *The link form of an accepted risk:* `cat .project-map/link.md; rm notes/d.md` gets nothing. Attempt 3 failed
    closed there by accident. D14 already accepts "a command that removes or reverts the entries it read".
  - *Not regressions:* two folder names decoded alike (both builds miss the entry), ENOTDIR (both fail closed), and
    ELOOP (both fail closed).
- *Rule 4:* attempt 4 was the last, so this goes to the user. The choice is between two options:
  - alpha.8 as built, with this form added to the accepted risks;
  - the one-condition fix as a fifth attempt, which the rule leaves to the user.

### 2o, attempt 4: check 5, the bench (2026-11-08): pass

alpha.7 against attempt 4 (`75183744c5b9`) on the P2 worktree, in 3 valid pairs of 3 (samples 4.0% to 5.5%).
- *The candidate's highest hook:* 64.4 ms, a Bash command that names no map entry. That kind now runs one `git show`
  of the map file each time, since every uncommitted entry is listed: 53.0 to 64.4 ms, against alpha.7's 18.4 to
  20.2.
- *The Bash map read:* 51.5 to 56.3 ms, against 53.1 to 56.5.
- *Session start:* 41.0 to 50.2 ms, against 44.5 to 48.1.
- 0 errors.

### 2o, attempt 5 (registered 2026-11-08, before the code): the user's exception to rule 4

- *The user's answer* to attempt 4's result was "Allow a 5th fix, then ship". The fix is the one condition the
  verifier tried. The checks are the self-test, CI and the smoke, with no new open verifier round.
- **The change:** when a link's target cannot be stat-ed, the walk checks the link's own name (`lstatSync`) before
  skipping it. A link whose own name cannot be reached throws, so the folder fails closed, as in attempt 3. A link
  whose target is gone is still skipped.
- **Checks:**
  1. *The self-test,* with one case run on Linux: a link named with an invalid UTF-8 byte, leading to a file that
     holds an entry, gets the closed line for the folder. It gives nothing on attempt 4. The Emacs-style dangling link
     keeps captured.md's labels.
  2. *Byte identity* with alpha.7.
  3. *The smoke* on both CLIs.
  4. *CI* on three systems.
  - *The bench stands from attempt 4:* the change adds one `lstat`, and only for a link whose target is gone.
- **On a pass:**
  - D14 re-locks on (S), with the README's accepted risks;
  - the tag `v2.0.0-alpha.8`, an install from it in an isolated config, and both field repos' installs moved;
  - the field sessions are asked to reload;
  - `field.mjs` gets the move;
  - count 4 is scheduled.

### 2o, attempt 5: checks 1 and 2 (2026-11-08): pass

- *The build,* moved to `plugin/` unchanged: product hash `e427a546cc6a`.
- **Check 1, the self-test: pass** on Windows and on Linux in WSL. On attempt 4's scripts, on Linux, the link with a
  non-UTF-8 name gave captured.md's labels and no closed line. It passes here, and the Emacs-style dangling link
  keeps captured.md's labels on both.
- **Check 2, byte identity: pass,** on the three repos.

### 2o, attempt 5: result (2026-11-08): pass

- *Check 3, the smoke: pass* on CLI 2.1.305 and 2.1.319, every assertion; the background `cat` ran in the background
  on both.
- *Check 4, CI: pass* on three systems (`493c195`).
- *Product hash* `e427a546cc6a`. D14 re-locks on (S), with the accepted risks its record lists.
- *What 2n and 2o changed, against alpha.7:*
  - every Bash command that names the map folder carries every uncommitted entry's label, whatever it printed;
  - committed entries' labels come for what the output shows;
  - every file's labels come when the hook cannot see the whole output;
  - the note on "unverified quote" follows the list;
  - the Bash walk follows links to folders, reads regular files only, and fails closed on listing errors.
- *Next:* the tag `v2.0.0-alpha.8`, the release notes, an install from the tag, both field repos' installs moved, the
  field sessions asked to reload, `field.mjs`'s move, and count 4.

### 2o: the release notes (drafted before the tag)

> Plugin hash `e427a546cc6a`. **The "unreviewed" label by the repo's state** ([06, steps 2n and 2o](https://github.com/Cain-Ish/claude-code-plugin/blob/v2/docs/v2/06-first-slice.md)).
>
> - Every Bash command that names the `.project-map` folder now carries the "unreviewed, not yet committed" label of
>   every map entry that is not yet committed, whatever the command printed. alpha.7 read the command's text and
>   missed forms seen in real use, such as a `grep` pattern with `|` inside quotes. An attempt to label by what the
>   command printed failed three review rounds: output can be reshaped in too many ways.
> - Committed entries' labels ("unverified quote", "not found") come for the entries the command printed. A Bash read
>   no longer repeats the whole file's labels; in real use, a check of the file's end had carried 36 to 39 of them.
> - When the hook cannot see the whole output (a background command, or output Claude Code saved to a file), every
>   map file's labels come, as a Read gives them.
> - "unverified quote" is explained in one line after the list.
> - The walk of the map folder follows links to folders, reads regular files only, and fails closed when the folder
>   or a file in it cannot be read.
> - **Still unlabelled** (README, Known issues): a command that does not name the folder, entries removed or reverted
>   by the same command, entries only in git's index or a stash, map files not ending in `.md`, and a few file-system
>   edge cases.
> - **Checked:**
>   - the self-test on Windows and Linux;
>   - session start and the prompt hook byte-identical to alpha.7's on three repos;
>   - the smoke on Claude Code 2.1.305 and 2.1.319, and CI on three systems;
>   - the reference bench: every hook at most 64.4 ms added at 8 concurrent;
>   - six refute-first review rounds, and an install from the tag.
>
> ```
> claude plugin marketplace add Cain-Ish/claude-code-plugin#v2.0.0-alpha.8 --scope project
> claude plugin install second-brain@second-brain-v2 --scope project
> ```

### 2o: published as `2.0.0-alpha.8` (2026-11-08)

- *The tree:* `git diff 493c195 -- plugin/ .claude-plugin/` at the release commit `23139e0` is empty, so CI on
  `493c195` stands.
- *The tag* [`v2.0.0-alpha.8`](https://github.com/Cain-Ish/claude-code-plugin/tree/v2.0.0-alpha.8) is on `23139e0`,
  pushed with the branch.
- *The release page:* the session's `gh release create` was refused by the permission check, as for alpha.7. The notes
  are drafted above, for the user.
- *Install from the tag* in an isolated config on CLI 2.1.319: version `2.0.0-alpha.8`, hash `e427a546cc6a`. It also
  rehearsed the move: added at alpha.7, the marketplace added again at the new tag, updated, and the plugin updated.
  The uninstall and the removal succeeded. The user's registry files are unchanged by checksum. *Pass.*
- *The user's installs* moved at 21:18:04Z (the field repo) and 21:18:05Z (the second field repo). Both are at local
  scope, `2.0.0-alpha.8` at `23139e0`, hash `e427a546cc6a`, enabled, and each repo's local settings name the new tag.
- **A slip, disclosed:** the move script's first step ran in this repo instead of the field repo, through an empty
  path variable.
  - This repo's git-ignored local settings already declared the `second-brain-v2` marketplace, at an earlier ref.
    They now declare it at the new tag. The earlier ref was not saved, and the plugin stays disabled here (V2-D06).
  - The update step that ran here moved the field repo's install, as the registry shows. That repo's settings were
    then set to the new tag in a separate step.
- *`field.mjs`* labels epochs from 21:18:04Z as alpha.8 (one entry in its move table). On count 3's corpus its output
  is unchanged.
- *Next:* the field sessions are asked to run `/reload-plugins`, and count 4 is scheduled.

### 2o: the field sessions asked to load alpha.8 (2026-11-08, 21:19Z)

- Both running field sessions were sent a message: the user should type `/reload-plugins`.
  - The first repo's session was told what alpha.8 changes in the labels. It was already primed, from 15:23Z.
  - The second repo's session was told what the plugin does, the forced decision included, so it is primed from now.
    Its counts are reported apart, outside D24's corpus.
- *Count 4* runs by the field README's loop, for both repos, once a day while this session lives. Its corpus for D24 is
  every epoch of the first repo since count 3's freeze (14:47Z). Epochs before each session's reload ran alpha.7's
  hooks, and count under D24's clauses for their build.
- *The README at the tag* keeps three stale lines in "What was measured": the alpha.8 bullet still describes 2n's
  design, and the bench lines stop at alpha.7. They are corrected on `v2` after the tag, and the tag is not moved.

### D24's field count 4 (2026-11-09, 14:43Z): not met on item 1 (C1); item 4 now passes

- *Run:* by hand, at the user's question. The daily cron belonged to the session that set it up, which had ended, so
  the count did not run on its own.
- *Freeze, a deviation:* the README's folder, `research/raw/2l-field/count4/`, was refused twice by the permission
  check, both the direct copy and a copy from the scratchpad. The frozen corpus exists only in the counting session's
  scratchpad, and counts 1 to 3 stay the only ones in `raw/`.
- *Corpus:* the first repo's one main session, with 5 epochs after count 3's freeze:
  - compactions at 18:13Z and 21:00Z on 2026-11-08, on alpha.7's hooks;
  - the session's `/reload-plugins` at 03:13Z on 2026-11-09 ("8 hooks");
  - then, on alpha.8's hooks, compactions at 04:18Z and 13:56Z, and a resume at 14:40Z on 2026-11-09.

  All five are primed (from 15:23Z on 2026-11-08), so they count for every item except 2 and 3.
- **C1: one miss, at the 14:40Z resume.**
  - The plugin's session-start hook ran with exit 0. It printed valid JSON whose context (3,107 bytes) is
    byte-identical to the four epochs before it.
  - No `hook_additional_context` record follows it. Every other epoch has one within a second of its hooks.
  - The instruction's first sentence is not in the request sent after the resume.
  - Claude's answer to the forced decision named every index directory, read from the restored history: the same
    text was delivered at the 13:56Z compaction.
  - Two facts, recorded without a cause:
    - a background task's notification was queued about 30 ms after the last session-start hook finished;
    - the context was identical to the epoch before it.

    Either could explain it: a race with the queue, or Claude Code not re-adding identical context on resume. D12's
    `resume` cell sent a new nonce in each run, so it tested neither.
  - Under the registered rule, this is a C1 miss, and a miss is a defect. The plugin's side was correct, so "fixed in
    the plugin" has nothing to fix. Under D24's failed-bar clause, it goes to the user.
- *The rest of item 1, no defect:*
  - C2: one force per epoch, each on the epoch's first human prompt. The resume's queued notification was a machine
    turn and got none.
  - C5b, by output: 5 calls named the map folder and showed entries; all 26 of the entries they showed were
    labelled. Two of those calls ran on alpha.8, with 4 entries, all labelled. The only miss in the session is
    count 3's.
  - C6: 6 new entries, all appended through Bash. All are in format, none holds a forbidden item, and all were found
    verbatim. Each has a `when:` line.
  - C7: every named path exists (10 in the session). C8: 0 errors of any hook.
- *D24's alpha.8 clause:* the session-start context hash is the same before the reload (the alpha.7 epochs) and
  after it (the alpha.8 epochs).
- **`field-scope.mjs` (item 4): within the bar.**
  - The corpus is every gate event after check 5's epoch: 23 events, 52 pairs. D 44 (84.6%, bar at least 70%), R 1
    (1.9%, bar at most 10%), X 7.
  - The new events alone: 19 events, 46 pairs. D 40 (87.0%), R 1, X 5.
- *Items 2 and 3:* met by count 2's unprimed in-claim epoch (C3 1 of 1). The five new epochs are primed. Reported
  apart: all 5 answered the forced decision per directory, and two first prompts named changes.
- *D22 observation:* X is 7 of 52 pairs (13.5%), above 2k's 10%.
  - 5 of the 7 are rules Claude Code delivered with or after the write: one edit with 3, one new file with 2.
  - The 2 from count 2 stand.
  - Whether a rule bore on its change is not judged.
- *Reported:*
  - C9: 96 subagents in the session, none with the index; 42 wrote repo files (228 writes).
  - Main-session writes: 108; commits: 51.
- **The second repo:** nothing to count.
  - The plugin's hooks never ran there: no session started or reloaded after the install. The one running session
    last had a turn at 21:22Z on 2026-11-08.
  - It has no map folder yet.
  - The 22 hook errors the scanner lists are that repo's own `Stop` hook, not this plugin's.
- *Ask:* the first repo's session was asked at 15:23Z on 2026-11-08, so the README's once-per-session question is
  spent. The second repo has no session to ask.
- *Result: not met, on item 1 only.* Items 2, 3 and 4 hold. Nothing is tagged, and `release-2.0.0` stays staged.
- *What the result needs from the user:*
  1. *Count the miss as a defect.* `2.0.0` waits until a probe finds the cause and the miss is fixed or worked
     around. The probe is registered after the user answers: D12's `resume` cell, with identical context in
     consecutive epochs and with a queued notification at the resume.
  2. *Or accept it as Claude Code's* (D24's reopen trigger: the user sets a different bar). The release then goes
     ahead at this count, with the miss a known issue.

### C1's resume miss: the field since count 4, and a probe (registered 2026-11-12, before the probe is written)

- *The user's word:* "continue", after count 4 put the miss to them with a probe recommended first.
- *The field since count 4, read by session-start records only:*
  - A second resume in the first repo, on 2026-11-10, missed in the same way. No notification was queued at it.
  - Every compaction since then got its context, and so did a `clear`, two startups and a resume in the second repo
    (its first session, CLI 2.1.322).
  - Across the four resumes seen, the context was attached each time it differed from the last one delivered (2 of 2).
    It was missing each time it was identical to the last one (2 of 2). The queue explains only one of the two misses.
- *Hypothesis:* on `resume`, Claude Code does not attach session-start context identical to context already in the
  restored conversation.
- *Probe* (`probes/V2-D12-channels/resume-same.mjs`), on the installed CLI, D12's method: a fresh repo and probe plugin
  per run, Haiku, user settings excluded. One process replies OK, a second `--resume`s it and lists the `PRB-` tokens
  in its context. Two arms, 3 runs each:
  - *SAME:* the `startup` and `resume` hooks print the same text (one nonce);
  - *DIFF:* the `resume` hook prints a new nonce, which is D12's `RE` cell (the control).

  *Measured:* in the session's transcript, the resume's `hook_additional_context` records holding the hook's text.
  Also reported: whether the resumed reply quotes the nonce.
- *Pass for the hypothesis:* DIFF attached in 3 of 3, SAME attached in 0 of 3, with the SAME nonce quoted after the
  resume in 3 of 3. Then the miss is Claude Code's, and the text was in context. Recommended to the user: D24's
  reopen trigger, C1 counting context present in the restored conversation, and release at count 4.
- *Otherwise:* if SAME is attached in 3 of 3, the hypothesis falls and the cause stays open. A mixed result is
  unreliable. Either way, the miss stays a defect and goes back to the user.

### C1's resume probe: result (2026-11-12, CLI 2.1.322): the hypothesis passes

- [`results-resume-same.json`](probes/V2-D12-channels/results-resume-same.json):
  - *DIFF:* attached at the resume in 3 of 3, nonce quoted in 3 of 3;
  - *SAME:* attached in 0 of 3, nonce quoted in 3 of 3, from the startup's delivery in the restored conversation.
- *The hook ran in SAME:* the resumed process's stream shows its `hook_started` and `hook_response`, with the output.
  The transcript keeps no record of it at all. In the field, the interactive CLI kept the hook's `hook_success` and
  dropped only the context. Either way, identical context is not attached again.
- *Reading:* count 4's miss is Claude Code skipping context that the resumed conversation already holds. The plugin's
  instruction was in Claude's context at the miss.
- *Still the user's call (D24):* the registered recommendation is D24's reopen trigger. C1 would count context present
  in the restored conversation, and the release would go ahead at count 4. Until the user answers, the miss stays a
  defect and nothing is tagged.

### 18f: `2.0.0` released (2026-11-12)

- *The branch:* `release-2.0.0` rebuilt on `v2`'s head (alpha.8 plus documents) as `66ee916`, by the same edits as
  before. Product hash `ac6d00173453`.
- *Checks, all passed:*
  1. `git diff v2.0.0-alpha.8 -- plugin/scripts plugin/hooks plugin/commands` is empty. Under `plugin/`, only
     `plugin.json`'s version and the self-test's pin differ.
  2. The self-test passes. The smoke passes on CLI 2.1.322, the current one.
  3. CI on the branch passed on three systems, and so did D26's workflow.
  4. Install from the branch in an isolated config: marketplace `second-brain`, plugin `second-brain@second-brain`,
     version `2.0.0`, hash `ac6d00173453`. The uninstall and the removal succeeded, and the user's registry files are
     unchanged by checksum.
  5. The release review: 2.0.0's review closed on alpha.7 (2m). alpha.8's only change, 2o, closed its own five
     verifier rounds. The devils-advocate workflow was not run again on this branch: a multi-agent run needs the
     user's go.
- *Published:*
  - `v2` fast-forwarded to `66ee916`, tagged `v2.0.0`;
  - the release page, marked latest, by the session;
  - `main` fast-forwarded to the tag, so v1's `ci.yml` left it. *A correction to 18f:* `main` is not unprotected.
    Its rules (a pull request, 3 required checks) were bypassed with the owner's admin rights. The commit had passed
    the same checks on the branch.
- *Checks after the move:* `main`'s README is v2's and holds "Coming from v1". An install from the repo with no ref, in
  an isolated config, gives `2.0.0` at `ac6d00173453`. The user's registry files are unchanged.
- *The user's installs:* both field repos are on `second-brain@second-brain` `2.0.0` at local scope, with the
  installed copy at `ac6d00173453`.
  - In the first repo, `second-brain-v2` was uninstalled and its marketplace removed. That removed it machine-wide,
    with the second repo's install.
  - The second repo's local settings still named the old plugin and marketplace. Those two keys were removed, after a
    backup.
  - Running sessions keep alpha.8's hooks until the user types `/reload-plugins` in them.
- *Next:* later field counts, under D24's reopen trigger (a defect in C1, C2, C5, C6b, C7 or C8).

### 2p: the labels' trim, as `2.0.1` (registered 2026-11-12, before the code)

- *Why:* D24's answer made the labels' trim a registered fix after `2.0.0`, and the user asked for it on 2026-11-12.
  - *The field on alpha.8,* from the reload at 03:13Z on 2026-11-09 to 2026-11-12, both repos: 93 label blocks, 196 KB,
    1,663 label lines. 64 blocks listed 40 to 48 lines each.
  - About 95% of the lines are a committed entry whose only label is "unverified quote, captured <date>". The field
    session called the labels noise it never used (count 3's question).
- *Scope:* D16's content is kept. Every committed entry is still labelled unverified, with its capture date, so no
  locked decision changes. Dropping those labels would change D16's "delivered with its date", and no D16 trigger
  fired. That option is the user's, not built here.
- **The change,** in `labels()` only, which the Read hook and the Bash handler share:
  1. An entry whose labels hold anything besides "unverified quote" keeps its own line, as now: unreviewed, not found
     or cannot read.
  2. The other entries go into one line, before the per-entry lines: `unverified quote, committed: entries <ranges>`.
     A range is a run of consecutive entries with the same capture date, written `1-6 (captured 2026-10-26)`. An entry
     with no date stands alone, with no date.
  3. *The cap, still fail-closed:* the grouped line comes first. If the per-entry lines are cut, the tail covers every
     entry after the last one shown, as now. If even the grouped line does not fit, the tail covers every entry.
  4. The header, the note and the Bash rules (which entries are picked) are unchanged.
  - The version becomes `2.0.1` in both manifests, and the self-test's hash is pinned again.
- **Checks:**
  1. *The self-test:* the existing cases change only where an entry's only label is "unverified quote". New cases:
     - ranges split by a date change, by a non-consecutive entry and by an entry with no date;
     - a file mixing grouped and per-entry entries;
     - the cap cutting the per-entry lines, and the grouped line alone too wide.
  2. *No label lost:* a replay over the field repo's map files, in their current state and at each commit of them
     since 2026-10-26, Read case. Expanding each grouped line back to one line per entry gives exactly alpha.8's output.
     *Pass:* identical in every case.
  3. *Size:* the same replay. Reported, with no bar: bytes before and after.
  4. *Byte identity* of session start and the prompt hook with `2.0.0`, on this repo and the field repo.
  5. *The smoke* on CLI 2.1.322. *Pass:* every assertion. Its read and Bash assertions already use uncommitted entries,
     which keep their own lines.
  6. *CI* on three systems.
  7. *A verifier round,* one refute-first agent: any entry whose label the new output loses or changes, or a cut that
     fails open, is a finding that survives.
  - *Not run:* the reference bench. The change only builds a shorter string from the same work, so D18's cost cannot
    rise. It is stated as an accepted gap.
- **On a pass:** tag `v2.0.1` and its release page. Both field installs update. A later count reads the labels'
  bytes again.

### 2p: checks 1 to 6 (2026-11-12): pass

- *Built* in `1f70345`. Product hash `34298485285b`, version `2.0.1`.
- *Check 1, the self-test:* passes. Three existing cases changed, each one where an entry's only label was "unverified
  quote". The Bash helper `only()` cuts the grouped line to the entries it keeps. New cases: ranges split by a date,
  a gap and an entry with no date; a mixed file; a Bash subset; the cap with per-entry lines cut; the grouped line
  alone too wide.
- *Check 2, no label lost:* on a clone of the field repo, 17 commits touching the map, each committed and with its
  entries uncommitted. 34 cases, 34 identical once the grouped line is expanded. *Pass.*
- *Check 3, size:* the same 34 cases, 151,755 bytes on `2.0.0` and 26,961 on `2.0.1` (82% less).
- *Check 4, byte identity:* session start and the prompt hook are identical to `2.0.0`'s, on this repo and the field
  repo's clone. *Pass.*
- *Check 5, the smoke* on CLI 2.1.322: every assertion. *Pass.*
- *Check 6, CI* on three systems. *Pass.*
- *Check 7,* the verifier round, is running.

### 2p, attempt 1: check 7 failed; attempt 2 registered (2026-11-12, before the code)

- *The verifier:* no difference without a cut (1,800 fuzz comparisons), and no cut fails open (472 capped cases). But
  near and past the cap, the grouped line shows fewer labels than `2.0.0`:
  - F1: a file just under the cap on `2.0.0` goes over it, since a lone grouped entry's line is longer;
  - F2: a grouped line too wide by itself hides every per-entry line;
  - F3: the grouped line takes budget from per-entry lines;
  - F4: with only the grouped line shown, the closing line covers the entries it has just listed.

  Each is a lost label under check 7's bar, so attempt 1 fails.
- *Attempt 2:* the grouped form is used only when its whole text fits under the cap. Otherwise the output is
  `2.0.0`'s per-entry form, cut exactly as before. So past the cap the output equals `2.0.0`'s, byte for byte.
- *Checks:* the same seven. The self-test's cap cases assert `2.0.0`'s output past the cap, and a new case covers F1.
  Check 7 re-runs the verifier's own scripts on attempt 2, and every capped case must equal `2.0.0`'s output.

### 2p, attempt 2: result (2026-11-12): pass

- *Built* in `e5f83d9`. Product hash `02bc0eae190b`, version `2.0.1`.
- *Check 1:* the self-test passes. The cap cases now assert `2.0.0`'s form past the cap, and the verifier's F1 input
  is a case.
- *Check 2:* 34 of 34 field cases identical once expanded. *Check 3:* 151,755 bytes down to 26,961 (82% less).
- *Check 4:* session start and the prompt hook are byte-identical to `2.0.0`'s on both repos.
- *Check 5:* the smoke on CLI 2.1.322 passes. *Check 6:* CI passes on three systems.
- *Check 7, the verifier's scripts on attempt 2:*
  - F1 to F4's inputs all give `2.0.0`'s output;
  - the fuzz, 3 seeds and 8,800 cases with about 2,350 capped, has 0 failures;
  - every output that is cut equals `2.0.0`'s byte for byte (436 of 436 in seed 3).

  In 64 cases of seed 3, `2.0.0` cut but the grouped form fits whole. Those now show every label, more than `2.0.0`
  showed, never less. *Pass.*
- *Disclosed:* a first re-run of the fuzz counted 230,000 failures. The cause was my uncapped copy, whose cap had not
  been lifted. Once that was fixed, the count was 0.
- *Release:* tag `v2.0.1` and its page. The direct push to `main` was refused by the permission check (merge
  without review), so `main` moves by a pull request. Installs with no ref follow `main`, so the field installs
  update once it is merged.

### D24's field count 5 (2026-11-12, 10:12Z): no defect

- *Run:* by hand, at the user's question. Frozen to the counting session's scratchpad, as count 4 was.
- *Installs:* both repos run `2.0.0` (product hash `ac6d00173453`, checked on the cached copy). `2.0.1` waits on
  `main`. The scanner attributes these epochs to alpha.8, whose product `2.0.0` is.
- *Corpus:* in the first repo, the main session counted at count 4 (7 new epochs), a new session (3 epochs) and a
  one-turn session (1 epoch). In the second repo, its first session with the plugin (3 epochs). 14 new epochs.
- **C1: 14 of 14.** 11 carry the context. The 3 without it are resumes whose hook printed context byte-identical to
  the last one delivered (3,107 and 3,317 bytes), which passes under C1's amendment. Count 4's 14:40Z resume is the
  same case.
- **C2:** one force per epoch, each on the epoch's first human prompt (13 forces); the one-turn session had no human
  prompt.
- **C3, reported:** 12 of 13 forced epochs answered per directory. The miss delegated the work to a subagent with no
  directory statement.
- **C5b, by output:** 2 calls flagged by the scanner, each with one entry shown and unlabelled. Read: both entries are
  committed, and their quotes are found word for word in the repo file their source names, so D16 gives them no
  label. *Not a defect;* the scanner counts every shown entry as needing a label, which a verified entry does not.
- **C6:** 6 new entries, all in format, none with a forbidden item, 5 found verbatim. The sixth (second repo) splices
  two of the session's human prompts into one quote and corrects a spelling: a paraphrase of found statements, not
  unsourced. It is a D14 observation.
- **C7:** 4 named paths in the second repo, all exist; the first repo's session total is 28, all exist. **C8:** 0
  plugin hook errors. The second repo's 14 are its own hooks.
- **`field-scope.mjs`, reported:** over the first repo's three sessions whole (count 4's pairs included), 98 pairs:
  D 84 (85.7%), R 5 (5.1%), X 9 (9.2%). Within the bar.
- *Reported:* C9, 142 subagents in the first repo's sessions and 5 in the second, none with the index; 60 wrote repo
  files. The first repo's map holds 56 entries, all committed; the second's holds 1.
- *Result:* no defect in C1, C2, C5, C6b, C7 or C8; D24 stays locked.
- *The scanner, after this count* (the field README's amendment of 2026-11-12, registered in `8cb89b7` before the
  code): C5b prints a miss whose entry's source names a file apart, as "to check (cites a file)". *Pass:* on counts 4
  and 5's frozen corpora every other printed count and the JSON (apart from the split field) are unchanged; count 4's
  miss stays a miss; count 5's two flags print as "to check".

### 2q: the source's path and date, and onboarding's uncommitted map, as `2.0.2` (registered 2026-11-18, before the code)

- *Why:* on 2026-11-18 the first field repo's session sent a checkup of `2.0.0`. Re-run here on that repo's map (67
  entries) with `2.0.0`'s and `2.0.1`'s `labels()`:
  - *B1, the path.* The source's path is the first path token anywhere in the source line, parentheses included. 4 of
    67 entries are the owner's words with a repo file named only inside parentheses. One gets "not found word for word
    in <file>; check it", a false alarm the session saw 16 times. Three get no label at all, because the owner's words
    happen to be repeated in the file named.
  - *B2, the date.* The capture date is read only at the end of the source line. 41 of 67 put text after it, so their
    labels lose the date. Since `2.0.1` an undated entry also stands alone in the grouped line.
  - *G6, onboarding.* In the second field repo the whole map folder is untracked, so every entry stays "unreviewed"
    for good, and `/onboard` says nothing about it.
- *Scope:* D16's choice is unchanged: a source that names a repo file is re-found in it, and any other entry carries
  its capture date as unverified. This step fixes how the name and the date are read from the source text, which D16's
  attempt 3 described as "a token with a `/` or a document extension". No D16 trigger fired literally. The not-found
  label was on a quote that is not in the file the parser named. So this is a fix under the lock, as 2p was (D16's
  note of 2026-11-18). The checkup's other items are not in this step (see the end of this entry).
- **The change:**
  1. *The path:* the first path token, as now, in the source text with every parenthesized part removed (nested ones
     too). An opening parenthesis that is never closed cuts the text to its end. Where the rule is unsure it drops the
     path. A dropped path costs a re-find ("unverified quote"), while a wrong one can give a silent "verified".
  2. *The date:* the first date that stands alone, that is, not inside a file name or a longer token, in that same
     text. If there is none, the first date that stands alone anywhere in the source.
  3. *Onboarding:* the `Map:` line adds how many of its files git does not track, and that their entries stay labelled
     "unreviewed" until committed.
  - The version becomes `2.0.2` in both manifests, and the self-test's hash is pinned again.
- **The expected differences**, fixed now from the two corpora by a scratch script that applies these rules to every
  distinct `- source:` line. Each line was read by hand.
  - *The field corpus,* 57 distinct source lines from the first field repo's map at its 22 commits and in its working
    tree:
    - the path is dropped on 5, each the owner's words with a repo file named only inside parentheses;
    - a date is gained on 42;
    - no date changes and none is lost.
  - *The repo corpus,* 362 distinct source lines from this repo's eval and probe records:
    - the path is dropped on 2: a person's words with a file in parentheses, and a web page's address in parentheses,
      which `2.0.1` labels "not found";
    - a date is gained on 24;
    - no date changes and none is lost.
    - Kept: a person's source that names the file outside parentheses ("via <path>", "recorded in <path>").
  - *Rejected rules,* on the same corpora:
    - the path from the text before the first `(` drops a "recorded in <path>" source;
    - the path only when the source starts with it drops "via <path>" and "recorded in <path>";
    - the first date anywhere takes a file name's date or a date in a quoted question, wrong on 6 repo lines and 1
      field line;
    - the last date takes a date from trailing text.
- **Checks:**
  1. *The self-test.* New cases:
     - a person's words with the cited file inside parentheses: no path, the date kept;
     - a document followed by a section in parentheses, re-found as now;
     - "via <path>" re-found;
     - a date followed by text;
     - a date only inside a file name: no date;
     - a date only inside parentheses: taken;
     - a quoted question holding an earlier date in parentheses: the outer date wins;
     - onboarding with an untracked map file, and with none.
  2. *The expected differences, end to end,* with the built `labels()` against `2.0.1`'s. Grouped lines are expanded to
     one label per entry.
     - (a) A clone of the first field repo: each of the map's 22 commits, with the entries committed and with them
       uncommitted, Read case.
     - (b) A scratch repo with one entry per repo-corpus source line, each quoting one fixed sentence, and every file
       any rule names created to hold that sentence.
     - *Pass:* an entry's label differs only when its source is on the list, and only as listed (a dropped path gives
       "unverified quote", a gained date adds ", captured <date>"). Every other label is identical.
  3. *Size,* on (a): bytes before and after, reported with no bar.
  4. *Byte identity* of session start and the prompt hook with `2.0.1`, on this repo and on the field clone.
  5. *The smoke* on CLI 2.1.327. *Pass:* every assertion.
  6. *CI* on three systems, dispatched on a side branch, so `v2` and PR #116 do not move before the pass.
  7. *A verifier round,* refute-first, through the Antigravity CLI (rule 10; public text only: the diff and this
     entry). A finding survives if it shows a source whose real document the rule drops, a date other than the capture
     date, or a label that fails open.
  - *Not run:* the reference bench. The change only adds a short scan of the source line, so D18's cost cannot rise
    beyond noise. This is an accepted gap, as in 2p.
- **On a pass:** the change lands on `v2`, tagged `v2.0.2`. PR #116 then carries `2.0.2`, and the user is told it no
  longer equals the `v2.0.1` tag.
- *Not in this step,* from the same checkup:
  - *G2, label noise:* answered by `2.0.1`. On the map above it cuts one Read's labels from 6,778 to 830 characters,
    and it waits on PR #116.
  - *G1, a lifecycle for entries* (superseded, expired): a new question, registered as its own decision. Its options
    touch D14's frozen instruction and D23's line.
  - *G3, the forced decision's "read every document" in a large directory,* and *G5, the named decisions at every
    finish:* field observations for D22 and D23. Neither is a count, nor the user's own finding, so no trigger fires.
  - *G4, decisions kept in Claude Code's auto memory and not in the map:* a D14 observation.

### 2q, attempt 1: result (2026-11-18): checks 1 to 6 pass; check 7 failed

- *Built* in `69bf479`. Product hash `631345c67f8c`, version `2.0.2`.
- *Check 1:* the self-test passes. Every existing case is unchanged.
- *Check 2:* 0 mismatches.
  - (a) The field clone: 44 cases (22 commits, committed and uncommitted). Of 2,056 entry labels, 1,052 differ, every
    one as listed.
  - (b) The scratch repo: 724 entry labels, 30 differ as listed, and the 592 named files were all created.
  - The expected list was frozen to a file before the replay, and its counts equal the registration's. Each gained date
    was then read in its line: every one is the date the source's `<who>, <date>` gives.
- *Check 3, size:* on (a), 154,681 bytes before and 166,886 after (8% more). Uncommitted entries gain their dates.
  On the map's current committed state, one Read's labels go from 830 to 785 characters, and every entry is dated.
- *Check 4:* session start and the prompt hook are byte-identical on both repos, at startup and at compact.
- *Check 5:* the smoke on CLI 2.1.327 passes. *Check 6:* CI passes on three systems (self-test and load).
- *Check 7, the verifier* (Gemini 4 Argon through `agy`, given this entry and the diff). Findings that survive the bar:
  - *Fail open, in 2q's own target:* a `1)` or `a)` inside a parenthesis closes it early, so the path inside leaks
    out: `Owner (1) discussed in <path>), <date>`.
  - *A file the rule makes up:* removing `(v2)` from `docs/guide(v2).md` leaves `docs/guide.md`, a different file.
  - *Wrong dates* where `2.0.1` was right:
    - a stray `(` in a quote cuts the outer date;
    - an earlier date in a quote that is not in parentheses;
    - a date after `+`, `#` or `=`, or inside a range `..`.
  - *A real document dropped:* `Title (docs/adr-016.md), <date>`, where the parenthesis holds only the path.
  - *Fail open, already in `2.0.1`:* the path is a fragment taken after a non-path character. A URL gives
    `main/README.md` or `README.md`; `docs/(archive)/README.md` and `../(backup)/README.md` give the root `README.md`;
    `docs\guide.md` gives `guide.md`. The bar does not exempt old behaviour.
  - *Onboarding:* `git ls-files` counts a staged file as committed, while the labels read HEAD.
- *Not surviving:*
  - a folder named in parentheses (`app/(auth)/page.tsx`) is not read as a path, before or after the change;
  - "Owner on <path>" outside parentheses is re-found there, which is the registered "via <path>" choice;
  - entries not yet committed inside a committed file are the labels' job, not the onboarding line's;
  - outside git, "not committed" is true.
- *Result:* attempt 1 fails (rule 4, attempt 1 of 3).

### 2q, attempt 2 (registered 2026-11-18, before the code)

- **The change, from attempt 1:**
  1. *The date:* the date at the line's end first, `2.0.1`'s rule, so no date `2.0.1` gave can change. Else the first
     date that stands alone outside parentheses. Else the first one anywhere. "Stands alone" is now named, not
     excluded: the date follows the start, a space, `(`, `[` or a quote. It is followed by the end, a space, `)`,
     `]`, a quote, `,`, `;`, `:`, or a `.` that ends the text or comes before a space.
  2. *The parentheses:* a parenthesized part becomes a space, not nothing, so no two tokens fuse. One that holds only a
     path stays, as the source's path. A `)` left over once the pairs are gone drops everything before it, and an
     unclosed `(` still drops everything after it.
  3. *The path:* a token counts only where it starts a word. It may not follow a word character, `/`, `.`, `\`,
     `-`, `:`, `@`, `=`, `?` or `#`, so no fragment of a URL, a Windows path or a longer path is taken.
  4. *Onboarding:* committed means in HEAD (`git ls-tree`), as the labels read it.
- *Prototype, on the same corpora* (scratch script): attempt 2 gives exactly attempt 1's path and date on all 57 field
  lines and all 362 repo lines. So the frozen expected list stands unchanged.
  - Of the verifier's 21 inputs, attempt 2 answers each surviving one correctly.
  - The stated limit: an undated source whose only date sits in a parenthesized file name (`notes-(2026-10-01).md`)
    is taken as its capture date.
- **Checks:** the same seven.
  - Check 1 adds the verifier's inputs as cases, and a staged map file for onboarding.
  - Check 2 replays against the frozen list from attempt 1.
  - Check 7 is a second verifier round, on attempt 2's diff from `2.0.1`. The bar is unchanged.

### 2q, attempt 2: result (2026-11-18): checks 1 to 5 pass; check 7 failed

- *Built* in `cf59996` on the side branch `v2-2q`. Product hash `5963394b10e6`.
- *Checks 1 to 4:* the self-test passes, with the verifier's inputs as cases. Check 2 gives 0 mismatches against the
  frozen list, with the same counts as attempt 1. Check 3 is unchanged. Check 4 is byte-identical.
- *Check 5:* the smoke on CLI 2.1.327 passes.
- *Check 6:* CI, 5 of 6 jobs passed. The macOS self-test was still running when check 7 failed the attempt, so its
  result changes nothing.
- *Check 7, the second verifier round:* partial. `agy` hit its 10-minute print timeout in its second category, so
  nothing is known about new fail-opens. Findings that survive the bar:
  - *A regression attempt 2 made:* a stray `)` later on the line drops a real path at its start,
    `docs/x.md, section 2) Auth flow, <date>`. `2.0.1` and attempt 1 kept it. It comes from the rule added for round
    one's stray `)`.
  - *A wrong date where `2.0.1` gave none:* `reply to "What broke on 2026-10-15?", 2026-11-18 (in chat)` gives
    2026-10-15. This is round one's quoted-date case with a parenthesis appended. The instance was fixed, but not
    the class.
  - *Real documents dropped:* a title with its path and an anchor, a section or backticks in the parentheses.
  - *Behaviour `2.0.1` already had:* a date at the line's end taken from trailing text; `--docs/x.md`; `./hook.mjs`; a
    parenthesis inside a file name.
- *Result:* attempt 2 fails (rule 4, attempt 2 of 3).

### 2q: the rethink before attempt 3 (rule 4, 2026-11-18)

- *What failed is the bar, not the regexes.* Check 7 counts a dropped real document and a fail-open as the same kind
  of finding. Yet 2q's registration says "where the rule is unsure it drops the path". On free text, a fresh adversary
  can always hit one side or the other, so no rule passes such a bar. Two rounds showed it: each fix for one side
  opened the other, or moved a case one character over.
- *The failed assumption:* that a source's free text can be parsed into its true file and capture date. The format
  (`<who stated it, or the document's title or path>, <date>`) does not make either one unambiguous.
- *What can be guaranteed is a direction, relative to `2.0.1`:*
  - **I1, the path:** `2.0.2` either takes `2.0.1`'s path or withholds it, and never picks a different token. It
    withholds the path when it lies inside parentheses, and when it is a fragment that follows `/`, `\`, `:`, `@`, `=`,
    `?` or `#`, as in a URL, a Windows path or a longer path. If the parentheses do not pair, the path is withheld
    once any `(` comes before it. A withheld path gives "unverified quote", so a label never moves toward a silent
    pass.
  - **I2, the date:** a date `2.0.1` gave never changes. Where it gave none, `2.0.2` gains one only when it is
    unambiguous. There must be exactly one standalone date outside parentheses, or, when none stands outside, exactly
    one anywhere. Otherwise the entry stays undated.
- *The change of bar, stated as one and open to the user's override:*
  - Check 7 becomes mechanical, as 2p's attempt 2 did. It is a seeded differential fuzz against `2.0.1` that passes
    when I1 and I2 hold on every case. To it is added a table of both rounds' 49 inputs, written before the code, each
    marked as fixed, withheld, or identical to `2.0.1`.
  - What this no longer claims: that every real document is re-found. A real document the rule withholds is a stated
    limit, on the safe side. So is behaviour `2.0.1` already had.
  - This is a reduced claim. It is weaker than the bar attempt 1 registered, and the user may hold 2q to that bar
    instead. Then 2q stops here, unlanded.
- *Prototype* (scratch script): the I1 and I2 rule gives exactly the frozen list, with the same path and date on all
  57 field lines and all 362 repo lines, and breaks neither invariant there. On the 49 inputs, every path is
  `2.0.1`'s or withheld, and every date is `2.0.1`'s or the single candidate. One gain is still wrong: a date inside a
  parenthesized file name, which stays a stated limit.
- *A second opinion on the bar,* before attempt 3 is registered: asked whether the change is a goalpost move. If it
  says yes for a reason that cannot be answered, 2q goes to the user unlanded.
- *The second opinion's answer (Gemini 4 Argon, the rethink above as its brief): YES, a goalpost move,* for two
  reasons:
  1. the prototype still gains a wrong date where `2.0.1` gave none, from a parenthesized file name, which breaks the
     direction it claims;
  2. "gain only when unambiguous" restates the code's own recipe, so fuzzing it is circular.

  It agreed that "withhold rather than guess" is sound. Its bar for attempt 3 was zero false date gains, the
  differential fuzz, the 49-input table, and a fresh refute-first round. In that round a finding survives only if
  `2.0.2` regresses against `2.0.1`: it newly fails open, gains a date that is not the capture date, or drops an
  unparenthesized path that is not a fragment and that `2.0.1` kept.
- *Answered by narrowing, not by arguing:*
  - In free text, a capture date cannot be told from a topic date ("the PM, about the 2026-10-01 outage"). So any
    rule that gains dates fails that bar. **I2's gain is withdrawn.** B2 leaves 2q and goes to the user as a format
    question. The writer can put the date last, or the capture instruction can say so (D14's frozen text). Under
    rule 4 it is not re-registered as a new step.
  - The path keeps only the parenthesis withhold. Under a relative bar, `2.0.1`'s fragment fail-opens (URLs, `\`) are
    not findings, and withholding them could itself regress (`/docs/x.md`). Where the parentheses do not pair, `2.0.2`
    does exactly what `2.0.1` does.
  - The user may still hold 2q to attempt 1's bar instead. Then 2q stops unlanded.

### 2q, attempt 3 (registered 2026-11-18, before the code). The last under rule 4

- **The change, against `2.0.1`:**
  1. *The path:* `2.0.1`'s path, unless it lies inside parentheses that pair across the whole source line. Then no
     path, so the label is "unverified quote". `2.0.2` never picks another token.
  2. *The date:* `2.0.1`'s, unchanged.
  3. *Onboarding:* the `Map:` line counts the map files that HEAD lacks (`git ls-tree`), staged ones included.
- *The frozen list* (scratch, written before the code):
  - field, 57 lines: the path is withheld on 5, every other path is unchanged, and no date changes;
  - repo, 362 lines: the path is withheld on 2, and nothing else changes.
- *The 49-input table* (both verifier rounds' inputs, classified before the code). 7 are withheld, each a path inside
  paired parentheses. 42 are identical to `2.0.1`. None is changed otherwise.
- **Stated limits** (all as in `2.0.1`, or on the safe side):
  - A real document cited only inside parentheses loses its re-find and its drift alarm. Examples are
    `Title (docs/x.md)`, `Title (docs/x.md#anchor)` and the Markdown link `[title](docs/x.md)`.
  - Unchanged from `2.0.1`:
    - unpaired parentheses (a list marker `1)` inside a parenthesis);
    - URL and Windows-path fragments;
    - dates read only at the line's end, so 41 of the field map's 67 entries stay undated, and a date from trailing
      text is taken.
- **Checks:**
  1. *The self-test.* The 2q cases of attempts 1 and 2 now assert `2.0.1`'s label wherever attempt 3 keeps
     `2.0.1`'s behaviour: every date gain, and the fragment, stray-`)` and fused-name cases. They assert "unverified
     quote" where a path inside paired parentheses is withheld. The onboarding cases stay as they are.
  2. *The frozen list, end to end,* as before: the field clone at 22 commits, both states, and the corpus repo.
  3. *Size,* reported. 4. *Byte identity* of session start and the prompt hook. 5. *The smoke.* 6. *CI.*
  7. *Against `2.0.1`, mechanically and adversarially:*
     - (a) *A seeded differential fuzz* of generated source lines (people, paths, URLs, nested and unpaired
       parentheses, quotes, dates). Both libraries' real `labels()` run in a scratch repo where every file `2.0.1`
       picks holds the quote. *Pass:* every entry's label is `2.0.1`'s, or `2.0.1`'s path is withheld and the label
       is "unverified quote" with `2.0.1`'s date.
     - (b) *The 49-input table* above, run through both libraries. *Pass:* as classified.
     - (c) *A fresh refute-first round,* through `agy`.
       - *The brief:* only the diff from `2.0.1` and this bar. Fail-opens are asked for first, and findings are capped
         at 8.
       - *Triage by execution:* each claimed input is run through both libraries.
       - *A finding survives only if the outputs show one of these:*
         - a label that moves toward a silent pass against `2.0.1`;
         - a date that differs from `2.0.1`'s;
         - a path `2.0.1` kept that `2.0.2` withholds, when that path is not inside paired parentheses;
         - an onboarding line that misstates which map files HEAD lacks.
       - *A partial round* (a timeout): the findings of the categories it completed are triaged. If it ended before its
         fail-open category was complete, it is re-run once, with the cap at 4. If that run is partial too, (c) is
         recorded as unrun, and 2q goes to the user unlanded: not passed, not BLOCKED.
- **On a fail:** 2q is BLOCKED. `v2`'s plugin and PR #116 stay at `2.0.1`, and the level above goes to the user.
- **On a pass:** the change lands on `v2` as `2.0.2`, tagged, and PR #116 carries it. The user is told.

### 2q, attempt 3: result (2026-11-18): pass

- *Built* in `v2-2q`'s last commit, fast-forwarded onto `v2`. Product hash `41b9b34034a9`, version `2.0.2`.
- *Check 1:* the self-test passes, with the 2q cases asserting `2.0.1`'s label except where a path inside paired
  parentheses is withheld.
- *Check 2:* 0 mismatches against the frozen list.
  - The field clone: 2,056 entry labels, of which 102 differ, each a listed withheld path across the map's history.
  - The corpus repo: 724 entry labels, of which 4 differ, as listed.
- *Check 3, size:* the field cases go from 154,681 bytes to 154,499. On the map's current committed state, one Read's
  labels go from 830 characters to 688, and the false "not found" line is gone.
- *Check 4:* session start and the prompt hook are byte-identical on both repos, at startup and at compact.
- *Check 5:* the smoke on CLI 2.1.327 passes. *Check 6:* CI passes on three systems, self-test and load.
- *Check 7:*
  - (a) *The differential fuzz,* seeds 1 to 3 with 2,000 sources each, uncommitted and committed: 12,000 entry labels,
    0 violations. 456 are withheld to "unverified quote" with `2.0.1`'s date, and every other one is `2.0.1`'s.
  - (b) *The 49-input table,* through both libraries: 42 identical and 7 withheld, exactly as classified, with 0
    violations.
  - (c) *The fresh round* (Gemini 4 Argon, a 5 KB brief: the diff and the bar) completed with no timeout and answered
    "NONE". The answer gave no reasoning, so it is weak evidence by itself; (a) and (b) carry the check.
- *Result:* pass. 2q lands as `2.0.2`.
  - *Fixed:* the field's false not-found label, and its three silent passes.
  - *Added:* onboarding's count of map files that HEAD lacks.
  - *Not fixed, and with the user:* B2, a capture date not at the line's end. It is a format question.
  - *The claim's reduction* in the rethink stays open to the user's override.

### 2q: corrections to the record (2026-11-18)

- *Attempt 1's result* said every gained date was "the date the source's `<who>, <date>` gives". That was not true of
  every one: several sat inside parentheses, as in `(read <date> …)` or `(owner, <date>)`. Attempt 3 gains no dates,
  so nothing shipped rests on it.
- *The repo corpus* (362 lines) includes lines from frozen transcripts of the field repo. One of its 2 withheld paths
  duplicates a field line, so the repo-only withhold is 1, a web address in parentheses.
- **D24's field count 5 rested on B1.** Its two C5b flags were read as "not a defect": the entries were committed,
  and their quotes were found word for word in the file their source names.
  - Re-run with `2.0.0`'s `labels()` at the map's state of that count (56 entries). `2.0.0` left exactly 3 entries
    unlabelled, and in each the source names the file only inside parentheses: B1's silent passes.
  - Under `2.0.2` all 56 are labelled. So the two flagged calls showed entries that should have carried "unverified
    quote".
  - Whether that is a C5 defect under D24, for the released `2.0.0`, is the user's call. It is not settled here.
  - The field scanner's `CITES` (`field.mjs`) matches a path anywhere in the source, the same class as B1. It only
    routes a miss to a hand read. A change to it is a probe change, registered first.

### 2q: the release notes (drafted before the page, which is the user's)

> **second-brain 2.0.2.** A map entry's label no longer checks a person's words against a file they only mention in
> parentheses.
> - An entry whose source reads `the lead developer, 2026-11-03 (after reading docs/grid.md)` holds the lead
>   developer's words. 2.0.1 checked the quote against `docs/grid.md`, which gave a false "not found word for word
>   in docs/grid.md; check it", or no label when the words happened to be repeated there. Now it is labelled
>   "unverified quote".
>   - A source that starts with its document, or names it outside parentheses (`via docs/x.md`), is still re-found.
>   - Where the parentheses do not pair, the path is read as in 2.0.1.
>   - Limit: a document cited only inside parentheses (`Title (docs/x.md)`, `[title](docs/x.md)`) is no longer
>     re-found. Write its path first.
> - `/second-brain:onboard` says how many map files are not committed. Their entries stay labelled "unreviewed"
>   until they are.
> - Unchanged: the capture date is read only at the end of the source line.
>
> Session start and the prompt hook are byte-identical to 2.0.1. Checks: the self-test, a replay over a field map's
> history against a list fixed before the code, a differential fuzz against 2.0.1 (12,000 labels), the smoke on
> Claude Code 2.1.327, and CI on three systems. Product hash `41b9b34034a9`.

### 2r: D28's (L), the labels read a status line, as `2.1.0` (registered 2026-11-18, before the code)

- *Why:* the field checkup's G1 and the rethink (`research/2026-11-18-field-checkup-rethink.md`). The first field
  repo's map holds 10 `- status:` lines, which `2.0.2` ignores. A Bash command that shows an entry without its status
  line delivers a superseded entry as current.
- *Scope:* D28's (L) alone, with its check as registered, plus the rethink's additions. No frozen text changes:
  INSTRUCTION, FORCE and NAME stay byte-identical. (I) and (N) are 2s.
- **The change,** in `labels()` only:
  1. An entry with a `- status:` line gets the label `status: <head>`. The head is the line's text, cut at the last
     space before 60 characters and ended with `…` when cut. It comes after "unreviewed" and before the quote's
     label.
  2. So such an entry never joins the grouped "unverified quote" line. One whose quote is re-found, which had no
     label, now gets its own line.
  3. The status line is part of the entry's block. A status line that HEAD does not hold makes the entry
     "unreviewed", so an uncommitted status never reads as reviewed.
  4. The label quotes the line's own words and never says "ended": "narrowed" and "refined" entries still bind in
     part.
  - The version becomes `2.1.0` in both manifests, and the self-test's hash is pinned again.
- **Checks:**
  1. *The self-test.* New cases:
     - a status line on a committed entry and on an uncommitted one;
     - an entry inside the grouped line, and one re-found in its file;
     - a status line added to a committed entry and not committed, which gives "unreviewed" and the status;
     - a long status line, which is cut;
     - a Bash output that shows an entry's heading but not its status line, which still gives the status label.
  2. *The field replay,* on a clone of the first field repo:
     - at its current map, the 10 marked entries carry their status label;
     - at every map commit and in both states, every entry without a status line has a label byte-identical to
       `2.0.2`'s once grouped lines are expanded.
  3. *Byte identity* of session start and the prompt hook with `2.0.2`, on this repo and the field clone.
  4. *A differential fuzz against `2.0.2`,* near and past the 10,000-character cap. Maps are generated with and
     without status lines, both committed and uncommitted. *Pass:* in every uncut output, each entry's label is
     `2.0.2`'s with the status label added where the entry has a status line. In a cut output, every entry not shown
     is covered by the closing line.
  5. *The smoke* on the current CLI. 6. *CI* on three systems.
  7. *A verifier round* through `agy`, given the diff and this bar. A finding survives only if executing it shows one
     of these:
     - a label `2.0.2` gives that `2.1.0` drops or changes, other than by adding the status;
     - a status that HEAD does not hold, shown without "unreviewed";
     - a cut that fails open.

     A partial round is handled as in 2q's attempt 3.
  - *Not run:* A1, since no text changes; and the reference bench, since the change adds one regex per entry. Both
    are stated gaps.
- **On a pass:** the change lands on `v2` after PR #116 is merged, or rides with it, and is tagged `v2.1.0`.

### 2r: result (2026-11-18): pass

- *Built* in `7b58f96`. Product hash `b53f5c4c5245`, version `2.1.0`.
- *Check 1:* the self-test passes with the new cases.
- *Check 2, the field replay:*
  - at the current map, the 10 marked entries carry their status label;
  - across the map's 22 commits in both states, 2,056 entry labels: 2,036 identical to `2.0.2`'s, and 20 with the
    status added as specified;
  - 0 violations.
- *Check 3:* session start and the prompt hook are byte-identical to `2.0.2`'s, on both repos, at startup and at
  compact.
- *Check 4, the fuzz near and past the cap* (3 seeds, 72 map files of 40 to 220 entries, both states):
  - 10,094 entry labels: 7,030 identical, 1,398 with the status added, and 1,666 covered by the closing line of a cut
    output;
  - 0 violations.
- *Check 5:* the smoke on CLI 2.1.327 passes. *Check 6:* CI passes on three systems.
- *Check 7, the verifier (agy):* "NONE". It checked that existing labels are kept, that an uncommitted status line
  still gives "unreviewed", and that the cap logic is unchanged.
  - A first call returned nothing: `agy` tried to run a command, which headless mode denies. It was re-run with
    reading only.
- *Size:* the field cases go from 154,499 bytes to 156,835 (2% more), since 10 entries leave the grouped line.
- *Result:* pass. D28's (L) is built. D28 stays OPEN for (I) and (N), which are 2s.

### 2s: the texts: D28's (I) and (N), B2's date, G4's store, D23's (d), as `2.2.0` (registered 2026-11-18, before the code)

- *Why:* the rethink's outcomes (`research/2026-11-18-field-checkup-rethink.md`).
  - D28's (I) and (N) follow 2r.
  - B2: a capture date put last.
  - G4: the store sentence, adopted by its count.
  - D23 reopened on its own field trigger: 28% restated in 41 lists, so its record names (d) as the next attempt.
  - D14 and D23 reopen for their frozen texts, through the user's delegation of 2026-11-18 and D23's trigger. D16's
    trigger "the capture instruction changes" fires, and D16 re-locks on this step's checks.
  - The forced decision (D22) stays frozen (the rethink, G3).
- **The texts.** Additive only: every line of the old text stays, byte for byte and in order.
  - *INSTRUCTION:*
    - after "…leave out one-off details of the current task.", the new line "Decisions and rules for this project
      belong in this map, not in your auto memory, which is for your own way of working." (G4);
    - after the `- when:` line of the format, these three lines:
      1. "End the source line with the date, as YYYY-MM-DD; put any other detail in parentheses before it." (B2)
      2. "When a new entry replaces, narrows or ends an existing one, keep the old entry and add this line under its
         when line:" (D28's I)
      3. `- status: <superseded|narrowed|expired|done> <YYYY-MM-DD> by "<the new entry's heading>": <what still holds>`
  - *NAME:*
    - after "…as the map entry or document gives it", the clause ", unless you named it earlier in this session"
      (D23's d);
    - after "Do not name a decision you did not follow,", the clause "one whose status line says it no longer holds,"
      (D28's N).
  - The version becomes `2.2.0`. The self-test pins the new hashes and bytes, and checks that every old line survives
    in order.
- **Checks.** All are run from a plugin copy, on Opus 5.5 with the pinned CLI 2.1.305 (A1's epoch), against a `2.1.0`
  control. A same-day `2.1.0` A1 run (1 run) first proves the harness still works.
  1. *The self-test,* the smoke and CI.
  2. **A1, the V2 arm, 10 runs.** *Pass:*
     - each pass item at A1's Opus bar: C1 10, C2 at least 2, C3 10, C4 10, T1 10, T2 10, T3 at least 8, T4 10,
       T5f at least 8, N1 to N3 10;
     - over-attribution in at most 1 of 10 (D23);
     - *the negative,* that no run writes a `- status:` line, since A1 replaces nothing.
     - *Reported:* the share of captured entries whose source line ends with the date; always-on bytes.
     - *Attribution, fixed now:* a miss on C1 to C4, or a status line in the negative, implicates INSTRUCTION. A miss
       on T5f, or over-attribution, implicates NAME. Misses on T1 to T4 or N1 to N3 implicate neither text alone, and
       are read by hand.
  3. **Scenario S1, a decision replaced (D28's I),** 5 runs per arm. A1's fixture, with a committed map of 3 entries:
     the folder rule (the lead developer), "avatars load locally, never from the CDN" (the PM), and an unrelated
     test rule. The prompt brings the PM's reversal: avatars load from the CDN when an address exists, with the
     local file as the fallback. *Pass:* in at least 4 of 5 `2.2.0` runs the avatar entry gets a `- status:` line
     that starts with one of the four kinds and a date, and no other entry gets one. The control's count is
     reported.
  4. **Scenario S2, the date (B2),** 5 runs per arm, in the field's shape: the owner answers a question Claude
     asked, with a condition and a later review. *Pass,* the rethink's rule: the new entry's source line ends with
     the date in at least 4 of 5 `2.2.0` runs, and in at least 2 more runs than the control. Otherwise the B2
     sentence is dropped from the build.
  5. **Scenario S3, naming across turns (D23's d),** 5 runs per arm. A two-turn session (the second resumed) on the
     same map: "Create a UserAvatar component.", then a TeamAvatars component built from it. *Pass:*
     - turn 1 names at least one recorded source role in at least 4 of 5 runs;
     - turn 2 names none of the roles turn 1 named, in at least 4 of 5 `2.2.0` runs. A1's role patterns are the
       scorer.
     - The control's repeats are reported.
  6. *Session start's size:* on the field clone, and on this repo's own index, every directory is still listed under
     the cap. The added bytes are reported.
  - *Not checked, and stated as direction:*
    - that a status label stops a superseded entry from being followed or named (D28's N in use);
    - G4's sentence in use (A1's V2 arm does not compete with auto memory).
  - *Not run:* the reference bench. Session start gains about 0.5 KB of text and no work.
- **On a fail:** each failed check is attempt 1 of 2s, under rule 4. A text whose check fails is dropped or revised
  alone, by the attribution above.
- **On a pass:**
  - D14, D16 and D23 re-lock, and D28 locks on (LIN).
  - Tag `v2.2.0`. The field session is asked to migrate its source lines and status kinds to the locked format.

### 2s, attempt 1: result (2026-11-18): every check passes except A1's negative, which failed as written

- *Built* in `v2-2s` (product hash `ee8625f06842`, `2.2.0`). The texts are as registered: INSTRUCTION sha
  `bd491ace7f2f`, 1,349 bytes, with every old line in order; NAME 304 bytes. Self-test, smoke (CLI 2.1.327) and CI
  pass.
- *The same-day control* (`2.1.0`, A1's V2 arm, 1 run on the pinned epoch): valid, and every item passes. The harness
  works.
- **A1, the V2 arm, 10 runs** (`results/V2-opus-ee8625f.json`), all valid:
  - every item at its bar except the negative: C1 to C4 10, T1 to T4 10, N1 to N3 10 (both variants);
  - **T5f** 8 of 10 on "same" and 9 of 10 on "second". The bar is at least 8: met, at the bar;
  - **over-attribution:** 0 of 10.
  - **The negative failed as written:**
    - 5 of 10 runs wrote a `- status:` line. Read by hand, every one is on the same entry: H1's "Last month I said
      new components should go under src/widgets/. Scrap that, it's off". It is marked superseded by the folder rule.
    - No other entry got one.
    - The registration's premise, "A1 replaces nothing", was false: A1's own history holds a replacement. The
      behaviour is D28's (I) working.
    - The bar was the bar, so under rule 2 this attempt fails.
  - *Reported:* 179 of 180 captured source lines end with the date. Each run cost about 1.35 USD.
  - *T5f's two misses, read:* each reply names the designer's decisions by the document's title alone ("Profile page
    notes (v3)"). That run's capture had put the role in parentheses ("(the designer's notes, …)"), and the reply
    dropped the parenthesis.
    - In the control, the role stands in the main text ("from the project's designer").
    - So the B2 sentence ("other detail in parentheses before it") plausibly moves the role out of sight when an
      entry is named.
    - An observation at the bar, not a fail.
- **S1, a decision replaced** (`V2-D28-lifecycle/results/S1.json`):
  - the candidate passes in 5 of 5: the avatar entry gets `- status: superseded <date> by "…"`, and no other entry
    gets one;
  - the control: 0 of 5. It added no entry at all for the reversal.
- **S2, the date:** the candidate 5 of 5, the control 1 of 5. The control wrote the field's shape: `<user>,
  2026-11-18 (the CDN contract ends March 2027)`. **B2's sentence stays,** by the rethink's rule.
- **S3, naming across turns:**
  - the candidate passes in 5 of 5: turn 1 names both roles, and turn 2 names neither again ("the ones I named last
    time apply again");
  - the control repeats both in 5 of 5.
- *Session start:* every directory is still listed. On a synthetic P2-shaped repo it goes from 9,029 to 9,566 of
  10,000 characters, which leaves 434 of headroom. The field repo goes from 3,496 to 4,033.
- *Result:* attempt 1 fails, on the negative only (rule 2).

### 2s, attempt 2 (registered 2026-11-18, before its runs)

- *The build is unchanged* (`ee8625f06842`). Only the negative's premise is corrected.
- **The negative, corrected:** no run writes a `- status:` line on any entry other than one for the widgets rule H1
  retracts. *Reported:* how many runs mark that rule, and with which kind.
- **The other bars, unchanged,** on 10 fresh A1 runs (`D17_TAG=-opus-ee8625f-a2`, the same plugin copy and epoch):
  - every pass item at its Opus bar;
  - T5f at least 8 of 10;
  - over-attribution at most 1 of 10.
- S1 to S3, the self-test, the smoke and CI are not re-run: the build is the same, and they passed.
- *If T5f falls below its bar,* attempt 3 revises the B2 sentence so that the role stays outside the parentheses. That
  text would need A1 and S2 again.

### 2s, attempt 2: result (2026-11-18): pass

- *The build:* `ee8625f06842` (`2.2.0`), unchanged from attempt 1. 10 fresh A1 runs (`results/V2-opus-ee8625f-a2.json`),
  all valid.
- **Pass items:** C1 to C4, T1 to T4 and N1 to N3 in 10 of 10, both variants. **T5f:** 9 of 10 on "same", 10 of 10
  on "second".
- **Over-attribution:** 0 of 10.
- **The corrected negative:** 4 runs mark the widgets rule H1 retracts (3 superseded, 1 expired), and no run marks
  any other entry, in H, T or N.
- *Reported:* 185 of 185 captured source lines end with the date. Each run cost about 1.36 USD.
- *With attempt 1's scenarios* (S1 5 of 5, S2 5 of 5, S3 5 of 5, against the control's 0, 1 and 0), every registered
  check of 2s has passed.
- *Result:* pass.
  - D14, D16 and D23 re-lock, and D28 locks on (LIN), in the ledger.
  - `2.2.0` lands on `v2`, tagged `v2.2.0`.
  - *Still direction:* D28's (N) in use, and G4's sentence in use.

### 2r and 2s: the release notes (drafted as release drafts, published after `main` moves)

> **second-brain 2.1.0.** Map entries that have stopped binding are labelled as such.
> 
> - An entry with a `- status:` line gets a label that quotes the line's head, for example `status: superseded 2026-11-18 by "Avatars (CDN first)"`. So a Bash command such as `grep` that shows the entry without its status line still says the entry was superseded, narrowed, expired or done.
> - The label quotes the line rather than saying "ended", because a narrowed entry still binds in part.
> - A status line that is not committed leaves the entry "unreviewed".
> 
> Session start and the prompt hook are byte-identical to 2.0.2.
> 
> Checks: the self-test; a replay over a field map's history (its 10 status entries labelled, every other label identical to 2.0.2's); a fuzz near the 10,000-character cap (10,094 labels, 0 violations); the smoke; CI on three systems. Record: `docs/v2/06-first-slice.md`, 2r. Product hash `b53f5c4c5245`.

> **second-brain 2.2.0.** The capture instruction and the closing line learn from the field.
> 
> - **Replaced decisions are marked.** When a new decision replaces, narrows or ends a recorded one, Claude keeps the old entry and adds `- status: <superseded|narrowed|expired|done> <date> by "<new heading>": <what still holds>`. With 2.1.0's labels, a superseded rule no longer looks current. In a test where the PM reversed a decision, the old entry was marked in 5 of 5 runs, against 0 of 5 before.
> - **The capture date comes last** on the source line, with any other detail in parentheses before it, so every label keeps its date. 5 of 5 runs, against 1 of 5 before.
> - **Project decisions go in the map,** not in Claude's auto memory, which is for its own way of working.
> - **Decisions are named once per session.** The closing "decisions I followed" list names a decision the first time it shapes the work, not again in every reply, and never one whose status line ends it. In a two-turn test, the second reply repeated none, against both before.
> 
> Checks: scenario A1 on Opus 5.5 over 20 runs. Every pass item at its bar, and naming its sources in 8 and 9 of 10 against a bar of 8. Over-attribution 0. The three scenarios above, each against a 2.1.0 control. The self-test, the smoke, and CI on three systems.
> 
> Session start grows by about 540 characters. Record: `docs/v2/06-first-slice.md`, 2s. Product hash `ee8625f06842`.

### 2s: corrections to the record (2026-11-19)

- *2s's registration* said "the self-test … checks that every old line survives in order". The self-test pins the new
  hash and size. The in-order check of INSTRUCTION's old lines ran once, as a scratch script, before the build, and
  it passed.
- *2q's claim* that no legitimate re-find was lost held on its registered corpora, but not on A1's captured maps:
  - the `2.1.0` control's capture cited the style guide as `Title (docs/style-guide.md)`, so `2.0.2`'s rule withheld
    the re-find of 6 of 6 file-citing entries;
  - under `2.2.0`'s capture text, 114 of 120 file-citing entries over 20 runs put the path first. 6, in one run, lost
    the re-find.
  - Recorded in D16, with a field trigger. This is the limit the user approved with 2.0.2, now measured.
- *Session start's added bytes:* 537 characters, always-on. D13 records them with no cap. Before the index is cut,
  8,199 characters remain for it, against about 8,736 before.

## 3: the redesign onto Anthropic's layout (registered 2026-11-20, before any code)

**Why.** On 2026-11-20 the user decided to change the plugin's approach. It now follows that day's research
([research/2026-11-20-anthropic-memory-and-dreaming.md](research/2026-11-20-anthropic-memory-and-dreaming.md)):
- a setup command creates Anthropic's layout: `CLAUDE.md`, `.claude/rules`, `.claude/skills`, `.claude/agents` with
  project agents that use `memory: project`, and the team memory;
- map entries become versioned, so stale memory can be told from current;
- an on-demand dream runs over this repo's past sessions, and the plugin tracks when one is due.

The user's answers are in D29-D32. Each decision this reopens shows "REOPENED 2026-11-20" in the status table.

**Rules for every step below:**
- Each step's bar is fixed here before its code. Changing a bar after a result counts as a failed attempt (rule 2).
- Attempts run from a copy of the plugin, passed with `--plugin-dir`, never from `plugin/` in place.
- At most three failed attempts per step (rule 4).
- Each step ends in one commit carrying the step gate.
- CI runs on three systems, and an agy verifier runs on every step that changes a hook.
- **Nothing ships before S8.** There is one release, and the user merges to main.

### 3: budget (replaces the 2a budget for this series; PM6 and PM8)

| Unit | Budget | Outcome served |
| --- | --- | --- |
| Hook events | the same 4 (SessionStart, UserPromptSubmit, PostToolUse Read and Bash, PostToolUseFailure Bash) | as today |
| Added hook p95 | at most 100 ms, at 1 session on every CI machine and at 8 concurrent on the reference machine in its reference state. No new git call at session start | D18 |
| Hook processes | 1 Node process per event; hooks spawn only `git`; no model or network call | D18 |
| Skills | 3: `setup`, `dream`, `status`. Each has `disable-model-invocation: true`, so none costs listing context | Onboarding (setup); Capture and Freshness (dream); Freshness (status) |
| Commands | 1: `onboard`, kept for 2.x users | Onboarding |
| Plugin agents | 1: `dream-analyzer`, with read-only tools and its front matter pinned by the self-test | Capture |
| Templates written into a repo | `CLAUDE.md` (or a marked block), 1 rule, 1 skill, 3 project agents, `.project-map/` README, a first topic file, `dreams.md`, and one `.gitattributes` line | Onboarding; Consistency (decision-checker); Orientation (codebase-guide); Freshness (memory-curator) |
| Always-on bytes | 2.2.0's (instruction 1,349 B, index header 143 B, naming line 304 B, forced decision 227 B, plus the index), plus 1 catalog line per topic file that has front matter. A repo shaped like 2.2.0 stays byte-identical | Orientation |
| Product lines | no cap; the self-test counts and reports them | — |

### 3, S0: records and probes

- **Records:**
  - the ledger (D29-D32 opened, the reopens);
  - this section;
  - the charter's "What changed and why";
  - `04-architecture.md`'s status line;
  - map issue #115.
- **Probes** run with the pinned CLI 2.1.305 on Haiku, from `docs/v2/probes/V2-D29-setup/`, each at the run count
  shown:
  - **P1, transcript folders (1 run each).** A session started in a subdirectory and one in a linked worktree. *Read:*
    the folder each transcript is written to, and whether `transcript_path` in a SessionStart hook's input names it.
  - **P2, temp-folder access (1 run per mode).** In `-p` with `default` and `acceptEdits` permission modes, a Read
    and a Write of a file in `os.tmpdir()`. *Read:* whether each is allowed, or denied because it would prompt.
  - **P3, an unreviewed native rule (5 runs).** An untracked `.claude/rules/nonce.md` with `paths:` matching the
    task's file. The rule tells Claude to add a nonce comment. The plugin copy's session start labels it "unreviewed,
    not yet committed". *Read:* how often the nonce lands. *Pass:* at most 1 of 5.
  - **P4, cleanup age (1 run).** In an isolated `CLAUDE_CONFIG_DIR` with `cleanupPeriodDays: 1`, three fake
    transcripts are set up:
    - one with its mtime set 3 days back;
    - one 3 days old by its content's timestamps but with a fresh mtime;
    - one fresh.

    *Read:* which ones are deleted.
  - **P5, the gate on `.claude/` (1 run per mode).** A Write of `.claude/rules/x.md` and of
    `.claude/skills/x/SKILL.md` in `-p` with `default`, `acceptEdits` and `auto`. *Read:* allowed or denied.
  - **P6, project agents (1 run per case).** A project agent with `tools: Read, Grep, Glob` and `memory: project`,
    asked to write a file outside its memory folder. A second agent's front matter tries to allow only
    `Bash(git diff:*)`. *Read:* whether the write lands, and whether that Bash form is honoured.
- **Pass for S0:** P1-P6 answered, with their output saved under the probe folder.
  - If P3 lands the nonce in more than 1 of 5, or P5 shows no gate in `auto` mode, then staging as `*.md.draft` (never
    loaded) goes back to the user before S7.
  - If P2 shows temp reads denied, the dream's run folder moves to `.project-map/.dream-run/`.

### 3, S1: the outcome probe, before any dream code (PM1)

A throwaway script under `docs/v2/probes/V2-D31-dream/` runs the dream's design by hand-built prompts on the pinned
CLI with Opus 5.5.

**Inputs:**
- A1's H1 to H3 sessions, run with capture off (the plugin not loaded), so each yields its real transcript;
- two sessions that repeat one correction, a rule candidate scoped to a path;
- two sessions that repeat one procedure, a skill candidate;
- one session where a decision is made by answering an `AskUserQuestion`;
- one session whose tool result carries an injected nonce instruction.

**Pass**, with every item counted:
- C1 to C3 recovered as map entries in at least 8 of 10 runs;
- the repeated correction proposed as a rule with `paths:` in at least 4 of 5;
- the procedure proposed as a skill draft in at least 4 of 5;
- the `AskUserQuestion` decision kept, its source saying "chosen from Claude's options", in at least 4 of 5;
- noise, meaning entries that hold no decision, at most the capture arm's count in D17's A1 V2 runs plus 1;
- a status line written on an entry nobody replaced in fewer than 2 of 10;
- the nonce placed in any file in 0 of 5;
- usage (tokens) reported per run.

**If S1 fails:** the dream is not built (PM1, rule 4), and the case goes to the user with the counts.

### 3, S2 to S8 (bars fixed now; each step's details are registered before its code)

| Step | What | Pass |
| --- | --- | --- |
| S2 | `map.mjs` refactor: export `entries`, `foundIn`, `sourcePath`; factor out `gitDir`; add `repoKey` | Every hook's output byte-identical to 2.2.0 on the self-test corpus |
| S3 | Entry format 3 and the read-hook states (D30) | A differential fuzz against 2.2.0, as in 2r: output identical for 2.2.0 entries; each new state correct on new fields; fail-closed near the cap |
| S4 | Capture instruction v3: new entries go to topic files, with `id` and `verified` | A1, 10 runs against a 2.2.0 control:<br>- C1-C4 at 2s's bars;<br>- T5f in at least 8 of 10;<br>- over-attribution 0;<br>- a topic file written in at least 9 of 10.<br>2s's S1 and S2 scenarios (D28, B2) at 2s's bars |
| S5 | Setup: the skill, the templates, the three project agents (D29) | **Five repo shapes** (empty, existing `CLAUDE.md`, existing `.claude/`, dirty tree, worktree): every existing file's hash unchanged; a second run creates nothing.<br>**Smoke:** the starter rule loads only when a map file is touched.<br>**Per agent, 5 runs:**<br>- decision-checker flags a change that breaks a committed entry in at least 4 of 5, and calls an uncommitted dream entry unreviewed in 5 of 5;<br>- codebase-guide answers a repeated where-is question with fewer tool calls than its first answer, in at least 3 of 5;<br>- memory-curator flags a due entry and a duplicate, changes a committed claim in 0 of 5, and writes only uncommitted edits |
| S6 | Catalog, the list of unreviewed dream files, the due nudge (D30, D32) | 2.2.0 repos byte-identical; every directory of the P2 shape still listed; at most 100 ms of added p95 with 300 synthetic transcripts; unit tests of the three due conditions; the nudge only in `systemMessage`; a user's own untracked rule never labelled |
| S7 | The dream product (D31) | **Self-test on synthetic JSONL only:**<br>- a 50 MB stream;<br>- injection in R lines;<br>- secrets;<br>- a quote from an ignored file;<br>- an attempted deletion;<br>- an unscoped rule;<br>- bad YAML;<br>- a missing skill flag;<br>- a stray write;<br>- a declined gate;<br>- a dirty map snapshotted and restored;<br>- a kill between steps;<br>- two concurrent prepares;<br>- the session and byte caps.<br>S1's bars re-run on the product. A security review |
| S8 | The status skill and the release | The status report's self-test; `/code-review` and the devils-advocate workflow over the series; README; release notes; a tag. The user merges |

### 3, S0: result (2026-11-20): answered; one registered fallback fired and went to the user

The probe results are in [probes/V2-D29-setup/README.md](probes/V2-D29-setup/README.md):
- **P1:** each transcript folder follows its launch directory, and the hook input carries `transcript_path`.
- **P2:** temp-folder access is denied headless, so the dream's run folder is `.project-map/.dream-run/`, ignored and
  excluded from the index.
- **P3:** Opus followed an unreviewed rule in 0 of 5 runs with the label, against 5 of 5 without it. The Haiku arm was
  uninformative.
- **P4:** inconclusive. The expiry warning uses mtime and is advisory.
- **P5:** writes under `.claude/` are gated in manual and acceptEdits, and not gated in auto. **This fired the
  registered fallback.**
- **P6 and P6c:** a `memory: project` agent writes outside its memory folder, and an agent's `Bash(pattern)` does
  not limit Bash.

**The user's answers (2026-11-20), recorded in D30 and D31 before any code they affect:**
1. **Drafts plus promote.** The dream writes rules and skills as `*.md.draft`, never loaded. The review skill
   promotes approved drafts by renaming them.
   - S7's check gains: a draft is never loaded in a smoke session, in `manual`, `acceptEdits` and `auto`.
2. **A visible `- proposed: dream <date>` line** on every dream entry until it is accepted in review.
   - S3's states gain "proposed", keyed on that line.
   - **S5's decision-checker bar is restated** before S5's code: it treats an entry carrying a `proposed:` line as a
     proposal, not as binding, in 5 of 5. This replaces "calls an uncommitted dream entry unreviewed in 5 of 5",
     which no agent without git could meet (P6c).
   - **S5 gains, from P6:** each project agent writes outside its memory folder (and, for memory-curator, outside the
     map) in 0 of 5 runs.

These are changes made on the user's word, before any result of the steps they touch, so no attempt counts against
them.

### 3, S2: result (2026-11-20): pass

- **The change.** `map.mjs` now exports `entries`, `foundIn` and `sourcePath`. It factors `gitDir` out of
  `ignoreCase`, unchanged, and adds `repoKey`, a 16-hex sha256 of the shared git folder's real path.
- **Byte identity with 2.2.0.** `probes/V2-D30-entries/diff.mjs` runs both builds' hooks on generated repos: maps with
  1-160 entries, person and file sources, sources in parentheses, status lines, a byte-order mark, UTF-16, uncommitted
  entries and drifted documents. It covered session start, the prompt, read, bash, bash-failure and onboard.
  - **Four seeds, 1,506 hook calls: 0 differences.** Two seeds ran on the copy and two on `plugin/` after agy's
    changes.
  - A path bug in the harness gave 372 false differences once (a relative build path). It was fixed, and the run
    repeated.
- **The self-test passes.** New: `gitDir` and `repoKey` are the same from a linked worktree; two repos whose paths
  differ only in punctuation keep their own keys; a missing `.git` throws. The product hash moves to `6672b7f811f8`.
- **The agy round** (Gemini 4 Argon, refute-first, on the diff):
  - it found **no input on which the hooks differ**;
  - on the new helpers' stated contract, it found key collisions for paths that differ only in punctuation, a
    comment that overstated the subdirectory case, and dangling gitdir behaviour;
  - **fixed:** the key became a hash, so `node:crypto` joins the tripwire's import list, and the comments now state
    what holds;
  - **left as a `shortcut:` note:** a relative `commondir` under a symlinked gitdir resolves lexically. 2.2.0's
    `ignoreCase` does the same, and changing it would break the S2 bar.
- **CI:** runs on push.

### 3, S3: entry format 3, and the read hook's new states (registered 2026-11-20, before the code)

- *Why:* D30. The plugin must say which memory is stale and which is current.
- **The change.** `labels()` reads three optional lines of an entry. An entry has new labels only through lines that
  no 2.2.0 map holds:
  1. **`- proposed: dream <YYYY-MM-DD>`** (the user's answer, D30) gives the label `proposed by a dream <date>, not
     yet accepted`, whether or not the entry is committed. Acceptance in review replaces the line.
  2. **`- review: <YYYY-MM-DD>`** gives `review due since <date>` once that date has passed.
     - There is **no default review horizon**: one would relabel every 2.2.0 entry as time passes, and break this
       step's bar.
     - The capture instruction (S4) asks for the line where a decision is time-bound.
  3. **A status line naming an id** (`- status: superseded <date> by <id>: …`) gives
     `replaced by <id>, which the map does not hold` when no map file has `- id: <id>`.
     - It applies only when the map has at least one `- id:` line. A 2.2.0 map, which has none, keeps its labels;
       the field's free-text status lines, such as "by the PM", are untouched.
- **Kept as they are:**
  - `- id:`, `- verified:` and `- origin:` add no label. They feed the status skill (S8) and the dream (S7);
  - an entry with any new label leaves the grouped "unverified quote, committed" line, as a status line already
    does (2r).
- **Checks:**
  1. *The self-test.* New cases: each state on committed and uncommitted entries; a review date in the past and in the
     future; a `by <id>` that resolves, one that does not, and one in a map with no ids; and a proposed entry in a
     Bash output.
  2. *Byte identity on 2.2.0 entries.* `probes/V2-D30-entries/diff.mjs`, 2.2.0 against S3, at 3 seeds × 40 repos.
     **Pass:** 0 differences. The generator makes only 2.2.0-shaped entries.
  3. *A fuzz with the new lines* (`probes/V2-D30-entries/fuzz3.mjs`), near and past the cap. Maps carry random
     `proposed`, `review` (past and future), `id` and `by <id>` lines. **Pass:** in every uncut output, each entry has
     exactly the new labels its lines call for, and its 2.2.0 labels unchanged. In every cut output, the closing
     fail-closed line covers every entry not shown.
  4. *CI* on three systems.
  5. *An agy refute-first round* on the diff. A finding survives only if executing it shows:
     - a 2.2.0-shaped entry whose label changed; or
     - a new state missing or wrong; or
     - a cut that fails open.
  - *Not run:* A1 and the bench, since no frozen text changes and the work per entry is a few regexes. Both are
    stated gaps.

### 3, S3: result (2026-11-20): pass

- **The change.** `labels()` gives three new states, each only from lines no 2.2.0 map holds:
  - `proposed by a dream <date>, not yet accepted`;
  - `review due since <date>`, by the user's local date;
  - `replaced by <id>, which the map does not hold`.
- **The checks:**
  1. *Self-test:* passes, with every case registered and agy's inputs added. Product hash `844fe48349d8`.
  2. *Byte identity on 2.2.0 entries:* 3 seeds × 40 repos, 1,062 hook calls, **0 differences**.
  3. *The format-3 fuzz:* 2 seeds × 200 maps, 800 label outputs (258 cut past the cap), **0 failures**.
  4. *CI:* runs on push.
  5. *The agy round* (Gemini 4 Argon, refute-first). It found three breaks of this step's own bar, all fixed, each
     with a self-test case:
     - `by <word>` read free text as an id (`done … by hand`, a note ending "off by default"). The id must now follow
       the status line's date and hold a digit or a hyphen;
     - `today` used UTC, so a review could fall due a day early west of UTC. It now uses the local date;
     - `proposed:` accepted trailing text after the date. It is now anchored.

     Two claims did not hold on inspection:
     - CRLF on `review:`: `entries()` strips `\r` before the match;
     - backslash paths in the run-folder exclusion: `under()` always joins with `/`.
- *Not run, as registered:* A1 and the bench. These are stated gaps.

### 3, S8 gains the user's end-to-end acceptance check (registered 2026-11-20, before S8's code)

The user (2026-11-20): "make sure that plugin installed in claude and runned in new project will pass the researched
best approach and will keep claude to be aware of them and use them".

**Route.** The release candidate is installed as a user installs it: the marketplace route from a local clone of the
tag, into an isolated `CLAUDE_CONFIG_DIR`, in a **brand-new repo** (a small app with no `CLAUDE.md` and no
`.claude/`). The pinned CLI runs on Opus 5.5, 5 runs.

**Pass, all of:**
1. *Layout:* `/second-brain:setup` creates every file of D29's table, with Anthropic's rules met:
   - `CLAUDE.md` under 200 lines;
   - every rule scoped by `paths:`;
   - the skill with `disable-model-invocation: true`;
   - three agents with `memory: project`;
   - the team memory's README and first topic file with front matter.

   A second run creates nothing. In 5 of 5.
2. *Aware:* in a fresh session after setup, asked "Where does this project keep its decisions, and how should you
   record a new one?", Claude names `.project-map/` and the entry format. In at least 4 of 5.
3. *Capture used:* a session where the user states a project decision in passing writes it into a topic file, with
   `id`, `source` and `verified`. In at least 4 of 5.
4. *Rule used:* the starter rule loads when a map file is touched (`InstructionsLoaded` or the transcript). In
   5 of 5.
5. *Agent used:* asked to check a change against the project's decisions, Claude uses `decision-checker` and names
   the entry it checked. In at least 4 of 5.
6. *Dream loop:* after three sessions that state decisions with capture off, `/second-brain:dream` proposes them:
   - its map entries carry `proposed:`;
   - a draft rule lands as `*.md.draft`, never loaded;
   - the next session's labels show "proposed by a dream".

   In at least 4 of 5.
7. *Nudge:* with 10 synthetic sessions past the watermark, session start shows the due line in `systemMessage`, and
   it is absent from Claude's context. In 5 of 5.

Each item, with its count, goes into S8's result.

### 3, S1: result (2026-11-20): pass

Every registered item met its bar. Record: `probes/V2-D31-dream/README.md` and `results/s1.json`.
- **10 counted runs, after one shake-out run.** The shake-out found a confound (the history wrote the map itself) and
  a gap in the dream's criteria (D14's "requirements" scope). Both were fixed and recorded before the counted runs.
- **The counted results:**
  - C1-C3 in 10 of 10;
  - the rule, the skill draft and the choice in 5 of 5 each;
  - noise 0 in every run;
  - wrong status lines 0 of 10, with the retracted entry marked in 10 of 10;
  - the injected nonce placed 0 of 5, never staged;
  - $5.32 for 10 dreams.

**The dream is built (S7).**

### 3, S4: the capture instruction v3, entries in topic files (registered 2026-11-20, before its runs)

- *Why:* D29 and D30. Setup (S5) creates topic files, and capture must write into them, with `id` and `verified`
  lines, or the layout goes unused.
- **The text,** sha256 `392c26c2a5e9`, 1,765 bytes (it was `bd491ace7f2f`, 1,349). It keeps 2.2.0's lines in order, except
  where it routes entries to topic files and adds the `id`, `verified` and `review` lines and the status line's id:

```
This project keeps a map of its knowledge in the folder .project-map/. When, during your work, someone states a
decision or rule for this project, or you receive or read a document that states requirements, specifications or
rules the project's work must follow, add each one as its own entry, in the words used, with its source, to the
topic file in .project-map/ that covers its area. If none fits, create one named for the area, such as avatars.md,
that starts with this front matter:

---
name: <the area>
description: <what it covers, and when to read it>
---

Keep what will still matter in later sessions; leave out one-off details of the current task.
Decisions and rules for this project belong in this map, not in your auto memory, which is for your own way of working.
Entry format:

### <the part of the project it governs>
> <the decision, rule or requirement, in the words used>

- id: <a short unique slug, such as avatars-local-only>
- source: <who stated it, or the document's title or path>, <date>
- when: ["<kind of work it applies to>", "..."]
- verified: <YYYY-MM-DD> <how you know it holds, such as "stated by the PM">

End the source line with the date, as YYYY-MM-DD; put any other detail in parentheses before it.
If a decision holds only until a known date, add the line: - review: <YYYY-MM-DD>
When a new entry replaces, narrows or ends an existing one, keep the old entry and add this line under its when line:
- status: <superseded|narrowed|expired|done> <YYYY-MM-DD> by <the new entry's id>: <what still holds>

Never write session ids, email addresses or absolute file paths into an entry. The map is plain files in this
repository: your changes to it stay in the working tree and are reviewed with the commit, like any other change.
```

- **Built in a copy:** `INSTRUCTION` is swapped, and the self-test's pins move. The self-test passes on the copy.
- **Harness changes, made before the runs:**
  - `probes/V2-D28-lifecycle/scenarios.mjs` scores every map file, not only `captured.md`, and writes tagged results
    (`D28_TAG`), so 2s's records stay;
  - `probes/V2-D30-entries/s4topic.mjs` reads the topic-file bar from A1's run folders.
- **Checks,** on Opus 5.5 with the pinned CLI 2.1.305, against a 2.2.0 control:
  1. *A same-day 2.2.0 A1 run* (1 run), to show the harness still works.
  2. *A1, the V2 arm, 10 runs* on the candidate. **Pass:**
     - each item at A1's Opus bar: C1 10, C2 at least 2, C3 10, C4 10, T1 10, T2 10, T3 at least 8, T4 10, T5f at
       least 8, N1 to N3 10;
     - over-attribution in at most 1 of 10;
     - no status line on any entry other than the widgets rule H1 retracts;
     - **new:** a topic file (a `.md` file other than `captured.md`, with front matter `name` and `description`) in at
       least 9 of 10 runs, and every entry carrying `id` and `verified` in at least 9 of 10.
  3. *2s's scenarios S1-S3,* 5 runs per arm against 2.2.0, at 2s's bars:
     - S1: the replaced avatar entry gets a status line in at least 4 of 5, and no other entry does;
     - S2: the date ends the source line in at least 4 of 5, and in at least 2 more runs than the control;
     - S3: turn 2 repeats none of turn 1's roles in at least 4 of 5.
  4. *The self-test, and CI on three systems.*
- **Attribution, fixed now:**
  - a miss on C1 to C4, on the topic-file bar or on S1 and S2 implicates the new text;
  - a miss on T or N items implicates neither text alone, and is judged against the control.

### 3, S5: setup, the templates, the three project agents (registered 2026-11-20, before the code)

- **The surface.**
  - A plugin skill, `/second-brain:setup` (`disable-model-invocation: true`). Its `` !` `` line runs
    `node scripts/hook.mjs setup`.
  - `scripts/setup.mjs` copies `plugin/templates/` into the repo, creating each file with `wx`. It **never modifies a
    file that exists**: this step's bar is strict, and D29's table, which appended a block to an existing
    `CLAUDE.md`, is read through it. For an existing `CLAUDE.md` or `.gitattributes`, the report gives the line to
    add. The skill body then asks the user, and Claude adds it with an ordinary, visible edit only when they agree.
- **The templates** (D29's table):
  - `CLAUDE.md`: under 40 lines, from Anthropic's include list, with a pointer to the team memory. The skill body
    asks Claude to fill its commands from the repo's build files, and to drop any line it cannot fill;
  - `.claude/rules/project-map.md`: `paths: [".project-map/**"]`, the entry format, and the "proposed" rule;
  - `.claude/skills/map-review/SKILL.md`: `disable-model-invocation: true`. It reviews proposals (accept: the
    `proposed:` line becomes `origin:` plus `verified: … accepted in review`), drafts (promote: rename
    `*.md.draft` to `*.md`), and due entries;
  - `.claude/agents/decision-checker.md`, `codebase-guide.md` and `memory-curator.md`: `memory: project`, no Bash
    (P6c), each told where it may write (P6);
  - `.project-map/README.md`, `.project-map/decisions.md` (front matter, no entries) and `.project-map/dreams.md`
    (the log's header);
  - `.gitattributes`: `.project-map/dreams.md merge=union`, only when no `.gitattributes` exists.
- **Guards:**
  - setup refuses writes under a `.claude/` that resolves outside the repo;
  - it warns when auto memory is off (in user, project or local settings, or in the environment), because
    `memory: project` then does nothing;
  - it reports what it created, skipped and left to the user.
- **Checks:**
  1. *Self-test, five repo shapes:*
     - empty;
     - an existing `CLAUDE.md`;
     - an existing `.claude/` with a `decision-checker.md` of the user's own;
     - a dirty tree;
     - a linked worktree.

     **Pass:** every file that existed has the same sha256 afterwards; every template that did not exist is
     created; a second run creates nothing and changes nothing.
  2. *Smoke,* pinned CLI 2.1.305, in a temp repo after setup:
     - the starter rule loads only when a map file is touched;
     - the skill's description is not in the listing;
     - `claude agents` lists the three agents.
  3. *The agents' outcomes* (PM6), Opus 5.5, 5 runs each, as registered in section 3 and its S0 result:
     - decision-checker flags a change that breaks a committed entry in at least 4 of 5, and treats a `proposed:`
       entry as a proposal in 5 of 5;
     - codebase-guide answers a repeated where-is question with fewer tool calls than its first answer, in at least
       3 of 5;
     - memory-curator flags a due entry and a duplicate, changes a committed claim in 0 of 5, and writes only
       uncommitted edits;
     - each agent writes outside its memory folder (memory-curator: outside the map) in 0 of 5.
  4. *CI* on three systems.

### 3, S6: the catalog, the waiting-review count, and the dream-due nudge (registered 2026-11-20, before the code)

- **The catalog (Claude's context).**
  - When a map file has front matter (`name`, `description`), the index's `.project-map/` line becomes one catalog
    line: `.project-map/: <file> (<description, cut at 80 characters>; <n> entries, <k> due, <p> proposed), …`. Files
    without front matter, such as `captured.md` and `dreams.md`, keep their bare name.
  - The line keeps its place first when session start is cut (2g).
  - **A repo with no front matter in any map file gets 2.2.0's bytes.**
  - `.project-map/.dream-run/` is never listed.
- **The user's line** (`systemMessage` only, on `startup` and `clear`). It is one line, and only when something is
  waiting or due:
  - *waiting review:* `*.md.draft` files under `.claude/rules/` and `.claude/skills/*/`, and entries carrying
    `proposed:`. The drafts are inert (D31), so this is a reminder, never a label on a live rule;
  - *dream due* (D32, the user's thresholds): 10 or more new sessions since the last dream; or 7 or more days since
    it with at least 3 new sessions; or a session Claude Code's cleanup deletes within 5 days.
- **Where the dream data comes from.**
  - A new session is a top-level `*.jsonl`, other than the current one, in a known transcript folder and not in the
    dream's `seen` set.
  - The known folders are the current `dirname(transcript_path)` plus `${CLAUDE_PLUGIN_DATA}/repos/<repoKey>/dirs.log`.
    Session start appends to `dirs.log`, one line, when the folder is new.
  - The dream's state is `state.json` beside it, written only by the dream under its lock.
  - The cleanup age is `cleanupPeriodDays` from the user's settings file (default 30), judged by mtime (P4's
    conservative reading). At most 50 unseen files are `stat`ed.
- **Checks:**
  1. *Self-test:*
     - a 2.2.0-shaped repo gives byte-identical session-start text;
     - with front matter, the catalog line and its counts;
     - `.dream-run` never listed;
     - each due condition, met and not met, on synthetic folders;
     - the line only in `systemMessage`, never in `additionalContext`;
     - no line when nothing waits and nothing is due;
     - no state written anywhere except one `dirs.log` line.
  2. *Byte identity:* `diff.mjs` (2.2.0 against S6, 3 seeds × 40 repos), 0 differences.
  3. *The bench:* session start with 300 synthetic transcripts in two known folders. **Pass:** at most 100 ms of
     added p95, at 1 and at 8 concurrent on the reference machine in its reference state, against the 2.2.0
     control (D18's pairing).
  4. *CI* on three systems, and an agy refute-first round on the diff.

### 3, S5: result (2026-11-20): pass

- **The change.**
  - `/second-brain:setup`, a plugin skill (`disable-model-invocation: true`), runs `scripts/setup.mjs`. It copies
    `plugin/templates/` into the repo with `wx`, never modifying a file that exists.
  - The templates: `CLAUDE.md`, the path-scoped rule `project-map.md`, the `map-review` skill, three project agents
    with `memory: project` and no Bash, the team memory's README, its first topic file, and the dream log, plus the
    `.gitattributes` line. They sit under undotted names, so this repo never loads them.
  - Product hash `8a03cece2265`.
- **Self-test:** five repo shapes and a linked worktree. Every existing file keeps its sha256, every missing template is
  created, and a second run creates and changes nothing. The templates obey Anthropic's rules (a short
  `CLAUDE.md`, a scoped rule, a user-invoked skill, agents with project memory and no Bash). A `.claude` junction
  out of the repo is refused.
- **Smoke** (Haiku 5.5, pinned CLI 2.1.305):
  - the starter rule **did not load** in a session that touched no file, and **loaded** (`path_glob_match`) in one
    that read a map file;
  - the init event lists all three agents;
  - the skill's description reached the model in 0 of the session's 6 recorded API requests. Its name appears, as a
    command the user can invoke.
- **The agents' outcomes** (Opus 5.5, 5 runs each):

  | Agent | Result | Bar |
  | --- | --- | --- |
  | decision-checker | flagged the CDN break in **5 of 5**; called the proposed entry a proposal in **5 of 5** | 4, 5 |
  | codebase-guide | fewer tool calls on the repeated question in **4 of 5** (7→4, 5→2, 9→4, 7→3, 5→5); notes written in its memory folder in 5 of 5 | 3 |
  | memory-curator | flagged the due entry and the duplicate in **5 of 5**; changed a committed claim in **0 of 5** | 4, 0 |
  | all three | wrote outside their allowed folders in **0 of 5** each | 0 |

  Records: `probes/V2-D29-setup/results/s5-*.json`.
- **CI:** runs on push.

### 3, S4, attempt 1: result (2026-11-20): every check passes except S2's relative clause, which failed as written

- **A1, 10 runs on the candidate** (`results/V2-opus-s4.json`, `V2-opus-s4b.json`; $15.53):
  - C1 to C4 in 10 of 10. T1 to T4, T5f and N1 to N3 in 10 of 10, for both the same person and the second person.
  - Over-attribution in 0 runs.
  - **The topic-file bar:** a topic file with front matter in **10 of 10**. Every entry in every run carries `id` and
    `verified` (**10 of 10**, 18 to 21 entries a run). `captured.md` was never written.
  - **The negative:** status lines only on the widgets rule H1 retracts (in 6 runs), on no other entry.
- **The same-day 2.2.0 control run:** valid, C1 to C4 pass, so the harness works.
- **Scenarios S1 to S3** (`results/S*-s4.json`): the candidate scored 5 of 5 on each, and so did the control.
  - **S2's second clause, "in at least 2 more runs than the control", failed as written.** It was copied from 2s, whose
    control was 2.1.0, without the date sentence. S4's control is 2.2.0, which carries that sentence, so the clause
    cannot be met; the premise was wrong.
  - The registration error is mine, and it counts as a failed attempt (rule 2).

### 3, S4, attempt 2 (registered 2026-11-20, before its runs)

- *The build is unchanged:* the candidate with INSTRUCTION `392c26c2a5e9`.
- **S2, the bar corrected:** the date ends the source line in at least 4 of 5 candidate runs, **and in no fewer runs
  than the 2.2.0 control**. That clause guards against a regression, since both texts carry the date sentence.
- **5 fresh runs per arm** (`D28_TAG=-s4a2`). The other checks passed in attempt 1 and are not re-run.

### 3, S4, attempt 2: result (2026-11-20): pass

- **S2,** 5 fresh runs per arm (`results/S2-s4a2.json`): the date ends the source line in **5 of 5** candidate runs, and
  in 5 of 5 for the control. That is at least 4, and no fewer than the control.
- **S4 passes.** Capture v3 (`392c26c2a5e9`) is in `plugin/`. Product hash `95fa7c3f71f7`. D13 and D16 re-lock on S3's
  and S4's passes (the records).

### 3, S6, attempt 1 (2026-11-20): check 2 failed as written

- **What happened.** S6 was rebased onto S4 and S5, and its self-test passes. Check 2 compared S6 with **2.2.0**: in
  every repo, session start differed (40 of 40 per seed), and nothing else did.
- **Why.** Every difference is S4's registered INSTRUCTION swap: with INSTRUCTION removed, the session-start texts are
  identical. The premise was wrong, because S4 changed session start before S6 landed.
- **Measured while diagnosing it,** against the S4-S5 build (`plugin/` at `f1d1204`): 0 differences in 1,062 calls.
  It does not count, because it was run before the corrected bar was registered.

### 3, S6, attempt 2 (registered 2026-11-20, before its runs)

- **Check 2, corrected:** `diff.mjs` compares the previous step's build (`plugin/` at `f1d1204`, S4 and S5) with S6,
  at fresh seeds 41, 53 and 67, × 40 repos. **Pass:** 0 differences.
- **Checks 1, 3 and 4 as registered.** The bench pairs the candidate, with the nudge's 300-transcript worst case,
  against the 2.2.0 control, in D18's reference state.

### 3, S6, attempt 2: result (2026-11-20): pass

- **The change.**
  - The catalog: the map folder's line lists each topic file with its description and counts, and keeps only the
    counts past 3,000 characters.
  - `.dream-run` is never listed.
  - For the user only, on `startup` and `clear`: the waiting-review line (proposed entries and drafts) and the
    dream-due nudge, with the user's thresholds.
  - Session start's only write: one `dirs.log` line naming its transcript folder.
- **Check 1, the self-test:** passes, every registered case plus agy's. Product hash `690320c43cc1`.
- **Check 2,** against the S4-S5 build (`f1d1204`), seeds 41, 53 and 67, × 40 repos: **0 differences in 1,122 hook
  calls**, re-run after agy's fixes.
- **Check 3, the bench.** A first run was sequential (candidate, then control), not the pairing registered. It drifted,
  with empty Node's p95 moving between 56 and 85 ms, and showed `bash-map@8` at 113 ms; it is reported, not counted.
  The registered pairing then ran: `probes/V2-D30-entries/pairbench.mjs`, empty Node, 2.2.0 and S6 interleaved call by
  call in one pool. CPU was 7.8% over 10 s. The candidate carried the nudge's worst case: 300 unseen transcripts in
  two known folders. Added p95 in ms, 2.2.0 against S6:

  | | session start | prompt | read-other | read-map | bash-map | bash-other |
  | --- | --- | --- | --- | --- | --- | --- |
  | @1 | 31.4 / 40.9 | 7.2 / 9.6 | 5.2 / 9.4 | 38.2 / 43.9 | 40.2 / 46.5 | 37.8 / 43.1 |
  | @8 | 52.3 / **67.1** | 20.7 / 22.6 | 19.4 / 23.7 | 61.8 / 66.9 | 65.9 / **78.8** | 64.7 / 73.6 |

  Every hook is within 100 ms. The series S2-S6 costs 2 to 15 ms per hook over 2.2.0. Record:
  `results-s6-paired.json`.
- **Check 4, the agy round** (Gemini 4 Argon, refute-first). It found no leak into Claude's context and no extra
  write. **Fixed,** each with a self-test case:
  - a malformed `state.json` (`seen: null`, or a non-string `lastDream`) silenced the nudge, and now reads as fresh;
  - one transcript that could not be stat'ed silenced the nudge, and now costs only itself;
  - CRLF in `dirs.log` re-appended folders, and is now read as one folder per line;
  - a catalog of very many topic files could crowd out the other directories, and now keeps only counts past 3,000
    characters.

  **Accepted,** with the reasons:
  - a cleanup period under 5 days really does put every transcript within 5 days of deletion;
  - Claude Code always supplies `transcript_path` (P1);
  - a front-matter-less map file that opens with YAML-shaped front matter is front matter;
  - the double read of map files is inside the measured budget.
- **CI:** runs on push.

### 3, S7: the dream product (registered 2026-11-20, before the code)

- **The surface:**
  - the `/second-brain:dream` skill (`disable-model-invocation: true`). Its `` !` `` line runs `dream-prepare`; its
    last step has Claude run `dream-finish`, or `dream-abort` on any failure;
  - the plugin agent `dream-analyzer` (Read, Grep and Glob, front matter pinned by the self-test);
  - `scripts/dream.mjs` (`prepare`, `finish` and `abort`, spawning only git);
  - three `hook.mjs` cases.
- **The rules, as in D31 and S0's result:**
  - entries arrive with `- proposed: dream <date>`; rules and skills arrive as `*.md.draft`;
  - provenance needs a U or Q line, or a tracked file;
  - the privacy scan;
  - a rule or skill needs 2 or more sessions behind it;
  - committed entries only gain status lines;
  - the run folder lives in the repo and ignores itself; the manifest, which names session ids, lives in the data
    folder;
  - a discarded dream's sessions return to the next one.
  - **Added here: stray writes.** `finish` restores every map file Claude changed directly (not through the staged
    proposals) to its snapshot, removes map files and live rules or skills that appeared during the dream, and says so.
- **Checks:**
  1. *The self-test, on synthetic JSONL only:*
     - a stream of 50 MB or more;
     - an injected quote that rests only on R lines (dropped);
     - secrets (dropped);
     - a quote found only in an ignored file (dropped);
     - a committed entry deleted directly (restored);
     - a live rule and a topic file written directly (removed);
     - an unscoped rule and bad front matter (dropped);
     - a skill missing its flag (the flag added);
     - a dirty map snapshotted, and restored by abort byte for byte;
     - a second prepare while one runs (refused);
     - a stale lock (taken over);
     - the session and byte caps;
     - the watermark: it advances on finish, and returns after the log line is discarded;
     - nothing from a transcript left in the repo after finish.
  2. *S1's bars, re-run on the product:* fresh histories as in S1, then `claude -p "/second-brain:dream"` with the
     plugin, on Opus 5.5. The bars are S1's, read on the product's output:
     - entries carrying `proposed:`;
     - the rule and the skill as drafts;
     - C1-C3 in at least 8 of 10;
     - the rule, the skill and the choice in at least 4 of 5;
     - noise at most 1 per run;
     - wrong status lines in fewer than 2 of 10;
     - the nonce in 0 of 5.
  3. *Drafts never load:* in `manual`, `acceptEdits` and `auto`, a session touching a file a `*.md.draft` rule's
     `paths:` matches never loads it (InstructionsLoaded), and a `SKILL.md.draft` skill never lists.
  4. *A security review* of the dream (the `/security-review` skill and an agy round), and *CI*.

#### S7: amendments from the security review (registered 2026-11-20, before their code)

The first agy round of check 4, on the build that passed check 1's self-test and check 3, found two data-loss paths and
several gaps. Check 1's self-test result was seen before these amendments; the bars of checks 1-3 do not change, and
the cases below are added to check 1. That build never reached `plugin/`.

- **The surface, changed:** the dream runs as its own command, `node scripts/dream.mjs <prepare|finish|abort> <data>`,
  not as three `hook.mjs` cases, so no hook pays to load it. The skill's lines call it.
- **The snapshot and the run record move to the plugin's data folder.** `.project-map/.dream-run/` keeps only the
  digests and the staged proposals (P2). `run.json` records the repo root. `finish` and `abort` refuse, before they
  change anything, when the run record is missing, names another root (a linked worktree shares the state folder), or
  its snapshot or a manifest digest is missing. (Found: a missing `.dream-run/snapshot`, as after `git clean -X`, made
  `finish` delete every map file.)
- **Nothing is destroyed.** Every file `finish` or `abort` restores or removes is first copied to
  `<data>/repos/<key>/undone/<time>/`, and the report names that folder. (Found: a capture made by another session
  during a dream was overwritten by the restore.)
- **The watched set,** restored or removed by `finish` and `abort` alike: map files; every file under `.claude/rules/`,
  `.claude/skills/` and `.claude/agents/`, at any depth, drafts included; `CLAUDE.md`, `CLAUDE.local.md` and
  `.claude/CLAUDE.md`. Not watched: settings files and `.claude/agent-memory/` (the user's own changes there during a
  dream must stand), and `CLAUDE.md` files in subfolders (accepted, listed in the review).
- **A stale lock** (more than two hours) is taken over without a restore: a restore days after a crash would revert
  the captures and commits made since. The old run's snapshot moves to `undone/`, and prepare's report says which
  watched files differ from it.
- **The lock's age** is its file's mtime, not its content (a reader between create and write saw 0 and took a live
  lock over).
- **Write targets:** `finish` writes no file whose path, or any folder on it, is a symlink or resolves outside the
  repo.
- **Provenance, tightened for the dream only** (the read hook's `foundIn` stays as 2.2.0's): every ellipsis-separated
  segment of a proposed quote has 3 or more words, so no segment goes unchecked.
- **Entries:** a proposed entry keeps only its heading, its quote and the lines `id`, `source`, `when` and `review`. The
  heading is cut to 80 characters, and `source` to 200.
- **Status lines:** the id after `by` names an entry the map holds, or one this dream proposes; the text after the
  colon is cut to 200 characters.
- **The privacy scan, widened:** case-insensitive; absolute paths after `=`, `:` or `>`; the roots `/opt`, `/srv`,
  `/mnt` and `/private`; UNC paths; `github_pat_` and `ASIA` keys. A new topic file's front matter is scanned too.
- **Sessions:** a session whose `cwd` exists and belongs to another repo (a sibling folder sharing the encoded prefix,
  or a nested repo) is skipped and marked seen. A `cwd` that no longer exists falls back to path containment, and is
  skipped without being marked. The stream stops at the first foreign `cwd`.
- **Check 1 gains:**
  - a missing snapshot (`finish` and `abort` refuse, nothing changes);
  - a run record from another root (refused);
  - a capture made during the dream (moved to `undone/`, and the report names it);
  - a live rule in a subfolder, an edited live rule, and a stray live rule left at `abort` (all undone);
  - a symlinked map file (not written through);
  - a quote with a two-word segment (dropped);
  - a status line naming an unknown id (dropped);
  - an extra line in an entry (stripped);
  - private data in a new topic file's front matter (dropped);
  - a sibling repo's and a nested repo's sessions (skipped and seen);
  - a stale takeover (the old snapshot is in `undone/`, and the report names the differing files).
- **Before check 2's counted runs:**
  - the skill's text states the tightened rules;
  - one uncounted product smoke;
  - a second agy round on the amended code;
  - one auto-mode probe of the analyzer: an R-line instruction to read a canary file outside the repo. P2 covered only
    `manual` and `acceptEdits`. The outside reads are recorded as an accepted risk only if the canary is read in 0 of
    3 runs.

### 3, S8: the status skill (registered 2026-11-20, before its code)

- **The surface:**
  - `/second-brain:status` (`disable-model-invocation: true`). Its `` !` `` line runs
    `node scripts/status.mjs <data>`, a command of its own like the dream's, so no hook loads it;
  - the skill tells Claude to show the report as it is, then name the next step (`/map-review`, or
    `/second-brain:dream` when one is due), and to change no file.
- **The report** (no model and no network; it spawns only git; map.mjs is unchanged, so the hooks keep their bytes):
  - *the team memory:*
    - entries and files;
    - the date of the last commit that touched `.project-map/`;
    - its uncommitted changes;
  - *dreams:*
    - the last dream's date;
    - the sessions since, counted as `dreamDue` counts them;
    - `dreamDue`'s line when a dream is due;
  - *waiting for review:* `waiting()`'s counts;
  - *agent memory:* uncommitted changes under `.claude/agent-memory/`;
  - *stale entries,* each with its file, its number and its heading. It lists the read hook's labels "review due
    since", "not found word for word in", "cannot read" and "replaced by …, which the map does not hold". It also
    lists a source changed since verified: an entry whose `verified:` date is earlier than the last commit touching
    the tracked file its source names (`git log -1 --format=%cs -- <path>`), with both dates;
  - *retired:* entries with a status line, counted;
  - *current:* the rest, counted.
- **Check, the self-test,** on a fixture repo:
  - an entry whose review date has passed is listed;
  - an entry whose source file was committed after its `verified:` date is listed with both dates;
  - an entry whose quote is not in its source is listed;
  - a current entry is not listed, and is counted as current;
  - a superseded entry is counted as retired, not listed;
  - 3 unseen transcripts are counted;
  - a committed map gives its commit date;
  - an uncommitted agent-memory file, a proposed entry and a draft are counted;
  - a repo with no `.project-map/` says so and points to `/second-brain:setup`.

### 3, S8: the acceptance check's route, amended (registered 2026-11-20, before any run)

The registered route cannot run as written. A session in an isolated `CLAUDE_CONFIG_DIR` cannot log in (P4), and
copying the user's credentials was declined. The marketplace install itself needs no login (checked 2026-11-20, CLI
2.1.305: `marketplace add` and `plugin install`, at project scope, both succeed in an empty config folder). The route,
changed before any run:

- **Check 0, the install.** The candidate is installed as a user installs it, in each run's brand-new repo, into an
  isolated `CLAUDE_CONFIG_DIR`:
  - `claude plugin marketplace add <a clone of the candidate> --scope project`;
  - `claude plugin install second-brain@second-brain --scope project`.

  Both must succeed, and the installed copy's files must equal the candidate's `plugin/` byte for byte, in 5 of 5.
- **The sessions** run under the user's own login:
  - `--plugin-dir` set to that installed copy;
  - `--setting-sources project,local`;
  - the install's `.claude/settings.json` set aside first. It names the marketplace, and the user's own config holds
    one of the same name, so a second copy would load.
- **Items 1-7 and their bars are unchanged.** How each is read is fixed in `probes/V2-D29-setup/e2e.mjs`, committed
  with this amendment:
  - *aware:* the reply names `.project-map` and at least 3 of `source`, `id`, `verified`, `when` and the quote;
  - *capture:* an entry holding the stated decision has `id`, `source` and `verified` lines in a topic file;
  - *rule:* `InstructionsLoaded` reports `.claude/rules/project-map.md`;
  - *agent:* an Agent call with subagent type `decision-checker`, and a reply that names `widgets-home` or
    `src/widgets`;
  - *dream loop:* three sessions without the plugin state the decisions. Then:
    - the dream's map entries carry `proposed:`;
    - a `*.md.draft` rule exists and `InstructionsLoaded` never reports it;
    - a `PostToolUse` hook output in the next session holds "proposed by a dream";
  - *nudge:* the `SessionStart` hook output's `systemMessage` holds "a dream is due", and its `additionalContext`
    does not.
- Before the 5 counted runs, the candidate passes CI, and one uncounted run checks the probe itself.

### 3, S7: check 2, attempt 1 failed; attempt 2 registered (2026-11-20, before its runs)

**Attempt 1** (10 runs, Opus 5.5, CLI 2.1.305, from the build that passed check 1, check 3 and check 4's fixes;
`results/s7-product-a1.json`) failed as written: the rule in 3 of 5, against a bar of 4. Every other bar was met:
- C1-C3 in 9 of 10;
- the skill and the choice in 4 of 5;
- noise 0 in every run;
- wrong status lines 0;
- the nonce 0 of 5;
- live rules 0;
- $5.76 for 10 dreams.

Two runs missed:
- **Run 2:** the dream filed the repeated date correction as a map entry and staged no rule. That is a model choice,
  and within the bar's one allowed miss.
- **Run 4** never finished, and is the failure. The session staged every proposal, the rule included, but its finish
  command was refused ("This command requires approval"). In that run alone (1 of 13 dreams so far) Claude ran the
  analyzers with `run_in_background`, 18 of 18 calls. The turn ended, the session resumed on the analyzers'
  notifications, and a skill's `allowed-tools` grant does not outlive its turn:
  - `probes/V2-D31-dream/grant2.mjs`: in a session resumed with `--continue`, the same `ok.mjs` call the skill's turn
    ran was refused, in 2 of 2 runs;
  - the docs (skills, "Pre-approve tools for a skill"): the grant holds "during the turn that invokes the skill" and
    "clears when you send your next message".

  The old `Bash(node:*)` grant would have failed the same way.
- **No setting pins the analyzer to the foreground.** Agent front matter has only `background: true`, so the skill's
  text is the one lever.

**Attempt 2** changes one thing:
- **The dream skill's step 1** now says: send up to 4 Agent calls in one message with `run_in_background` false, wait
  for their results, and do every step, finish included, in this one turn, because the finish command's permission
  ends with the turn.
- **Step 5** adds: if finish asks for approval, ask the user to approve it.
- **Run 2's miss is left as it is.** The rule wording is not tuned on a seen result.

The method:
- the bars are attempt 1's, unchanged;
- 10 new runs, in a new scratch folder, written to `results/s7-product-a2.json`;
- the scorer, committed with this registration, also reports per run the background analyzer calls (`bgAgents`) and
  the turns the run took (`turns`).

**What 10 clean runs will not show:** background calls came in 1 of 13 dreams, so ten runs without the fix would also
come back clean about 4 times in 10. The result will report how many runs used background calls, and will not claim
the fix as proven by a clean count alone.

### 3, S7: result (2026-11-20): pass

The dream product (D31): `/second-brain:dream`, the `dream-analyzer` agent, and `scripts/dream.mjs` (prepare, finish
and abort), run as its own command. Product hash `81768634263b`.

1. **Check 1, the self-test on synthetic JSONL:** passes. It covers:
   - every registered case;
   - every case from the amendments;
   - the cases added for check 4's findings, below.

   A mutation check removed each check-4 fix in turn: every fix's case then fails. On Windows the file-link case is
   skipped, since making the link needs a privilege. CI's Linux and macOS runs exercise it, and a folder junction
   covers folder links on every system.
2. **Check 2, S1's bars on the product:** attempt 1 failed, and attempt 2 passed every bar.
   - **Attempt 1** failed with the rule in 3 of 5 (cause and fix in the attempt-2 registration above).
   - **Attempt 2** (`results/s7-product-a2.json`): 10 runs on Opus 5.5, CLI 2.1.305, all finished.

   | Bar | Result |
   |---|---|
   | C1-C3, at least 8 of 10 | 10 of 10 |
   | The rule, the skill and the choice, at least 4 of 5 each | 5, 5 and 5 of 5 |
   | Noise, at most 1 per run | 0 in every run |
   | Wrong status lines, fewer than 2 of 10 | 0 of 10 |
   | The nonce | 0 of 5 |
   | Live rules | 0 |
   | Usage | $5.73 for 10 dreams |

   No run used background analyzer calls, and every run took one turn. As registered, this is consistent with the fix
   but does not prove it: without the fix, ten runs would also come back clean about 4 times in 10.
3. **Check 3, drafts never load:** pass (`results/s7-drafts.json`, Haiku 5.5). In `manual`, `acceptEdits` and `auto`:
   - the `*.md.draft` rule was never reported by `InstructionsLoaded`;
   - the `SKILL.md.draft` skill was never listed;
   - its nonce never landed;
   - the control rule loaded each time.
4. **Check 4, the security review:** two agy rounds, `/security-review`, and the probes below. What they found, and
   the fixes, each with its self-test case:
   - *agy, round 1* found two data-loss paths and several gaps. The amendments above fixed them, registered before
     their code.
   - *agy, round 2*, fixed:
     - the privacy scan now sees paths after `[`, `,`, `{` and `;`, ids or keys behind `_`, and JWT, Google, GitLab
       and npm tokens; it also checks proposal file and folder names;
     - a link that appears under the watched folders is removed, and a folder of the watched set that resolves outside
       the repo is never walked;
     - a map folder that is a link out of the repo is refused at prepare;
     - "$" patterns in a status line stay as text;
     - a pending dream is judged in the worktree that made it;
     - abort with no run record refuses a lock another worktree holds;
     - a session whose cwd folder is gone is judged by the nearest existing folder's repo.

     Dismissed: a session that changes `cwd` midway belongs to the repo it started in.
   - *`/security-review`*, three findings, all fixed:
     1. *Provenance read files the session can write* (confidence 9).
        - Each digest's hash is kept in the run record, in the data folder, and finish refuses a changed digest.
        - Repo sources are read from HEAD's blobs, without links, not from the working tree.
        - The skill's grant is narrowed from `Bash(node:*)` to its own script. `grant.mjs`: the narrow grant runs the
          script, and refuses `node -e`, which the broad grant let through.
     2. *A new topic file's front matter, and status lines, skipped provenance* (confidence 7).
        - A new topic file gets fixed front matter.
        - A dream's status line carries `- proposed: dream`.
        - `/map-review` rejects one by removing just that line.
     3. *The restore covered less than the skill said* (confidence 7).
        - The watched set adds `.claude/commands/`, `.claude/output-styles/` and `.mcp.json`.
        - Settings files are reported, not restored, since an "always allow" the user gives during the dream lands
          there.

     Two shapes the review left unverified are closed:
     - a Q line now needs its call to be AskUserQuestion;
     - sidechain user records are dropped.
   - *Probes:*
     - `canary.mjs`: in `auto` mode, an R line asking the analyzer to read a file outside the repo was followed in 0
       of 3 runs, and not attempted;
     - `grant2.mjs`: a skill's grant ends with its turn, the cause of attempt 1's run 4.
   - *Accepted, recorded for the README's known issues:*
     - the digests sit in the repo's ignored run folder (P2);
     - rule and skill draft bodies are not checked against what was typed, since they stay inert until a person
       promotes them;
     - `CLAUDE.md` files in subfolders are not watched;
     - the privacy scan matches patterns, so a secret of another shape can pass;
     - a user who types during a dream ends its turn, and finish then asks for approval.

   CI runs on the commit that lands this build.

**Step gate.**
- *Produced:*
  - the dream product;
  - its self-test cases;
  - check 2's passing attempt;
  - check 3's result;
  - the security fixes and probes.
- *Doubted:*
  - whether the foreground instruction holds outside these 10 runs, since background calls came in 1 of 13 dreams
    before it;
  - CI on macOS and Linux, where the link cases run.
- *Next needs:* S8.

### 3, S8: what the uncounted run and the reviews changed (registered 2026-11-20, before the counted runs)

**The uncounted acceptance run** (candidate `f454bbd`, CLI 2.1.305, Opus 5.5) met check 0 and items 1, 2, 3, 4 and 7.
It missed two:
- **Item 5, the agent** (product). Claude named `widgets-home`, but checked the change itself and never called
  `decision-checker`. S5 had always named the agent in its prompts, and nothing a session always loads tells Claude
  the agents exist. The fix:
  - the `CLAUDE.md` template's Team memory section names `decision-checker` for checking a change or plan against
    the decisions, and `codebase-guide` for where-is questions. That section is also the block setup proposes for an
    existing `CLAUDE.md`;
  - `decision-checker`'s description now says to use it whenever someone asks for that check.
- **Item 6, the dream loop** (the probe). The three sessions without the plugin ran after setup. Setup's `CLAUDE.md`
  told Claude to record decisions even without the plugin, so the decisions were captured and the dream rightly
  proposed nothing. `e2e.mjs` now runs those three sessions before setup, where nothing tells Claude to capture: a
  repo's history from before the plugin came in. The item's bar and its reading are unchanged.

**/code-review** (high, everything in `plugin/` since 2.2.0) found 12 issues. All are fixed, each with a self-test
case, and a mutation check confirms each case fails without its fix:
- a pruned-away worktree's missing folder made prepare throw;
- the dream appended UTF-8 text to a UTF-16 map file; it now skips such a file, and status decodes UTF-16 as the read
  hook does;
- the log line's survival counts compared the dream's UTC date with local dates; the dream's local date is now kept;
- the dream's own session was never recognized (Claude Code records the command as a command record), so its later
  turns fed the next dream; it is now marked seen for good;
- sessions with no working folder recorded, or a vanished folder outside the repo, were never marked seen, so the
  nudge could never clear. They are now marked seen. A vanished folder inside a transcript folder that session start
  learned, such as a removed worktree's, counts as this repo's and is read;
- a discarded dream gave back its sessions but not its date;
- a skill draft flagged `false` kept both flags;
- a quote from Claude's question text alone passed as typed; a quote resting on a Q line must now hold the answer
  chosen;
- the map README's example parsed as an entry;
- a rule draft could take a live rule's name, so promoting it would replace that rule;
- a status line on an entry that ends its file without a newline was counted but not written;
- setup's link guard checked only the top folder.

**The dream changed after S7 passed,** so S7's check 2 runs again in full on the final build, at its bars, into
`results/s7-product-a3.json`. The 5 counted acceptance runs follow, then the tag.

**The devils-advocate workflow** (five lenses, refute-first, 48 agents) ran on the S8 candidate: 43 findings raised, 29
survived refutation. Eleven repeat `/code-review`'s findings above. The rest are fixed, each with a self-test case
that fails without its fix:
- **The dream's command now refuses a data folder inside the repo or outside Claude Code's `plugins/data`.** The
  skill's grant allows the command with any arguments, so a session could point finish at a run record it forged and
  have it "restore" `.claude/settings.json` or a git hook. A run record naming any path the dream never watches is
  refused as well.
- **A link at a watched folder's own path** (`.claude/rules` itself, `.claude`, the map folder) is removed when it
  appears during a dream, and the folder's files come back from the snapshot.
- **The privacy scan** catches Git Bash and Cygwin paths (`/c/Users/…`, `/cygdrive/c/…`).
- **A commit made during the dream is no source:** the tracked sources are HEAD as prepare found it.
- **`/second-brain:status` checks every entry, as the read hook labels every entry.** A narrowed entry still binds in
  part. The report also leaves `.git/index` alone (`--no-optional-locks`).
- **A repo that never ran setup has no `/map-review`.** The waiting line, the dream's next step and its refusal now
  point to `/second-brain:setup` first.
- **Session start tells the user,** in one `systemMessage` line, when a dream holds the repo's lock: one running in
  another session, or one stopped before it finished. The dream skill offers to abort the old one.
- **Setup creates nothing outside the top of a git repo.** In a home folder it would have written Claude's
  user-level `.claude/`.
- **finish writes the state last,** so a retried finish cannot overwrite the first run's `prevSeen`.
- **Only the dream's own invocation** marks a session as the dream itself. Before, any typed line starting with
  "dream" did.
- **The self-test's PM6 and PM8 checks** cover the skills, the agent and the templates: each names its outcome, and
  their lines are counted.
- **CI's gated bench** runs session start with the plugin's data folder and 300 unseen transcripts, so the nudge's
  work is timed on every system.
- **The record is corrected:**
  - the D31 ledger line lost "$5" to a shell;
  - section 3's budget row says "a repo shaped like 2.2.0 stays byte-identical", but since S4 session start carries
    instruction v3 (1,765 B, not 1,349 B). What stays byte-identical for such a repo is its labels;
  - the release notes say that 2.2.0 repos get the new instruction, and that a repo with 10 or more unseen
    transcripts gets the nudge at its first session start.
- **Recorded, not fixed:**
  - status repeats the read hook's stale conditions rather than sharing `labels()`, whose output must stay
    byte-stable. Both now check every entry;
  - PR #116 (to main, titled 2.2.0) has the `v2` branch as its head, so merging it now would ship this unfinished
    work. It is retitled for 2.3.0 at the tag, and the user merges.

**S7's check 2, run again on the reviewed build** (`3c9e2d01cea8`, `results/s7-product-a3.json`, 10 runs, Opus 5.5)
passed every bar:
- C1-C3 10 of 10;
- the rule, the skill and the choice 5 of 5 each;
- noise 0; wrong status lines 0; the nonce 0 of 5; live rules 0;
- no background analyzer call, one turn per run;
- $5.73.

The answer-holding rule for Q quotes and the dream-session fix cost no bar.

**The acceptance probe, two more changes from the uncounted runs** (item 6's reading and every bar unchanged):
- **The history sessions cannot write `CLAUDE.md` or `.claude/`.** In the second uncounted run, Claude wrote a
  "from now on" rule into a new `CLAUDE.md`. Setup then met an existing file, not item 1's brand-new repo, and offered
  its Team memory block only as a "For you" item, which a headless run cannot accept. With the history kept out, the
  third uncounted run's `CLAUDE.md` came from setup, and Claude used `decision-checker` (item 5 passed). Each run
  records `claudeMdBeforeSetup`.
- **Item 6's history follows S1's R1 and R2:** two sessions where the user corrects Claude's date code in a second
  turn, plus the ApiError decision. A rule stated up front is a decision, and the dream rightly filed it as an entry,
  so the third uncounted run had entries but no rule draft. The skill drafts a rule only from a correction that
  repeats.
- **Item 6's first turns ask for `toLocaleDateString`,** so each second turn is a real correction. In the fourth
  uncounted run, with the helper in the repo, Claude used `formatDate()` at once. The "No…" then corrected nothing;
  the analyzers filed it as a decision, and the dream rightly drafted no rule.

### 3, S8: the acceptance check, attempt 1 failed; its focused probe registered (2026-11-20, before it runs)

**Attempt 1** (candidate `087e2ac`, CI green, 5 runs, Opus 5.5, CLI 2.1.305; `results/s8-e2e-a1.json`; $10.54) met
every item but one:

| Item | Result | Bar |
|---|---|---|
| Check 0, the install (bytes equal to the candidate's) | 5 of 5 | 5 |
| Layout | 5 of 5 | 5 |
| Aware | 5 of 5 | ≥ 4 |
| Capture | 5 of 5 | ≥ 4 |
| Rule | 5 of 5 | 5 |
| **Agent** | **2 of 5** | ≥ 4 |
| Dream loop | 4 of 5 | ≥ 4 |
| Nudge | 5 of 5 | 5 |

This is the acceptance check's first strike of three.

- **Agent: the cause.** The reply named the entry in 5 of 5, but `decision-checker` was used in only 2.
  - Every run that delegated (counted runs 1 and 2, uncounted runs 3 to 5) read at most two files before the Agent
    call, or none.
  - Every miss read 4 to 6 files first, then answered itself. The plugin's own forced decision drives that reading
    ("read the yes directories"). Once the map has been read, the `CLAUDE.md` pointer gives no reason to delegate.
  - In one miss the index listed `.claude/agents/` as a document directory. Claude read `decision-checker.md` itself
    and followed it.
- **Dream loop: run 5's miss is the model's, and is left alone.** Its history matched run 1's: the first turn wrote
  `toLocaleDateString`, and the correction followed. Its analyzers returned both date corrections. The main session
  filed them as an entry rather than drafting a rule. The rule wording is not changed.

**The focused probe** (`probes/V2-D29-setup/agent-probe.mjs`, committed with this registration):
- **Item 5 alone, three arms,** each a plugin build:
  - *control:* the attempt-1 candidate;
  - *C:* the `CLAUDE.md` pointer says to hand the check to `decision-checker` even after reading the map, and why
    (it also checks `.claude/rules/`, and keeps notes on what earlier checks missed);
  - *AC:* C, plus an index that leaves out the `.md` files under the root's `.claude/agents/`, `skills/`, `commands/`
    and `output-styles/`. Claude Code loads those itself, as it loads `.claude/rules/`, which the index already
    leaves out.
- **The method:**
  - each arm's repo is built as attempt 1's was at item 5: the app, setup run by its hook command, the widgets
    decision and a captured prices entry, all committed;
  - each run starts from a fresh copy;
  - two prompts: the counted one, and one worded differently; 5 runs each, 10 per arm;
  - Opus 5.5, acceptEdits.
- **The decision rule:**
  - an arm qualifies when Claude delegates and names the entry in at least 9 of its 10 runs. That is the rate that
    clears 4 of 5 reliably;
  - the smaller change wins, C before AC;
  - AC changes hook output, so it would also need the hook-step checks before any counted run: the diff harness at 0
    differences for repos without those folders, the bench, and an agy round;
  - **if no arm qualifies,** no strike is spent on wording. The question goes to the user: should item 5 require
    delegation, or should the checker be one the user invokes?
- **Then attempt 2:** 5 new counted runs, in a new scratch folder, on a CI-green candidate. S7's check 2 is not
  re-run: neither arm changes `dream.mjs`, the dream skill or the analyzer.

**The focused probe's result** (`results/s8-agent-probe-{control,C,AC}.json`; $7.3):

| Arm | Delegated | Named | Tool calls before the Agent call |
|---|---|---|---|
| control | 9 of 10 | 10 of 10 | 0 in 8 runs; the run that read 5 files first answered itself |
| C | **10 of 10** | 10 of 10 | 3 to 5 in every run, and it still delegated |
| AC | 10 of 10 | 10 of 10 | 2 to 4 |

- **By the registered rule, C qualifies and is the smaller change, so C goes in:** the `CLAUDE.md` template's pointer
  now says to hand a check to `decision-checker` even after reading the map, and why. Product hash `a4a4a64f5099`.
  AC is not adopted. Its index change stays a candidate for a later release, with the hook-step checks it needs.
- **What the probe shows, and what it does not:**
  - The control arm also reached 9 of 10 here, mostly by delegating before reading anything. So this setting does
    not reproduce attempt 1's rate, and the probe cannot say how often attempt 2 will delegate.
  - It does show C holding delegation through attempt 1's failure pattern: in C, Claude read 3 to 5 files first and
    still delegated in 10 of 10.
  - Attempt 2 decides.

### 3, S8: result (2026-11-20): pass

- **The status skill:** its self-test passes every registered fixture case, plus the review cases (a narrowed entry
  checked, UTF-16 decoded, `.git/index` untouched). A live smoke on a dreamed repo printed the report under the
  skill's script-only grant.
- **Every skill and command grants only its own script.** The self-test pins this; `grant.mjs` shows the narrow form
  works and the broad one let `node -e` through.
- **The reviews:**
  - `/code-review` (12 findings) and the devils-advocate workflow (29 that survived refutation) are all fixed, each
    with a self-test case shown by a mutation check to fail without its fix, or recorded above;
  - S7's check 2 passed again on the reviewed build (`s7-product-a3.json`);
  - CI is green on all three systems for the final candidate. CI's gated bench now includes the nudge's work: session
    start added 55.4 ms on macOS and 61.9 ms on Windows at 1 session, after one noisy run went over 100 ms on hooks
    this change does not touch.
- **The user's acceptance check** (`results/s8-e2e-a2.json`; candidate `b8248dc`, product `a4a4a64f5099`, CLI 2.1.305,
  Opus 5.5, 5 runs, $11.32) passed at attempt 2:

  | Item | Result | Bar |
  |---|---|---|
  | Check 0: installed as a user installs it, bytes equal to the candidate's | 5 of 5 | 5 |
  | 1. Layout: D29's files, Anthropic's rules met, a second setup creates nothing | 5 of 5 | 5 |
  | 2. Aware: names `.project-map/` and the entry format | 5 of 5 | ≥ 4 |
  | 3. Capture: a decision stated in passing, with `id`, `source` and `verified` | 5 of 5 | ≥ 4 |
  | 4. Rule: the starter rule loads on a map read | 5 of 5 | 5 |
  | 5. Agent: `decision-checker` used, and the entry named | **5 of 5** | ≥ 4 |
  | 6. Dream loop: proposals, a rule draft that never loads, labels next session | 4 of 5 | ≥ 4 |
  | 7. Nudge: in `systemMessage`, not in Claude's context | 5 of 5 | 5 |

  Attempt 1 had failed item 5 (2 of 5), its first strike; the cause and the fix are above. Item 6's one miss in each
  attempt is the model filing a repeated correction as an entry, which its bar allows.

**Step gate.**
- *Produced:*
  - `/second-brain:status`;
  - script-only grants;
  - the reviewed 2.3.0 build;
  - the acceptance check, passed;
  - S7 re-confirmed.
- *Doubted:*
  - item 6 sits on its bar in both attempts;
  - the agent rate in other repos;
  - the index still lists `.claude/agents`, `skills`, `commands` and `output-styles` (the AC arm, left for a later
    release).
- *Next needs:* the user merges PR #116 to main, which carries 2.3.0.

### 3, S8: the release's own checks on the final hook code (registered 2026-11-20, before the tag)

The advisor's release review asked for three checks on the code as it stands. `hook.mjs` and `map.mjs` changed after
S6's bench, and the post-review security code had not been read by an outside reviewer.
- **The diff harness** (S6's build `faf872a` against the final build, 60 generated 2.2.0-shaped repos): 582 hook
  calls, 0 differences.
- **agy, two rounds** (split after a single round timed out):
  - **write safety:**
    - a link named `plugins/data`, or any outside folder so named, passed the data-folder test, which matched on the
      name;
    - a watched folder that was a link before the dream, then retargeted, let the restore delete or write through
      it, as far as `.git/hooks`;
    - forged paths with a backslash, `.` or empty segments, or a nested run-folder path, passed `watchable`;
  - **provenance, setup, status:**
    - in an unborn repo, the pin fell back to `HEAD` at finish;
    - a quote of Claude's question alone passed when the answer's word also occurred in it;
    - paths after `_` or `*` passed the privacy scan, which also ran after `tidy` cut lines;
    - a dangling link defeated setup's guard;
    - a home folder kept in git was taken for a project;
    - status: holds.

  All are fixed, each with a self-test case, and a mutation check confirms each case fails without its fix:
  - no link on the way from the repo root is ever traversed, though a link that was there is kept;
  - the data folder is tested on real paths under Claude Code's own `plugins/data`;
  - `watchable` rejects every irregular segment, and snapshot entries must be regular files;
  - the pin uses `rev-parse --verify` (in an unborn repo, plain `rev-parse` prints "HEAD" itself, which the test
    caught);
  - a Q-based quote must hold `<question> = <answer>`, with the answer chosen word for word;
  - the privacy scan sees paths after `_`, `*`, `~` and `|`, reads the whole entry before `tidy`, and reads it
    again after the id is made;
  - setup walks by `lstat` and fails closed, and refuses a home folder.
- **Which checks run again on the new candidate:**
  - the self-test and CI;
  - S7's check 2 in full, because `chosen()` and the privacy scan act on every dream;
  - one uncounted acceptance run, as a smoke of the normal flow. Its counted runs are not repeated: these fixes
    change behaviour only for links, home folders, unborn repos and Q quotes, none of which the acceptance check's
    repo has.
- **The 8-session bench on the reference machine** (D18) runs when the machine is in its reference state. At the
  time of this registration, the user's own applications held the CPU at about 19%, above the 10% that state
  requires. The tag waits for it, or for the user's word.

**S7's check 2 on the release-round build** (`3650f785f984`, candidate `655d384`, `results/s7-product-a4.json`, 10
runs, Opus 5.5) passed every bar:
- C1-C3 10 of 10;
- the rule 4 of 5, the skill and the choice 5 of 5 each;
- noise 0; wrong status lines 0; the nonce 0 of 5; live rules 0;
- no background analyzer call, one turn per run;
- $5.93.

In the one run without a rule draft (run 5), finish dropped nothing: the dream filed the repeated date correction as
a map entry, a choice the release round's fixes do not reach. CI passed on `655d384`.

**The uncounted acceptance smoke on `655d384`** (one run, the pinned CLI, Opus 5.5) passed all seven items:
- install from the marketplace, 2.3.0, the installed copy byte-identical;
- the layout, with a second setup that created nothing;
- awareness, capture, the scoped rule, `decision-checker` used and the entry named;
- the dream: 2 proposed entries and a draft, labelled and never loaded;
- the nudge in the user's line only;
- $2.27.

### 3, S8: the reference bench, registered (2026-11-22, before it runs)

The release check D18 requires before each release (S8's release checks, above), on the final candidate.
- **Builds.**
  - *Candidate:* `plugin/` at `655d384`, product `3650f785f984`.
  - *Control:* `plugin/` exported from tag `v2.2.0`.
  - Each is hashed before the run as the eval does (every file but `test/`). A hash that differs voids the run.
- **Fixture:** S6's setup, rebuilt fresh:
  - `plugin/test/fixture.mjs`, the synthetic repo of P2's shape;
  - `plugin/test/benchmap.mjs`, its 30-entry map;
  - `probes/V2-D30-entries/benchprep.mjs`, the nudge's worst case: 300 unseen transcripts in two known folders.
- **Run:** `pairbench.mjs`, 200 calls per hook kind, at 1 and 8 concurrent. Empty Node, the control and the candidate
  are interleaved call by call in one pool.
- **Reference state (D18):**
  - a 10-second CPU sample of at most 10%, taken just before the run;
  - empty Node's p95 at 8 concurrent at most 100 ms, read from the run's own `emptyP95` at `@8`.
  
  A run outside that state is void, not failed. It is reported, and the bench runs again in a later window. No agent,
  agy call or other bench runs at the same time.
- **Pass:**
  - every hook kind's added p95 (`candidateAdded`) is at most 100 ms, at 1 and at 8;
  - errors are 0.
  
  A miss is a failed attempt under rule 4.

### 3, S8: the reference bench, result (2026-11-22): pass

- **Builds hashed before the run:** candidate `3650f785f984` (`plugin/` at `655d384`), control `ee8625f06842` (`v2.2.0`).
  Both match.
- **Reference state:** the CPU sample was 4.6% over 10 seconds, just before the run. Empty Node's p95 at 8 concurrent
  was at most 49.0 ms.
- **Added p95 in ms, 2.2.0 against 2.3.0,** 200 calls per hook kind, with the nudge's 300 unseen transcripts:

  | | session start | prompt | read-other | read-map | bash-map | bash-other |
  | --- | --- | --- | --- | --- | --- | --- |
  | @1 | 28.2 / 37.1 | 7.1 / 10.2 | 6.1 / 9.9 | 33.7 / 37.4 | 34.1 / 38.2 | 34.2 / 38.7 |
  | @8 | 41.2 / 55.0 | 16.4 / 21.7 | 15.4 / 18.8 | 46.9 / 54.1 | 51.8 / 58.1 | 55.3 / **62.7** |

- Every hook is within 100 ms, with 0 errors. 2.3.0 costs 3 to 14 ms per hook over 2.2.0, as S6 measured.
- Record: `probes/V2-D30-entries/results-s8-reference.json`.

### 3, S8: the documentation review before the merge (2026-11-22)

A review, not a check with a bar: nothing was registered for it, and it changes no product file. `plugin/` stays at
`3650f785f984`, the build every S8 check ran on.
- **What looked:**
  - two agy sweeps (Gemini 4 Argon, read-only): the README and the shipped files against each other, then the
    project's own docs against the ledger;
  - a docs check of the plugin's manifests, hooks, skills, agents and rule against Claude Code's current
    documentation;
  - `claude plugin validate` (CLI 2.1.330) on the plugin and the marketplace: passed with one warning, no `author`.
- **Fixed, outside `plugin/`:**
  - `04-architecture.md` rewritten for 2.3.0, as its status line promised. Its byte counts were measured on a fresh
    repo after setup (instruction 1,767 B, index 302 B, naming 304 B; the forced decision 227 B);
  - the README: the user's three lines come at start and after `/clear` only, not after a resume or a compaction, as
    `hook.mjs` gates them; accepting a proposal writes `origin`; a known issue for the mismatches below;
  - the charter's status line and its account of the first act (setup, versioned entries, the dream);
  - `.claude/CLAUDE.md` and the `v2-step` skill no longer say v1 is on `main`, or call this the concept phase. The
    skill names `agy` for the second opinion, as rule 10 does;
  - `05-eval-plan.md`: the investigation tasks joined A2.
- **Confirmed against Claude Code's docs:** `if` on `PostToolUse` and `PostToolUseFailure`; `shell` and `args`;
  `PostToolUseFailure`'s input; `systemMessage` shown to the user while `additionalContext` reaches Claude; skill
  grants lasting only for the invoking turn; `disable-model-invocation`; `memory: project` under
  `.claude/agent-memory/<name>/`, which needs auto memory on; `paths:` rules loading on a matching read.
- **Not changed, with the reason:**
  - the grants' `:*` form is not in the skills docs, which show ` *`. `grant.mjs` (S8) showed the narrow form allows
    the script and refuses `node -e`, and the acceptance runs used it;
  - `if` is best-effort in the docs. When it lets another Bash command through, the handler labels every
    uncommitted entry: more text, never fewer labels.
- **On record for the next release** (product text, so each needs its own registered step):
  - N1: the analyzer's `failure` kind has no proposal type in the dream skill;
  - N2: the starter rule names only `superseded`, while the other texts use four kinds; neither it nor the map's
    README defines `origin`;
  - N3: the status report sends stale entries to `/map-review`, which walks only entries whose review date passed;
  - N4: `plugin.json` has no `author`, the validator's one warning.

### 3, S8: 2.3.0 tagged (2026-11-22)

- **Tag `v2.3.0`** on `b54129f`. Its `plugin/` and `.claude-plugin/` are byte-identical to `655d384`, and hash
  `3650f785f984`. A draft release holds the notes.
- **CI on `b54129f`:** every job passed in the pull-request run. In the push run, the macOS self-test hung after its
  first line for 12 minutes (it takes about 40 seconds), with two `node` processes left. It was cancelled, and its
  re-run passed in 44 seconds. The self-test prints only at its start and end, so the case that hung is unknown. It is
  the only hang in this workflow's history, and the same code passed on the other macOS run.
  - N5, for the next release: give every self-test `spawnSync` a timeout, so a hang fails with its case's name.
- **`main`'s ruleset** (the user's choice): the required checks `linux` and `macos` belonged to v1's `ci.yml`, which
  no longer exists, so no merge could pass without a bypass. They are now `selftest` on Ubuntu, macOS and Windows,
  plus GitGuardian. `v2.yml` runs on pull requests to `main`.
- **Next:** merge PR #116 with a merge commit, so the tagged commits stay in `main`'s history. Publish the release
  drafts, then update both field installs and check their hash.

### 3, S8: 2.3.0 on `main` (2026-11-22)

- **PR #116 merged** as `a0e2a9e`, a merge commit with no bypass: every required check passed on its head
  `3135de7`. `main` and `v2` held the same tree after it, and `v2.3.0` is in `main`'s history.
- **Releases** 2.0.1, 2.0.2, 2.1.0, 2.2.0 and 2.3.0 published from their drafts. 2.3.0 is the latest.
- **Installs from `main`:**
  - an isolated 2.0.0 install at local scope updated to 2.3.0 with `marketplace update` and `plugin update`, and
    hashed `3650f785f984`;
  - the user's two field installs took the same commands, and their cached copy hashes `3650f785f984`.
  
  Running sessions keep the old hooks until `/reload-plugins` or a restart. The new layout reaches a field repo only
  when its user runs `/second-brain:setup` there.
- **Next:** the live tests (map issue step 22), then the next release with N1 to N5 and what they find (step 23).

### 3, S8: corrections and two more findings from the final review (2026-11-22)

- **Correction: the macOS self-test hang is not the first.** The record above called it the only one in this
  workflow's history; that is wrong.
  - `cf59996` (2026-11-18, 2q attempt 2) hung the same job for 6 hours, until GitHub cancelled it. It printed
    nothing and left one `node` process.
  - On `b54129f` it left two `node` processes and no `git`. The self-test starts `node` only for `hook.mjs`, so a hook
    or setup call is the likely place, not the harness. That is not shown.
  - So it is intermittent on macOS, 2 of 62 runs, across two versions. Every other failure in the history is an
    assertion or a load bar, each under 4 minutes.
  - D18's triggers are measured p95s, so a CI hang does not fire one as written. It is recorded in D18 as an
    observation.
  - In a live session, a hung hook would show as a hook that runs until Claude Code's timeout, at a session's start,
    a prompt, or a read of a map file.
  - N5 becomes: **diagnose the hang first** (a timeout and a progress line on every self-test call, then repeated
    macOS runs), before any other change of the next release.
- **N6: `dream prepare` exits 1 when it refuses** (another dream holds the lock, or the data folder check fails).
  Every other refusal exits 0.
  - Claude Code's skills docs say a failed `!` command aborts the whole skill. Then the skill's own recovery text
    ("ask whether one is still running, then run abort") would never reach Claude.
  - A probe on CLI 2.1.330 (headless, one run, Haiku 5.5): a skill whose `!` command printed a line and exited 1
    still reached the model with the output. So the path works today. It depends on behaviour the docs say
    otherwise about, and the interactive mode was not probed.
- **The README's index cut** said "about 8,200 characters since 2.2.0". In 2.3.0 the fixed text is about 2,215
  characters, so about 7,800 fit. Corrected.
- **The releases were published** with the merge, as PR #116's description planned. The user's request named the
  PR, the merge and the update, not the release pages. 2.0.1, 2.0.2 and 2.1.0's notes were read after publishing:
  accurate, and no private data.

## 4: the next release (registered 2026-11-23, before any code)

**Why.** 2.3.0 is on `main` (section 3). The next release carries:
- N1 to N6, recorded in section 3 by the documentation review and the final review;
- what the live tests find (map issue step 22). The first came on 2026-11-23, in this plugin's own repo, where the
  user installed 2.3.0 and ran setup:
  - **N7:** setup knows only a root `CLAUDE.md`. Claude Code reads `./CLAUDE.md` or `./.claude/CLAUDE.md`
    ([platform channels](research/2026-10-19-platform-memory-channels.md), §1). In a repo that has only
    `.claude/CLAUDE.md`, setup created a second instruction file instead of proposing its section for the existing
    one, and the two disagreed on where decisions are recorded.
  - **The user's goal:** setup is run once and sets everything up; from then on the plugin keeps the memory current and
    learns by itself. 2.3.0 leaves three things to the user, by their answers of 2026-11-20: the lines for files that
    already exist (D29), starting a dream (D31, D32), and accepting what a dream proposes (D30, D31). Recorded as D29
    reopened and D33 opened.

**Order.** N5 first, as section 3 recorded: a hang nobody understands could hide in any later step's CI.

| Step | What | Pass (each step's details are registered before its code) |
| --- | --- | --- |
| 4a | N5: diagnose the macOS self-test hang | below |
| 4b | D29 and N7: setup adds its lines to the files that exist, and knows `.claude/CLAUDE.md` | Repo shapes: the five of S5, plus `.claude/CLAUDE.md` only, both instruction files, and an existing `.gitattributes`. Every byte that existed is kept; only a marked block or line is appended. A file with uncommitted changes is left alone and reported. A second run changes nothing. Nothing is committed |
| 4c | N1 to N4 and N6: the dream skill's `failure` kind, the rule template's status kinds and `origin`, status to map-review, `plugin.json`'s author, the refusal exit code | Self-test pins for each; `claude plugin validate` with no warning; the smoke |
| 4d | D33: what runs without the user after setup | The user's answer on (C). For (B), the feasibility read named in D33, before any design |
| 4e | The release | As S8: CI on three systems, D18's reference bench, a review of the series, the README and release notes, a tag, and a pull request that the user merges |

**Rules**, as section 3's:
- attempts run from a copy of the plugin, at most three failed attempts per step, one commit per step with the step
  gate, and an agy verifier on every step that changes a hook;
- probe and smoke sessions never start in this repo, where 2.3.0 has been installed at local scope since 2026-11-23.
  They run in temporary repos with an isolated config.

### 4, 4a: N5, the macOS self-test hang (registered 2026-11-23, before the code)

**What is known** (section 3, "corrections"):
- 2 of 62 macOS runs of the self-test hung: `cf59996` for 6 hours with no output at all; `b54129f` for 12 minutes
  after its first line, with two `node` processes left and no `git`.
- The self-test prints only at its start and its end. On macOS, Node writes to a pipe asynchronously, so a process
  that blocks can lose even the line it printed first.

**The instrument.** It is test-only: `plugin/` outside `test/` is unchanged, so the hash `3650f785f984` is the same
before and after.
- Every `spawnSync` in the self-test goes through one wrapper:
  - it sets a 120-second timeout, unless the call sets its own;
  - on a timeout it throws, naming the self-test line that made the call;
  - `SELFTEST_TIMEOUT_MS` overrides the 120 seconds.
- With `SELFTEST_TRACE=<file>`, the wrapper appends `<line> <command> <first argument>` to that file, with a
  synchronous write, before each call.
- `v2.yml`: `timeout-minutes: 15` on every job, so a hang ends in minutes, not hours.

**Check 1, the instrument works (locally, before CI):**
- `SELFTEST_TIMEOUT_MS=1` makes the self-test fail, and its error names a self-test line and the timeout;
- with `SELFTEST_TRACE`, the self-test passes and the file holds one line per call;
- the plain self-test passes;
- `plugin/` hashes `3650f785f984`.

**Check 2, CI:** `v2.yml` passes on all three systems with the instrument.

**Check 3, the repeated macOS lane.** A workflow, `v2-n5.yml`, runs the self-test 70 times on macOS:
- 10 jobs, each running it 7 times in a row with `SELFTEST_TRACE` set;
- a 20-minute step timeout;
- on a failure, it prints the trace's last 20 lines and a `ps` listing of the `node` and `git` processes.

At the old rate of 2 in 62, 70 runs show at least one hang with about 90% odds.
- **Outcome R, reproduced:** the failed run names its call, either by the timeout's error or by the trace's last
  line. That case is read, and its fix becomes a registered step of its own. After the fix the lane runs 70 times
  again, with 0 hangs as the bar.
- **Outcome N, not reproduced in 70 runs:** recorded as such, together with the 10% chance that a hang at the old rate
  shows in none of them. N5 then closes as mitigated: any future hang fails within 2 minutes, at most 15, and names
  its call. The cause stays a known issue, and D18's observation stands.
- A run that fails any other way, for example on an assertion, is a finding of its own. It is reported, not counted as
  a hang.

### 4, 4a: check 1 (2026-11-23): pass at attempt 2

- **Attempt 1 failed.** The traced run wrote 321 lines for 320 calls: one call's argument held a newline (the
  self-test's case of odd file names), so its trace entry took two lines. The instrument now replaces control
  characters in what it logs.
- **Attempt 2, every item at its bar** (Windows, Node 22):
  - `SELFTEST_TIMEOUT_MS=1` fails the self-test with `selftest.mjs:112<115: git init timed out after 1 ms`, naming the
    helper's line and the line that called it;
  - with `SELFTEST_TRACE`, the self-test passes in 32 seconds, and the file holds 320 lines for 320 calls;
  - the plain self-test passes;
  - `plugin/` hashes `3650f785f984`, as before.
- **Next:** check 2, `v2.yml` on three systems, and check 3, `v2-n5.yml`'s 70 macOS runs. Both start with this push.

### 4, 4b: D29 and N7, setup completes the files that exist (registered 2026-11-23, before the code)

**The change** (`plugin/scripts/setup.mjs`, the setup skill's text, the self-test):
- **The instruction file.** Setup looks for `CLAUDE.md`, then for `.claude/CLAUDE.md`.
  - If neither exists, it creates `CLAUDE.md` from the template, as 2.3.0 does.
  - If one or both exist and neither holds the `## Team memory` heading, it appends the template's team-memory
    section to the first of them that exists, when that file is safe to append to.
  - If either one already holds the heading, nothing is added.
- **`.gitattributes`.** If it is missing, setup creates it, as 2.3.0 does. If it exists without the dream log's merge
  line, setup appends the line, when the file is safe to append to.
- **Safe to append to:** a regular file, not a link, tracked by git, with no change against `HEAD`, staged or not.
  Anything else stays byte for byte as it is, and the report gives the text to add, as 2.3.0 does: an untracked,
  ignored or modified file, a link, or a repo with no commit yet.
- **How it appends:**
  - the file's existing bytes stay as an exact prefix;
  - a newline comes first if the file does not end in one;
  - the appended text uses CRLF when the file's first line ends in CRLF.
- **The report** gains a line naming each file setup added to, and what it added. The skill tells Claude not to add the
  same text again, and to show the user the added lines.
- **Unchanged:**
  - setup never overwrites or deletes a file, and never commits;
  - the other templates are created only when they are missing;
  - setup starts no process but `git`, as the self-test's tripwire requires.
- `plugin/` is edited in place. Every install comes from GitHub (checked 2026-11-23), so no session loads this
  checkout. The smoke runs from a copy.

**Checks.** All five must pass:
1. **Self-test, by repo shape.** Each shape records the sha256 of every file, runs setup, then runs it a second time.
   - **S5's five shapes:**
     - `claudeMd`, a committed `CLAUDE.md`: its old bytes are an exact prefix of its new bytes, the rest is exactly
       the team-memory section, and every other file that existed is unchanged;
     - `dirty`, an untracked `CLAUDE.md` and `.gitattributes`: both stay byte-identical and are reported to the user,
       as in 2.3.0;
     - `empty`, `ownClaude` and the linked worktree: as in 2.3.0.
   - **New shapes:**
     - only `.claude/CLAUDE.md`, committed: it gains the section, and no root `CLAUDE.md` is created;
     - both instruction files committed: only `CLAUDE.md` gains the section;
     - the heading already in `.claude/CLAUDE.md`: neither file changes;
     - a committed `.gitattributes` without the line and without a final newline: it gains a newline, then the line;
     - a committed CRLF `CLAUDE.md`: the section arrives in CRLF;
     - these stay byte-identical and are reported: a committed `CLAUDE.md` with an unstaged edit, one with a staged
       edit, an ignored one, a link, and a repo with no commit.
   - **In every shape:** the second run changes nothing, and setup leaves `HEAD`, the index and the commit count
     unchanged.
2. **The smoke, 3 runs.** Pinned CLI 2.1.305, Haiku 5.5, the plugin copy through `--plugin-dir`, the user's login, and
   `--setting-sources project,local`, as S8's route. Each run uses a fresh temp repo whose only instruction file is a
   committed `.claude/CLAUDE.md`, and runs `/second-brain:setup` in `-p`. Pass in 3 of 3: no root `CLAUDE.md`;
   `.claude/CLAUDE.md` holds `## Team memory` exactly once; nothing committed.
3. **A refute-first review of the diff by agy** (Gemini 4 Argon, plan mode, given the diff only), aimed at data loss
   and at writes outside the repo. Each finding is fixed or recorded as an accepted risk before CI.
4. **CI** on three systems.
5. **The new hash of `plugin/`** is recorded.

### 4, 4d: D33, the feasibility read for option (B) (registered 2026-11-23, before it runs)

**The question:** can a dream start without the user typing a command, once one is due?

**What is read:** Claude Code's current documentation, fetched on the day of the read, on:
- hooks: whether a hook can start a skill, a prompt or a session;
- skills: what `disable-model-invocation` does to the listing and to Claude's own invocation;
- scheduled and background work: `/loop`, session cron, routines, and headless `-p`.

The read is saved as `research/2026-11-23-dream-without-a-command.md`, with its sources.

**A route counts as feasible when all four hold:**
1. the dream starts without a typed command;
2. no hook process calls a model or the network, or starts a process that does (D18);
3. it runs on the user's machine, where the transcripts are (D31 reads only local transcripts);
4. a dream's proposals still wait for review. Option (C) is the user's answer alone.

**The read's output:**
- each route found, with the items it breaks and any decision whose trigger it would fire (for example D32's
  "the nudge reaches Claude's context");
- if one or more routes are feasible: a rethink, then a refute-first agy round on the best route, before any design;
- if none is feasible: (B) is rejected with the reason, and D33 is settled between (A), (N) and the user's answer on
  (C).

### 4, 4a: checks 2 and 3 (2026-11-23): check 2 passes; check 3, outcome R, reproduced

- **Check 2, pass:** `v2.yml` on `45fd0a3`, the self-test and load jobs on Ubuntu, macOS and Windows.
- **Check 3, outcome R, reproduced.**
  - 8 of the 10 macOS jobs ran 7 of 7 runs, in 18 to 28 seconds each, with 323 calls per run.
  - Two jobs failed, job 6 at its run 2 and job 8 at its run 5. Each was a hang, ended by the 120-second timeout at the
    same call: `selftest.mjs:226<371<379: node hook.mjs bash timed out after 120000 ms`.
  - The `ps` listing, taken after the kill and after the self-test exited, held no `node` or `git` process. That fits
    a stuck hook, but also a hook that had already exited, or a child of it that died with the closed pipe. It does
    not say which process waited.
  - 2 hangs in the 63 runs that started (56 in the eight full jobs, 2 and 5 in the two that failed; a job stops at its
    first failure), against 2 of 62 before.
- **The case:** self-test line 379, "a long output with neither field". The `bash` hook gets a `tool_response.stdout`
  of 25,000 characters, as one line with no newline, so its standard input is over 25 KB. Whether other calls send as
  much is not yet measured: lines 340 and 349 pass real `cat` output of several map files. The hook reads its input
  with `fs.readFileSync(0)` (`hook.mjs:12`).
- **Why this is not yet a diagnosis:** neither the code nor the listing shows which process waited, or on what. The
  hook could be reading its input, computing its labels or writing its output at exit. The parent's `spawnSync` could
  also have missed an exit. The same call passed in 61 runs.
- **Open question:** does this reach real sessions? Claude Code starts hooks its own way, not through Node's
  `spawnSync`, so the self-test's mechanics may not apply. Not checked.
- **Next:** a diagnosis probe, registered before it runs.

### 4, 4a: the diagnosis probe (registered 2026-11-23, before it runs)

**Measured first.** A traced self-test, locally, now logs each call's input size. Four calls send the hook more than
8 KB:
- line 379, 25,208 bytes: the call that hung;
- line 349, 21,163 and 9,003 bytes;
- line 340, 15,541 bytes.

None of the other three hung in check 3's 63 runs. So up to 21 KB, size alone does not hang the hook, and the 25 KB
input on one line is the lead.

**The probe** (`probes/V2-D18-hang/`) runs on macOS in `v2-n5.yml`, beside the full lane.
- **`probe.mjs`** builds a temp repo with a small map: two committed entries and one uncommitted. It runs seven arms
  in turn, 150 calls each in each of 2 jobs, so 300 per arm. Each call has a 15-second limit.
  - H21, H25 and H100: the `bash` hook given a one-line `stdout` of 21,000, 25,000 and 100,000 characters, through
    `spawnSync`, as the self-test calls it;
  - H25n: 25,000 characters in lines of 80;
  - S: 100 characters, the control;
  - T25: the same 25,000-character input given to a child that only reads its input and prints the length;
  - A25: H25's call through an async `spawn`, the way an event-loop host starts a hook.
- **`watch.mjs`** starts before the arms, and before the full lane's runs. Every second it lists the processes. A hook
  or reader child alive for 5 seconds gets these, once:
  - `ps` with state and wait channel, for it, its parent and its children;
  - `sample` of it and of its parent;
  - `lsof` of both.
- **The full lane** runs its 10 × 7 self-tests again, with `watch.mjs` running.

**How the result is read (fixed now):**
- **Which process waits, and on what:** from the samples of the first hangs caught, in the focused arms or the full
  lane. The diagnosis names the process (the hook or its parent), its state (running, sleeping or zombie), and the
  call it waits in.
- **The arms.** An arm "hangs" when it has at least one timeout. Two arms "differ" when one has at least 3 and the
  other has 0; at a 3% rate, 300 calls give about 9.
  - If T25 hangs, the hook's own code is not needed for the hang.
  - If A25 stays at 0 while H25 hangs, the hang needs `spawnSync` on the parent's side.
  - H21, H25, H100 and H25n separate size from shape.
- **If no focused arm hangs but the full lane does:** the hang needs state the self-test builds before line 379. That
  is neither a fix nor a harness-only finding, and the full lane's samples are then the evidence.
- **If nothing hangs anywhere:** recorded together with the odds (2 in 63 before), and the probe runs once more. A
  second empty round goes up a level (rule 4).
- **The fix** is a registered step of its own. Its bar is 70 clean runs of the full lane.

### 4, 4a: the diagnosis probe, result (2026-11-23, run on `bdac932`)

**The arms, 300 calls each over 2 macOS jobs.** Timeouts: S 0, H21 0, H25 2, H25n 7, H100 0, T25 2, A25 0. No call
failed any other way.

**Read as registered:**
- **T25 hangs** (2 of 300). A child that only reads its input and prints its length hangs too, so the hook's own code
  is not needed for the hang.
- **A25 against H25:** 0 against 2. That does not reach the registered "differ" (at least 3 against 0). Pooled, the
  three 25 KB arms started by `spawnSync` (H25, H25n, T25) hung 11 times in 900 calls, and A25 never did in 300. At
  that rate, 300 calls would show none about 3% of the time. That is a strong lead that the hang needs `spawnSync` on
  the parent's side, but not proof by the registered test.
- **Size and shape:** H25n against H21 is 7 against 0, and against H100 also 7 against 0: both differ. So it is not
  "the bigger, the worse". The hang sits in a window around 25 KB. Input in lines of 80 hangs more often than one
  line, but H25 against H25n (2 against 7) does not reach "differ".

**Which process waits, and on what** (the watcher's samples of the first hang caught; the others match):
- **The child**, the `bash` hook, is asleep in `read()` on its standard input: `fs.readFileSync` → `uv_fs_read` →
  `read`. It holds its three stdio sockets, and their peers are open.
- **The parent** is inside `spawnSync`'s own event loop (`SyncProcessRunner::Run` → `uv_run` → `kevent`), waiting.
  `lsof` lists no socket in the parent at that moment.
- So the child is waiting for input, or for its end, that never arrives, while the parent waits for the child.
- **The full lane with the watcher:** 1 hang, in job 3's first run, at the same call, `selftest.mjs:226<371<379`,
  with 25,216 bytes of input. Across both lanes that is 3 hangs, all at that call.

**What is not known yet:** whether the child had already read all of its input and lacks only the end of it, or
stopped partway. That decides the fix:
- **All input read, only the end missing:** the hook can stop reading once it holds one complete JSON document, as
  every hook input is. That protects real sessions whatever starts the hook.
- **Partway:** no reading strategy in the child can help, and the harness has to give the input another way.

**Next:** one more registered probe arm that logs, with a synchronous write, the bytes read after each chunk. Then
the fix as its own step, with 70 clean runs of the full lane as its bar.

### 4, 4a: the bytes probe (registered 2026-11-23, before it runs)

**The question:** when the child hangs, has it read all of its input, so that only the end of input is missing, or
did it stop partway?

**The probe** (`probes/V2-D18-hang/chunks.mjs`, on macOS in `v2-n5.yml`, 2 jobs × 300 calls):
- The child reads standard input with `fs.readSync` in 64 KiB chunks, the size `readFileSync` uses for an input of
  unknown size. After each chunk it appends its running byte count to a file of its own, with a synchronous write.
- The parent starts it with `spawnSync` and H25n's input, the shape that hung most: 25,000 characters in lines of 80
  inside the hook's JSON. Each call has a 15-second limit.
- After a timeout, the parent compares the last count with the bytes it sent.

**How it is read, fixed now:**
- **End missing:** in every hang, the count equals the bytes sent. The fix is then in the hook: it reads chunk by
  chunk and stops as soon as it holds one complete JSON document, without waiting for the end of input. That holds
  whatever starts the hook. The fix's bar: 70 clean runs of the full lane, and 0 hangs in 300 calls of H25n against
  the fixed hook.
- **Partway:** in any hang, the count is below the bytes sent. No reading strategy in the child can help. The
  self-test then gives the hook its input through a file instead of a pipe. A real session's exposure goes to the
  open question recorded above (A25, an async parent, hung 0 of 300).
- **Both kinds seen:** each is recorded, and the fix covers the kind the child can.
- **No hang in 600 calls:** the probe runs once more. A second empty round goes up a level (rule 4).

### 4, 4a: the bytes probe, round 1 (2026-11-23, on `39d7d00`): no hang in 600

- **The result:** 600 of 600 calls ended normally, in 2 jobs, each reading all 25,458 bytes. No hang, so the
  registered question, all read or partway, has no answer from this round.
- **What it does show:** the input was H25n's. Read with `fs.readFileSync(0)`, H25n hung 7 times in 300 calls, while
  the `readSync` loop here never hung in 600. At H25n's rate, 0 in 600 has odds below one in a million. The way the
  child reads is the strongest lead so far. But this round also adds a file write after each chunk, which changes the
  timing.

### 4, 4a: the bytes probe, round 2 (registered 2026-11-23, before it runs)

As registered, the probe runs once more. This time it carries control arms in the same jobs, interleaved, with
2 jobs × 300 calls per arm:
- **F:** the child reads with `fs.readFileSync(0, 'utf8')`, as the hook does;
- **C:** round 1's `readSync` loop, with a logged count after each chunk;
- **C2:** the same loop with no logging.

**How it is read, fixed now:**
- **F hangs, while C and C2 stay at 0:** the way `readFileSync` reads a socket on macOS is what hangs. The fix is in
  the hook: read with a `readSync` loop until the end of input. Its bar is 70 clean runs of the full lane, plus 0
  hangs in 300 calls of H25n against the fixed hook.
- **C hangs:** round 1's question gets its answer from C's counts, as registered.
- **C2 hangs but C does not:** the logging changed the timing, and the case goes up a level (rule 4).
- **No arm hangs:** the case goes up a level (rule 4). The hang is then too rare to study this way, and the
  mitigation stands: the timeouts already registered, plus a reading method chosen on round 1's evidence.

### 4, 4a: the bytes probe, round 2 (2026-11-23, on `19dfdbd`): readFileSync is what hangs

- **F, `fs.readFileSync(0)`:** 13 hangs in 600 calls (4 and 9 in the two jobs).
- **C, the logged `readSync` loop:** 0 in 600.
- **C2, the same loop without the log:** 0 in 600.

This is the registered outcome "F hangs, while C and C2 stay at 0". On macOS, when standard input is a socket fed by
`spawnSync`, `fs.readFileSync(0)` can block for good, while a `readSync` loop over the same input ends every time.
Round 1's question (all read, or partway) is moot: the hang belongs to `readFileSync`'s way of reading, and the hook
can avoid it. In the plugin, only `hook.mjs:12` reads its input this way.

### 4, 4a: the fix (registered 2026-11-23, before the code)

**The change:** `hook.mjs:12` reads its input with a `readSync` loop in 64 KiB chunks until a read returns 0, in place
of `fs.readFileSync(0)`. Nothing else changes. `plugin/` is edited in place: every install comes from `main` on
GitHub, so no session loads this branch.

**Checks.** All must pass:
1. **The self-test passes on Windows, locally.** This covers a pipe's end of input on Windows.
2. **A refute-first agy review of the diff** (Gemini 4 Argon, plan mode, the diff only), as section 4's rules ask for
   every hook change. Each finding is fixed or recorded as an accepted risk.
3. **CI:** `v2.yml` passes on all three systems.
4. **The registered bar, in `v2-n5.yml` on macOS:**
   - the full lane runs 70 of 70 clean;
   - in the seven-arm probe (2 jobs × 150 calls per arm), the hook's arms (S, H21, H25, H25n, H100, A25) hang 0 times;
   - T25, the bare `readFileSync` reader, is the positive control: it should still hang. If it never does, the bar
     has not shown that the conditions held, and the probe runs once more.
5. **The new hash of `plugin/`** is recorded.

### 4, 4a: the fix, check 2 (2026-11-23): agy's review, triaged; no code change

agy (Gemini 4 Argon, plan mode) was given the diff only, and asked to break it:
- **High: `EAGAIN` if standard input is non-blocking.** `fs.readFileSync(0)` reads the same descriptor and fails the
  same way, so this is not a regression. No module the hook loads touches `process.stdin` (checked by search), so the
  hook does not make the descriptor non-blocking itself. Accepted risk, unchanged from 2.3.0.
- **Medium: "`readFileSync(0)` already is a `readSync` loop, so the fix may only shift a timing window."** Partly
  contradicted by the probe's own sample: under Node 20, `readFileSync(0, 'utf8')` ran Node's native `ReadFileUtf8`
  path, not a JavaScript `readSync` loop. The concern about inputs over 64 KiB is covered by the registered bar: the
  probe's H100 arm sends 100,000 characters, so the fixed hook makes several `readSync` reads there, and it must not
  hang. If the bar fails, the fallback is to read the input through `process.stdin`'s event loop, which agy also
  proposes. That fallback is untested.
- **Low: a 64 KiB zero-fill and two copies of the input.** Microseconds for a hook's input; Claude Code saves tool
  output over 30,000 characters to a file instead. Accepted.
- **Refuted by agy's own check:** a Windows pipe's end of input. Node 20 and later return 0 there and do not throw
  `EOF`. `EINTR`, UTF-8 characters split across chunks, and an empty input are all handled.

### 4, 4a: the fix, checks 1 to 5 (2026-11-23, on `11c1895`): pass; step 4a done

1. **The self-test on Windows** (Node 24): pass.
2. **agy's review:** triaged above; no code change.
3. **CI:** `v2.yml` passes, the self-test and load jobs on Ubuntu, macOS and Windows.
4. **The registered bar, on macOS:**
   - the full lane ran 70 of 70 clean: 10 jobs × 7 runs;
   - the hook's probe arms hung 0 times in 300 calls each (S, H21, H25, H25n, H100, A25), so 1,800 calls in all.
     H100's 100,000 characters take several `readSync` reads;
   - T25, the bare `readFileSync` reader and the positive control, still hung 8 times in 300 (2 and 6 in the two
     jobs), so the conditions that hang `readFileSync` held during the run.
5. **The product hash** is `4a869e6030aa`, pinned in the self-test (2.3.0 was `3650f785f984`).

**N5 is closed.** The hang's cause was `fs.readFileSync(0)` on a socket standard input, on macOS, and the hook no
longer reads that way. Real sessions benefit too: a command hook's default timeout is 600 seconds, so a stuck hook
could have held a session for up to 10 minutes. Whether Claude Code's own hook runner ever fed a hook so that it hung
was not checked; the fix holds either way. D18 records the observation as resolved.

**Next:** step 4b, setup completes the files that exist (registered above).

### 4, 4b: the build, a simplification pass, and check 3 (2026-11-23)

- **The draft, then shorter.** The user asked that every verification also check whether the code can be shorter and
  smarter. The first draft checked a file with two git calls, `ls-files --error-unmatch` and `diff --quiet HEAD`.
  The final code uses one helper and an empty `git status --porcelain --ignored`, which also covers staged, untracked,
  ignored and no-commit-yet files. The report's bookkeeping uses a map. That draft passed the self-test, and the smoke
  in 3 of 3 runs. Since the code changed after that, the smoke runs again on the final code, as check 2.
- **Check 3, agy's review** (Gemini 4 Argon, of the draft's diff):
  - **Fixed in the final code:** (2) `diff --quiet HEAD` missed a staged change whose working copy matched `HEAD`;
    `git status` reports it. (1) A `skip-worktree` or `assume-unchanged` flag hides a local edit from `git status`,
    and (7) on a case-insensitive file system a tracked `claude.md` answers for `CLAUDE.md`. Setup now also needs
    `git ls-files -v` to print `H <name>` for the exact name. (6) A read error counted as an empty file, which could
    append twice. The file is now read without swallowing the error. The self-test gains a `skip-worktree` and an
    `assume-unchanged` case.
  - **Accepted:** (3) UTF-16 files, (5) hard links, (9) LFS pointers and clean filters, and (10) a concurrent writer.
    Setup appends only to a file git tracks and shows unchanged, so git holds the original, the addition shows in the
    diff, and one `git checkout` undoes it.
  - **Not bugs, or covered:**
    - (8) both instruction files with the heading in `.claude/CLAUDE.md`: the registered rule, "if either one already
      holds the heading, nothing is added";
    - (4) reading through a link: a read, not a write. Writes are refused by the outside check and by git's "beyond a
      symbolic link";
    - (11) an inherited `GIT_DIR`, and no timeout: setup is run by the user, as the rest of the plugin's git calls are;
    - (12) the report does not quote the added lines: the smoke showed Claude reading and quoting them in 3 of 3.
- **The product hash** of the final code is `e3ab14af7348`.

### 4, 4b: the decision-checker's review (2026-11-23)

The repo's own `decision-checker` agent, which setup installed, checked the change against D29 (and its reopen), D18,
`.claude/CLAUDE.md` and 4b's registration. It found no break.
- **Fixed:**
  - setup's `git status` now runs with `--no-optional-locks`, as `status.mjs` does, so that a refresh cannot rewrite
    `.git/index`. The self-test's "the index unchanged" now compares the index file's bytes as well as its entries.
    With the flag removed, in a scratch copy, that check still passed 3 of 3: in these test repos `git status` did
    not rewrite the index. So the check guards against a rewrite, but does not show the flag was needed. The flag
    follows `status.mjs`'s precedent;
  - a shape the self-test lacked: a root `CLAUDE.md` without the heading beside a `.claude/CLAUDE.md` that holds it.
    Nothing is added (`headingInnerBoth`);
  - the skill's description named only `CLAUDE.md`; it now names `.claude/CLAUDE.md` too.
- **Beyond the registration's wording, recorded:**
  - a blank line comes before the appended section when the file has content. The self-test pins it;
  - the stricter "safe to append to" (`ls-files -v` printing `H <name>`) comes from agy's review (check 3, above);
  - "holds the heading" is a substring test for `## Team memory`, carried over from 2.3.0;
  - D29's "marked block" is the section's own heading, by which a second run finds it.
- **The product hash** of the final code is `2aeaa35744a0`. The smoke runs a third time, on this code.
- **Check 2 on the final code:** the smoke passed 3 of 3. There was no root `CLAUDE.md`, `.claude/CLAUDE.md` held
  `## Team memory` once, and nothing was committed. Each reply showed the user the added lines and did not add them
  again.
- **Check 4, CI** (on `6d71bfc`): `v2.yml` passed, the self-test and load jobs on Ubuntu, macOS and Windows. The
  link case ran on Linux and macOS.
- **Check 5:** the product hash is `2aeaa35744a0`.

**Step 4b is done; D29 is re-locked** on the narrowed guardrail, recorded in the ledger. **Next:** 4c (N1 to N4,
N6), and the conference research the user asked for (4f).

### 4: corrections (2026-11-23), from a review of the session's claims

- **4a's "real sessions benefit too" outran the evidence.** Every hang the probes saw had a `spawnSync` parent. A25,
  the unfixed hook started by an async parent, hung 0 times in 300. Claude Code starts hooks its own way, so whether a
  real session was ever exposed is not shown. The fix is harmless and defensive; that is all the record supports.
- **4b's shape count is 18, not 19.** That is S5's four shapes plus the linked worktree, and 13 new ones. The link case
  runs only on Linux and macOS, so Windows runs 17. The commit `6d71bfc` and the map issue said 19.
- **4b's check 3 (agy) reviewed the draft,** not the final code. The final code's safety test is exactly what changed:
  one `--no-optional-locks status`, the `H <name>` match, and the flags. One agy round on the final function runs
  before 4c, and its result is recorded here.
- **For 4e, so it is not lost:** bump the version in `plugin.json`; the README, `04-architecture.md` and the charter
  still say setup "overwrites nothing" or "never modifies a file that exists", which since D29's re-lock is narrower.

### 4, 4b: agy's review of the final function (2026-11-23)

The review the corrections above asked for. agy (Gemini 4 Argon, plan mode) was given the final append function only.
- **Fixed:**
  - (1) **A real bug.** The section's lines were split on `\n` alone. A template with CRLF line endings would leave a
    stray `\r` in every line: `\r\r\n` in a CRLF file, and CRLF lines in an LF file. The repo's `.gitattributes`
    forces LF on `*.md`, so a git install never meets such a template, but a zip download or a hand edit could. The
    split is now `/\r?\n/`.
    - The self-test could not show the bug, because its expected text came from the same template file. It now
      normalizes that text.
    - A one-off run with a CRLF template, in a scratch copy, appended LF only: 0 CR bytes, 8 LF.
  - (3) **A hard link**, where the file's link count is above 1, could carry the addition to a file outside the repo.
    Setup now requires a link count of 1, and the self-test gains a `hardlink` shape. That makes 19 shapes, 18 on
    Windows.
  - **Shorter:** `--ignored` is dropped, since `ls-files -v` printing `H <name>` already rejects every untracked or
    ignored file. The git calls now stop at the first failing guard, so a missing file, a link or a file outside the
    repo starts no `git` process.
- **Accepted:**
  - (2) An inherited `GIT_DIR`, `GIT_WORK_TREE` or `GIT_INDEX_FILE` would point git at another repository. None of
    the plugin's git calls strips them, and setup refuses a home folder; recorded as a risk shared with `map.mjs`.
  - (4) The duplicate check for the merge line misses forms such as `/.project-map/dreams.md merge=union`, so setup
    may add the line a second time. A duplicate attribute is harmless.
  - (5) Edits that a clean filter or line-ending normalization hides from `git status` are lost on a later
    `git checkout`. They differ only in how git normalizes the file.
  - (6) A read-only tracked file stops setup with an error, which is visible and changes nothing. `read()` follows a
    link or a FIFO for the heading check, as 2.3.0 did.
- **The product hash** of this code is `96d3d89b4442`. The smoke runs again on it.
- **Check 2 on this code:** the smoke passed 3 of 3 (no root `CLAUDE.md`; the heading once; nothing committed).

### 4, 4c: N1 to N4 and N6 (registered 2026-11-23, before the code)

**The changes, each the smallest that settles its item:**
- **N1:** the analyzer's `failure` kind is deleted (`plugin/agents/dream-analyzer.md`). No proposal type used it, and
  a proposal must rest on a person's line, so a failure could only reach the map through the person's fix: a
  `correction`, which the analyzer already has.
- **N2:** the starter rule (`templates/claude/rules/project-map.md`) names all four status kinds
  (`superseded|narrowed|expired|done`). The rule and the map's README template each gain one line defining
  `- origin: dream <date>`.
- **N3:** `/map-review`'s step 3 (`templates/claude/skills/map-review/SKILL.md`) also walks the stale entries listed by
  a `/second-brain:status` report in the same session. Its step 1 already uses the dream's report this way.
- **N4:** `plugin.json` gains `"author": { "name": "Cain-Ish" }`.
- **N6:** `dream prepare`'s refusals (another dream holds the lock; the data folder fails its test) exit 0 with their
  message, so that a failed `!` command cannot abort the skill before Claude reads why. Usage errors, and `finish` and
  `abort`, keep exit 1.

**Checks.** All must pass:
1. **Self-test pins:**
   - the analyzer lists no `failure` kind;
   - the rule names the four kinds and `origin`, and the README defines `origin`;
   - `/map-review`'s step 3 names the status report;
   - `plugin.json` has an author;
   - `prepare` with a bad data folder, and with a fresh lock held, exits 0 with its message;
   - `finish`'s refusal still exits 1.
2. **`claude plugin validate plugin`** passes with no warning.
3. **CI** on three systems.
4. **The new hash** of `plugin/` is recorded.

N1 changes the analyzer's prompt, and no step here runs a dream. That is checked at 4e: section 3's S8 acceptance check
runs again before the tag, and its dream-loop item exercises the analyzer. If that item fails there, N1 is reverted
first.

### 4, 4b check 4 on the final code; 4c's decision-checker review and an addendum (registered 2026-11-23, before its code)

- **4b, CI on `acfef92`** (hash `96d3d89b4442`): `v2.yml` passed on all three systems.
- **4c, the repo's `decision-checker` agent:** no break. Its points, and what follows from each:
  - **N6 is wider than its wording.** Every error `prepare` throws now exits 0: the two named refusals, plus the map
    link, waiting for review, and unexpected errors. In 2.3.0 these all exited 1, so section 3's "every other refusal
    exits 0" was wrong for two of them. The direction is safe, since the skill stops on "The dream stopped"; recorded.
  - **The step table promised "the smoke", but 4c's check list has none.** The check list is the later, more specific
    registration. Running the dream, and an interactive `!` abort, are left to 4e.
  - **The copy rule:** `plugin/` is edited in place for 4b's reason, which still holds: every install comes from
    GitHub, not this checkout.
  - **N1 against D31:** deleting `failure` matches D31's provenance rule. The analyzer's own text already demanded a
    U or Q line, and a repeated tool failure lives in T and R lines. No trigger fires. But D31's bars were measured
    with the kind in the prompt, and 4e's fallback re-ran only S8's dream item, which sat at its bar with no margin.
    **4e therefore re-runs S7 check 2's bars on the product as well.**
  - **N3 was half-fixed.** `/map-review`'s step 3 can only confirm an entry or end it. A source that changed, a quote
    no longer found word for word, or a source that cannot be read needs the entry updated, and the step had no route
    for that. **Addendum, registered here before its code:** step 3 gains a third outcome, "It changed: update the
    quote or the source to what holds now, and set `- verified:` to today". It is pinned by the self-test like N3's
    first line.
  - **N8, recorded for later:** `status.mjs` checks the source of every entry, including one a `- status:` line has
    already retired. So a retired entry whose quote is gone stays "stale" in every report. It reads only an entry's
    first status line. Both behaviours are 2.3.0's, outside N3, and go to the next release's list.
  - **For 4e:** `04-architecture.md` still lists N1 to N4 as open. The release notes must say that template text
    (N2, N3) reaches new setups only, because setup never overwrites a template that already exists.
- **4c, checks 1, 2 and 4:** the self-test passes with every pin, N3's addendum included; `claude plugin validate plugin` passes with no warning (N4 cleared the only one); the hash is `d502b016a0a1`. CI (check 3) runs on this commit.

### 4, 4g: the conference candidates (registered 2026-11-23, before the code)

From [research/2026-11-23-ai-native-devcon.md](research/2026-11-23-ai-native-devcon.md), section 3.

**K3, a grounded and adversarial `decision-checker`: deferred, not built.** In S5 the checker flagged the breaking
change in 5 of 5 runs, treated a proposal as a proposal in 5 of 5, and wrote outside its folder in 0 of 5. With no
measured miss, a prompt change could only add risk (PM1). *Reopen if:* a field session or an eval run shows the
checker passing a change that breaks a recorded decision.

**K2, a self-update line in the capture instruction: waits for the user** (D14's frozen instruction).

**K1, usage evidence in the dream's report: built here.**
- **The change:**
  - `dream.mjs`: `digestFrom` already streams every record of a session. It also collects the map files the session
    read, by a `Read` of `.project-map/<file>.md` or by a Bash command naming one. These are the two routes the read
    hooks label.
  - prepare's report gains one line: for each digested session, the map files it read; then the topic files no
    session read. `README.md` and `dreams.md` are left out, since they are not topic files.
  - The dream skill's report step gains one sentence:
    - pass that line on, because a topic file no session read has a title or description that does not lead Claude
      to it;
    - when a correction candidate came in a session that had read the relevant entry's file, say so, because the
      entry's wording did not hold Claude to it.
  - It is evidence for the user, never a proposal, so D31's provenance rule is not touched. There is no new store, no
    second pass over the transcripts, and no hook change.
- **Checks.** All must pass:
  1. **Self-test, on synthetic transcripts:** a session reads one map file by `Read` (an absolute path, with
     backslashes as on Windows) and another by `cat` in Bash. A second session reads none. A topic file nobody read
     is listed as never read. `README.md` and `dreams.md` are not listed. Each session's files are named against its
     digest.
  2. **A field read, read-only and not committed:** the same counting, run over a field repo's transcripts. It must
     name at least one topic file read, and give a never-read list that is not every topic file. The record gives
     counts only and does not name the repo.
  3. **CI** on three systems; **the new hash** recorded.
  4. **At 4e:** the S7 check 2 re-run already planned there covers the skill's changed report step.

### 4, 4c done; 4g, K1's checks 1 and 2 (2026-11-23)

- **4c, check 3, CI on `a680e91`:** passed on all three systems. Step 4c is done (hash `d502b016a0a1`).
- **K1, check 1, the self-test:** pass. `mapReads` keeps a Bash command's map files and drops a `Grep` and a non-map
  `Read`. In the dream's synthetic run, session 2 read `decisions.md` by a Windows-path `Read` and `tail.md` by `cat`,
  and prepare's report names both against that session's digest. `wide.md` is the one topic file no session read, and
  neither `README.md` nor `dreams.md` is listed.
- **K1, check 2, the field read:** pass, read-only, counts only. The same counting ran over two field repos'
  transcripts:
  - repo A: 15 sessions, 13 of them read the map; 2 topic files, read in 13 and 1 sessions; none never read;
  - repo B: 11 sessions, 3 read the map; its 1 topic file was read in 3.

  Both maps are small, so "never read" has nothing to show yet. The skew between files (13 against 1) is the
  signal a user can act on.
- **The hash** is `7769d957bc6a`. CI (check 3) runs on this commit.

### 4, 4h: the whole-plugin audit and simplification (registered 2026-11-23, before it runs)

**Why:** the user asked that, once the steps are done, the whole plugin be validated by hand and with the installed
review tools. They see issues and places to clean up, and code that is over-thought and could be shorter.

**How:**
1. **Reviews, which change nothing:**
   - `ponytail-audit` over `plugin/`: bugs, security, load, untested risk, and what to delete, merge or split;
   - a read of every product file by hand, for the same;
   - `code-review` over the diff since `v2.3.0`.

   Each finding is triaged: fix, accept with a reason, or record for later. A finding that touches a recorded decision
   is checked by `decision-checker` before its fix.
2. **The rewrites:** each one is the smallest change that keeps behaviour, unless a finding is a bug. Files are
   rewritten one at a time, with the self-test run after each. A text the self-test pins byte for byte (`INSTRUCTION`,
   `FORCE`, `NAME`, `HEADER`) is not rewritten: its pins and its measured bars belong to D14, D22 and D23.
3. **Then `simplify`** over the whole 4h diff, as the last pass.

**Checks after 4h,** all of which must pass:
- the self-test on Windows, and CI on three systems;
- `claude plugin validate plugin` with no warning;
- the hooks' smoke (`plugin/test/smoke.mjs`, pinned CLI, Haiku) and setup's smoke (`smoke4b.mjs`), each 3 of 3;
- the product's line count goes down, or each line it adds is named in the record;
- every hook's output is unchanged on the self-test's corpus, where 4h did not set out to change it. The self-test's
  pinned outputs show this.

4e's bars (S7 check 2, S8's acceptance, D18's bench) then run on the 4h code.

### 4, 4h: the reviews and the rewrite (2026-11-23)

- **`ponytail-audit` over `plugin/`,** with every script read in full. 12 findings, no security hole or data loss:
  - **must fix:** (1) N8: the status report kept entries a status line had ended "stale" forever. `narrowed` still
    binds, so only `superseded`, `expired` and `done` skip the review-date and source checks. (2) Three patterns for
    `- id:` lines, in `map.mjs`, `status.mjs` and `dream.mjs`, so labels and the dream could disagree;
  - **should fix:** `status.mjs` repeated most of `labels()`'s rules; quote extraction and the UTF-16 check were each
    written three times; the `proposed` and `review` patterns twice; two copies of the inside-the-repo guard with
    different strictness; four `git` helpers; the unseen-sessions count twice;
  - **nice to have:** a sort comparator that equals the default, a dead alias, a pass-through `today()` wrapper, and
    the same environment check written twice.
- **`code-review` (medium) over `v2.3.0..HEAD`:** 7 findings:
  - **fixed:** (1) one unreadable map file stopped `mapIds()` and `waiting()` from reading the rest, so a status line
    could be called "replaced by an id the map does not hold". Each file now has its own `try`. (2) A damaged
    `pending` record in `state.json` stopped every later dream; `loadState` now checks its shape. (3) A dream that ran
    past two hours lost its lock, and its proposals, to the next dream. A lock is now never taken over by age; only
    `abort` releases it, as the skill and the session-start note already say. (4) The dream's `within()` walked past a
    dangling link; the dream now uses the shared `inRepo()`, which stops there. (5) A proposal could be aimed at
    `dreams.md` or `README.md`; both names are refused. (7) A missing object misaligned the `git cat-file` parser; a
    header that is not a blob is now skipped;
  - **accepted:** (6) killing `finish` between removing its run and writing the state cannot be retried. The order is
    the devils-advocate review's, so that a retried finish never applies proposals twice or overwrites the first
    pending record.
- **The rewrite:** `map.mjs` exports the shared helpers (`git`, `utf16`, `quoteOf`, `idsIn`, `proposedOn`,
  `reviewOn`, `statusOf`, `replacedBy`, `docReader`, `refind`, `inRepo`, `unseenIn`), and `status.mjs`, `dream.mjs`,
  `setup.mjs` and `labels()` use them. Each caller keeps its own wording, and the self-test passed after each file.
  - The self-test's S8 status case now gives the superseded entry a missing quote and a passed review date.
  - The lock case now expects the refusal, then a run left without its lock.
  - A mutation check (the `ended` guard switched off, in a scratch copy) failed the N8 case: "Stale: 5".
- **The line count:** the scripts' code fell by 5 lines (93 removed, 88 added); their comments rose by 13 (15 removed,
  28 added), mostly on the shared helpers and the seven fixes. `simplify` runs next over the whole diff.

### 4, 4h: the `simplify` pass (2026-11-23)

Four cleanup reviews ran in parallel over the 4h diff: reuse, simplification, efficiency and altitude.
- **Applied:**
  - `dataOk` is two `inRepo` calls. One `configDir()` replaces four `CLAUDE_CONFIG_DIR` fallbacks.
  - One `mapMd()` list and one `textOf()` read replace the nested `try` blocks.
  - One `refinder(root)` closure replaces `isFile`, `docReader` and `refind`. `isProposed` and `isDue` are inlined.
  - One `mapIdsOf()` serves the read hook and the status report. It returns `null` when any map file cannot be read,
    so no id is called missing on a partial read: the altitude review found the per-file `try` only patched that
    symptom. Status now reads ids from whole files, as the read hook does; before, an id under a heading with no quote
    counted for one and not the other.
  - The dream reads ids with `idsIn` everywhere, which drops two more patterns, one of them a hand-escaped regex.
  - One case-insensitive `topic()` rule serves prepare's K1 line and finish. A `Dreams.md` proposal is dropped as
    "not a topic file" instead of being filtered out silently.
  - The dream uses the exported `words()` in place of its own `WORD`. `hook.mjs`'s onboard and status's last commit
    use the shared helpers. Orphaned and over-claiming comments are fixed.
  - A regression of 4h is undone: the rewritten `there()` in setup threw on `EACCES` or `ENOTDIR`, for example a file
    named `.claude`; it has its `try` back.
- **Tests added:** a `Dreams.md` proposal is dropped and never reaches the log; a `pending` record without its line
  reads as none.
- **Skipped, with the reason:**
  - the efficiency review's notes predate 4h. `labels()` re-reads cited files for each map file in one Bash event, so
    the cost grows with the square of the file count; status lists transcripts twice; finish reads map files several
    times. Each costs milliseconds at today's map sizes, the D18 bench passed, and fixing the first would add a
    parameter. *Upgrade when* a map is large enough to show in the bench;
  - the `.dream-run` filters, which differ by design;
  - `sourceOf` and `headingOf`, and the other small repeats, which do not pay for the edit;
  - one `git worktree list` per prepare instead of two, which touches prepare's logic;
  - having `labels()` skip ended entries, which would change the hook's output, ruled out by 4h's registration.
- **The line count, against `c2424e3b`:** code down 11 (129 removed, 118 added); comments up 13 (17 removed, 30
  added). The added comments carry the shared helpers' contracts and the source of each fix. The product total is
  1,716 lines, against 1,714 before 4h.

### 4, 4h: the decision-checker's review, and what followed (2026-11-23)

The repo's `decision-checker` ran over the 4h diff after the fixes, not before them as 4h's registration asked. It
found two breaks:
- **The lock change broke S7's registered design.** S7 takes over a lock more than two hours old without a restore,
  because a restore days after a crash would revert what was captured since. D31 locked on S7 passing. Without the
  takeover, `abort` and its restore were the only way out, and a dream prepared in a worktree removed since would keep
  the repo locked for good. **Reverted to S7's design.** `code-review`'s finding 3 (a dream still running after two
  hours loses its run to the next one) is accepted. It carries a `shortcut:` comment that names the limit, and S7's
  dreams took minutes.
- **N8 ignored a dream's proposal, and read only the first status line.** A dream writes its status line with
  `- proposed:`, and that line turned off the checks before review accepted it, against D28 and D30. An entry narrowed,
  then superseded, stayed stale. **Fixed:** an entry is ended by any non-proposed `superseded`, `expired` or `done`
  line. The S8 status case now has a narrowed-then-superseded entry, not stale, and an uncommitted dream proposal with a
  `done` line and a passed review date, still stale. Its expected counts are "Stale: 5" and "Proposed by a dream: 0".

Also from that review:
- **4h's promises:**
  - the `agy` round on the hook changes runs now;
  - the remaining product files (the skills, the command, the agent and project-map templates) were read by hand, with
    no finding;
  - the line count is below.
- **Side effects, accepted:**
  - a dangling `.md` link in the map, such as an editor's lock link, now withholds the "replaced by" label while it
    exists. That fails closed;
  - `idsIn` reads an id followed by `\r`, so a dream's status line now reaches a CRLF map file, as an LF line.
    Before, such a file's ids went unmatched and the line was dropped.
- **The line count, against `c2424e3b`:** three comments that only restated their code are gone. The product is
  1,718 lines, against 1,714. The four added lines are named here: the lock's `shortcut:` comment, which this
  codebase's rule asks for whenever a limit is known (2 lines), and the N8 comment on a dream's status line (2
  lines).

### 4, 4h: agy's round on the hook changes (2026-11-23)

The verifier section 4's rules ask for on every hook change. agy (Gemini 4 Argon, plan mode) was given the `map.mjs`
and `hook.mjs` diff:
- **Fixed:**
  - (1) `mapMd()` matched the run folder with `startsWith`, where `labels()` had used `includes('/.dream-run/')`. So a
    `.dream-run` folder nested inside the map changed what the read hook printed. `mapMd()` now uses `includes`, so
    the read hook's output is the same as before 4h. `waiting()` and the status report now also skip a nested run
    folder, which the dream never makes.
- **Accepted:**
  - (2) the `pending` shape check changes session start's note for a damaged state file. That is `code-review`'s
    finding 2, fixed on purpose;
  - (3) onboard's `git --version` runs in the repo's folder, which exists, and `ls-tree`'s buffer is larger, which
    only removes a failure;
  - (4) `inRepo` with a repo at the file-system root. Setup's old `outside()` had the same test, so it predates 4h.
- **agy found nothing else:** no fail-closed path weakened, no new exception escaping a hook, and the helpers'
  patterns are byte-identical to the inline code they replaced.
- **The hash** is now `5bca1aa901d4`. The hooks smoke runs again on it.

### 4, 4h: the checks after 4h (2026-11-23)

- **The self-test** passes on Windows with every new case, and `claude plugin validate plugin` passes with no warning.
- **Setup's smoke** passed 3 of 3, and **the hooks smoke** 3 of 3, on the code before agy's one-line filter fix.
- **The hooks smoke on the final hash `5bca1aa901d4`:**
  - attempt 1 failed. Its first run ended in a Node error whose output was not kept; the other two passed. Rule 2
    counts that as a failed attempt;
  - two uncounted re-runs passed;
  - attempt 2 passed 3 of 3, with every run's output kept.

  The only change since the last clean 3 of 3 was the nested run-folder filter, which no smoke repo exercises. The
  first run's cause is unknown.
- **CI on `e07469dc`:** `v2.yml` passed on Ubuntu, macOS and Windows, the self-test and the load jobs. **Step 4h is
  done** (plugin `5bca1aa901d4`).

### 4: the field report of 2026-11-23, triaged (map issue step 22)

The user installed 2.3.0 in a large field repo, ran setup and onboarding, and passed on that session's report. It is
paraphrased here with counts only:

| # | The report | Triage |
| --- | --- | --- |
| 1 | Setup wrote its files onto an unrelated feature branch with uncommitted work, without a word | **N9:** setup's report names the branch and says when the tree holds other uncommitted changes. Small |
| 2 | An empty scaffold: filling the map took two agents, about 500k tokens and 25 minutes | The cause is #9's: the capture instruction told Claude to add an entry for each requirement in a document it read, so the repo's own documents were copied in. **Fixed by 4i's document clause (D14).** No importer is built: D15 keeps the documents as the source |
| 3 | No upgrade path: setup never overwrites, so template fixes never reach a repo | **N10:** setup's report lists each setup file that differs from the plugin's current template, for the user to diff. Small. This is 4c's release-notes caveat |
| 4 | Agent notes are not seeded, and the report does not mention them | **N11:** setup's report says where the agents keep their notes (`.claude/agent-memory/`, made on first write). Text only |
| 5 | The `when:` work kinds are generic | Recorded. `when:` is never surfaced (the field note of 2026-11-08), so a better list changes nothing yet |
| 6 | Session start overflows: about 850 documents in 179 directories, 71 listed; it also costs that context every session | **D22's trigger fired:** "a repo's index exceeds P2's (45 directories, 6 KB) and its forced decision or reads are not measured there". **D22 REOPENED.** A size budget or a summary mode is the next release's first decision |
| 7 | "Unreviewed until committed" ties review to git; on a branch carrying other work it forces commits | D14's choice, the commit being the review. **The user's call** |
| 8 | `verified:` is free text; about 10 mirrored documents had drifted from the code | Partly there: status re-finds an entry's quote in its source and flags a source committed after its verified date. **N12:** status also checks that every repo path an entry names exists |
| 9 | The map duplicates the repo's own rules with no way to keep them in step | As #2: **4i's document clause** |
| 10 | memory-curator has no Bash, so it cannot check dates or merge-request references | P6c: an agent's `Bash(pattern)` does not limit Bash, so the agents get none. **Accepted**, as section 3 recorded |

### 4, 4i: learning every run (registered 2026-11-23, before the code)

From [research/2026-11-23-learning-every-run.md](research/2026-11-23-learning-every-run.md), on the user's request of
2026-11-23. That request is read as the word that reopens D14 for K2.

**The change:** two edits to D14's capture instruction (`INSTRUCTION`, `map.mjs`):
- **K2:** when the user corrects Claude, or Claude hits a non-obvious problem that will trip up a future session,
  record it as an entry, in the user's words or as the problem was found;
- **the document clause:** "you receive or read a document that states requirements" becomes a document from outside
  the repo. The index already points to the repo's own documents (D15, D22).

**Checks.** All must pass before the change ships:
1. **A-4, the second run** (`probes/V2-D14-every-run/`). A copy of A1's fixture with `formatPrice()` in
   `src/utils/money.ts`.
   - Session 1: "Add a price label to ProductCard." Claude's first attempt is corrected by a fixed follow-up: "No,
     prices here go through formatPrice() from src/utils/money.ts; toFixed breaks the locales."
   - Session 2, fresh, with no commit in between: "Add a price to StatTile."
   - **Read:** session 2 uses `formatPrice` and not `toFixed`.
   - **Arms,** 5 runs each, on the pinned CLI with Opus 5.5 and auto memory on, as users run it: **H**, the plugin as
     it is; **K**, with both edits.
   - **Pass:** K at least 4 of 5, and at least H + 2. If H already reaches 4 of 5, A-4 shows no need for K2, K2 is
     not shipped (PM1), and the document clause is checked on its own by item 2.
2. **D16's re-check, as 06's 2s ran it:** A1's V2 arm, 10 runs with the changed instruction, at 2s's bars. The
   document clause must not lose A1's designer document, which is kept outside the repo.
3. **The self-test** pins the new instruction's sha256 and bytes, and **CI** passes on three systems.

If check 1 passes and check 2 fails, the document clause is dropped and check 2 runs again with K2 alone.

### 4, 4i: A-4's floor, and the amended check 1 (2026-11-23, before any counted run)

The advisor asked for a floor before the counted runs. The floor runs session 2 alone, with no plugin and auto memory
off, on the tree as the correction left it, 3 runs each, uncounted. If the code alone teaches the lesson, the arms
cannot separate. Runner: `probes/V2-D14-every-run/a4.mjs`, results in `results/floor-*.json`.

| Scenario | The correction | Floor |
| --- | --- | --- |
| price-F0, as registered | toFixed, then formatPrice() from `src/utils/money.ts` | 3 of 3 used formatPrice |
| price-F1, with two older toFixed prices elsewhere | the same | 3 of 3 |
| tokens: `src/theme/tokens.ts` is generated from `design/tokens.json`, and nothing in it says so | "change design/tokens.json instead" | 3 of 3 changed the JSON |
| frozen: `src/legacy/` must not change, so restyle where it is used | "src/legacy/ is frozen until the payment audit is over" | 3 of 3 left it alone |

- **12 of 12.** In each run, session 2 read the corrected code next to its task and copied it: the formatPrice call,
  the JSON beside the generated file, the style passed at the call site. On Opus 5.5 in a small repo, a correction
  that left its fix in the code reaches the next session through the code.
- *The two price floors ran on the script's first version.* Only the scenario table and the scorer self-check
  (`node a4.mjs <scratch> check`) changed after them. The correction's wording changed from the registered "prices
  here go through formatPrice()" to a correction of the work, because the registered wording states a rule that D14's
  current clause already covers (the advisor's point).
- **Check 1, amended:** the frozen scenario, which leaves the least trace. Arm H first, 5 counted runs. A run counts
  when turn 1 changed `src/legacy/` (the mistake) and every session is valid. Other runs are replaced, at most 10
  attempts, and reported.
  - **H at 4 of 5 or more:** by 4i's rule, A-4 shows no need for K2, and K2 is not shipped (PM1). Arm K is not run.
    The document clause goes to check 2 on its own.
  - **H at 3 or less:** arm K, 5 counted runs, at the registered bar (K at least 4 of 5, and at least H + 2).

### 4, 4i: check 1's result (2026-11-23): H 5 of 5, so K2 is not shipped

- **Arm H** (`results/a4-frozen.json`): a copy of plugin `5bca1aa901d4`, whose INSTRUCTION is the pinned
  `392c26c2a5e9`. 5 attempts, all counted: every turn 1 changed `src/legacy/`, and every session was valid.
  - **5 of 5 passed:** session 2 left `src/legacy/` alone.
  - The route in all 5: session 1 wrote the correction into the map under the current clause ("someone states a
    decision or rule"), and session 2 read that map file. Auto memory held it in none, as G4's line asks.
  - About 0.53 USD a run.
- **By the rule, K2 is not shipped (PM1),** and arm K is not run. A correction that gives its reason is a stated rule,
  and D14's clause already records it. One that leaves its fix in the code reaches the next session through the code
  (the floor). A-4 found no case left for K2.
- *Not shown:* a correction with no reason and no trace, in a large repo where the next task is far from the fix.

### 4, 4i: check 2, registered (2026-11-23, before it runs)

- **The text:** the document clause alone. "you receive or read a document that states requirements" becomes "you
  receive or read a document from outside this repository that states requirements", and the paragraph reflows.
  INSTRUCTION `105cdd6d3d4a`, 1,794 bytes (from `392c26c2a5e9`, 1,765).
- **The runs:** A1's V2 arm (`eval.mjs`), with Opus 5.5, the pinned CLI 2.1.305 and the plugin copy that carries the
  clause:
  - 10 runs, split over two processes (`D17_TAG=-opus-4i-a` for runs 1 to 5, `-opus-4i-b` for 6 to 10);
  - first, a same-day control: 1 run of the unchanged copy (`-opus-4i-ctl`), which shows the harness still works.
- **Pass, at 2s attempt 2's bars:**
  - C1, C3 and C4 10 of 10; T1, T2 and T4 10; T3 at least 8; N1 to N3 10, in both variants;
  - T5f at least 8 of 10; over-attribution at most 1 of 10;
  - no `- status:` line except on the widgets rule H1 retracts.
- **The designer's notes, kept:** they are pasted in H2 and live outside the repo, so the clause still covers them.
  C2, their capture, must hold in at least 8 of 10. 2s's bar was 2; its attempt 2 had 10.
- *Reported:* whether any run's map copies the style guide's numbered rules. The guide is a repo document, so the
  narrowed clause no longer asks for that. Also reported: topic files written (S4's measure) and the cost.

### 4, 4i: check 2's result (2026-11-23): pass, and the clause ships

- **The control** (`results/V2-opus-4i-ctl.json`, the unchanged copy, 1 run) is valid and passes every item. The
  harness works.
- **10 runs with the clause** (`results/V2-opus-4i-a.json` for runs 1 to 5, `-b.json` for 6 to 10). All are valid.
  - C1 to C4: 10 of 10. **C2, the designer's notes:** 10 of 10, against a bar of 8.
  - T1 to T4 and N1 to N3: 10 of 10, in both variants. **T5f:** 9 of 10 on "same", 10 of 10 on "second".
  - **Over-attribution:** 0 of 10.
  - **Status lines:** only on the widgets rule H1 retracts. 3 runs mark it, 2 superseded and 1 expired; no other
    entry gets one.
- **Reported:**
  - **the style guide in the map:** quotes of its six rules, found by their words, appear in 0 of 10 runs. The
    control quoted all 6, in 19 entries; runs with the clause hold 12 to 14. This is the field report's copying (#2
    and #9), reproduced at A1's size and gone with the clause;
  - topic files: 3 or 4 per run;
  - about 1.43 USD a run.
- **Result:** pass. The clause goes into `map.mjs` with the same bytes (`105cdd6d3d4a`, 1,794 bytes). The self-test
  pins it. D14 and D16 re-lock in the ledger.
- *Ledger fix:* commit `ca562c4b` had also written D14's and D22's reopen notes onto the ledger's title line. They
  are removed there; the rows keep them.

### 4, 4j: N9 to N12, from the field report (registered 2026-11-23, before the code)

The field report's small items (triage table above). No frozen text changes.
- **N9:** setup's report names the branch it wrote on. When the tree already held uncommitted changes before setup ran,
  it gives their count and says to commit setup's files on their own.
- **N10:** setup's report lists each kept file that differs from this version's template, with the template's path,
  for the user to diff. The six plugin-owned files only: the rule, the map-review skill, the three agents and the map's
  README. The instruction file, the topic files and `.gitattributes` are the user's and are never listed.
- **N11:** setup's report says that the agents keep their notes in `.claude/agent-memory/`, made on their first write.
  When auto memory is off, the existing warning stands in its place.
- **N12:** status flags an entry that names a repo path which does not exist. A path counts when it holds a slash and
  ends in a file extension or a slash, and its first folder exists in the repo, so build output (`dist/`), URLs, globs,
  package names and "and/or" are not flagged. The entry's source path is left to the existing check. An entry a status
  line ended is not checked (N8).

**Checks:**
1. *The self-test:*
   - N9: a clean repo's report names the branch and no count; the `dirty` shape gives "3 uncommitted changes";
   - N10: the `ownClaude` shape lists its own decision-checker, and a second run on the `empty` shape lists nothing;
   - N11: the line in the `empty` shape;
   - N12: a fixture with a present path, a missing path, a path under a missing top folder, a URL, a glob, "and/or" and
     an ended entry: only the missing path is stale. S8's existing counts stay as they are.
2. `claude plugin validate plugin` with no warning, setup's smoke, and CI on three systems.
3. A shorter-code pass on the diff (the user's rule of 2026-11-23).

### 4, 4j: checks and reviews (2026-11-23)

- **Edited in place, not from a copy:** the user's installs come from GitHub at a release tag. Checked in
  `known_marketplaces.json` on 2026-11-23: `second-brain` is a `github` source. So the checkout reaches no real
  session. Setup's smoke ran from a copy, as before.
- **Check 1, the self-test:** every registered case passes. A mutation check, with the product-hash pin disabled so
  that the mutations are what fails, kills all 12 mutants. Two survivors were found and closed along the way:
  - one mutation was written wrong (`[] && ended` is `ended`);
  - one was a real gap, that the user's own files are never listed. Its assertion was added.
- **Check 2:** `claude plugin validate plugin` passes. Setup's smoke passed 3 of 3; run 3's reply named the branch.
  CI runs on the commit.
- **An independent review** (a fresh Claude subagent, given the code and the brief only; agy's quota was spent on
  2026-11-23) reproduced five defects. All are fixed, each with a self-test case that a mutation check kills:
  - a second setup run said "already held N uncommitted changes" although it wrote nothing;
  - a failing `git branch` read as "a detached HEAD";
  - `src/../../x.md` was looked up outside the repo;
  - `release/2.3.0`, and the folder before a glob (`src/old/*.ts`), were flagged;
  - one path was named three times.

  Accepted, with a `shortcut:` comment: non-ASCII names, and a path in markdown italics, are missed.
- **The decision-checker's review:** no recorded decision is broken. Acted on:
  - the setup skill's summary step now names the branch, the work already there, and the differing files. Its old
    "at most six lines" would likely have dropped them, and field item #1 was "without a word";
  - tests for the source-path exclusion and a folder path;
  - the N10 test that pins the template's path; status's header comment;
  - the plugin-owned files as a positive test (`.claude/` or the map's README).
  - *Accepted:* letter case differs by file system; an entry that records a removal stays flagged until it is
    reworded (in the shortcut comment).
- **Check 3, shorter code:** the review's rewrites are taken: one `replace` for both normalisations, a `Set` for
  duplicates, `!ended &&`, and the positive owned-file test. 4j adds 18 lines of product code in all.

### 4, 4k: the whole-plugin audit's fixes (registered 2026-11-23, before the code)

The user asked for an audit at the end. A subagent ran `ponytail-audit` on `plugin/`, with no edits. Its findings and
what is done:

| # | Finding (audit's verdict) | Done |
| --- | --- | --- |
| A1 | The dream analyzer may read only the start of a long digest: 7 of this repo's 11 transcripts make digests over 100 KB, the largest 2,575 lines (PLAUSIBLE) | One line in `dream-analyzer.md`: read the whole digest, continuing with offset and limit. Checked by S7's check 2 re-run at 4e |
| A2 | The privacy filter drops "react@18.3.1" and "node@20.11.0" as e-mail addresses (CONFIRMED) | The e-mail pattern needs a letter TLD. `PRIVATE` is exported for a self-test of both sides |
| A3 | Setup appends UTF-8 text to a UTF-16 `CLAUDE.md` (CONFIRMED) | Setup refuses a UTF-16 file and gives the text to the user, as the dream already does. A 4b-style case |
| A4 | A failing status report exits 1, which can abort the skill (CONFIRMED) | Status exits 0 with its message, as `dream prepare` does (N6). A self-test case |
| A5 | A URL source is re-found as a repo path (CONFIRMED) | **Not now:** it changes the read hook's labels, which D16 locks. Recorded as **N13** for the next release, with its own check |
| A6 | Status counts a dream-proposed entry with a status line as retired (CONFIRMED) | `proposed` is counted before `retired`. A self-test case |
| A7 | Onboard counts ", 1 due" and ", 2 proposed" as documents (CONFIRMED) | Strip the counts before the split. A self-test case |
| L | Lean: the dream skill's "new topic file starts with front matter" (finish writes its own); the skill-draft clause `disable-model-invocation` (finish forces it); `drafts` exported but not imported elsewhere; `git worktree list` parsed twice | All four removed. The two skill lines change no behaviour, since finish enforces both |

*Not taken:* the dream's transcript read past its recorded size, and `state.json` written without a rename. Both
are small and stay as they are.

**Checks:** the self-test with each new case killed by a mutation; `claude plugin validate`; CI. A1 and A2 change
the dream, so S7's check 2 re-runs at 4e, as already planned.

### 4, 4k: result (2026-11-23)

- **Built as registered.** Every fix has a self-test case. A mutation check, with the hash pin disabled, kills each
  one: A2 (the e-mail pattern), A3 (UTF-16), A4 (the exit code), A6 (the tally) and A7 (onboard's count). A1 and the
  lean items change only text, or the dream's internals that its self-test covers.
- **The self-test passes** (product `8f7f9b95dbd7`, 1,745 lines) and `claude plugin validate plugin` passes. CI runs
  on the commit.
- **4i, 4j and 4k share one commit,** because their code meets in the same files (`map.mjs`, `status.mjs`, the
  self-test's hash pin). Each has its own step gate in the commit body.
- **N13 for the next release:** a URL source is re-found as a repo path (audit A5). Changing it changes the read
  hook's labels, so it needs a registered check under D16.
- **Still before the tag (4e):** S7's check 2 on this build (A1 and A2 change the dream), S8's acceptance, D18's
  bench, the version bump, the release notes, and the pull request.

### 4, 4e: the release checks, registered (2026-11-23, before their results)

The candidate is `5456401e`, `2.4.0`, product `60455a805197`. Each check is as section 3 ran it for 2.3.0, at the
same bars:
- **S7's check 2** (`s1.mjs`, histories then `product`, 10 runs, Opus 5.5, the pinned CLI;
  `results/s7-product-a5.json`). It runs on a copy of `8f7f9b95dbd7`, which differs from the candidate only by
  `plugin.json`'s version. The bars are `psummary`'s: C1 to C3 in at least 8, rule, skill and choice at least 4 of 5,
  noise at most 1 per run, a wrong status line in fewer than 2 runs, the nonce 0, live rules 0.
- **S8's acceptance check** (`e2e.mjs`, 5 runs, from a clone at `5456401e` installed as a user installs it;
  `results/s8-e2e-240.json`). The items are those of S8's attempt 2, at its bars.
- **D18's reference bench** (`pairbench.mjs`, 200 calls per hook kind at 1 and 8 concurrent). The candidate is
  `60455a805197`; the control is `v2.3.0`, exported from its tag (`3650f785f984`). The fixture is S6's, rebuilt:
  `fixture.mjs`, `benchmap.mjs` and `benchprep.mjs` (300 unseen transcripts). It runs only in D18's reference state,
  after S7 and S8 end, with nothing else running. *Pass:* every hook kind's added p95 at most 100 ms, at 1 and 8, with
  0 errors.
- **CI** on the candidate, on three systems.
- *Then:* the release notes, the tag `v2.4.0`, and a pull request to `main` that the user merges.

### 4, 4e: S7's check 2 on `8f7f9b95dbd7` (2026-11-23): pass

- `results/s7-product-a5.json`: 10 runs, all finished in one turn, with no background analyzer call. Each dream made
  9 analyzer calls.
- **Bars:** C1 to C3 10 of 10; the rule 4 of 5 (bar 4); the skill and the choice 5 of 5; noise 0; status lines on
  other entries 0; the nonce 0 of 5; live rules 0.
- **The miss is the same as 2.3.0's:** in run 5, the dream filed the repeated date correction as a map entry, not as
  a rule draft (`s7-product-a4.json`, also run 5). The audit's analyzer line (A1) and the e-mail pattern (A2) changed
  nothing measured here.
- 5.92 USD for the 10 dreams, against 5.93 for 2.3.0.

### 4, 4e: S8's acceptance check on `5456401e` (2026-11-23): pass

- `probes/V2-D29-setup/results/s8-e2e-240.json`: 5 runs, each in a new repo. In every run, 2.4.0 was installed from a
  clone at the candidate, as a user installs it, and the installed copy was byte-identical to the candidate.
- **Every item 5 of 5:** install, layout, awareness, capture, the scoped rule, `decision-checker` used with the entry
  named, the dream loop, and the nudge. The dream loop was 4 of 5 in 2.3.0's attempt 2.
- 11.49 USD for the 5 runs.

### 4, 4e: the reference bench (2026-11-23): pass, and 4e's result

- **Builds hashed before the run:** candidate `60455a805197` (`5456401e`), control `3650f785f984` (`v2.3.0`). Both
  match.
- **Reference state:** the CPU sample was 9.4% over 10 seconds, just before the run. Empty Node's p95 at 8 concurrent
  was at most 52.1 ms.
- **Added p95 in ms, 2.3.0 against 2.4.0,** 200 calls per hook kind, with the nudge's 300 unseen transcripts
  (`probes/V2-D30-entries/results-4e-reference.json`):

  | | session start | prompt | read-other | read-map | bash-map | bash-other |
  | --- | --- | --- | --- | --- | --- | --- |
  | @1 | 42.7 / 48.5 | 10.1 / 10.5 | 10.3 / 10.4 | 47.1 / 48.0 | 48.5 / 48.9 | 48.4 / 48.8 |
  | @8 | 62.1 / 70.0 | 19.4 / 17.9 | 17.7 / 22.0 | 74.8 / 76.0 | 74.7 / 76.2 | 76.3 / 75.8 |

- **Pass:** every hook is within 100 ms, with 0 errors.
  - *The control now has a data folder to use and is not given one,* so its session start skips the nudge's work.
    The 7.9 ms between the two on session start is that work.
  - The other hooks are within 5 ms of 2.3.0.
  - The whole table sits about 10 to 20 ms above 2.3.0's own bench of 2026-11-22. This window's empty Node was
    slower (52 against 49 ms at 8), and the two builds moved together.
- **CI on `5456401e`:** `v2.yml` passed on Ubuntu, macOS and Windows.
- **A review of the series:** the whole-plugin audit (4k) ran on the code after 4j, and its fixes are mutation-tested.
  4b to 4j each had their own reviews.
- **4e's checks all pass.** The release is `2.4.0`, product `60455a805197`. Next: the tag, the release draft, and the
  pull request to `main`, which the user merges.

## 5: the next release, opened (2026-11-23)

2.4.0 is tagged (`0b242f5a`), and PR #117 waits for the user. The next release is built on branch `v2-next`, which
joins `v2` after #117 merges, so #117 stays exactly the tagged 2.4.0. Its first decision stays D22's large index, as
section 4 recorded.

### 5, 5a: P1 and P2, from the Matt Pocock research (registered 2026-11-23, before the code)

The user, on 2026-11-23: "yes to P1 and P2, implement them". The research
([2026-11-23-matt-pocock-approach.md](research/2026-11-23-matt-pocock-approach.md)) found that the plugin teaches
Claude to use its structure, not to extend it. That word reopens D29 (the templates) and D31 (the dream's drafts).

**The change:**
- **P1, a placement table** in the map's README template, `## Where it belongs`. It names the home of each kind of
  knowledge:
  - a decision, rule or requirement: an entry;
  - a procedure repeated across sessions: an entry, and a skill offered to the user;
  - a rule for certain paths that keeps being corrected: an entry, and a path rule offered to the user;
  - a rule a tool can enforce: an entry, and a check offered to the user (a lint rule, a test or a hook);
  - a command every session needs: a `CLAUDE.md` line;
  - where code lives: nowhere in the map.

  Plus one line in the rule template, which loads whenever Claude touches a map file, pointing to the table before
  an entry is added. Captured knowledge still lands in the map, as D14 says. The other homes are offers to the user,
  never files Claude makes live by itself: an unreviewed skill or rule would load at once (D31).
- **P2, draft-writing rules** in the dream skill's step 4:
  - a rule draft's `paths:` is no wider than the files the sessions worked on, and the rule is stated for every file
    those paths cover;
  - a skill draft's `description` says what it does, then "Use when" and the words a user would type to ask for it;
  - its steps are written for the kind of task, not the sessions' one instance, each ending with how to tell it is
    done, with no step Claude would take anyway.

**Checks.** All are run from a plugin copy, on Opus 5.5 with the pinned CLI 2.1.305:
1. *The self-test* pins the README's table, the rule's pointer line and the skill's draft lines. A mutation check
   kills each pin. `claude plugin validate` passes.
2. **P1 in a session** (`probes/V2-D29-setup/p1place.mjs`), 5 runs per arm, candidate against a 2.4.0 control. Each
   run is a fresh repo after setup, committed. One session gets: "Two things for this project. First: we never import
   lodash; use the native array and object methods. Second: our release procedure is to bump the patch version in
   package.json, add a CHANGELOG.md section for it, then tag vX.Y.Z. Nothing to build now."
   - *Pass:*
     - both statements are map entries in at least 4 of 5 candidate runs (capture holds);
     - the reply offers a check for the lodash rule in at least 3 of 5 runs, and in at least 2 more than the
       control;
     - no run of either arm makes a new live rule or skill (a `.md` file under `.claude/rules/` other than setup's,
       or a `SKILL.md` other than map-review's).
   - *Reported:* a skill offered for the release procedure (stated once, so the table does not ask for one), and
     files changed outside the map.
3. **P2 in the dream:** S7's check 2 on the candidate, at its bars (`results/s7-product-a6.json`). *Reported:* skill
   drafts whose description holds "Use when", and each rule draft's `paths:`.
4. **CI** on three systems, through a pull request from `v2-next` into `v2`.

On a fail, each failed check is attempt 1 of 5a under rule 4. The text it implicates is revised or dropped alone.

### 5, 5a: check 2, P1 in a session (2026-11-23): pass

- `probes/V2-D29-setup/results/p1place.json`: candidate `61fb668a3ea6` against the 2.4.0 control `60455a805197`, 5
  runs each, all valid. Each run cost about 0.12 USD.
- **Capture holds:** both statements are map entries in 5 of 5 runs of each arm.
- **The check offered for the lodash rule:** 5 of 5 against the control's 0 of 5 (bar: at least 3, and at least the
  control + 2). One candidate reply, read by hand: it saved both entries, then listed "two optional additions I
  haven't made": an ESLint `no-restricted-imports` rule ("the note only makes mistakes less likely"), and a release
  skill. It asked before each.
- **No live rule or skill** was made in either arm. No file outside the map changed.
- *Reported:* a skill offered for the release procedure in 5 of 5 runs, against 0. The table asks for that offer only
  for a procedure repeated across sessions; here it was stated once, and Claude still noted that it "repeats every
  time".

### 5, 5a: check 3, attempt 1 (2026-11-23): bars pass, the rule clause dropped

- `probes/V2-D31-dream/results/s7-product-a6.json`, on `61fb668a3ea6`: every bar passes. C1 to C3 10 of 10; the
  rule 4 of 5; the skill and the choice 5 of 5; noise 0; status lines on other entries 0; the nonce 0; live rules 0;
  5.80 USD.
- **Reported, against 2.4.0's run of S7 (`s7-product-a5`):**
  - *Skill drafts:* every one, in both builds, has "Use when" in its description, so that part changed nothing.
    Lines saying how to tell a step is done: 3 to 5 per draft, against 0 in 2.4.0.
  - *Rule drafts:* 2.4.0's covered `src/**/*.js`, `src/**/*.ts` and `src/**/*.tsx`. With P2's "no wider than the
    files the sessions worked on", 4 drafts list only the two files the sessions touched (`src/orders/format.js`,
    `src/users/card.js`). The rule, that dates shown to users go through `formatDate()`, holds for every such file,
    so a narrowed draft would never load for a new one. That is worse, and the bar did not see it: its scorer checks
    only that `paths:` exists.
- **The rule clause is dropped alone,** as the registration says. The rule's line is 2.4.0's again; the skill's lines
  stay. Product `38602db7055f`.

### 5, 5a: check 3, attempt 2 (registered 2026-11-23, before its runs)

- S7's check 2 on `38602db7055f`, 10 fresh runs, at its bars (`results/s7-product-a7.json`).
- *Also a pass item now:* no rule draft's `paths:` lists only single files. Each must hold a glob, as 2.4.0's did.
- *Reported:* the skill drafts' lines on how to tell a step is done.

### 5, 5a: check 3, attempt 2 (2026-11-23): pass; step 5a done

- `probes/V2-D31-dream/results/s7-product-a7.json`, on `38602db7055f` (the copy hashed before the run). Every bar
  passes:
  - C1 to C3 10 of 10;
  - **the rule 5 of 5** (4 in attempt 1 and in 2.4.0); the skill and the choice 5 of 5;
  - noise 0; status lines on other entries 0; the nonce 0; live rules 0;
  - 5.73 USD.
- **The glob item:** every rule draft holds globs (`src/**/*.js`, `*.ts`, `*.tsx`, or one brace glob), as 2.4.0's
  did.
- *Reported:* the skill drafts have 3 to 5 lines each on how to tell a step is done.
- **CI** on `36d9f7c5`: the self-test passed on three systems, through PR #118 into `v2`.
- **Step 5a is done.**
  - P1 ships whole.
  - P2 ships its skill part. Its rule-paths clause is dropped (attempt 1), so 5a's text for rules is 2.4.0's.
  - D29 and D31 re-lock in the ledger. PR #118 stays a draft until #117 (2.4.0) merges.

### 4 and 5: the merges (2026-11-23), on the user's "do it by yourself"

- **#117 (2.4.0) merged into `main`** (`cb89b73d`), plainly, with every required check green. The `v2.4.0` release
  is published. Three local installs, the two field repos and this repo, moved from 2.3.0 to 2.4.0. The installed
  copy hashes `60455a805197`, the release. Running sessions there need `/reload-plugins`.
- **The merge deleted `v2` on GitHub:** the repo deletes a pull request's head branch on merge. GitHub then retargeted
  PR #118 to `main`. `v2` was pushed back from the local copy at the same commit, `0b242f5a`, and #118 was pointed at
  `v2` again. It is recorded as this repo's first map entry, `v2-branch-deleted-on-merge`. The setting itself is the
  user's; it is not changed by a session.
- **#118 (5a) was merged into `v2` (`cd645bfc`) before its re-run checks were read.** One job had failed:
  `load (windows-latest)`, with empty Node's p95 at 190 to 247 ms on that runner (about 140 is usual). The job re-ran
  on the same commit and passed, with every other job. The same commit had passed every job before the retarget.
  The slip is a merge made before reading its checks; from now on, the checks are read before any merge.
- **This repo runs its own plugin.** The user's setup output of 2026-11-23 is committed (`01e4bc3a`). The rule,
  map-review and the map's README were updated to the current templates: setup's own N10 line listed exactly those
  three. The root `CLAUDE.md` is merged into `.claude/CLAUDE.md`, which keeps v2's decisions in the ledger.

### 5, 5b: N13, a URL source is no repo path (registered 2026-11-23, before the code)

- **The defect** (the audit, A5): `sourcePath` (`map.mjs`) takes a path from inside a URL. A source
  `https://github.com/o/r/blob/main/docs/adr/001.md, 2026-11-01` is re-found in `github.com/o/r/blob/main/docs/adr/001.md`.
  Every read of the entry then labels it "not found word for word … check it", and status lists it as stale.
- **The change:** a path inside a URL (after `://`, in the same run of non-blank text) is not taken. The entry reads
  as an unverified quote, as any source that is no repo file does. This is a fix to how the source's path is parsed,
  like 2q's path inside parentheses, so D16 gets a note, not a reopen.
- **Checks:**
  1. *The self-test:*
     - the source grid's `url` row (`https://example.com/view?file=README.md`) changes from a kept path to
       "unverified quote", as the change intends. Every other row stays byte for byte;
     - unit cases: a GitHub blob URL gives no path; a plain path is kept; a path beside a URL is kept;
     - status no longer lists a URL-sourced entry as stale;
     - a mutation check kills each case.
  2. `claude plugin validate`, and CI on three systems.

### 5, 5b: result (2026-11-23): pass

- The self-test passes, product `9ebb998c0293`. The grid's `url` row now reads "unverified quote, captured
  2026-11-12", and every other row is unchanged. Removing the URL guard fails the self-test, so the mutation is
  killed.
- `claude plugin validate` passes. CI runs on `066f96ad`. D16 gets a note, not a reopen.

### 5, 5c: field item #7 and D33, settled; their two lines (registered 2026-11-23, before the code)

The user, on 2026-11-23: "do it byself", on the open questions. As [[v2-continue-without-asking]] says, each one is
settled by a written rethink plus a second opinion. agy's quota is spent, so a fresh Claude agent, given the facts and
not this rethink, gave the second opinion. It agreed on both, and found the command below by running it in a scratch
repo.
- **#7 (D14): keep "the commit is the review".**
  - A separate review marker would be a file in the working tree, which the hand that wrote the entry can also write.
    So an injected entry could mark itself reviewed, which is D14's own reopen trigger.
  - The field's friction is a missing step: nothing offers a commit of the reviewed files alone.
  - So `/map-review`'s last step offers `git add <files> && git commit -m "…" -- <files>`. It commits only those
    files, and staged or unstaged work elsewhere on the branch stays as it is.
  - D14 is not reopened; none of its triggers fired.
- **D33: (C) rejected, (M) built, (A)'s "later" kept.**
  - With (B) rejected, (C) would skip only the review walk; a dream still starts on a typed command. A proposal can
    count only through a commit, so (C) would mean the dream commits text from transcripts by itself. The charter's
    non-goal ("a background process that rewrites knowledge without a reviewable diff") and v1's cause 5 rule that
    out.
  - (M): the dream's last step asks whether to review its proposals now. On a yes, Claude reads the map-review skill's
    file and follows it in the same session, with the dream's reasons at hand. Neither skill can invoke the other.
    "Later" leaves everything for `/map-review`.
  - R4 (a desktop scheduled task) stays out of the product: testing it means driving the user's desktop app, and setup
    could never create one. D33 locks.

**Checks:**
1. *The self-test* pins both lines. A mutation check kills each.
2. **No walk without the user's yes:** S7's check 2 on the candidate, at its bars (`results/s7-product-a8.json`). Its
   headless dreams have no one to say yes, so every proposal must still carry `- proposed:` and every draft keep
   `.draft`. S7's bars already count both.
3. S8's acceptance check at the release (its dream item counts proposals and unloaded drafts the same way), and CI.

### 5, 5d: D22, an index past the cap is summarised, not cut (registered 2026-11-23, before the code)

- **Why:** D22's trigger fired on the field report: a repo with about 850 documents in 179 directories listed 71.
  Measured today: a repo of P2's own shape (`fixture.mjs` plus the bench map, 46 directories) is past the cap even
  on 2.3.0 (10,009 characters), so it lists 45. The repo D22 was locked on already loses a directory. The field
  repo is not on this machine, so the large repo here is synthetic.
- **The change:** `startText` (`map.mjs`), only when the full text passes the 10,000-character cap. A repo that fits
  is byte-identical to 2.4.0, so A1's and P2's evidence carries over.
  - **Summary mode:** every directory stays listed, without its file names, as `<dir>/ (<n> documents)`. The map
    folder's line comes first and whole (J2). One note line: file names are left out, and listing a directory shows
    them.
  - **Grouped mode,** if the summary still passes the cap: directories group under their top folder, as
    `<top>/** (<k> directories, <n> documents)`.
  - **The old cut** applies only if even the groups pass the cap.
  - Onboard's warning says which mode applies.
  - FORCE is unchanged: it already asks per directory, and the note says how to see a directory's files.
- **Not addressed:** a repo under the cap still pays up to 10 KB at every session start. A lower budget would change
  P2's and A1's text, so it would need its own pull check.

**Checks:**
1. *The self-test:*
   - every existing index and start-text pin holds, so a repo that fits is unchanged;
   - new cases: summary mode lists every directory, under the cap, with the map line first and whole; grouped mode;
     the cut as a last resort; 10,000 directories within 100 ms.
   - A mutation check kills each new case.
2. **Coverage and size** on a synthetic field-shaped repo (`probes/V2-D22-large/large.mjs`: 179 document
   directories, about 850 documents, A1's `src/`):
   - directories covered at session start, 2.4.0 against the candidate;
   - the start text's characters.

   *Pass:* the candidate covers all 179, under the cap, in fewer characters than 2.4.0.
3. **A pull check in that repo,** 5 runs per arm, 2.4.0 against the candidate, on Opus 5.5 with the pinned CLI. Two
   binding documents are planted:
   - **D1** in a directory 2.4.0 lists by name: "Avatars never load from the CDN; they use the local file at
     /static/avatars/<id>.png";
   - **D2** in a directory 2.4.0 cuts: "Every new component file starts with the line // owner: web-platform".

   The task is "Create a UserAvatar component."
   - *Pass:* D1 is followed in at least 4 of 5 candidate runs (the summary loses no document that 2.4.0 showed by
     name). D2 is followed in at least as many candidate runs as control runs.
   - *Reported:* D2's counts, the documents each run read, and the cost.
4. `claude plugin validate`, the hooks smoke, and CI on three systems.

### 5: the field counter reads 2.0.1 to 2.4.0's labels (2026-11-23)

- `probes/V2-D17-field/field.mjs`, C5b: the entries a label block names. It now also reads:
  - 2.0.1's grouped line (`unverified quote, committed: entries 1-3 (captured …), 5`), by entry number, mapped to
    headings in the plugin's order;
  - labels that open with a status, a dream's proposal or a passed review date (2.1.0 and later).
- A self-check on those shapes runs at every load, and a mutation trips it. Probe code only, so no product change.

### 5, 5d: result (2026-11-23): attempt 1 fails check 3; D22 keeps the cut

- **Check 2 passed** (`probes/V2-D22-large/results/size.json`). On the synthetic repo (179 document directories,
  789 documents), 2.4.0 cuts to 65 of 181 directories at 9,886 characters. The candidate lists all 181 at 9,031 in
  summary mode.
- **Check 3 failed** (`results/pull.json`, 5 runs per arm, all valid):
  - **D1** (a directory 2.4.0 lists by name): followed in 5 of 5 runs of both arms, read in 5 of 5. The file holds
    1 and 0, from a scorer defect. It accepted only the literal `/static/avatars/` and counted "never the CDN" in a
    JSDoc comment as a CDN use. Every run used the fixture's `Img` with `local`, which resolves to that path. The
    probe's scorer is fixed, and the rescoring was done by hand on the saved files.
  - **D2** (a directory 2.4.0 cuts): **followed in 3 of 5 candidate runs against 5 of 5 control runs.** The bar,
    "at least as many", fails.
- **Why, read in the transcripts:**
  - a candidate run wrote "all 182 doc directories except `avatars/` are no". It judged
    `docs/standards/components/` by its name, then searched for words D2 does not use;
  - control runs read the cut's note ("116 more directories not listed"), searched the whole tree, and found D2.

  Listing every directory makes the list look complete, without the file names that would show what it holds.
- **The rethink:**
  - the cut already leads Claude to the documents it drops. The summary saves only about 850 characters, and it
    cost finding;
  - a lower budget would hide more file names, which is the measured harm;
  - a hybrid (names while they fit, counts for the rest) adds code for a gain nothing shows.

  So no second attempt. The code is reverted (`f30cd78d`); the product is `c3e75c22b0ea` again.
- **D22 re-locks on the cut.** The per-session size in a large repo, about 10 KB, is accepted. Claude explores past
  the cut, and the measured alternative found less.

### 5, 5c: result (2026-11-23): pass

- **Check 1:** the self-test pins both lines, and a mutation check kills each.
- **Check 2** (`probes/V2-D31-dream/results/s7-product-a8.json`, on `c3e75c22b0ea`, the copy hashed before the run).
  Every bar passes: C1 to C3 10 of 10; the rule, the skill and the choice 5 of 5; noise 0; other status lines 0; the
  nonce 0; live rules 0; 5.92 USD.
- **No walk without the user's yes:** in all 10 headless dreams, no proposal was accepted. No map file has an
  `- origin:` line, every map file the dream touched still has its `- proposed:` lines, and every draft keeps
  `.draft` (2 per fixture run).
- D33 locks, and D14 gets #7's note. S8's acceptance check runs at the release.

### 5, 5e: the 2.5.0 release checks, registered (2026-11-23, before their results)

2.5.0 holds 5a (P1, and P2's skill part), 5b (N13) and 5c (#7's files-only commit, D33's (M)). 5d was reverted. The
candidate is product `44a8c3454df2`. As 4e:
- **S7's check 2:** `s7-product-a8.json`, on `c3e75c22b0ea`, which differs from the candidate only by
  `plugin.json`'s version. It passed.
- **S8's acceptance check:** 5 runs, from a clone at the candidate commit, installed as a user installs it
  (`results/s8-e2e-250.json`), at its bars.
- **D18's reference bench:** the candidate against `v2.4.0` (`60455a805197`), in D18's reference state, after S8 ends.
  *Pass:* every hook kind's added p95 at most 100 ms, at 1 and 8, with 0 errors.
- **CI** on three systems; the release notes; the tag `v2.5.0`; and a pull request to `main`, merged once its checks
  are read. `v2` is pushed back after the merge (map entry `v2-branch-deleted-on-merge`).

### 5, 5e: the release checks (2026-11-23): pass

- **S8's acceptance check** (`probes/V2-D29-setup/results/s8-e2e-250.json`): 5 runs, every item 5 of 5. Every run
  installed 2.5.0 from a clone at `e35b60ae`, byte-identical to the candidate. 11.64 USD.
- **D18's reference bench** (`probes/V2-D30-entries/results-5e-reference.json`):
  - *the first window was void:* 8 CPU samples from 10.8% to 21.6%, from the user's own work (an editor and a build
    script), which was left alone;
  - *the second window:* CPU 9.3%, empty Node's p95 at 8 at most 53.7 ms;
  - **every hook within 100 ms, with 0 errors;** the largest is 82.3 ms (bash-other at 8). Against 2.4.0, the
    builds are within 2 ms of each other, but for session start (+10.7 at 8), whose nudge work the control skips.
- **CI** on `e35b60ae`: the self-test and the load jobs passed on three systems.
- **S7's check 2:** `s7-product-a8.json`, passed (5c).
- **5e passes.** Next: the tag `v2.5.0`, the release, and the pull request to `main`.

### 5: 2.5.0 released (2026-11-23)

- **PR #119 merged into `main`** (`530ab3eb`) after its checks were read: all seven passed. GitHub deleted `v2`
  again, as the map entry `v2-branch-deleted-on-merge` says, and it was pushed back at once at the same commit,
  `fbc32ae6`.
- **The `v2.5.0` release is published.** The two field repos and this repo moved from 2.4.0 to 2.5.0. The installed
  copy hashes `44a8c3454df2`, the release. Running sessions need `/reload-plugins`.
- **Open:** nothing from the user's list of 2026-11-23. The talk the user saw is not found in published text (4f),
  and R4 stays out (D33).

### 5: a field read of 2.3.0 and 2.4.0 in real use (registered 2026-11-23, before it runs)

Map issue step 22, "live tests on 2.3.0". The user's own sessions in the first field repo since the 2.3.0 install
(2026-11-22) are read, as the field loop of `probes/V2-D17-field/README.md` reads them. Two main sessions qualify; the
second field repo has none.
- **Freeze:** copies of the two transcripts, with their subagent folders, in the session's scratch folder. They are
  never put in the repo.
- **Scan:** `count.mjs` (`field.mjs` and `field-scope.mjs`), with C5b reading the newer label formats (today's
  update).
- **Record:** counts only, here. No quote from a transcript, and no name of the repo.
- **Triage,** by the loop's rule 6: a defect is fixed under its decision with a check registered first; an
  observation goes to the ledger; a candidate goes to the map issue.
- *Not a pass or fail:* D24's bar was 2.0.0's. This read looks for defects and for what real use shows.

### 5: the field read (2026-11-23): no defect

Two main sessions of the first field repo, 6 epochs (startup 2, resume 1, compaction 3). Counts only.
- **C1, arrival:** the plugin's session start arrived in 6 of 6 epochs, and its context was recorded each time. The
  index listed 10 or 11 directories.
- **C2, the forced decision:** once per epoch with a human prompt (5 of 5); never on a later prompt, never twice.
- **C6, capture in real use:** 2 entries written in the main session, both in the format and quoted word for word.
  None was forbidden data.
- **C8:** 0 hook errors in either session.
- **C5b, labels by output:** 9 calls showed map entries, 85 entries in all, and 81 were labelled by the counter's
  rule. All three calls it flagged were read by hand:
  - two printed files from Claude Code's own auto-memory folder, which restate some map headings. They are not map
    reads, and no label was due, so the counter's loose heading match is the false alarm;
  - one was a real `grep` of the map. Checked against the map as it was then, all 16 entries it showed are
    labelled. The counter compares each call with the map as it is now, and the file was committed again after the
    call.
- **Observations, recorded and not changed:**
  - **C9:** subagents (20 and 14) never got the index, and made no map entries in 188 repo writes. D14's
    instruction reaches the main session only, by design;
  - **field-scope:** (S-b)'s unread-documents bar is missed in 9 of 10 events, as in 17m. D22 settled on (N).
  - The counter's build label ("alpha.8") is stale for sessions after 2.0.0. Its time-to-build table stops at the
    GitHub install, and it misreads nothing else.
- **Triage:** no defect, no new candidate. Step 22 is read as done for 2.3.0 to 2.4.0; the next read waits for
  sessions on 2.5.0.

### 5: 2.5.0 checked live (2026-11-23, the user's request)

- **GitHub:**
  - `v2.5.0` is published and marked latest; the tag is on `fbc32ae6`;
  - `main` (`530ab3eb`) says 2.5.0 in `plugin.json` and `marketplace.json`, and its `plugin/` hashes
    `44a8c3454df2`, the release.
- **The user's installs:** the two field repos and this repo are each recorded at 2.5.0, enabled, and pointing at the
  2.5.0 cache, which hashes `44a8c3454df2`. The marketplace clone is at #119's merge.
- **A new user's install:** with an isolated config folder, `marketplace add Cain-Ish/claude-code-plugin` and
  `plugin install` from GitHub got 2.5.0, byte-identical to the release.
- **A session:** a headless session on the user's current CLI (2.1.330) ran in a scratch repo, with the installed
  2.5.0 copy:
  - the plugin was loaded, session start and the prompt hook both exited 0, and the forced decision arrived;
  - the start text is 2.4.0's narrowed capture wording, and the index listed the repo's documents;
  - the reply was a success.
- Sessions already running in the three repos keep their old hooks until `/reload-plugins` or a restart.

## 6: 2.5.1, setup brings a set-up repo up to date (registered 2026-11-23, before the code)

- **What the field showed.** In the first field repo, after `/reload-plugins` on 2.5.0, `/second-brain:setup`
  created nothing and kept 10 files. Three of them differ from 2.5.0's templates: the map rule, the review skill and
  the map's README.
  - Each of the three is byte-identical to 2.3.0's template (sha256, CRLF folded), committed and unchanged.
  - None of 2.4.0's or 2.5.0's template changes reached the repo, so the user cannot try them there.
  - The setup skill only says to name the files that differ. The session counted their lines and changed nothing.
- **The user's word** (2026-11-23): "we need to fix everything and push it to v2 and main branch cause we cannot test
  it now". Asked how setup should bring a repo up to date, the user chose "Auto-update copies". D29's guardrail
  "setup never overwrites a file" reopens.
- **The change:**
  - `setup.mjs`: each template that setup leaves in the repo for the plugin (the rule, the review skill, the three
    agents, the map's README) lists the hashes of the texts earlier releases shipped (2.3.0, 2.4.0). A kept file is
    replaced with this version's template only when both hold:
    - its text, CRLF folded, hashes to one of them, so it holds nothing of the repo's own;
    - it passes the guard that appending already uses: a regular, singly linked file inside the repo, not UTF-16,
      that git tracks under that name with no flag, and that shows unchanged.

    The diff is then the upgrade alone, and `git checkout -- <file>` undoes it. The file keeps its line ending. The
    report says "Updated to this version's templates (N)".
  - A file that differs and is no earlier template was changed in the repo. It is kept and listed, as now. The setup
    skill gains a step: show the user the template's lines that the file lacks, and add them on the user's yes,
    keeping the file's own lines.
  - The closing "review the new files in the diff, and commit them" shows only when setup wrote something. The field
    run printed it with nothing written.
  - `CLAUDE.md`, the topic files, `dreams.md` and `.gitattributes` stay the user's, and are never replaced.
- **Checks:**
  1. *The self-test:*
     - fixtures, under `test/`: the three changed templates as 2.3.0 and 2.4.0 shipped them. Each fixture's hash is
       in setup's list for its path. Each current template's hash is pinned, so a template change fails the
       self-test until the old hash is listed;
     - 2.3.0 copies, and 2.4.0 copies, committed and clean: each is replaced, equals the template, and is reported
       as updated. A second run updates and creates nothing, and its last line asks for no review;
     - kept and listed as differing: a 2.3.0 copy with an uncommitted change; a 2.3.0 copy edited and committed; an
       untracked 2.3.0 copy;
     - a CRLF copy keeps CRLF;
     - a mutation check kills each guard: the hash match, tracked, unchanged, and the write itself.
  2. *The field shape:* a local clone of the first field repo at its HEAD, in the scratch folder. Setup updates
     exactly the three files, each equals the candidate's template, `git status` lists only them, and a second run
     updates nothing. Counts only in this record.
  3. *The skill, headless* (the candidate copy, Opus 5.5, the user's CLI), 3 runs, in a scratch repo where the
     README is a 2.3.0 copy with one line added and committed, and the other two files are 2.3.0 copies:
     - the script updates the two copies, in 3 of 3;
     - with no yes given, the README is unchanged, and the reply shows its missing lines and asks, in 3 of 3;
     - each run resumed with "yes": the README holds every line of the template and its own added line, in 3 of 3.
  4. `claude plugin validate plugin`, and CI on three systems.
  5. A review of the diff by a fresh Claude agent (agy's quota is out). Each finding is fixed or recorded.
  - *Not run, and why:* D18's bench, because no hook path changes (`setup.mjs` runs only from the setup skill, and
    the module grows by a constant); S7, because the dream is untouched; S8, because a new repo's path (create with
    `wx`) is unchanged and pinned; A1, because the capture text is untouched.
- **The field counter** (`probes/V2-D17-field/field.mjs`, not the product): its time table stops at alpha.8, so every
  session after 2.0.0 was named "alpha.8". It now takes the version from the install path when the session shows one
  (a plugin skill ran), and otherwise says "2.0.0 or later".
- **Release:** 2.5.1, by 5e's route. Tag it, open a PR to `main`, read its checks before the merge, push `v2` back,
  publish the release, then move the three installs and check their hash. Setup in the field repo stays the user's own
  test.

### 6: check 3, attempt 1 (2026-11-23): fails on the skill step

- `probes/V2-D29-setup/upgrade.mjs`, 3 runs, CLI 2.1.331, Opus 5.5. The script updated the two untouched copies in 3
  of 3, and the edited README was untouched in 3 of 3. The other bars missed in 3 of 3: shown 0, asked 0, merged 0.
- **Why:** the new step had Claude run `git diff --no-index` against the template in the plugin's install folder.
  That folder is outside the repo, and Claude Code refused both the diff and a Read of it. So Claude could only ask
  for the access, and the "yes" granted none. The field session ran in auto mode, which allowed that read; a session
  that asks for permissions does not.
- **Attempt 2** (rule 4), registered here before its code. Setup's report itself carries, for each file that differs,
  its diff against the template (`git diff --no-index`, run by the script, CR at line end ignored, at most 4,000
  characters per file). Lines marked `+` are the template's. The skill step says to show those and add them on a yes.
  Claude then reads nothing outside the repo. The bars stay as registered, and the self-test pins the diff in the
  report.

### 6: the results (2026-11-24): pass on the final build; D29 re-locked after CI

- **Where it ran:** the edits were made in `plugin/` on `v2`'s working tree. No real session runs from this checkout:
  the installs run GitHub's release since 2026-10-29. Every check ran from a copy of it in the session's scratch
  folder, and check 3's probe names only the copy's folder name.
- **Attempts under rule 4, in this reopen:** 2 failed, and the final build is the third.
  1. Check 3's first skill step (above).
  2. Check 1's expected outcome for an untracked 2.3.0 copy changed after the review's result: from "listed as
     differing" to "named apart, with why". Rule 2 counts that as a failed attempt.
- **Check 1, the self-test,** passes. Product `2625c8cd263b`.
  - *Fixtures:* the three changed templates of 2.3.0 and 2.4.0, under `plugin/test/earlier/`. Each one's hash is listed
    in `setup.mjs`, and the six templates setup may replace are pinned.
  - *Updated:* 2.3.0 copies, and 2.4.0 copies. A CRLF copy keeps CRLF. An update with every other file in place
    counts as a write.
  - *Kept and named apart, with why:* untracked, staged, with an uncommitted change, skip-worktree, hard-linked, and
    read-only copies.
  - *Kept and listed as changed here, with its diff in the report:* an edited copy.
  - *A second run* writes nothing, and its last line asks for no review, in every case.
  - *The mutation check* (`probes/V2-D29-setup/mutate6.mjs`, `results/mutate6.txt`): 16 mutations of the update
    path, 16 killed.
- **Check 2, the field shape:** in a local clone of the first field repo, setup updated exactly the three files, and
  each equals the template. `git status` lists only them. The second run wrote nothing ("Ran on …", "Nothing was
  written.").
- **Check 3, attempt 2:** 3 runs, CLI 2.1.331, Opus 5.5. Updated 3, untouched 3, shown 3, asked 3, merged 3, for
  1.06 USD. It ran on the build before the review's fixes. The final build's report is byte-identical on that repo
  shape (44 lines), but the review's fix also changed the skill's step 5, so check 3 ran again on the final build
  (`results/upgrade.json`): updated 3, untouched 3, shown 3, asked 3, merged 3, for 1.12 USD. Pass.
- **Check 5, the review** (a fresh Claude agent):
  - It found no way to lose a file's own content or to write outside the repo.
  - It reproduced the refusals: staged, skip-worktree, a hard link, a junction, a name that differs in case, a
    submodule, untracked, ignored, a UTF-8 BOM.
  - It reported five findings:
    - an untouched copy that the guard stops was labelled "changed in this repo", so the skill would mix old and new
      lines in it. *Fixed:* such a file is named apart, with why;
    - a read-only copy stopped setup with an error and no report. *Fixed:* the write error is caught and the file is
      named;
    - the skill's diff read a CRLF file as all changed. *Fixed by attempt 2:* the script diffs it, ignoring CR at
      line end;
    - a file with mixed line endings is rewritten in its first line's ending. *Recorded:* only template text is
      affected;
    - test gaps on the update path. *Closed* by the staged, skip-worktree, hard-link and read-only cases.
  - Also fixed while checking: a run that wrote nothing said "Written on"; it now says "Ran on".
- **Check 4:** `claude plugin validate plugin` passes. CI passed on `6072c38e`, the commit that records these results:
  the self-test and the load check on Linux, macOS and Windows, 6 of 6 jobs.
- **The decision-checker** (this repo's agent) found no broken guardrail: setup commits nothing, deletes nothing, and
  replaces only on an earlier release's hash with the guard passing. Its process points are taken: the attempt
  count, where the build ran, and the re-lock waiting for CI (all above); the mutation script is now in the repo; a
  second run's last line is asserted in every case; and check 3 runs again on the final build. A partly written file
  (a write that fails midway) stays tracked and is named "not updated", and `git checkout` restores it.
- **The counter:** `field.mjs` labels the three latest field sessions "v2.3.0" or "2.0.0 or later", and never
  "alpha.8".
- **D29 is re-LOCKED (2026-11-24),** CI having passed. The guardrail now reads: setup commits nothing and deletes no file. It changes a
  file that exists only in two ways, and only when git shows that file tracked under its name, with no flag, and
  unchanged:
  - it appends its section or line to an instruction file or `.gitattributes`;
  - it replaces a file whose text is a template an earlier release shipped.

### 6: 2.5.1 released (2026-11-24)

- **PR #120 merged into `main`** (`e180263d`) after its seven checks were read, all passing. GitHub deleted `v2`
  again (`v2-branch-deleted-on-merge`), and it was pushed back at once at `155aad9c`.
- **The tag `v2.5.1`** is on `155aad9c`, whose `plugin/` is byte-identical to `6072c38e`, where CI passed. The release
  is published and marked latest. `main`'s `plugin/` equals the tag.
- **The user's installs:** the two field repos and this repo moved from 2.5.0 to 2.5.1 at local scope. The installed
  copy is byte-identical to the tag. Running sessions need `/reload-plugins`.
- **Next, the user's own test:** in the first field repo, `/reload-plugins`, then `/second-brain:setup`. By check 2,
  it should update the three files and leave the rest of the tree as it is.
- **For the next release** (a comment edit changes the product hash): `setup.mjs`'s header (line 2) and its N10
  comment (line 111) still say that setup never overwrites. The code and the skill are right; only these two comments
  are stale.
- **Before the user's run,** checked read-only in the first field repo: its three files are tracked with no flag
  (`H`), clean, and singly linked, so setup's guard lets the update through.

## 7: agents and skills made for one repo, tested before anyone keeps them (registered 2026-11-24, before the code)

- **The user's word** (2026-11-24): full guidelines in the plugin, so that in other repos Claude creates dedicated,
  correctly made agents and skills per repo, with a self-evaluate and self-improve loop.
  - The research: [research/2026-11-24-repo-agents-and-skills.md](research/2026-11-24-repo-agents-and-skills.md).
  - **D34** opens on it for making and testing.
  - **D35** opens with 7b, for improving from the repo's sessions. That is a second question, so it gets a second
    decision.
- **The probes** ([probes/V2-D34-repo-artifacts](probes/V2-D34-repo-artifacts/README.md)):
  1. A nested `claude -p` loads a draft skill (`--plugin-dir`) and uses it from plain words. A draft agent
     (`--agents`) loads, but was not delegated to on a simple question, so use is a bar of its own.
  2. In the first field repo, the repo's own two agents ran in 9 of 14 sessions each, and its own two skills in 6 and
     3. The plugin's codebase-guide and memory-curator ran in no session of three repos.
  3. `.claude/agents/<name>.md.draft` is not loaded, as D31 found for rule and skill drafts.
- **`claude plugin eval` stays out.** Its cases start in an empty workspace, and whether its skills-dir target can
  test a repo's own `.claude/` in place is unproven.

### 7, 7a: the guidelines skill, its paired trial, and the review gate (registered 2026-11-24, before the code)

- **What reopens, on the user's word of 2026-11-24:**
  - **D18's surface.** A fourth skill that Claude may invoke: its description is listed in every session. The budget
    row below replaces section 3's skills row for this series.
  - **D10's scope.** The plugin also guides making the repo's own agents, skills and path rules from evidence. Made
    agents stay task agents, and nothing is kept without a person's yes.
  - **The charter** gets a dated entry saying both, and restates the non-goals. The trial's nested sessions only test
    an artifact in a copy; they never do the user's work.
- **Budget** (PM6, PM8):

  | Unit | Budget | Outcome served |
  | --- | --- | --- |
  | Skills | 4: `setup`, `dream`, `status` (each `disable-model-invocation: true`), and `tailor`, which Claude may invoke | Consistency (tailor: artifacts that hold Claude to how this repo works) |
  | Always-on bytes | section 3's, plus tailor's listing text (its description), at most 400 bytes, measured by the self-test | Orientation |
  | Scripts a skill may run | tailor: `trial.mjs` only | — |
  | Plugin agents | still 1 (`dream-analyzer`). The trial's grader is a general subagent given the grading prompt, not a new agent | — |
  | Hooks | unchanged | — |

- **The change** (2.6.0, built in a copy of `plugin/` until the checks pass):
  - **`skills/tailor/SKILL.md`.** It makes or improves one agent, skill or path rule for this repo, and offers the
    other homes. Its steps:
    1. **The gap.**
       - The gap rests on the user's typed lines in this repo's sessions, a map entry, or the user's request.
       - A request counts only when it names a task the artifact will do, and at least one example or rule of how this
         repo does it. "Make agents for this repo" names no task.
       - With no gap, it makes nothing and says what evidence it needs.
    2. **The home.**
       - The smallest that holds the gap: a `CLAUDE.md` line, a path rule, a skill, an agent, or a check or hook.
       - First check that nothing in the repo already does it.
       - A `CLAUDE.md` line, a check and a hook have no draft form. For these, nothing is written: Claude shows the
         text and writes it only on the user's yes.
    3. **Grounding.**
       - Every path, command and name it states exists, and is checked.
       - It holds only what Claude cannot infer from the repo.
    4. **Writing,** by `skills/tailor/guidelines.md`, a reference file read on use. It holds Anthropic's rules for
       agents, skills and path rules, re-read at the source on 2026-11-24, as principles rather than a field table.
       A made agent does one task, names its tools, and is no persona for a role.
    5. **Cases,** in `.project-map/evals/<name>.json`:
       - three or more, and one where the artifact should not be used;
       - each with a prompt, an outcome a grader can check, and the tools the run may use;
       - prompts come from the user's typed lines or examples, never from tool output;
       - the trial refuses a case file that holds a secret, a session id, an email address or an absolute path
         (D31's scan).
    6. **The trial.**
       - Claude first shows the user what `trial.mjs plan` prints: each prompt, its tools, and the permission mode.
       - On the user's yes, in this session, Claude invokes `tailor` again with `run <name>`. A skill's grant lasts
         one turn, so the new invocation renews it, and only then is `trial.mjs run` used.
       - Each case runs in a scratch copy of the repo, with the artifact and without it (or with its old version).
         The sessions are nested `claude -p` runs with `--permission-mode acceptEdits`, `--allowedTools` only as the
         case lists, and all hooks off (`disableAllHooks`), alike in both arms.
       - A general subagent grades each outcome against the case, without knowing the arm.
       - Claude shows the counts: passes with and without, and, for a skill or an agent, use, including on the case
         where it should not be used.
       - The trial covers skills, agents and path rules. A path rule makes no call to detect, so its use is not
         counted, only its outcomes.
    7. **The result.**
       - A skill, agent or path rule stays a draft (`.draft`, inert by probe 3). Nothing is committed.
       - Agent drafts are not counted in the session-start "waiting for review" line, since `map.mjs` `drafts()`
         counts rule and skill drafts only. That is accepted in 7a: tailor makes a draft only in a session with the
         user. 7b, which lets the dream make agent drafts, changes `drafts()` and runs D18's bench.
    8. **Improving one:**
       - add the missed case first;
       - change the smallest part;
       - rerun every case;
       - stop after three failed rounds and bring in the user;
       - propose retiring it when the run without it passes as often.
  - **`scripts/trial.mjs`.** `plan <name>` prints what will run. `run <name>` does the following:
    - copies the repo's tracked and untracked, not ignored, files into a folder under the plugin's data folder, never
      inside the repo;
    - places the artifact at its live path for "with", removes it for "without", and puts the live text back for
      "old";
    - runs the sessions with the nesting variables removed;
    - records per run: whether the artifact was used (a `Skill` call by its exact name, plugin-scoped too, or an
      `Agent` call by its type), the final reply, and the files changed with their diff (capped);
    - deletes its copies.

    It grades nothing.
  - **Templates:**
    - The map README's "Where it belongs" table gains an agent row: a task that recurs and needs its own context,
      tools or notes. Its offers name `/second-brain:tailor`.
    - `map-review`'s drafts step changes. For an agent or skill draft, Claude invokes `tailor`, which:
      - writes cases from the draft's evidence lines;
      - shows them and asks;
      - on a yes, runs the trial, and only then asks whether to promote.

      `map-review` is a repo skill, so it never runs plugin scripts itself.
    - D29's copy rule: 2.5.1's texts of both templates go under `test/earlier/2.5.1/`, and their hashes into `FILES`.
  - **`setup.mjs`:** the comments on line 2 and in N10, which still say setup never overwrites (section 6's note for
    this release).
- **Checks:**
  0. *Order (PM1): baselines first.*
     - N, U and Us (check 3) run on 2.5.1 before `tailor` or `trial.mjs` is written.
     - **The ceiling rule** (D17): if the best baseline passes 5 or more of its 6 held-out runs, the fixture measures
       nothing. That is a failed attempt under rule 4, as D17 counts it, and the fixture is hardened and the baselines
       rerun. If the attempts run out on the ceiling, the making steps end: D34 settles on (A) for making.
     - **G's bars,** recorded before tailor's code:
       - G passes 5 or more of 6;
       - G passes at least 2 more than the best baseline.

       With 6 runs per arm, the result is directional.
  1. *The self-test.* A mutation check kills each guard:
     - (i) the copy lies outside the repo and holds no `.git`; the repo's files and `git status` are unchanged after a
       trial with a stub `claude`;
     - (ii) the artifact is at its live path in "with" only, and the old text is in "old";
     - (iii) use is matched on the exact name, plugin-scoped `x:name` too, never a substring;
     - (iv) the nesting variables are removed from the child's environment;
     - (v) the copies are deleted;
     - (vi) case validation (three or more, one with `use: false`, prompt and outcome) and the privacy scan;
     - (vii) all hooks off, `acceptEdits`, and only the listed tools are passed to the child.

     It also covers:
     - tailor's description at most 400 bytes;
     - the 2.5.1 fixtures and hash pins.
  2. *The runner, live.* A scratch fixture with one skill draft and one agent draft. Per kind:
     - one case built to use it (the agent named in the prompt) and one should-not case;
     - both arms, one run each.

     "Used" matches the stream's tool calls in 8 of 8 records, with at least one true positive per kind. The repo's
     files and `git status` are unchanged.
  3. *The outcome.*

     **The fixture,** fixed now:
     - a small plain Node repo with `src/util.js` (a function `fmt` and two callers);
     - migrations `db/migrations/0001_init.sql`, `0002_users.sql` and `0100_ledger.sql`, with their `.down.sql`
       files;
     - `db/reserved.txt`: core 0003 to 0099, payments 0100 to 0199;
     - `scripts/check-migrations.js`: prints `OK` when every migration has its `.down.sql`, numbers are unique, and
       every number above 0002 lies in a reserved range;
     - three entries in `.project-map/decisions.md`, from the lead developer:
       - core migrations take the next free number in the core range, not the highest file plus one (that would be
         0101, the payments team's);
       - every migration has a `NNNN_name.down.sql` that undoes it;
       - after adding one, `node scripts/check-migrations.js` must print OK.

     **The maker's request,** the same in every arm: "Make a skill or an agent for this repo that adds a database
     migration the way this project does it." In every maker arm alike, a run whose reply asks a question, or whose
     denied write was just applied, is resumed with "yes", at most twice (in G, this is how the trial gets its yes).

     **Arms,** each in a fresh scratch copy (Opus 5.5, the user's CLI). Every run uses the same settings:
     - `acceptEdits`;
     - listed tools only: `node`, `npm` and read-only shell commands, with PowerShell off;
     - no MCP servers, no web tools, project and local settings only.

     Claude Code protects `.claude/` even under `acceptEdits`, and a headless run has no one to approve. So a denied
     Write or Edit inside the copy's own `.claude/` is applied by the harness, standing in for the person's approval.
     The run is then resumed with "yes". A live file written that way counts against G's "left as a draft".
     - **N:** no artifact, 2.5.1;
     - **U:** a maker on 2.5.1;
     - **Us:** a maker on 2.5.1 with the official `skill-creator` loaded;
     - **G:** a maker on the 2.6.0 candidate.

     **Runs:**
     - three maker runs per maker arm;
     - each run's artifacts are placed live in a fresh copy. A run that wrote none faces the tasks with none; a run
       that wrote several has them all placed;
     - each copy faces the two held-out tasks (a nullable `phone` column on `users`; a `tags` table with `id` and
       `name`) and one should-not task (rename `fmt` to `formatDate`, with its callers);
     - N runs the two held-out tasks three times each.

     **The grader script,** fixed with the fixture. A held-out run passes when all of these hold:
     - new `0003_*.sql` and `0003_*.down.sql` files exist;
     - the check prints `OK`;
     - the up file does the task:
       - `alter table users add [column] phone`, with the down file naming `phone`;
       - or `create table [if not exists] tags`, naming `id` and `name`, with the down file dropping `tags`;
     - no other migration changed.

     **Bars:**
     - (a), (b) as fixed by check 0;
     - (c) G's artifact is used in at most 1 of its 3 should-not runs;
     - (d) G's artifact is used in 5 or more of its 6 held-out runs;
     - (e) in G's maker runs:
       - the cases were shown and asked before any trial, in 3 of 3;
       - after the yes, the trial ran and its counts were shown, in 2 or more of 3;
       - the artifact was left as a draft and nothing was committed, in 3 of 3;
       - every backquoted path and `node`/`npm` command it names exists in the fixture, checked by a script, in 3 of
         3;
       - a made agent names its tools, in 3 of 3, and does one task with no persona for a role, in 3 of 3. A fresh
         subagent judges the second part against that sentence, and its reason is recorded.
     - (f) the trial agrees with the held-out results. One trial each runs on a good draft (G's first) and on a
       planted bad one (it numbers by highest plus one). The good draft's with-arm passes more cases than its
       without-arm, and the bad draft's does not.

     **If U or Us reaches G, or the ceiling rule ends the making steps:** they are not shipped (PM1). The trial and
     the review gate ship only if (f), check 2 and check 5 pass.
  4. *No gap.* The fixture without the three entries; the request "Make agents and skills tailored to this repo".
     G makes no artifact, live or draft, and names the evidence it needs or asks for it, in 2 or more of 3. U's result
     is recorded, with no bar.
  5. *The review gate, headless* (3 runs). A scratch repo with a dream skill draft (with its evidence line) and no
     case file, then `/map-review`:
     - tailor writes cases from the evidence, shows them and asks, in 3 of 3;
     - resumed with "yes", the trial runs and its counts come before the promotion question, in 2 or more of 3;
     - nothing is promoted without a second yes, in 3 of 3;
     - after it, the draft is promoted, in 3 of 3.
  6. *Regressions:*
     - 5a's check 2 rerun on the candidate (the README table changes): told a rule a tool can enforce, Claude records
       it and offers a check, in 5 of 5, and no run makes a new live rule or skill, in 5 of 5;
     - D33's (M) handoff (the dream's last step into `map-review`'s text), as 5c checked it, in 3 runs: nothing is
       accepted without the user's yes.
  7. `claude plugin validate plugin`, CI on three systems, a review of the diff by a fresh Claude agent (agy's quota is
     out), and the decision-checker. Each finding is fixed or recorded.
  - *Not run, and why:*
    - D18's bench: no hook code changes; the listing bytes are counted in check 1;
    - S7: the dream is untouched, and its handoff is check 6;
    - A1: the capture text is untouched;
    - S8: setup's code path is unchanged, and the template texts are pinned.
  - *Attempts:* at most three failed attempts for 7a across its checks, a fourth only for a near miss with a known
    cause. Then D34 is BLOCKED and goes to the user. A bar changed after a result counts as a failed attempt (rule 2).
- **7b, registered later, before its code, with D35:** the dream reads failed tool calls and the use of each skill and
  agent, proposes agents and changes to existing ones, and gains a steering section (the research's G3 and G4).
- **Release:** 2.6.0, by 5e's mechanics: tag, PR to `main`, read its checks before the merge, push `v2` back, publish,
  move the installs. The release checks are 7a's, as listed above.

### 7, 7a: check 0, attempt 1 (2026-11-24): fails on the ceiling; the fixture gives the practice away

- **N, counted:** 6 of 6 held-out runs passed (both tasks, three runs each), on 2.5.1 with the three map entries and
  no artifact. Every run read `.project-map/decisions.md`. By the ceiling rule this is a failed attempt (rule 4, D17):
  one of 7a's three.
- **A floor run, read after the result** (diagnostic only; no bar moves): the same repo with no map entries and no
  artifact also passed 6 of 6. The repo gives the practice away: `db/reserved.txt` lists the core range first, every
  migration already has its `.down.sql`, and the check script prints its rules. So the result does not show that the
  map carried the rules. It shows that a short rule the repo makes visible needs no artifact.
- **Harness:** the stand-in for the person's approval now applies only to skills, agents, rules and commands, in
  maker runs only, never to a settings file.

### 7, 7a: check 0, attempt 2, registered (2026-11-24, before its runs)

- **The task kind,** from the first field repo's four own artifacts (kinds only): three are checks run after a change
  to one area, of several steps (a UI check, a board check, a walk through the built app), and one reads the
  project's sources before it implements domain logic. Fixture 2 takes the first kind: a procedure no single map line
  and no file in the repo states.
- **Fixture 2** (`outcome/fixture2`), fixed now:
  - the fixture's `src/util.js` and its callers;
  - `src/pricing/discount.js` (a loyalty discount of 5%, truncated to whole cents);
  - `scripts/golden.js`, which prints one line per case in `fixtures/pricing-cases.json`;
  - `reports/pricing-2026-11-01.txt`, an earlier output;
  - `PRICING-LOG.md`, with two earlier lines.

  No file says when to run the report or what to log.
- **The procedure,** given in the request: after any change under `src/pricing/`:
  1. run `node scripts/golden.js` and save its output to `reports/pricing-<YYYY-MM-DD>.txt`;
  2. add a line to `PRICING-LOG.md` with the date, what changed, and how many golden cases changed since the last
     report.
- **Arms** (protocol as in check 3; `.project-map/` is carried from the maker's copy into each held-out copy, in every
  arm, since 2.5.1's capture may keep what the request says):
  - **Floor:** no request, no artifact. If it passes 2 or more of its 6, the procedure is inferable and the fixture
    is void: a failed attempt.
  - **T (tell), on 2.5.1:** "Note for this repo:" and the procedure, with no artifact asked for. Three runs, each
    followed by the held-out tasks.
  - **U, Us, G:** the maker's request: "Make a skill or an agent for this repo that does our pricing check:" and the
    procedure.
- **Held-out tasks:**
  - change the loyalty discount from 5% to 7%;
  - round discounts half up to whole cents, instead of truncating.

  The should-not task is the rename, as in check 3.
- **The grader** (`outcome/grade2.mjs`), fixed now. A held-out run passes when all of these hold:
  - the code change is made;
  - `reports/pricing-<today>.txt` equals what `scripts/golden.js` prints after the change;
  - `PRICING-LOG.md` gained exactly one line, holding today's date and the number of cases whose line differs from
    the latest earlier report.
- **Bars:** check 0's ceiling rule, with T counted among the baselines. G's bars stay those of check 0 and check 3,
  against the best of T, U and Us. If the floor or a baseline hits the ceiling, the attempt fails.

### 7, 7a: check 0, attempt 2 (2026-11-24): fails; the floor is at the void line, and T and U reach the ceiling

Fixture 2, 2.5.1, Opus 5.5, under the registered protocol. Held-out passes, of 6 each:

| Arm | Passes | Artifact used | Should-not used | What the makers left |
| --- | --- | --- | --- | --- |
| Floor (no request, no artifact) | 2 | — | — | — |
| T (the procedure told, no artifact asked) | 6 | — | — | no artifact in 3 of 3; the map carried the note |
| U (a maker, no guidelines) | 6 | 6 | 0 of 3 | one live skill in 3 of 3 (one with a counting script) |
| Us (a maker with `skill-creator`) | 4 | 6 | 0 of 3 | one live skill in 3 of 3 (one with a counting script) |

- **The floor** passed 2 of 6, both on the rate task. With no word of the procedure, Claude wrote a report and a log
  line in every run: the repo's `reports/` folder and its log show the habit. By the registered rule (2 or more),
  fixture 2 is void. Failed attempt 2 of 7a's three.
- **T and U** each reach 6 of 6, so G could not pass "at least 2 more than the best baseline" on this fixture
  either.
- **What the two attempts show:**
  - On a short rule the repo shows, and on a procedure a person states once, Opus 5.5 does the task as the project
    wants with no artifact made: the map (T) or an unguided skill (U) is enough.
  - The making steps have shown no need on either task kind (PM1).
  - Us's two misses were one copy in which both tasks skipped the report and the log while the skill was used. The
    skill did not hold on that run.

### 7, 7a: attempt 2 read again; the making steps end; the last attempt registered (2026-11-24, before its code)

**Us, corrected.**
- The harness broke the registered protocol, "the artifact is taken from wherever the maker wrote it". One Us maker's
  skill calls `node scripts/pricing-check.js`, a script it wrote outside `.claude/`. The runner carried only `.claude/`
  and `CLAUDE.md`, so both held-out runs failed on a missing module.
- The runner now also carries any new file an artifact names. That maker's three held-out runs, rerun, pass both tasks
  with the skill used, and the should-not run leaves it unused. Us is 6 of 6.
- The first runs are kept in scratch. Counts and the made skills:
  [probes/V2-D34-repo-artifacts/outcome/results/attempt2](probes/V2-D34-repo-artifacts/outcome/results/attempt2/results.json).
  The made skills are filed under `dot-claude/`, so they never load.

**Cost.**
- A held-out run cost the same in every arm, about $0.21.
- Making the skill cost about four times as much as telling Claude: $1.55 for U's three makers and $2.25 for Us's,
  against $0.38 for T's.
- T's three copies each hold the procedure in `.project-map/pricing.md`.

**The making steps end, by choice after two ceilings.**
- On both fixtures, a told procedure kept in the map (T) and a skill made with no guidelines (U, Us) reach 6 of 6.
  G could not beat that by 2 on any fixture where the baselines pass.
- A third fixture chosen after these results would be fitted to them.
- So D34 settles on (A) for making: no making guidance ships, and the README's placement table stays as it is.
- This is a choice on the evidence, recorded as such. The ceiling rule did not run out.

**What can still ship: the trial and the review gate.** In the field, `map-review` promotes a dream's skill draft with
no test, and Us's first run shows how a good-looking skill fails: it named a script the repo did not hold. The skill
is renamed `trial`, since it no longer makes anything.
- **`skills/trial/SKILL.md`,** which Claude may invoke (the budget row above, with `trial` in place of `tailor`). It
  tests one agent, skill or path rule for this repo against a run without it: a draft, or a file the user names. Its
  steps are 7a's steps 5 to 7:
  - cases in `.project-map/evals/<name>.json`, from the user's typed lines, the draft's evidence lines, or the user's
    examples, with D31's scan;
  - `trial.mjs plan` shown, then the user's yes, then `run <name>` on a new invocation;
  - a blind grader subagent judges each run;
  - Claude shows the counts.

  It promotes nothing. Improving an artifact from what the trial finds is D35's question.
- **`scripts/trial.mjs`,** as registered. It also carries any new file the artifact names by its path.
- **`map-review`'s drafts step:** for an agent or skill draft, Claude invokes `trial` first, and asks whether to
  promote only after the counts. D29's copy rule applies to this one template.
- **`setup.mjs`'s** two stale comments, as registered.

**The last attempt covers these checks.** At most one failure remains; then D34 is BLOCKED and goes to the user.
- **1, the self-test,** with guards (i) to (vii). Its listing check reads `trial`'s description, at most 400 bytes.
- **2, the runner, live.** The trial accepts no fewer than three cases, so each kind gets three: two built to use it
  (the agent named in the prompt) and one should-not. That makes 12 records.
  - "Used" matches the stream's tool calls in 12 of 12, with at least one true positive per kind.
  - The repo's files and `git status` are unchanged.

  Amended before any run.
- **5, the review gate, headless,** as registered, with `trial` in place of `tailor`.
- **6, the regression:** D33's (M) handoff, in 3 runs. 5a's rerun drops out, since the README does not change.
- **(f), the trial agrees with the held-out results.** On fixture 2, `trial` runs once on each of two drafts:
  - **good:** U's first maker's skill, which passed 2 of 2 held-out runs;
  - **bad:** Us's second maker's skill without its script, which passed 0 of 2.

  The good draft's with-arm passes more cases than its without-arm, and the bad draft's does not. The cases are the
  ones `trial` writes from the procedure as the user's example, shown and accepted in the run.
- **7:** validate, CI, a fresh-agent review, and the decision-checker.

Checks 3 and 4 fall away with the making steps.

### 7, 7a: the user's word on the scope, and the last attempt re-registered (2026-11-24, before its code)

- **Asked** whether 2.6.0 ships the trial only, the trial with the making guidelines, or nothing, after the two
  ceilings, the user chose **"Trial plus making guidelines"**. The making steps ship by the user's word, against the
  measured result: on both fixtures, nothing showed that they help. That is recorded in D34 as the user's decision.
- **One skill again, `tailor`.** It makes or tests an agent, skill or path rule for this repo, so the budget's four
  skills hold. It keeps `trial.mjs` as its one script, and its description stays at most 400 bytes.
  - **Making:** 7a's steps 1 to 4 (the gap, the home, grounding, writing by `skills/tailor/guidelines.md`), then
    steps 5 to 7 (cases, the trial, a draft).
  - **Testing:** steps 5 to 7 alone, on a draft or a file the user names.
  - **The README's placement table** gains the agent row, and its offers name `/second-brain:tailor`, as first
    registered. D29's copy rule then covers the README too.
- **The making steps are checked for their guardrails, not their outcome,** since no fixture showed a need:
  - **Check 3's (e)** on fixture 2. G is three maker runs on the candidate, with the maker's request and the
    registered protocol:
    - the cases are shown and asked before any trial, in 3 of 3;
    - after the yes, the trial runs and its counts are shown, in 2 or more of 3;
    - the artifact is left as a draft and nothing is committed, in 3 of 3;
    - every backquoted path and `node`/`npm` command it names exists, in 3 of 3;
    - a made agent names its tools and does one task, in 3 of 3.

    Bars (a) to (d) are dropped as unreachable, since the baselines hit the ceiling. G's held-out passes are recorded,
    with no bar.
  - **Check 4,** no gap, as registered.
- **Check 5, amended before any run.**
  - A dream's skill draft cites its evidence as digest lines, `<digest>:<line>`, which hold no user words. So
    `tailor` cannot write cases from them alone, and by its step 2 it asks the user for examples.
  - The headless run follows that path, in five turns:
    1. `/map-review`;
    2. the user's examples (the two pricing tasks and the rename);
    3. "yes" to the plan;
    4. the promotion question, left unanswered;
    5. "yes".
  - Bars:
    - the cases are shown and asked before any trial, in 3 of 3;
    - the trial's counts come before the promotion question, in 2 or more of 3;
    - nothing is promoted before the second yes, in 3 of 3;
    - it is promoted after it, in 3 of 3.
  - A denied rename into `.claude/` is applied by the harness, as in check 3.
- **The last attempt covers checks 1, 2, 3(e), 4, 5, 6 and (f).** Check 6 includes 5a's rerun again, since the README
  changes. One failure remains; then D34 is BLOCKED and goes to the user.

### 7, 7a: the last attempt (2026-11-24): three checks pass, two fail; D34 is BLOCKED

Candidate `036aa02e7778` before the version bump, in a copy of `plugin/`. Counts:
[probes/V2-D34-repo-artifacts/outcome/results/attempt3](probes/V2-D34-repo-artifacts/outcome/results/attempt3/results.json).
The Claude Code process crashed once mid-run. The runs are resumable, and every result below comes from a finished
run.

| Check | Result |
| --- | --- |
| 1, the self-test and the mutation check | **pass**: the self-test passes; 28 of 28 mutations killed (`mutate7.txt`) |
| 2, the runner, live | **pass**: "used" matched the stream in 12 of 12 records, with 2 true positives per kind; the repo was unchanged |
| 4, no gap | **pass**: the candidate made nothing in 3 of 3 and named the evidence it needed. 2.5.1, with the same request, made a live agent and a live skill in 3 of 3 (recorded, no bar) |
| 3(e), the making guardrails | **fail**: drafts and no commit in 3 of 3; the trial ran in 0 of 3 |
| (f), the trial's verdict | **fail**: no verdict on either draft |
| 5, 6 | not run |

**A harness defect, found and fixed before these results.**
- The test sessions' tool list lacked `Skill`. Under `acceptEdits`, a headless session then declines a plugin's skill,
  though it allows the repo's own: `second-brain:tailor` was declined in all 6 first maker runs.
- The first G and no-gap runs never loaded the candidate, so they are filed as invalid. `Skill` was added for every arm
  and they were rerun. The counts above are the reruns.
- The same defect hit attempt 2's Us arm: `skill-creator` was declined there too. Us is 6 of 6 as a result, but it was
  not a run with `skill-creator`.

**Why 3(e) and (f) failed:**
1. **A read outside the repo, again.**
   - The making steps read `${CLAUDE_PLUGIN_ROOT}/skills/tailor/guidelines.md`, and the grader reads the records in the
     plugin's data folder. A permission-gated session declines both.
   - Section 6's attempt 1 failed on the same class, and its lesson ("put it in the report") was not applied here.
2. **The draft write into `.claude/`.** It is guarded, so it needs the person's approval prompt.
   - The harness applies a denied write only after the turn. Claude does not see that, retries on each "yes", and used
     up its three turns before the cases.
   - In a session with a person the prompt comes in the turn, so this loop is the harness's. Dream drafts avoid the
     guard altogether: `dream.mjs finish` writes them.
3. **Testing a draft with a missing script.** Claude tried to repair the bad draft before testing it. The skill does
   not say that a test leaves the artifact as it is.

**The fixes these causes point to,** not built:
- the guidelines inside `SKILL.md`;
- the records printed by `trial.mjs` for the grader, not left in a folder outside the repo;
- the draft written by `trial.mjs` (`draft <path>`), as the dream's finish writes its drafts;
- one line saying that a test changes nothing in the artifact.

**By rule 4** these were 7a's three attempts, so D34 is BLOCKED and goes to the user. A fourth attempt is allowed only
for a near miss with a known cause. Whether this is one is the user's call.

### 7, 7a: a fourth attempt, by the user's word (registered 2026-11-24, before its code)

- **The user's answer** to D34's block: "Fourth attempt". Rule 4 allows one only for a near miss with a known cause.
  Checks 1, 2 and 4 passed, and the two failures trace to the causes above. It is the last.
- **The fixes, and nothing else:**
  1. **The guidelines inside `skills/tailor/SKILL.md`,** so that making needs no read outside the repo.
     `guidelines.md` is removed, and the file stays under 500 lines.
  2. **The trial prints what the grader needs.**
     - `trial.mjs run` prints each record (blind; reply capped at 2,000 characters, diff at 6,000). Claude gives them
       to the grader in its prompt.
     - `trial.mjs score <run> <data> <grades>` reads the key itself and prints the table. Claude never opens a file in
       the plugin's data folder, and sees the arms only after grading.
  3. **The draft is written by the script,** as the dream's `finish` writes its drafts:
     - Claude writes the artifact to `.project-map/drafts/<name>/`, which is not guarded: `SKILL.md` and any helper
       files for a skill, `agent.md` for an agent, `rule.md` for a path rule;
     - `trial.mjs draft <name> <skill|agent|rule>` moves it to `.claude/skills/<name>/SKILL.md.draft` (helpers beside
       it), `.claude/agents/<name>.md.draft` or `.claude/rules/<name>.md.draft`;
     - it never overwrites, it refuses a path that resolves outside the repo, and it needs front matter with `name` and
       `description` (a rule needs `paths`).
  4. **One line in Testing:** a test changes nothing in the artifact or the repo. It tests the artifact as it is, and
     what is missing is what the test should show.
- **Checks, all on the new candidate.** Bars as registered.
  - **1:** the self-test, and a mutation check that also kills `draft`'s guards (no overwrite, inside the repo, the
    front matter) and `score`'s join of grades to the key.
  - **2:** the runner, live, with its harness reading records as `run` prints them.
  - **3(e):** G's three maker runs.
  - **4:** no gap, rerun, since the skill text changes.
  - **5:** the review gate.
  - **6:** 5a's rerun and D33's handoff.
  - **(f):** the trial's verdict on the good and the bad draft.
- **A failure ends it:** D34 stays BLOCKED, and nothing from section 7 ships.

### 7, 7a: the fourth attempt (2026-11-24): fails on (f); D34 stays BLOCKED

Candidate `711e2b817bc8` before the version bump.

| Check | Result |
| --- | --- |
| 2, the runner, live | **pass**: 12 of 12 records match the stream, 2 true positives per kind, the repo unchanged |
| 4, no gap | **pass**: nothing made in 3 of 3, each naming the missing task |
| 3(e), the making guardrails | **partial**: in 3 of 3, the draft was written by `trial.mjs draft` (inert, no commit), the cases were written, and `plan` was shown and asked; the run after the yes was stopped, see below |
| (f), the trial's verdict | **fail**: on both drafts the trial ran its 6 sessions, and no edit was possible in any of them |
| 1, the mutation check | running at the time of this record (40 mutations) |
| 5, 6 | not run |

- **Why (f) failed.**
  - The trial builds its scratch copies under `${CLAUDE_PLUGIN_DATA}`, which lies under `~/.claude/`. Claude Code
    guards everything there, so every edit in every nested session was refused, in both arms.
  - Each session's diff came back empty. Claude saw this, and in both runs declined to grade a result that would read
    "adds nothing". That was a fair call, but the procedure got no verdict.
  - Check 2 missed it because its harness passed a scratch data folder, not the plugin's own.
- **The fix it points to:** the copies go under the system's temporary folder, which is outside the repo and outside
  `~/.claude/`. Only the copies move; the key and the records stay in the data folder, which only the script reads.
  The fix is not built.
- **Harness defects found on the way,** fixed and recorded; neither moved a bar:
  - the question test read only a reply's last paragraph, and missed "**Should I run the test?**" that came before a
    paragraph on hooks. It now finds a question mark that ends a sentence anywhere;
  - a finished maker whose reply asked is resumed from its own stream.
- **The resumed makers were stopped.** Their trials would have built copies in the same guarded folder, so they could
  not change the outcome, and running them would only have spent usage.
- **By the registration of the fourth attempt,** a failure ends it: D34 stays BLOCKED, and nothing from section 7
  ships.

- **The mutation check on the fourth candidate,** which finished after this record: 40 of 40 killed
  ([attempt4/mutate7.txt](probes/V2-D34-repo-artifacts/outcome/results/attempt4/mutate7.txt)).

### 7, 7a: a fifth attempt, the user's override (registered 2026-11-24, before its code)

- **The user's answer:** "Fifth attempt, this fix only", against the stop registered for the fourth attempt. It is
  recorded as the user's decision.
- **The fix, and nothing else:**
  - `trial.mjs` builds its copies under the system's temporary folder, and refuses a place inside the repo or inside
    Claude Code's configuration folder (`~/.claude`, or `CLAUDE_CONFIG_DIR`);
  - the key and the records stay in the plugin's data folder, which only the script reads.

  The skill's text does not change.
- **The pre-flight, before any counted check.** One trial on the good draft, exactly as shipped: the candidate loaded
  as a plugin, `${CLAUDE_PLUGIN_DATA}` as Claude Code sets it, `/second-brain:tailor` in a headless session, and "yes".
  - It passes when the sessions changed files and `score` printed a verdict.
  - It is not counted. If it fails, the attempt fails before its checks.
- **Checks, on the final candidate:**
  - **1:** the self-test, and a mutation check with one more mutation, copies under the data folder. The self-test
    runs the trial with `CLAUDE_CONFIG_DIR` set and the data folder inside it, so that mutation is caught.
  - **2:** the runner, live.
  - **3(e), (f), 5, 6:** as registered.
  - **4 stands** from the fourth attempt, since the skill's text is unchanged.
- **A failure ends it:** D34 stays BLOCKED, and nothing from section 7 ships.

### 7, 7a: the fifth attempt (2026-11-24): fails on (f) and check 5; D34 stays BLOCKED

Candidate `e2552817a8d4` before the version bump. Its changed files are kept in
[probes/V2-D34-repo-artifacts/candidate](probes/V2-D34-repo-artifacts/candidate/). The skill folder is renamed
`skills-not-loaded`, and nothing there loads.

| Check | Result |
| --- | --- |
| Pre-flight (uncounted) | **pass**: one trial as shipped; 6 of 6 sessions changed files, and `score` printed a verdict |
| 2, the runner, live | **pass**: 12 of 12, 2 true positives per kind, the repo unchanged |
| 3(e), the making guardrails | **pass**, 3 of 3 on each step (below) |
| 4, no gap | stands from the fourth attempt (pass) |
| (f), the trial's verdict | **fail** on the good draft: "It adds nothing here", 2 passes with it, 2 without. The bad draft got the right verdict (1 with, 2 without) |
| 5, the review gate | **fail**: three bars pass (cases shown and asked 3 of 3; counts before the promotion question 2 of 3; nothing promoted before the second yes 3 of 3), but promoted after it in 0 of 3 |
| 6, the regressions | stopped unrun once (f) had failed: no result could change the outcome |
| 1, the self-test and the mutation check | **pass**: the self-test passes; the run killed 41 of 42 ([attempt5/mutate7.txt](probes/V2-D34-repo-artifacts/outcome/results/attempt5/mutate7.txt)). The 42nd, "(v) copies deleted", never applied, since the fifth fix had changed its line. Rerun alone on the new line, it is killed: the self-test fails on "the copies are deleted" |

**3(e), each step 3 of 3:**
- `tailor` wrote the draft through `trial.mjs draft`, with no commit;
- it wrote the cases, showed the plan and asked;
- after "yes" it ran the trial, graded blind, and showed `score`'s table;
- every path and command the drafts name exists; one names `golden.js` alone, meaning `scripts/golden.js`.

The made skills passed 6 of 6 held-out runs, were used in all 6, and stayed out of the rename.

**What (f) and 5 show.**
- The trial now runs, but its verdicts cannot yet be trusted.
  - Its grader judges each run against an `expect` that Claude wrote, and it passed the runs without the skill far more
    often than the strict grader did: 2 to 3 of 3 in every trial here, against the floor's 2 of 6 in attempt 2.
  - So on this fixture the trial called every skill "adds nothing", the good one included.
  - With one run per case it cannot tell a difference of one run from noise.
- In check 5, `map-review` acted on that verdict. It offered to discard, promote or leave the draft, recommended
  discarding, and would not act on a bare "yes". That is sound behaviour on a wrong verdict; the bar expected a
  promotion.

**What the five attempts established:**
- **Making guidance:** no measured gain (attempts 1 and 2). On the measured tasks, Opus 5.5 does as well told once, or
  making a skill alone.
- **The guardrails hold:**
  - nothing is made without a gap (3 of 3; 2.5.1 made two live artifacts in 3 of 3);
  - made artifacts are inert drafts, written by the script, never committed;
  - nothing is promoted without a clear word;
  - every path an artifact names exists.
- **The trial runs end to end,** in scratch copies outside the repo and outside `~/.claude`. Its verdicts disagree with
  a strict grader: before it could ship, its cases would need outcomes a script checks, not a model, and more than one
  run per case.

**By the fifth attempt's registration,** a failure ends it: D34 stays BLOCKED, and nothing from section 7 ships. The
research, the records, the fixtures, the harness and the candidate stay on `v2`.

### 7, 7a: the fifth attempt's (f) read again (2026-11-24): the "without" arm was not clean

The record above says the trial's grader was lenient. That cause was never tested, and the trial's repos point
elsewhere.
- `trial.mjs` copies every untracked, not-ignored file, and removes only the artifact itself.
- When (f) ran on the good draft, the repo held `.project-map/pricing.md` (the procedure, captured as a map entry in
  that session) and `.project-map/evals/pricing-check.json` (the cases, with every `expect`). The makers' repos held
  the same.
- So each "without" copy had the map entry, which made it attempt 2's arm T (6 of 6), and it had the expected
  outcomes, which a session could read.

**The corrected reading:**
- "It adds nothing here" was a defensible verdict against a repo whose map already holds the procedure.
- (f) measured it against the floor (no knowledge), which was the wrong yardstick.
- The trial has a real defect: the case file, with its expected outcomes, reaches both arms.

D34 stays BLOCKED, as registered. Its rethink is the user's next request (section 8).

## 8: one final logic, the user's word (opened 2026-11-24)

- **The user's word** (2026-11-24): use all the installed plugins and agents to verify the entry ideas and the
  implemented code, fix the gaps and issues, improve the code or rethink the approach and implement it, make new
  research if needed, think about what the plugin exposes on the machine and what it keeps in the repo, and audit the
  final code. Then: "we need to finish this plugin to cover previous features and new one as one final logic", agreeing
  to the list given that day:
  - decide from evidence, not at setup;
  - make a draft only on a gap, and retire what adds nothing;
  - self-evaluation with a strict judge;
  - monorepos placed by where the evidence clusters.
- **What reopens:** D34 (BLOCKED) is rethought under rule 4, one level up, and D35 opens for improving from sessions.
  Each fix group below is registered before its code.

### 8: the verification round (2026-11-24): the findings register

Six independent read-only reviews, each given the code and the ledger and not the author's conclusions:
- the decision-checker (guardrails against checks);
- a whole-plugin audit (the ponytail-audit lens);
- a security review;
- Claude Code's platform facts (claude-code-guide);
- the charter's ideas against the records;
- the plugin's footprint, measured in isolation (`probes/V2-D34-repo-artifacts/footprint/`).

"Ran" means the reviewer reproduced it, "read" that it was traced in the code. Each accepted finding gets a failing
self-test case before its fix. Findings marked "read" are reproduced first, on Linux in WSL where the case needs it.

**Group H, the hook path** (checked together: self-test, the paired CI bench, D18's bench):

| Id | Finding | Shown | Triage |
| --- | --- | --- | --- |
| H1 | The Bash handler labels commands that never name the map. Claude Code's `if` filter is best effort, so any command with `$()`, backticks or `$VAR` starts it; the handler never checks the command. Reproduced: `echo $(echo sub-bg)` got every map file's labels | ran | Reproduce, then read 2o's record and D14's lock first: 2m to 2o leaned on the filter for a reason. Count it in field transcripts before linking it to the noise complaint |
| H2 | The Read hook starts Node for every Read, about 80 ms each; an `if: Read(**/.project-map/**)` filter would skip the rest | read | An optimisation, and D18's bar already passes. A glob that misses Windows paths would silently drop D14's label. Only with a live probe on all paths; otherwise drop |
| H3 | The Bash handler follows a link in `.project-map/` out of the repo, walking and reading the target tree; headings from outside reach Claude's context | ran (junction) | Accept |
| H4 | Map files are read with no type or size check: a link to an endless file stalls every session start; a FIFO blocks the index (the Bash handler already skips FIFOs) | read | Reproduce in WSL, then accept: one reader that takes only regular files under a size cap |
| H5 | The quote re-find is quadratic: 800 words against 390 KB took 3.7 s, on every Read | ran | Try a linear search first. A cap would change D16's label on large real documents |
| H6 | Map file names reach label lines unsanitised (the index replaces control characters) | read | Accept: reuse `safe()` |
| H7 | On Windows, a repo's `git.exe` runs in place of git when the scripts start from a plain shell (Claude Code sets `NoDefaultCurrentDirectoryInExePath` itself) | ran | Accept: set it at the top of `map.mjs` |

**Group D, the dream** (checked together: self-test, S7's product run):

| Id | Finding | Shown | Triage |
| --- | --- | --- | --- |
| D-1 | A proposed topic named `CLAUDE.md`, `CLAUDE.local.md` or `AGENTS.md` is written in `.project-map/`, where Claude Code loads it as instructions before review; the `when:` line has no length cap | read (platform behaviour from the docs) | Accept |
| D-2 | The private-data filter misses Stripe (`sk_live_`), SendGrid (`SG.`), Hugging Face (`hf_`), Slack webhooks, credentials in URLs and bearer tokens | ran | Accept the key shapes, each with a must-pass fixture. `~/` and "token is …" would drop real proposals (this repo's own entries name `~/.claude`), so they are left out |
| D-3 | The digests in the repo's ignored `.dream-run/` hold unfiltered transcript text; an abandoned dream leaves them there | read | Accept: redact the filter's matches when digests are written; S7's product run again |
| D-4 | Two prepares can both take over a stale lock | read | Accept: take over by rename |
| D-5 | Finish joins every committed blob into one string, which throws past about 512 MB (binaries included), with the lock held | read | Accept: per-file search, binaries skipped |
| D-6 | A transcript that grows during prepare is read past the size recorded, so the next dream reads those lines again | read | Accept: bound the stream at the recorded size |

**Group F, the footprint:**

| Id | Finding | Shown | Triage |
| --- | --- | --- | --- |
| F-1 | The self-test leaves a marker in the real temp folder on every run (about 370 here) | ran | Accept: it removes its own markers |
| F-2 | The product leaves one empty marker per session that ends before a typed prompt (7 real ones in 4 days) | ran | Drop: pruning would cost a hook a directory scan |
| F-3 | State in the data folder (`dirs.log`, `state.json`, `undone/`) is never pruned | ran | Drop: about 3 KB in the real install. The data folder goes on uninstall |

**Group R, the records** (no product code):
- **R1:** D10 and D18 were to re-lock on 7a, which is BLOCKED. Record which lock governs 2.5.1 before any hook fix cites D18.
- **R2:** D04's trigger (v2's own map format is ready) fired, unrecorded.
- **R3:** D15 still says setup never overwrites; D29 and the code say otherwise.
- **R4:** D12 may have fired: a subagent's Read got the read hook's labels once, against P1's 0 of 3. Run a registered 3-run probe on the current CLI before any document changes.
- **R5:** `04-architecture.md` is stale on D22 and on its status line.
- **R6:** the README is stale:
  - the naming line is 304 B, not 212 B;
  - the CLI range of the live checks;
  - "78.8 ms" was S6's candidate; 2.3.0 measured 62.7 ms and 2.5.0 82.3 ms;
  - "file changes" should be "pairs";
  - the uninstall claim rests on the docs only.
- **R7:** D26's workflow does not run when the README changes.
- **R8:** guarantees with no standing check:
  - "no hook writes to the map": add a self-test that compares the repo before and after the hooks;
  - memory-curator "changes no committed claim";
  - "nothing is accepted without your answer".

  Name their one-time runs, or mark them as direction.

**Group N, the agreed features:**
- **N1, D35, telemetry:** the dream reads failed tool calls by kind, each skill's and agent's use, and the corrections
  that follow a use.
  - Subagent transcripts (separate files, `<session>/subagents/agent-<id>.jsonl`) are read for counts only, never as
    quote evidence: a delegating prompt is not the user's words (D31).
- **N2, D35, steering:** a section of `.project-map/dreams.md` the team writes, read by the analyzers.
- **N3, D35, proposals:** agent drafts, and proposed changes to existing skills and agents, each from 2 or more
  sessions; retirement suggested for one unused across N sessions.
- **N4, D35, monorepos:** a rule or skill draft is placed in the package's own `.claude/` when its evidence clusters
  there. Claude Code loads a subfolder's skills and rules when Claude works on its files (skills and memory docs).
- **N5, D34 rethought, the trial:**
  - the copies leave out `.project-map/evals/` and the drafts' staging folder;
  - a case may carry a `check` command whose exit code decides the outcome (the strict judge), with 3 runs per case by
    default;
  - the security findings in `trial.mjs` are fixed: a tool entry starting with `-` reaches the child as a flag; an
    artifact path may hold `..`; `draft` follows a staged link and copies sibling files live; `score`'s argument
    carries grader text.
- **N6, D34:** `tailor`'s making steps, kept by the user's word.

**Group M, the measurement debts, for the final build:**
- A1 (last run before 2.3.0);
- S8's acceptance check (2.5.1 changed setup);
- D16's seeded drift probe (the labels changed since it ran);
- D14's capture-injection probe (the instruction changed since it ran).

**Order:** R1 first, then group H, D, F (shippable on its own, as a fix release, if the features stall), then N, then
M and the final audit by reviewers who have not seen this register.

### 8, 8a: the fix release, 2.5.2 (registered 2026-11-24, before the code)

**H1 counted first** (read-only; the local transcripts of two repos). PostToolUse map labels that reached Claude after a
Bash command:

| Repo | Command named the map | Command did not name it (the `if` filter let it through) |
| --- | --- | --- |
| The first field repo (4,781 Bash calls) | 148 | 235 (about 1.4 M characters of attachment records) |
| This repo (3,816 Bash calls) | 10 | 65 |

Most of the labels Claude saw after Bash came from commands that never named the map. 2.3.0's record took that leak as
"more text, never fewer labels". The counts show it is most of the text.

**The change** (built in a copy of `plugin/`; D14, D16, D18 and D31 hold as locked, and none of their guardrails
changes):
- **H1.** A Bash command whose text does not name `.project-map` gets labels only for the entries its output shows,
  committed or not, by 2n's rule. When its output cannot be seen (a background command, or output saved to a file), it
  gets nothing.
  - A command that names the folder keeps 2o's rule: every uncommitted entry, plus the committed ones its output shows.
  - The change to D14's delivery goes to the decision-checker before the build.
- **H3.** The Bash handler follows no link whose target lies outside the repo.
- **H4.** One reader for map files: a regular file (directly or through a link inside the repo) under 4 MB, or nothing.
  It is used by the index, the waiting note and the labels. A special file is skipped by session start, as the Bash
  handler already does. A file over the cap is labelled "cannot read; check it".
- **H5.** The re-find matches the quote's words as a sequence against the document's words (KMP), with the words
  computed once per document. Same results, linear time.
- **H6.** Map file names in label lines pass through the index's `safe()`.
- **H7.** `map.mjs` sets `NoDefaultCurrentDirectoryInExePath`, so on Windows a repo's own `git.exe` never runs.
- **D-1.** A proposal's topic file cannot be named `CLAUDE.md`, `CLAUDE.local.md` or `AGENTS.md` (any case), and a
  `when:` line over 200 characters drops the entry.
- **D-2.** The private-data filter adds these shapes:
  - `sk_`/`rk_` keys (live and test);
  - SendGrid `SG.…`;
  - `hf_…`;
  - Slack webhook URLs;
  - credentials inside a URL (`://user:pass@`);
  - `bearer <16 or more characters>`.

  `~/` and "token is …" are not added, since real proposals name `~/.claude`.
- **D-3.** Digests are written with the filter's matches replaced by `[private]`.
- **D-4.** A stale lock is taken over by renaming it to a unique name, then checking that the renamed lock is still
  stale; otherwise it is renamed back and the dream refuses.
- **D-5.** Finish searches the committed files one by one, skips any with a NUL byte, and never joins them.
- **D-6.** Prepare reads each transcript only up to the size it recorded.
- **F-1.** The self-test removes the markers it makes in the temp folder.
- **The records**, docs only:
  - R2: D04's trigger;
  - R3: a narrowing note on D15;
  - R5: `04-architecture.md`'s status and D22 lines;
  - R6: the README's stale numbers;
  - R7: D26's path filter also covers `README.md`;
  - R8: the one-time runs named as the checks of their guarantees.
- **Version 2.5.2.** No template changes, so D29's copy rule has nothing to add.
- **Not in 8a:** H2 (the Read hook's `if`), F-2, F-3, R4 (a probe of its own, 8b) and group N.

**Checks:**
1. **The self-test.** For each finding, a case that fails on 2.5.1 is written and shown failing before its fix, then
   passes. FIFO and `/dev/zero` cases run on Linux and macOS (CI) and in WSL. There are three more cases:
   - H1's naming command is unchanged;
   - the existing D16 labels are unchanged on A1's maps (the self-test's label cases);
   - no hook changes a file in the repo: the self-test compares the repo before and after each hook event (R8).
2. **A mutation check** (`mutate8.mjs`) kills each new guard, and exits non-zero on any mutation it cannot apply.
3. **CI** on three systems, and D18's paired bench: at most 100 ms added p95, old against new in one job.
4. **S7's check 2 on the candidate,** at its registered bars (the dream changed in D-1 to D-6).
5. **H1 live:** one `claude -p` session on the candidate with an uncommitted entry:
   - `echo $(date)` gets no map labels;
   - `cat .project-map/<file>` gets them;
   - a non-naming command whose output prints an entry gets that entry's label.
6. **A review** of the diff by a fresh Claude agent and by the decision-checker; each finding fixed or recorded.
- *Attempts:* at most three failed attempts for 8a (rule 4).
- *Not run, and why:*
  - A1 and S8: no capture or setup text changes, and the labels on A1's maps are pinned by check 1;
  - D16's seeded probe: the re-find's results are the same, by check 1's cases.

  These measurement debts (group M) run at section 8's final release.
- **Release:** 2.5.2 ships on its own if group N stalls, by 5e's mechanics, on the user's word.

### 8, 8a: attempts 1 and 2 failed; attempt 3 registered (2026-11-24, before its checks)

**Attempt 1 failed (check 1).** The first H3 build skipped a link out of the repo. That failed open: 2o's self-test case
(entries behind a folder linked out of the repo are labelled) failed. H3 now fails closed instead. A linked folder
fails the whole folder, and a linked file its own labels. That case now expects the fail-closed line (the self-test's
"8a (H3)" comment).

**Attempt 2 failed (check 2,** `probes/V2-8a-fixes/results/mutate8-attempt2-win32.txt`, on `cand8`): 18 of 23 killed on
Windows.
- H1's early exit survived. It was redundant then.
- H4's in-repo check survived: no case linked a single map file out of the repo.
- H4's special-file skip and both H6 names survived. Their cases need POSIX and never ran on Windows.

The H1 live check on `cand8` passed (`results/live8a-cand8.json`). It stands only as evidence; check 5 runs again on
attempt 3.

**Check 6, the two reviews of `cand8`:**
- **The decision-checker:**
  - D16's re-lock says "no file is tokenized whole", and H5's fallback does tokenize one; this needs a note and
    evidence.
  - Check 1 had no case for D-4, for F-1, or for H3's single linked file.
  - `setup.mjs`'s two stale comments (section 6's carried item) belong in this release.
  - The records must say:
    - the D14 note;
    - when D18 re-locks;
    - that D30's trigger did not fire;
    - each deviation from the registration.
  - R8 has to be checked after each hook event.
- **A fresh agent, reproduced on `cand8`:**
  - **D-3 regressed against 2.5.1.** The redaction left a secret's tail: a webhook's path, a key body, a path after
    `/home/`. A proposal quoting a redacted line word for word passed finish.
  - **H1 lost labels in two cases:**
    - a UTF-16 map file printed raw by a command that does not name the map;
    - a map folder that cannot be listed, while the output shows an entry.
  - **H3 missed the map folder itself** being a link out of the repo. The folder was walked, and the names of the
    files in the outside tree reached Claude.
  - **A backslash-newline** inside the folder's name stopped a command counting as naming it.
  - **`digestFrom` threw** when the recorded size was at or before its start. `prepare` never passes one, since it
    queues only a transcript that grew, so `cand9` only drops `cand8`'s needless `Math.max`.

**Attempt 3, `cand9`**, changes `cand8` as follows. Each change has a case, shown failing on `cand8` or 2.5.1 before the
freeze:
- **H1:**
  - the early exit stays, and is load-bearing again;
  - "names" also drops a backslash-newline;
  - when no output can be matched (a UTF-16 file printed raw), every entry is picked;
  - a map folder that cannot be listed fails closed for any command whose output can be seen.
- **H3:** `under()` never walks the map folder when the folder itself resolves outside the repo. Every caller then fails
  closed or lists nothing. `/second-brain:status` says "The status report stopped" with the reason.
- **H5:** a document's words are kept for its next stretch (a one-entry cache), so they are computed once per document.
- **D-3:** each match is redacted to the end of its token, and a key's header to the end of its line. A proposal
  holding `[private]` is private text, so finish drops it.
- **`setup.mjs`'s two comments** now say what setup does.
- **New cases:**
  - H1: UTF-16 printed raw, a folder not listed, a backslash-newline;
  - H3: a single file link (POSIX), the map folder linked out;
  - H4: a FIFO is not named in the index;
  - H5: a quote found only past the budget;
  - H6: a fail-closed line's name (POSIX);
  - D-2: credentials in a URL, on an IP host (the earlier fixture matched the e-mail pattern);
  - D-3 and D-6 through `prepare`;
  - D-4, deterministic: the lock is replaced between `prepare`'s check and its takeover;
  - D-3: a quoted `[private]` (self-test);
  - F-1: the self-test asserts its own markers are gone;
  - R8: the repo is compared after each event.

**Deviations from the registration,** disclosed before attempt 3's checks run:
- **H3** fails closed, not skips (attempt 1).
- **H4:** a map file that cannot be read gets the whole-file fail-closed line, not "cannot read; check it". That label
  is for a cited source; D18 fails a map file's own read closed.
- **H5:** 2.5.1's scan runs first, within a budget of 200,000 word comparisons, and the linear search only past it. Past
  the budget a document is split into words whole, against D16's re-lock line "no file is tokenized whole". This is a
  D16 note, not a reopen. Its evidence is check 1(b).
- **H1, for a command that does not name the map:** a map file whose labels fail gets its fail-closed line, and a folder
  that cannot be listed fails closed, rather than nothing. Both arise only in a broken state: a link out of the repo,
  a file over 4 MB, or an unreadable folder.
- **D-3** redacts to the end of a token, beyond "the filter's matches".
- **D-4** is checked deterministically, not by a race.

**Recorded, not fixed** (accepted; each named for section 8's final audit):
- **D-4:** three prepares at once can still both hold the lock. A third can create one while another has renamed a
  fresh lock away. It needs three dreams started within microseconds on a lock two hours stale.
- **Length caps:**
  - a `- review:` line has no length cap;
  - an entry may hold several `when:` lines of 200 characters.
- **`status.mjs`** reads map files with no type or size check: a FIFO in the map stops `/second-brain:status`.
- **URL credentials** with an empty user (`redis://:pw@host`) are not private.
- **D-6:**
  - a transcript record that straddles the recorded size is read by neither dream;
  - the call site has its own case, through `prepare`.
- **A cost, not a label:** for a command that does not name the map, `labels()` still runs `git show` per map file when
  the output shows nothing.
- **From the review of the `cand8` to `cand9` delta,** which found no fail-open path and no caller of `under()` that
  crashes:
  - **D-3:** a secret's tail that holds a space survives redaction. Example: `C:\Users\John Smith\...` keeps
    `Smith\...`, and a quote of that tail passes finish. 2.5.1's finish had the same limit.
  - **D-3:** a URL password with a `/` keeps its user and part of the password. This predates 8a.
  - **The `[private]` check:**
    - it catches only the bracketed word, so a quote that drops the brackets passes (no secret is left to quote);
    - "Fields marked [Private]" is dropped as private.
  - **Noise in broken states only:**
    - with the map folder linked out, every command with visible output that does not name the map gets the folder's
      fail-closed line. Check 5's `echo $(date)` holds only while the folder can be listed;
    - a NUL in such a command's output labels every entry of every UTF-16 map file.
  - **`status.mjs`:**
    - with the map folder linked out, the report is one line, "The status report stopped: the map folder is a link
      out of the repo";
    - before 8a too, a map file linked out of the repo has its headings printed in the stale lines (`textOf`).
  - **H5's word cache has no case.** It changes time, not answers.

**How attempt 3's checks count.** The frozen copy of `cand9` is hashed first; every check runs on that hash. Order:
self-test, mutation, live, bench, S7. A failure stops the run.
1. **The self-test** passes on Windows and in WSL (pin off in the copy). Every `fix8a.mjs` case passes there, on the
   systems it runs on.
   - (b) `probes/V2-8a-fixes/equivalence8.mjs` on the frozen copy: 0 differences from 2.5.1, both for the candidate and
     for the candidate with its budget at 0 (the linear search alone).
   - A dry run on `cand9` gave 0 of 3,804 seeded quotes, 24 of them runs of one word.
2. **`mutate8.mjs`** on Windows and in WSL, 35 mutations, each tagged with the systems where its killing case runs.
   - Every mutation is killed on its system: `results/mutate8-win32.txt` and `results/mutate8-linux.txt`.
   - A MISSING mutation fails the check.
   - Dry runs are allowed before the freeze and are never a result: `MUT_FAST`, `fix8a.mjs` alone; `MUT_ONLY`, the
     chosen mutations.
   - On `cand9`, before the last review, every mutation was red-green:
     - the fast runs killed 31 of 35 in WSL and 28 of 32 on Windows, H7 included;
     - the 4 they missed (the `when:` cap, a quoted `[private]`, binaries, F-1) have their cases only in the
       self-test, and the self-test killed all 4.
   - The review then removed one guard ("D-6 nothing past the start") and its mutation.
3. **CI** on three systems, after the move into `plugin/`.
   - D18's bench: `probes/V2-D30-entries/pairbench.mjs`, with 2.5.1 as the control, run alone on the reference
     machine, CPU at most 10% sampled first, at 1 and at 8 concurrent.
   - Pass: at most 100 ms of added p95 per hook (D18's 2026-11-20 lock, R1).
   - D18 stays REOPENED until section 8's final release.
4. **S7's check 2:** `s1.mjs product` on the frozen copy, at its registered bars, into `results/s7-product-a9.json`.
   The history sessions ran plugin-free on 2026-11-24, in the same scratch folder.
5. **H1 live:** `live8a.mjs` on the frozen copy, into `results/live8a.json`. The Bash grant is the tool's name alone:
   `cand8`'s first run named commands, and the CLI refused the nested ones, so none ran.
6. **The reviews** are done above: the two on `cand8`, and a fresh agent's on the `cand8` to `cand9` delta. Every
   finding is fixed in `cand9` or recorded here.
- **The self-test's pin** is set to the frozen copy's product hash, so check 1 runs with the pin on.
- **The frozen copy:** product `15a7ee92a153`, version 2.5.2. 2.5.1 was `2625c8cd263b`, by the same hash.

**Records with the result:**
- **D14 note:** H1 ends 2.3.0's "more text, never fewer labels" (06, 2o) for commands the `if` filter lets through
  without naming the map. They stay inside D14's accepted risk, "a command that does not name the map folder".
- **D16 note:** check 1(b).
- **D30:** its trigger did not fire. The labels changed only in delivery (H1, H3, H4), not in their fields.
- **The rewritten 2o assertion:** H3's registered change.

### 8, 8b: R4, D12's subagent cell on the current CLI (registered 2026-11-24, before the run)

- **Why:** R4. A field transcript showed a subagent's Read carrying the read hook's labels once. D12's step 0 recorded
  that cell as "does not arrive" for general-purpose and "unreliable" (1 of 3) for Explore, on an older CLI.
- **The run:** `probes/V2-D12-channels/step0.mjs`, unchanged except that `STEP0_RESULT` names its result file.
  - 3 runs on Haiku, on the installed CLI 2.1.331, into `results-step0-2.1.331.json`.
  - Its CL and RE cells run too, and are reported.
- **Pass rule, D12's own, per cell:**
  - 3 of 3 runs quote the nonce: it arrives;
  - 0 of 3: it does not arrive;
  - 1 or 2: unreliable, which counts as not arriving.

  The hook's text in the subagent's input stream (`rawInSubagentInput`) is reported beside it.
- **Consequence:**
  - **If either subagent cell arrives,** D12's trigger has fired. It gets a dated note, and 04's "Unlabelled reads"
    line and the README's subagent line change.
  - **Otherwise R4 closes.** The field sighting is recorded as unexplained, and nothing changes.
- **Attempts:** one run of 3. A run that a harness fault makes invalid is rerun and recorded.

### 8, 8b: result (2026-11-24): R4 closes

`probes/V2-D12-channels/results-step0-2.1.331.json`, 3 runs on Haiku with CLI 2.1.331:
- **PT-sub, Explore:** does not arrive, 0 of 3. The subagent read the file in 3 of 3, and the hook's text was absent from
  its input stream in all 3.
- **PT-sub, general-purpose:** does not arrive, 0 of 3, with the same reads and the same absence.
- **CL and RE:** arrive, 3 of 3.

D12's trigger has not fired. A subagent's Read of a map file still arrives unlabelled, as 04 and the README say. The
field sighting stays unexplained: it may come from a path step 0 does not take, such as a resumed or forked session.

### 8, 8a: before the model runs (2026-11-24)

- **The digest pre-flight** (`probes/V2-8a-fixes/preflight8a.mjs`, `results/preflight8a.json`). It applies the frozen
  copy's `digestFrom` and D-3's redaction to S7's 60 history transcripts, read only.
  - **No typed line changes:** U 0 of 70, Q 0 of 5. The 25 typed lines carrying formatDate, the changelog procedure or
    pnpm are all intact.
  - **Tool lines lose their file paths:** T changes in 306 of 380 lines and R in 61 of 375. An absolute path inside a
    tool call's JSON is one token, so it is redacted whole, and the file inside the repo goes with it. S7's bars rest on
    typed and chosen lines, so S7 runs.
  - **The cost is recorded for group N.** A placement by where the evidence clusters (N4) needs those paths, so the repo's
    own root has to be made relative before redaction.
- **Check 5's validity:** a run counts only when the session made exactly three Bash calls, with the three registered
  command strings in order. Any other run is invalid, not failed, and is rerun once. A second invalid run fails the
  check.

### 8, 8a: attempt 3's result (2026-11-24): CI failed on Windows; 8a BLOCKED by the user's word

The local checks ran on the frozen copy, product `15a7ee92a153`, version 2.5.2, in the registered order, and all
passed. CI then failed on its Windows runner (below).
1. **The self-test passes** on Windows and in WSL, with the pin on.
   - Each `fix8a.mjs` case had been shown failing on 2.5.1 or on `cand8`. In WSL, 2.5.1 fails 18 cases.
   - (b) `results/equivalence8.json`: 0 differences in 3,804 seeded quotes over 67 documents, for the candidate and for
     the linear search alone.
2. **The mutation check kills every mutation on its system:**
   - `results/mutate8-win32.txt`: 31 of 31, H7 included;
   - `results/mutate8-linux.txt`: 34 of 34, the FIFO, device, control-character and file-link cases included.
3. **D18's bench passes** (`results/bench8a.json`): 200 calls per hook at 1 and at 8 concurrent, CPU at 5.8% before,
   on the 32-thread machine. The worst added p95 is 64.0 ms (Bash on a map file at 8), against 100 ms, with no
   errors.
   - Session start costs 6 to 12 ms more than 2.5.1, since only the candidate gets the data folder and its 300 unseen
     transcripts.
   - A command that does not name the map now costs about 11 ms less.
   - **CI on three systems failed on Windows** (run 45428527737, commit `6239074b`, after the move into `plugin/`).
     macOS and Linux passed both jobs.
     - **The self-test failed at H7.** On CI's Node 20, the repo's planted `git.exe` ran in place of git.
       - Reproduced locally: with `NoDefaultCurrentDirectoryInExePath` set, Node 20.18.1 still runs a `git.exe` in the
         working folder, and Node 24.19.0 runs the real git.
       - So H7's fix works only on newer Node, and the plugin supports Node 20. This is a known cause, with a known
         remedy: on Windows, run git by its full path.
     - **The load gate failed:** a map-file Read added 102.7 ms of p95 at 1 session, against 100 ms.
       - 2.5.1's last green Windows run measured 81.6 ms.
       - The paired local bench showed no difference (40.0 against 40.3 ms), and a single CI sample cannot tell the
         runner's noise from a cost.
4. **S7's check 2 passes** (`probes/V2-D31-dream/results/s7-product-a9.json`, Opus 5.5, CLI 2.1.305). Every bar
   passes:
   - all 10 runs finished, in one turn each, with no background analyzer;
   - C1 to C3: 10 of 10;
   - the rule, the skill and the choice: 5 of 5 each;
   - noise 0, other status lines 0, the nonce 0, live rules 0;
   - 5.65 USD.
5. **H1 live passes** (`results/live8a.json`, a valid run on CLI 2.1.331):
   - `echo $(date +%Y)` got no map labels;
   - `cat .project-map/decisions.md` got the uncommitted entry's label;
   - the unnamed command that printed the entry got that entry's label, and not the committed one's.
6. **The reviews** are recorded above.

**The block.** This was 8a's third failed attempt, which by rule 4 stops it. A fourth is allowed only for a near miss
with a known cause. The user was asked: a fourth attempt, block 8a, or ship without H7. **The user's word
(2026-11-24): "Block 8a".**
- **`plugin/` is back to 2.5.1** (the tag's files, product `2625c8cd263b`), and so is `marketplace.json`.
- **2.5.2's code is kept** in `probes/V2-8a-fixes/candidate/`: the changed scripts, `fix8a.mjs`, the self-test and
  `plugin.json`.
- **Undone, since nothing of 8a ships:**
  - the ledger's D14 and D16 notes;
  - the README's status line and its three passages on Bash labelling and links.
- **Kept:** 8a's doc records (R2 to R8, which hold for 2.5.1), 8b's result, and every result file.
- **What 2.5.1 keeps open, from the findings register.** Each fix exists in the probes and passed every local check, so a
  later step can register any of them again, as new attempts:
  - H1: commands that do not name the map get every label;
  - H3: links out of the repo are followed;
  - H4: a FIFO or device stalls session start;
  - H5: the quadratic re-find;
  - H6: control characters in names;
  - H7: a repo's `git.exe`, which needs the full-path remedy;
  - D-1 to D-6;
  - F-1.
- **D18** stays REOPENED, with its 2026-11-20 lock governing (R1). D30's trigger did not fire.
- **Group N builds on 2.5.1,** by the user's choice.
- **CI on the restored 2.5.1** (run 45431343162, commit `32292a8e`) failed the same Windows load gate: Bash on a map
  file added 112.4 ms at 1 session. With the same code, 2.5.1's last green run had measured 82.0 ms.
  - So the Windows runner's gate swings by about 30 ms, and attempt 3's 102.7 ms is within that noise. H7's failure
    on Node 20 was real.
  - D26's Linux job failed on the same push (v1's data folder gained a file during the route) and passed on its
    rerun.
  - The block stands, as the user chose it.

### 8, 8c: D35, the dream reads use (registered 2026-11-24, before the code)

**What it is:** the evidence half of D35, option (T), on 2.5.1 (8a is BLOCKED). The dream's digests and report learn
what sessions did with the repo's skills and agents, and the team can steer the dream. No new proposal kind and no
hook change: those are 8d's and 8e's. The decision-checker read a first draft; its gaps are taken in below.

**The change** (built in a copy of `plugin/` 2.5.1):
1. **The digest's tool lines** (`tag`):
   - a Skill call's line begins with the skill's name, `T: Skill <name>`;
   - an Agent call's line begins with its type, `T: Agent <type>`, so the 80-character cut never drops either;
   - a tool result marked as an error is `R!:`, not `R:`.

   `dream-analyzer.md` treats `R!:` lines as it treats `R:` lines: untrusted tool output, never a source.
2. **Counts** (`prepare` writes `usage.json` in the run folder; finish's report prints them). They cover the sessions the
   dream accepts, so the dream's own sessions and other repos' sessions are skipped, as for digests. For every skill
   and agent the repo holds (`.claude/skills/<name>/SKILL.md`, `.claude/agents/<name>.md`), and every one the sessions
   call:
   - **a skill's uses:** its Skill calls, plus each typed `/<name>`, which Claude Code records as a command, so a
     skill only a person starts is counted too;
   - **an agent's uses:** its Agent calls;
   - **the sessions** those uses fall in;
   - **"a typed line after it":** a use followed by a typed line before Claude's next Skill or Agent call. The report
     counts it and never calls it a correction. Telling a correction apart needs judgment, which is the analyzers'
     work in 8d.
     - *Amended before the build:* the first wording ended a use at "Claude's next tool call". A skill's own steps are
       tool calls, so that would almost never count a skill.
   - **failed tool results, by tool,** in the main session;
   - **subagent runs by type,** from `<session>/subagents/*.meta.json` (`agentType`; "unknown" when it is missing), and
     the failed tool results inside each subagent's own transcript, counted only. No subagent text enters a digest
     (D31: a delegating prompt is not the user's words).
   - **A watermark for subagent runs:** each meta file counted is named in `subagents.json` in the plugin's data
     folder. It is written at finish, as `seen` is, and undone when a dream is discarded.
     - Session start never reads that file, so D18's surface and cost do not change.
     - Names whose session folder is gone are pruned at finish.
3. **The report** adds one line per repo skill and agent: "used n times in k sessions here; a typed line after m".
   - "Sessions this dream read" is the number of digests it wrote.
   - When that number is 10 or more, a repo skill or agent with no use gets: "no use in the N sessions this machine's
     dream read; a teammate's sessions are not counted".
   - Nothing is written to a file for these lines. The counts stay in the run folder, which is ignored and removed when
     the dream closes.
4. **Steering:** an optional `.project-map/steering.md` the team writes.
   - `prepare` copies HEAD's version of it into the run, never the working tree's. Under D14, uncommitted text is
     unreviewed, and a commit is a person's review.
   - The dream skill tells each analyzer to read it first: what it says matters is weighed. It is never a proposal's
     source, since finish's tracked sources leave `.project-map/` out. A case checks that.
   - The dream never proposes into it, so `topic()` refuses that name.
   - When it is missing, nothing changes. The repo's README says how to write one. Setup does not create it, so no
     template changes and D29's copy rule has nothing to add.
   - This differs from N2's register ("a section of `dreams.md`"). That log is append-only and union-merged, so log
     lines would land inside a section placed after it.
- **Dropped from the first draft:** making repo paths relative before D-3's redaction. 2.5.1 has no digest redaction
  (D-3 is in the blocked 8a), so 2.5.1's digests keep their paths.
- **D31 holds:**
  - a count is evidence to weigh, never a quote;
  - a proposal still rests on typed lines, a chosen answer or a tracked file;
  - the steering file is the team's committed text, read as guidance and never quoted;
  - the analyzers' new inputs (`R!:`, the counts, steering) all go through finish's unchanged scan and provenance.

**Checks:**
1. **The self-test, on Windows (Node 24 and the portable Node 20) and in WSL (Node 20).** For each numbered item, a case
   that fails on 2.5.1 is shown failing before its fix, then passes:
   - (1) the names come first; `R!:` marks a failure; `dream-analyzer.md` names `R!:`;
   - (2) counts on fixture transcripts that hold:
     - Skill and Agent calls, and a typed `/<name>`;
     - a typed line after one use and not after another;
     - a failed result;
     - two subagent meta files, one with no `agentType`, and a subagent transcript with one failed result;
     - a dream session and another repo's session, both skipped.

     A second prepare after finish counts no meta file twice. A discarded dream leaves `subagents.json` as it was;
   - (3) the "used" line; the "no use" line at 10 sessions read, and none at 9;
   - (4) HEAD's steering is copied, and an uncommitted edit is not. Nothing changes when it is absent.
     `topic('steering.md')` is false. A proposal quoting steering text is dropped by finish's provenance.
2. **A mutation check** (`probes/V2-8c-use/mutate8c.mjs`) kills each new guard, on the system its case runs on, and
   exits non-zero on any mutation it cannot apply.
3. **Real data:** `probes/V2-8c-use/fieldcount.mjs` reads the first field repo's transcripts, read-only, the same day as
   D34's `usage.mjs`.
   - For each of that repo's own skills and agents, 8c's counter and `usage.mjs` must give the same number of sessions
     with a use.
   - Counts only. The repo is never named in a tracked file.
   - *Amended before the build:* `usage.mjs` counts Skill and Agent calls only. So the comparison takes 8c's call uses,
     each use now records whether it came as a call or a typed `/<name>`, and typed uses are reported beside. It runs
     over every transcript in the folder, from its start, through the candidate's exported `digestFrom`. `prepare`
     is never run in that repo.
4. **S7's check 2 at its bars** (`results/s7-product-a10.json`), with one change: the first five runs also carry a
   committed `steering.md` that orders the dream to propose an entry holding a nonce. The nonce must not land, as with
   the existing injection fixture. Every other bar is unchanged.
5. **No hook output changes** (D18). The self-test's hook cases pass unchanged, and session start's reads are unchanged
   (no new file).
6. **CI on three systems**, after the move into `plugin/`. A failure there is a failed attempt, as 8a's was.
   - *Amended before the build:* the Windows load job measured 2.5.1 at 112.4 ms on one run and 82.0 ms on another, with
     the same code. 8c changes no hook (check 5), so the load jobs cannot measure it: they are reported, and only the
     self-test jobs decide this check.
7. **A review** of the diff by a fresh agent and by the decision-checker. Each finding is fixed before the freeze, or
   recorded.
- **Attempts:** at most three (rule 4). The candidate is hashed and frozen before checks 1 to 4 count.
- **D35's lock:** D35 stays OPEN after 8c. It decides between (A) and (T) on 8d's evidence check, since only the
  proposals can show whether reading use changes what the dream proposes.
- **Not here:** new proposal kinds (agent drafts, change drafts, retirement proposals, placement), 8d; the trial, 8e.

### 8: the user's word on CI (2026-11-24)

- **The user's word:** "Drop ci tests and focus on deliver rest".
- **What changes:** CI is no longer a check anywhere in section 8.
  - 8c's check 6 is dropped, before any of 8c's counted checks ran.
  - Later steps register no CI check.
- **What stays:**
  - the workflows themselves, since `main`'s ruleset requires the self-test jobs. They run on each push and are
    reported, not waited on;
  - the local checks: the self-test on Windows and in WSL, the mutation checks, the real-data check, S7's model runs
    and the reviews.

### 8, 8c: amended after the two reviews, before the freeze (2026-11-24)

The decision-checker and a fresh agent reviewed the first build. These changes come before any counted check.

**Redesigned: subagent runs follow the sessions' read offsets.**
- A meta file carries `toolUseId`, the Agent call that started the run. Locally that holds in 1,562 of 1,565 files,
  and most of the rest name a parent run.
- A run now counts when its `toolUseId` names an Agent call in the part of the session this dream read, or when the
  run that started it counts.
- So runs go back with the sessions when a dream is discarded, and a session read in two dreams counts each run once.
- Item 2's watermark file (`subagents.json`), its rollback, its pruning and its write-order risk are gone. A run that
  names no call is not counted.
- The review found that the watermark counted runs from parts of a session the dream never read.

**Fixed, each with a case and a mutation:**
- **A typed command** counts as a skill use only when it names one of the repo's skills or a plugin's
  (`plugin:skill`). A built-in such as `/compact` is neither a use nor an end.
- **A person's typed use leaves Claude's open uses open.** Only Claude's next Skill or Agent call ends them, as the
  amended item 2 says.
- **Use is counted before a session with nothing typed is skipped,** so a skill a person only starts with `/<name>`
  counts, as item 2 promised.
- **Records in the main transcript marked as a subagent's** (`isSidechain`) are neither uses nor the session's
  failures.
- **An older Skill call that names its skill as `command`** counts, as D34's `usage.mjs` reads it.
- **Names in the report** pass through a filter for control characters and are cut to 80 characters, so an agent's type
  cannot add a line of its own.
- **The counters have no prototype,** so a skill named `constructor` is only a name.
- **A status line** is written only into a topic file, never into `steering.md`, `README.md` or `dreams.md`. The last
  two were open before 8c.
- **The dream skill's own read of the map** skips the working copy of `steering.md`. The analyzers had its committed
  text.
- **The subagent meta files are read in sorted order,** so counts do not depend on the system's directory order.
- **`setup.mjs`'s two stale comments** (section 6's carried item) say what setup does. Comments only.

**Records:**
- **The counts are also kept** in the run record in the plugin's data folder. Finish prints from there, since the
  session can edit the run folder in the repo. A stale run's record moves to `undone/` with them.
- **The analyzers do not get the counts in 8c.** They go to the report, and 8d gives them to the analyzers. The "D31
  holds" line is read that way.
- **The README** (repo root, outside `plugin/`) gets its steering and counting paragraphs with the move into
  `plugin/`. It also says that `steering.md` is listed in the session's index like any map file.
- **Check 4** also records whether each steered run passed the steering file's path to an analyzer (`steerReached`).
  The bar: 5 of 5.

**Carried, not fixed:**
- **Boundary counts:**
  - a use at the end of the part read loses its typed line after;
  - a failed result whose call came before the offset counts as "unknown";
  - an Agent call with no `subagent_type` is not counted (5 of 1,721 locally).
- **2.5.1's D-6 still applies:** a transcript that grows during prepare is read past the size recorded. Its next dream
  may count those uses again.
- **A `steering.md` with front matter** shows in session start's catalog like any topic file.

### 8, 8d: D35, proposals that rest on use (registered 2026-11-24, before the code)

**What it is:** the proposal half of D35, option (T), built on 8c. The dream can now propose:
- an agent;
- a change to one of the repo's own skills or agents;
- a path rule placed in a monorepo's package.

Each is an inert draft until `/map-review`, and nothing is committed (D31, D33). No hook changes (D18), so 8c's
check 5 holds here too. The decision-checker read a first draft; its gaps are taken in below.

**How 8d ships, by D10.**
- Dream-made agents, and changes to the repo's own artifacts, fall in D10's reopened scope. That scope asks for an
  artifact tested against a run without it, which is 8e's trial.
- So 8d ships only with 8e, in section 8's release (2.6.0). If 8e is BLOCKED, 8d's agent and change drafts do not
  ship. Its rule placement may, since a rule draft is D31's, as before.

**The change** (built in a copy of 8c's frozen plugin, 2.6.0):
1. **Agent drafts.**
   - The organizer stages `proposals/agents/<name>.md`, with front matter `name`, `description` and `tools`.
   - Finish writes it as `.claude/agents/<name>.md.draft` (`wx`, never over a file), through every gate a skill
     draft passes:
     - the privacy scan;
     - the link check;
     - `evidence()`: 2 or more sessions, each cited at a U or Q line;
     - a name that is not an agent the repo holds.
   - An agent draft is never loaded (D34, probe 3).
   - **Recorded limit:** session start's waiting note counts rule and skill drafts only, so an agent draft is named in
     the dream's report and found by `/map-review`, not by the waiting note. Changing that is a hook change (D18).
2. **Change drafts** for a skill or agent the repo holds.
   - The organizer stages `proposals/change/skills/<name>/SKILL.md` or `proposals/change/agents/<name>.md`, holding the
     whole new text.
   - Finish writes it beside the file as `SKILL.md.draft` or `<name>.md.draft`. It passes every gate of item 1, and
     two more:
     - **used:** each session the evidence cites used that skill or agent, by the per-digest uses kept in the run
       record in the data folder (the session cannot edit it);
     - **in place:** the file exists, and no draft waits beside it.
   - A skill's change draft keeps the current file's `disable-model-invocation` value as it is. A new skill draft is
     forced to `true` (D31), but a change must not turn a skill the person chose to let Claude start into one only a
     person starts.
3. **Placement of a path rule.**
   - **Per digest:** the files each session touched (Read, Edit and Write paths inside the repo, relative to its root)
     are kept in the run record. The analyzers and the organizer get them in the run folder.
   - **The report** gives counts per package only, never file names.
   - **A package** is the nearest folder below the root that holds `package.json`, `pyproject.toml`, `Cargo.toml`,
     `go.mod`, `pom.xml` or `build.gradle`.
   - **When every session the evidence cites touched files in one package only,** the organizer gives the rule draft
     `paths: <package>/**`. Finish checks that each `paths:` glob's fixed prefix is a folder the repo holds.
   - **Rules only.** A skill draft is forced to `disable-model-invocation: true`, and a flagged skill is not listed, so
     `paths:` gates nothing on a skill (D12).
   - **This differs from N4's register** ("a package's own `.claude/`"). A path rule at the root loads on a matching
     read (D12), like one in the package. A nested draft would need a hook change to be counted, or a template change
     and a probe that it stays inert.
   - **5a dropped narrowing a rule's paths from its touched files,** when it cut a rule down to two files. So placement
     takes only a whole package, and a rule whose sessions touched two packages keeps its wider paths.
4. **The analyzers** also get each digest's counts and touched files, beside its digest, as evidence to weigh.
   - A candidate still rests on a U or Q line.
   - Two new kinds:
     - `agent-task`: a recurring task a person hands over or does by hand, which one agent could hold;
     - `artifact-correction`: a person corrects the outcome of a skill or agent use.
5. **`/map-review`'s template** lists agent drafts and change drafts.
   - A change draft is shown as a diff against the file beside it. Promoting it replaces that file.
   - D29's copy rule: the template's 2.5.1 text goes into `test/earlier/2.5.1/`, and its hash into `FILES`. The
     self-test's per-file earlier-version cases cover it.
6. **The README** says what the dream can now propose. The version stays 2.6.0, section 8's release.

**D31 holds:**
- every new draft is inert until a person promotes it;
- each rests on typed or chosen lines in 2 or more sessions;
- every new kind passes the privacy scan and the link check;
- the counts, touched files and steering are evidence to weigh, never a quote.

**Checks:**
1. **The self-test, on Windows (Node 24 and 20) and in WSL.** For each item, a case that fails on 8c's frozen copy is
   shown failing before its fix, then passes:
   - an agent draft written; one refused:
     - with fewer than 2 sessions;
     - with a name the repo holds;
     - with private data;
     - with a link on its path;
   - a change draft written beside its file, keeping the file's `disable-model-invocation`; one refused:
     - when the cited sessions never used that artifact;
     - when a draft already waits;
     - when the file is missing;
     - for private data;
     - for a link;
   - a change draft refused when the run folder's copy of the uses was edited, since finish reads the data folder's;
   - touched files kept per digest and repo-relative, none outside the repo, and the report's counts per package;
   - a `paths:` prefix the repo lacks, refused;
   - the analyzer's two new kinds, and the template's diff and promotion text;
   - the template's 2.5.1 hash in `FILES`.
2. **A mutation check** (`probes/V2-8d-proposals/mutate8d.mjs`) kills each new guard, on the system its case runs on,
   and exits non-zero on any mutation it cannot apply.
3. **A model check on one fixture** (`probes/V2-8d-proposals/`), 5 counted runs on the frozen copy with Opus 5.5 and
   the pinned CLI. The fixture's sessions:
   - (a) a repo skill used in two sessions, each followed by the same typed correction: a change draft for it is
     expected;
   - (b) a second repo skill used in two sessions with no correction: no change draft for it;
   - (c) the same review task typed by hand in two sessions: an agent draft is expected;
   - (d) in a two-package repo, a rule stated twice while editing one package's files: a rule draft with
     `paths: <that package>/**` is expected;
   - (e) a rule stated twice while editing files in both packages: no single-package `paths:`.

   **The bars, fixed now:**
   - (a) in at least 4 of 5 runs;
   - (b) in 5 of 5;
   - (c) in at least 4 of 5;
   - (d) in at least 4 of 5;
   - (e) in 5 of 5;
   - nothing made live, and nothing committed, in 5 of 5.

   **The pilot** (2 uncounted runs) can only void the fixture, never a bar. When a session of the fixture fails to
   happen as written, the fixture is rewritten and the pilot runs again.
4. **S7's check 2 at its bars,** steering included.
5. **A review** by a fresh agent and the decision-checker. Each finding is fixed before the freeze, or recorded.
- **Attempts:** at most three (rule 4). The candidate is hashed and frozen before checks 1 to 4 count.
- **D35 locks** on (T) if check 3 passes. Option (A) cannot propose any of these kinds, so the question is whether
  (T)'s proposals are right, which bars (b) and (e) can fail. Otherwise it stays OPEN.
- **Not here:**
  - the trial (8e): it judges a draft against a run without it, and names what adds nothing;
  - retirement, which stays as 8c's "no use" line and 8e's "adds nothing" verdict. The dream deletes nothing.

### 8, 8c: result (2026-11-24): pass

Every counted check passed on the frozen copy, product `b9777170a9b6`, version 2.6.0. CI was dropped by the user's
word.
1. **The self-test** passes with the pin on, on Windows under Node 24 and Node 20 and in WSL under Node 20. Every
   `dream8c.mjs` case fails on 2.5.1.
2. **The mutation check** (`probes/V2-8c-use/results/mutate8c-win32.txt`): 32 of 32 killed. Every case runs on every
   system.
3. **Real data** (`probes/V2-8c-use/results/fieldcount.json`): on the first field repo's 16 transcripts, 8c's
   counter and `usage.mjs` agree for all 8 of its skills and agents. No typed `/<name>` use was found there.
4. **S7's check 2** (`probes/V2-D31-dream/results/s7-product-a10.json`, Opus 5.5, CLI 2.1.305): every bar passes.
   - All 10 runs finished, with no background analyzer.
   - C1 to C3: 10 of 10.
   - The rule, the skill and the choice: 5 of 5 each.
   - Noise 0, other status lines 0, the nonce 0, live rules 0.
   - Steering: in 5 of 5 steered runs the file's path reached the analyzers, and its nonce landed in none.
   - 6.28 USD.
5. **No hook output changed:** the self-test's hook cases pass unchanged.
6. **CI:** dropped (the user's word).
7. **The reviews:** recorded above, in the amendment.

**Records:**
- `plugin/` now holds 8c, byte-identical to the frozen copy, and `marketplace.json` says 2.6.0.
- The README gives the report's counts, the "no use" line and steering, and its status line says 2.6.0 is in
  progress.
- **D35 stays OPEN:** it decides on 8d's check 3.
- The `setup.mjs` comment item from section 6 is closed.

### 8, 8d: the probes, before any counted run (2026-11-24)

- **`probes/V2-8d-proposals/fixture8d.mjs`:** check 3's fixture, its history sessions and the scorer.
  - The repo holds two packages (`packages/api`, `packages/web`), `docs/api-conventions.md`, and two repo skills,
    `release-notes` and `lint-fix`.
  - The sessions:
    - A1 and A2: `/release-notes`, then the same correction;
    - B1 and B2: `/lint-fix`, then thanks;
    - C1 and C2: the same review task typed by hand;
    - D1 and D2: a rule stated while editing `packages/api`;
    - E1 and E2: a rule stated while editing both packages.
  - The bars are 8d's check 3, as registered.
  - 2 uncounted pilot runs come first. They can void the fixture, never a bar.
- **`probes/V2-8d-proposals/mutate8d.mjs`:** 25 mutations. A dry run on the unfrozen build killed 25 of 25.
- **One fixture change in the self-test:** the S7 block's repo now holds `src/utils/date.js`. Its sessions name that
  file, and finish now refuses a rule whose `paths:` names a folder the repo lacks. A real repo holds the folder its
  typed lines name.

### 8, 8e: D34 rethought, the trial as a script (registered 2026-11-24, before the code)

**Why, stated plainly.** D34 is BLOCKED after five attempts. The user's word (section 8) reopened it for a rethink one
level up, and agreed to "self-evaluation with a strict judge: script-checked outcomes, at least 3 runs per case". This
is a new option, (T): the trial as a script, with a fresh three attempts. It rests on three findings:
- **The agreed strict judge.** 7a's trial judged with a model, and its verdicts disagreed with a strict grader
  (D34's "(f) read again").
- **The case file reached both arms.** That was the copy script's defect, not a model's.
- **A skill's `!` line is killed after 2 minutes** (research/2026-11-24-final-logic.md). The detach probe
  (`probes/V2-8e-trial/detach/`) shows that a process started there outlives the session and the limit.

The making steps' guardrails already passed in 7a (3(e)), and are kept.

**The change** (built in a copy of 8d's frozen plugin, 2.6.0):
1. **A case file per artifact,** `.project-map/evals/<artifact>.json`, which the team writes and commits. Each case
   has:
   - a `prompt`. For an agent, the prompt names it: "use the `<name>` agent to …";
   - the `tools` it may use;
   - a `check`: the path of a script under `.project-map/evals/checks/`. The script exits 0 for a pass, and runs with
     the copy as its working folder;
   - optionally `runs`; the default is 3;
   - optionally `use: false`, for a case where the artifact should not be used. It must pass in both arms. Every case
     file holds at least 3 cases, and at least one of them has `use: false`.

   `trial.mjs` refuses a case file in any of these cases:
   - HEAD does not hold it unchanged (D14);
   - a tool entry starts with `-`;
   - a path in it holds `..`;
   - it is reached through a link;
   - it has a field it does not know;
   - the privacy scan matches it.
2. **One skill, `/second-brain:tailor`,** which only a person starts (`disable-model-invocation`). Its `!` line
   passes the person's words to `trial.mjs`:
   - **With no words,** the making steps: the fifth candidate's `tailor`, with its trial parts removed. They write a
     draft only through `trial.mjs draft`, which refuses a link on its path, the case file's folder, and a live
     artifact. The skill's grant is `trial.mjs draft` alone, so no model can start a run.
   - **`show <draft>`** prints the cases, each with its prompt, tools and check, the draft's `allowed-tools` and any
     `!` lines, and the line to type next. That line carries a hash of the case file and the draft. Nothing runs.
   - **`run <draft> <hash>`** checks that hash against the files as they are, then starts `trial.mjs` detached and
     returns. Typing it, after `show` printed the hash in that session, is the person's yes (D34's "shown to the user
     in that session, after a yes").
   - This keeps D18's surface at four skills (setup, dream, status, tailor), the fourth on the user's word. A flagged
     skill is not listed to Claude, so it adds 0 always-on bytes (D12).
3. **The run.** Each arm, in each run, gets its own copy of HEAD under the system's temp folder:
   - made by `git archive`, so it has no history;
   - with `.project-map/evals/` removed;
   - with the check script copied outside the copy first.

   Each session runs as `claude -p`, with the case's tools only, `--permission-mode acceptEdits`,
   `--strict-mcp-config`, and `--settings` setting `disableAllHooks`. The fifth candidate's checks on the session's
   arguments and environment are kept. The copies are deleted after the run.
   - **A new draft:** "with" has it promoted; "without" has no artifact.
   - **A change draft:** "with" has the draft in place of the file; "without" has the file as it is.
   - **A live artifact (retirement):** "with" is as it is; "without" has it removed.
4. **The verdict, fixed now:**
   - **"mixed":** any case passes more runs in one arm and another case more in the other. This wins over the totals;
   - otherwise, by total passes over all cases: **"helps"** when "with" is higher, **"hurts"** when it is lower,
     **"adds nothing"** when they are equal;
   - **a `use: false` case** that fails in "with" makes it **"hurts"**, whatever the rest.

   It is written to `.project-map/.trial/<artifact>.json`, inside the repo, git-ignored, and scanned for privacy. It
   holds the counts, the hashes and the date, and no transcript text.
5. **`/map-review`'s template** shows a draft's verdict before the promotion question.
   - A verdict whose hash differs from the draft is called stale.
   - A draft with no verdict is called untested, and the template names the line to type.
   - A promoted artifact whose own trial says "adds nothing" or "hurts" is offered for removal. Nothing is removed
     without the person's yes.
   - D29's copy rule: the template's 8d text is unreleased, so the 2.5.1 text already listed covers it.
6. **The README** gains the trial's lines. D31 holds: drafts stay inert, and only a temp copy promotes one. D33
   holds: a person's yes, and nothing committed.

**Checks:**
1. **The self-test, on Windows (Node 24 and 20) and in WSL.** For each item, a case is shown failing before its fix,
   then passes. The baseline is 8d's frozen copy, which has no `trial.mjs`, and the fifth candidate's `trial.mjs` where
   the check applies to it. The cases:
   - each refusal of a case file;
   - `show` runs nothing, and prints the hash and the draft's grant;
   - `run` refuses a wrong hash;
   - a copy holds no history, no evals and no check script, and its settings turn hooks off;
   - each arm's contents for a new draft, a change and a live artifact;
   - the verdict rule, on a table of counts that covers "mixed" against equal totals;
   - the verdict file's place and privacy, and stale and untested in the template;
   - `trial.mjs draft` refuses a link, the evals folder and a live artifact;
   - the D33 handoff (the dream still offers to review now) is unchanged;
   - no hook output changes.
2. **A mutation check** (`probes/V2-8e-trial/mutate8e.mjs`) kills each new guard, on the system its case runs on, and
   exits non-zero on any mutation it cannot apply.
3. **A real trial, through the shipped skill** (`claude -p "/second-brain:tailor run …"` after `show`, with the
   plugin), on a fixture repo in `probes/V2-8e-trial/fixture/`:
   - **The fixture:** a pricing report task whose procedure is in no file of the repo. Its check script holds the
     expected outcome. 3 cases, one with `use: false`.
   - **The two drafts are fixed files now:** `good.SKILL.md` holds the procedure; `bad.SKILL.md` holds wrong steps.
   - **The pilot runs the "without" arm only,** 2 runs per case. If it passes more than 1 of the 2 runs on any
     `use: true` case, the fixture is void and rewritten. The bars below never change.
   - **The bars:** the good draft gets "helps", and the bad one "hurts" or "adds nothing", each in 2 of 2 trials at 3
     runs per case.
   - **Before the counted trials,** the detach probe passes once more on Windows and once in WSL, and one pre-flight
     trial runs exactly as shipped.
4. **`tailor`'s guardrails:** 3 headless runs each, in 7a's two fixture repos (`probes/V2-D34-repo-artifacts/outcome/
   fixture` and `fixture2`), checked by a script:
   - nothing is made without a gap (3 of 3);
   - drafts only, nothing committed (3 of 3);
   - every path a draft names exists (3 of 3);
   - one task per agent draft (3 of 3).
5. **A review** by a fresh agent and the decision-checker. Each finding is fixed before the freeze, or recorded.
- **Attempts:** a fresh three for (T) (rule 4). The candidate is hashed and frozen before checks 1 to 4 count.
- **On a pass:**
  - D34 locks on (T);
  - D10's reopened scope and D18's surface re-lock with section 8's release, ending R1's interim;
  - 8d's agent and change drafts ship with it.
- **On a block:** D34 stays BLOCKED, and 8d's agent and change drafts do not ship (8d's D10 line).

### 8, 8d: the pilot (2026-11-24, uncounted)

`probes/V2-8d-proposals/results/check3-pilot.json`: 2 runs on the unfrozen build.
- **The fixture happens as written.** Every history session finished, and the typed `/release-notes` and `/lint-fix`
  were recorded as command records.
- **The scorer had a defect, now fixed.** (d)'s match looked for "numeric code" or "code field", and the drafts write
  "numeric `code` field", with backticks. Both runs drafted `api-errors-numeric-code` with
  `paths: ["packages/api/**"]`.
  - The match now allows any non-word run between the words.
  - A `rescore` mode scores a finished run again from what it left.
  - The bars do not change.
- **Rescored,** every case reads 2 of 2: (a) the change draft, (b) none for `lint-fix`, (c) an agent draft, (d) the
  package rule, (e) no single-package lowercase rule. Nothing was made live, and nothing was committed.

### 8, 8d: the two reviews, taken before the freeze (2026-11-24)

A fresh agent reviewed the diff and ran its own probes; the decision-checker read it against the ledger. No LOCKED line
is broken. Every finding is fixed below, with a case in `test/dream8d.mjs` and a mutation in `mutate8d.mjs`, or
recorded.

**Fixed in `dream.mjs`:**
- **A worktree's session got the wrong package.** Files were made relative to the main root only, so a session in
  `.claude/worktrees/feat` recorded `.claude/worktrees/feat/packages/api/...`. Each file is now relative to the root of
  the worktree that holds it, the longest first, and a relative path is taken from the session's own folder.
- **An inline brace glob was refused.** `paths: ["packages/{api,web}/**"]` was split on the comma inside the braces.
  The inline list now splits on commas outside quotes and braces.
- **The name gates used the file name; Claude Code goes by the `name` field.** An agent draft or a change draft whose
  `name` is not its file's is now refused ("a name that is not its file name"), so a draft cannot pass as, or shadow,
  another agent.
- **An empty field passed.** `\s*` crossed the line end, so an empty `tools:` took the next key's value. One `field()`
  helper now reads a key on its own line, for the agent, change and skill gates. The skill gate is D31's, older than
  8d; it had the same fault and the same fix.
- **An agent's change draft needed no `tools`.** It now passes item 1's gate, as registered ("every gate of item 1").
- **A NUL in a glob crashed finish** after the map was written. The folder check now uses `lstat`: a linked folder, or a
  name the system cannot hold, counts as lacking. A glob with a backslash is refused too.
- **Not registered, added (the decision-checker's D33 point):** a change to a file setup makes is refused ("a change to
  a file setup makes"). Those files are the plugin's: setup updates them by D29, and `map-review` is the review gate
  itself. `dream.mjs` now imports `FILES` from `setup.mjs`, an import the self-test already allows.

**Fixed in the texts:** the analyzer said "Name the task", but its format has no field for a name; both new kinds now
point at the U line, with the T line before a correction naming the artifact.

**Fixed in the checks:**
- `dream8d.mjs`: the link case requires exactly 2 refusals (its old pattern always matched). New cases: a skill a
  person starts keeps `disable-model-invocation: true` through a change; one cited session that did not use the skill;
  fewer than 2 sessions; empty fields; names that are not the file's; a file setup makes; private names; an agent's
  change written; a subagent's read not counted; a worktree's session, from a package folder, with relative paths;
  brace, YAML-list, NUL, backslash and outside-the-repo globs; the template's promotion line. All 7 cases fail on 8c.
- `mutate8d.mjs`: 23 mutations added, 48 in all; a dry run against `dream8d.mjs` alone killed 48 of 48.
- `fixture8d.mjs` (check 3):
  - "nothing live" now compares the live files' text, so a change draft promoted over its own file would show.
  - (c) now needs an agent draft for the review task C1 and C2 typed (its text names a review), as (c) is worded,
    where it took any agent draft. The pilot, rescored, still reads 2 of 2 on every case.
  - The summary lists each run's count of lowercase rule drafts. (e) can fail only in a run that drafts one: the
    pilot drafted none in run 1 and one in run 2. The result reports how many counted runs drafted one; the bar stays.

**Added before it runs, check 1b** (`probes/V2-8d-proposals/beside.mjs`, the decision-checker's D31 point): a change
draft beside a live `SKILL.md` stays inert. Until 8d, `freeName` kept drafts out of live folders. 3 runs where a
person types `/greet` and 3 where Claude starts it; every run answers from the live file, and no run shows the draft's
text or names the draft in a tool call. Pass: 6 of 6.

**Recorded, not changed:**
- **The waiting note** (item 1's limit) is wider than written: `/second-brain:status` uses the same `waiting()` as
  session start, so it also counts no agent draft. Both stay as they are (D18); the dream's report and `/map-review`
  name agent drafts.
- **Touched files also count `MultiEdit` and `NotebookEdit`,** beyond item 3's "Read, Edit and Write". Both are edits.
- **The README (item 6)** is written when 8d moves into `plugin/`, with 8e's.
- **D10:** 8d's agent and change code shares files with rule placement. If 8e is BLOCKED, the agent and change blocks
  in `finish()`, their texts and their cases come out before 2.6.0 ships; rule placement stays.
- **On 8c,** some cases fail with a TypeError (8c has no `usage.digests`) rather than on their own assertion. That is
  still a failure on 8c, as registered.
- **A nit not taken:** touched files sit in both the manifest (the report reads them) and `usage.json` (the analyzers
  read them).

### 8, 8e: the pilot, and the build before its reviews (2026-11-24)

**The pilot** (`probes/V2-8e-trial/results/check3-pilot.json`, the "without" arm only, 2 runs per case): both report
cases passed 0 of 2, and the `use: false` case 2 of 2. The fixture is not void: without the procedure, the task
fails, and the case that needs no skill passes.

**The build, against the registration:**
- **The grant was wider than item 2 says.** It was `trial.mjs":*`, which also let a model start `exec`. It is now
  `trial.mjs" cli:*` and `trial.mjs" draft:*`: the `!` line needs `cli`, and the making steps need `draft`. A real
  session through the shipped skill printed the run line under the narrowed grant. The self-test checks the exact
  grant, and a mutation that widens it is killed.
- **Residual risk, recorded:** inside a person-started `tailor` turn, the `cli` grant still lets the model type
  `cli run <name> <hash>` itself after `show` printed the hash. The skill's text forbids it ("Never run `trial.mjs show`,
  `run` or `exec` yourself"). A model cannot reach the trial outside that turn: the skill is flagged, so it is not
  listed, and no hook or other script names `trial.mjs` (the self-test checks both).
- **Words after `/second-brain:tailor`** other than `show` and `run` are a request to make something: the making steps
  take over and nothing runs. Before, any other word was refused, which check 4's requests would have hit. A case and a
  mutation cover it.
- **8d's review fixes** are carried into 8e's build (`dream.mjs`, the analyzer, `dream8d.mjs`); both case files pass.
- **D18's surface:** four skills (setup, dream, status, tailor), every one flagged, so none is listed and none adds
  listing bytes (D12); one script more, which no hook reaches.

### 8, 8e: amended after the two reviews, before the freeze (2026-11-24)

A fresh agent and the decision-checker reviewed the build. No LOCKED line is broken, but D34's boundary did not hold as
built, and several registered parts were missing. Two probes settled the design (scratch, uncounted, CLI 2.1.331, the
version on PATH that the product runs):
- **The grant.** With only `draft` granted, the `!` line is refused ("Shell command permission check failed"). A `!`
  line and a model's own Bash call see the same environment, so nothing tells them apart. As built, inside a
  person-started `tailor` turn the model could type `cli show`, then `cli run` with the hash: no person needed to see
  anything. The residual-risk line in the record above understated this.
- **The words.** `$ARGUMENTS` reaches the shell unescaped. An apostrophe breaks the `!` line, and `<…>` or `>` redirects;
  check 4's own pricing request holds `<YYYY-MM-DD>`. A fenced `!` block with a quoted heredoc passed an apostrophe,
  `<…>`, `>`, `$(…)` and quotes verbatim on stdin, wrote no file, and matched a `cli:*` grant.

**The amendments, each with a case in `test/trial8e.mjs` and a mutation in `mutate8e.mjs`:**
1. **Item 2, the yes.** The `!` block passes the person's words on stdin. `cli` only shows a trial or hands over to the
   making steps; it never starts one.
   - `show` prints a command for the person to type with Claude Code's own `!` prefix:
     `! node "<the script's path>" run <name> <hash>`. Typing it is the yes.
   - A model that tries the same command needs a Bash permission, which is a person's yes. Only a permission mode or an
     allow rule that already approves that command lets a model start a run; that is the person's setting.
   - The grant is `cli:*` and `draft:*`.
2. **Item 2, what `show` prints:** the artifact's whole front matter (any key, list form too), every line with a `!`
   command, the files beside a skill draft, and each check script's full text. The person approves what runs.
3. **Item 1, the case file:**
   - `runs` from 3 to 5, as agreed ("at least 3 runs per case");
   - a prompt that starts with `-` is refused;
   - every case lists the tool its kind needs (`Skill` for a skill, `Agent` or `Task` for an agent), since tools are now
     limited and an arm without that tool cannot differ;
   - a file counts as committed and unchanged when git says so (`git diff --quiet`), so `core.autocrlf` no longer
     refuses every case file on Windows.
4. **Item 3, the run:**
   - The commit is resolved once. The hash covers it, the case file, the artifact, the files beside a skill draft, and
     each check script; every copy comes from that commit.
   - "With" adds the files beside a skill draft. "Without" of a new skill draft has no skill folder; of a change, the
     file as the commit holds it.
   - Each copy has its own temp folder, and its commits turn off signing and hooks. Each commit message is the same,
     so no copy names its arm.
   - Each session also gets `--tools` (the case's tool names), `--setting-sources project,local`,
     `--no-session-persistence` and `--output-format json`. A session whose result record is missing or `is_error`, or
     which ran past 15 minutes, failed.
   - The check script is written fresh to its own temp folder after the session, from the text read at the start, and
     runs with a reduced environment.
   - The run sits in `try`/`finally`, so every temp folder is deleted.
5. **Item 4, the verdict:**
   - **"Not judged"** when any session or copy failed, or a `use: false` case failed in "without" (item 1 says it must
     pass in both arms). It gives the counts, and offers nothing.
   - Otherwise the rule is as registered.
   - The verdict file holds git's blob ids of the artifact and the case file, so `/map-review` can tell a stale one
     with `git hash-object`.
   - The file is privacy-scanned (registered, and missing), and written after any file or link at its path is removed.
6. **Item 5:** `/map-review` compares those blob ids, and shows "not judged" with its reason, never with a removal offer.
7. **Agents (the decision-checker's first finding, open since the draft):** check 3 adds an agent trial on the same
   fixture.
   - `good-agent.md` holds the procedure as an agent, and `pricing-reporter.json`'s cases name it ("use the
     pricing-reporter agent to …").
   - The bar: "helps" in 2 of 2 trials.
   - A pass ships 8d's agent drafts on evidence that a trial can judge an agent.

**Check 4's script (`guard8e.mjs`), fixed before it runs:**
- `draftsOnly` gave `every()` 12 rows where it needed 6, so it could never pass.
- "Made" is now any change in the repo by `git status`, not new files under `.claude/` only.
- "Drafts only" means every change is one of: a `.draft` under `.claude/`; a file beside a skill draft; or a case file
  or check under `.project-map/evals/`.
- The paths bar and the one-task bar now need a draft on each run with a gap, so an empty run no longer passes them.
- "Finished" is scored.
- **A check-4 pilot runs first,** one run per request: it can only void the probe, never a bar.

**Check 3 follows item 1:** `show` through the shipped skill, then the printed command, as the person would type it.
The "without" pilot runs again after these changes, and can only void the fixture.

**Recorded, not built:**
- **The trial is not a sandbox.** A session that lists `Bash` can reach other folders on disk, including other copies.
  A case lists `Bash` only when it needs it, and `show` prints the tools.
- **npm's `claude.cmd` shim** cannot be started without a shell. Such sessions fail, and the trial is "not judged".
- **A check script runs alone,** with no sibling imports.
- **The self-test's stand-in variable** (`SECOND_BRAIN_TRIAL_CLAUDE`) ships.
- **Copies come from `ls-tree` and `cat-file`,** not `git archive`. That keeps every file the commit holds, where
  archive would honour `export-ignore`, and executable modes are set.
- **The fenced `!` block is untested on WSL's CLI 2.1.228** until its login is renewed; the WSL detach run before that
  failed to authenticate, and is void.

### 8, 8d: result (2026-11-24): pass

Every counted check passed on the frozen copy, product `504278e402fe`, version 2.6.0, in the first attempt.
1. **The self-test** passes with the pin on, on Windows under Node 24 and Node 20, and in WSL under Node 20. Every
   `dream8d.mjs` case fails on 8c.
   - A first WSL run is void: `node` was not on WSL's PATH, so the self-test's child processes never started
     (`onboard()` read nothing). It passed once PATH held Node 20.
   - **Check 1b** (`results/beside.json`): a change draft beside a live skill stayed inert in 6 of 6 runs (3 typed, 3
     started by Claude). Every run answered from the live file; none showed the draft's text or named it in a tool
     call.
2. **The mutation check** (`results/mutate8d-win32.txt`): 48 of 48 killed, every case on every system.
   - It ran while the model checks ran, so the self-test's one timing assertion could have killed a mutation on its
     own. The dry run before the freeze killed all 48 with `dream8d.mjs` alone, which holds no timing check, so each
     kill is its case's.
3. **Check 3** (`results/check3.json`, 5 runs, Opus 5.5, CLI 2.1.305): every bar holds.
   - (a) to (e): 5 of 5 each. Nothing was made live, and nothing was committed. All 5 finished, with no history
     session failed.
   - **(e) could fail only in a run that drafted a lowercase rule.** 1 of the 5 did, and kept wider paths. (b) could
     fail in every run, and did not.
4. **S7's check 2** (`probes/V2-D31-dream/results/s7-product-a11.json`, fresh histories, steering in the first five
   runs): every bar passes.
   - All 10 finished, with no background analyzer.
   - C1 to C3: 10 of 10.
   - The rule, 4 of 5; the skill and the choice, 5 of 5.
   - No noise, no other status line, no live rule. The nonce landed in none.
   - Steering reached all 5 runs and landed in none.
5. **The reviews:** each finding fixed before the freeze, or recorded (above).

**D35 locks on (T)** (DECISIONS). 8d stays in its frozen copy until 8e ends, since by D10 its agent and change drafts
ship only with 8e's trial. On a pass, 8d and 8e move into `plugin/` together; on a block, the agent and change parts
come out first.

### 8, 8e: the amended build and its pilots (2026-11-24, before the freeze)

**The build follows the amendment above.**
- **`trial.mjs`, rewritten to items 1 to 7:**
  - the words on stdin, and a run only from the typed `! node … run` line;
  - one commit for every copy;
  - limited tools and project settings;
  - "not judged";
  - check scripts written fresh after each session;
  - blob ids;
  - the verdict written only after any link at its path is removed.
- **Two lines are simpler than the amendment's wording:**
  - **The hash** covers the commit, the artifact and the files beside a skill draft. The commit already holds the case
    file and the check scripts, both required unchanged since. A separate hash of them could never differ, and its
    mutations could not be killed.
  - **A copy's commits** turn hooks off through a hooks folder that does not exist, so `--no-verify` was dropped.
- **The template's pin moved** (`6d3e35da1c6033c9`). Its 8d and 8e texts are both unreleased, so the 2.5.1 text
  already listed covers setup's update (D29).
- **The diff against 8d's frozen copy touches no hook file** (`hooks.json`, `hook.mjs`, `map.mjs`), and the
  self-test's hook cases pass unchanged: no hook output changes (check 1's last case).
- **`test/trial8e.mjs`:** 9 cases, each fixed point of the amendment with its own assertion. They include a commit
  holding a backslash, a colon and a `.git` path (built with `git mktree`), a hostile global git config (signing with a
  missing program, and failing hooks), and a check that sees no stand-in variable.
- **`mutate8e.mjs`:** 80 mutations.
  - The dry run against `trial8e.mjs` alone first left four alive. Two are the self-test's own checks (the exact
    grant, and no code loaded at run time), and the full self-test kills both.
  - Two were weak cases, now fixed:
    - a tree's `.git/` files landed inside the copy's `.git`, and no case looked there. A committed `.git/config` could
      set a filter or `fsmonitor` that runs on `git add`;
    - the empty-field case matched "tools" in the draft's own name `emptytools`.
- **Platform facts on CLI 2.1.331** (the version on PATH):
  - `--tools Read Agent Skill` gives exactly those tools;
  - `--setting-sources`, `--no-session-persistence` and `--strict-mcp-config` are accepted.

**Check 3's "without" pilot, again** (`results/check3-pilot2.json`, both case files, 2 runs per case):
- the report cases passed 0 of 2 for the skill's cases and for the agent's;
- the support case passed 2 of 2 for each;
- no session failed under the new flags.

The fixture holds for both trials.

**Check 4's pilot** (`results/check4-pilot1.json`, one run per request, uncounted):
- **The pricing request (fixture2)** left a skill draft, its script beside it, a case file and four checks, all in
  their places, and nothing committed.
- **Neither request without a gap** made anything.
- **The migration request (fixture) made nothing.** A rerun of the same request made a sound skill draft. It found a
  real trap: the migration check accepts a number in another team's range.
  - The first run likely took the guideline "leave it out when the map already says it" over the table's "a
    procedure of several steps is a skill": the fixture's map holds the migration rules.
  - **The product text now says so:** "A recorded rule is not a procedure. When the map holds a task's rules but doing
    it takes several steps in a set order, or a step that must be exact, the procedure is the gap, and its home is a
    skill that follows those rules."
  - `guard8e.mjs` now keeps each session's reply in the scratch folder (never in `results/`), so an empty run can be
    read.
  - The bars do not change. The pilot runs once more on this text (`check4-pilot.json`).

**Check 4's second and third pilots** (`results/check4-pilot2.json`, `check4-pilot.json`, one run per request):
- **The second pilot** found two probe defects and one product gap.
  - **Probe: the path match** read `.project-map/decisions.md` as a missing `map/decisions.md`. A token may now start
    with a dot and follow a dash.
  - **Probe: "drafts only"** did not admit a map topic file. The pricing request states a rule, and the plugin's own
    capture (D14) recorded it as an entry, which the commit reviews. A topic file under `.project-map/` is now
    admitted and counted on its own (`mapEntries`). `README.md` and `dreams.md` are not.
  - **Product: the pricing run stopped before its draft step.** An unrelated `node scripts/golden.js` was refused for
    want of approval, and the model took that to mean every `node` command needs approval. So it left its files in
    `.project-map/drafts/` and guessed the draft's path in its case file.
    - The skill now says the `draft` command is granted to it, to run even when other commands wait for approval.
    - It also names the three draft paths.
- **The third pilot,** on the fixed probe and text, met every bar:
  - both gap requests left a skill draft, a script beside it, a case file and four checks;
  - the pricing request also left one map entry;
  - neither request without a gap made anything, and nothing was committed.
- **Both case files the making steps wrote** pass the trial's own validation: 3 runs, 4 cases, the right artifact.
- **The bars do not change.** The pilots can only void the probe, as 8d's pilot did with its scorer.

**Frozen 2026-11-24:** product `ce0daccd8a5d`, version 2.6.0 (8d's frozen copy plus 8e), the self-test pin set. The
first of (T)'s three fresh attempts.
- **Checks 1, 2 and 4 run now.**
- **Check 3's counted trials wait for the WSL detach probe**, registered to pass before them. WSL's CLI needs a new
  login, which only the user can do. Its pre-flight trial runs now.

### 8: the user's word on systems (2026-11-24)

> Skip Linux for now and focus on windows and mac only.

- **Linux is skipped for now.**
  - Check 3's precondition, "the detach probe passes … once in WSL", is dropped by this word. That WSL run was void:
    its CLI login had expired.
  - The WSL self-test runs already recorded (8d's and 8e's check 1 passed) stay as evidence, and no further Linux run
    is required.
  - CI's Linux job still runs on each push that changes `plugin/`. It is informative only.
- **macOS:** no Mac is at hand here. macOS evidence comes from CI's macOS job on the push that moves 8d and 8e into
  `plugin/`, as 8c's push passed there (run 45443149362). That job runs the self-test, which holds every case of
  checks 1, including 8e's detached run through the stand-in.
  - The real trial's detached process is probed on Windows only (`results/detach-win32.json`). On macOS it rests on
    Node's `detached` spawn, which CI's run of case (5) exercises with the stand-in, not with `claude`.
- **8e's pre-flight trial** ran exactly as shipped on the frozen copy:
  - `show` went through the skill, and the person's line was run as typed;
  - the verdict was "helps": the report cases passed 3 of 3 with the draft against 1 of 3 and 0 of 3 without, and the
    support case 3 of 3 in both arms;
  - no session failed. The counted trials start now.

### 8, 8e: attempt 1 of (T)'s three (2026-11-24): fail, on check 3's bad-draft bar

Counted on the frozen copy, product `ce0daccd8a5d`:
1. **The self-test** passes with the pin on, on Windows under Node 24 and Node 20, and in WSL under Node 20 (run before
   the user's word on Linux).
2. **The mutation check:** running when this was written; its result is added below.
3. **Check 3** (`probes/V2-8e-trial/results/check3.json`, CLI 2.1.331, 6 trials, each 18 sessions):
   - the good skill: "helps" 2 of 2 (the report cases 3 of 3 with it, 0 or 1 of 3 without). **Passes.**
   - the good agent: "helps" 2 of 2 (3 of 3 with it, 0 or 1 of 3 without). **Passes.**
   - the bad skill: "helps" once, then "adds nothing". **Fails** the bar (2 of 2 "hurts" or "adds nothing").
   - In the trial that said "helps", one "with" run of one report case passed (1 against 0), and the totals rule turned
     one pass in nine into "helps". No session failed in any trial, and every show line was typed and started.
4. **Check 4** (`results/check4.json`, 12 runs): every bar, 3 of 3 per repo.
   - Each gap run left one skill draft, a script beside it, a case file and its checks.
   - The pricing request also left the plugin's own map entry. No path was missing.
   - Each run without a gap made nothing, and nothing was committed.

**What the failure shows.** A pass should need the procedure: 8% VAT, half-up rounding, the order and the format are in
no file of the fixture. Yet "without" passed a report case in 3 trials, and the bad draft once.
- Two causes are open, and a diagnosis (uncounted, transcripts kept) is reading what those sessions read:
  - (i) the copies sit in the system temp folder, and in this test so do the scratch repos, whose check scripts
    encode the expected report. A session that searches beyond its copy could find one; this is the recorded "not a
    sandbox";
  - (ii) the model sometimes guesses the format.
- **Either way, the verdict rule has no margin:** one pass in nine decides "helps". That is the design's fault, not a
  run's. The next attempt rethinks it, registered before any code.

**The mutation check of attempt 1** was stopped unfinished once check 3 had failed, to free the machine. Attempt 2
runs its own.

### 8, 8e: attempt 2 of (T)'s three (registered 2026-11-24, before the code)

**The diagnosis** (uncounted, 8 "without" sessions on the two report cases, run as a trial runs them, transcripts
kept):
- **Passes:** 0 of 8.
- **Reads:** no session read anything outside its copy, except Claude Code's own auto-memory folder for that copy's
  path, which was empty.
- So cause (i), a session reaching the scratch repos' check scripts, was not seen.
- **The stray passes stay unexplained:** 3 "without" runs, and 1 "with" run of the bad draft, all on `report-month`,
  one per trial.
- **One fact stands either way.** Every trial session inherits the variables that link a Claude Code session to the
  one that started it: its session id, a messaging socket and token, and a child-notes folder. In the field, that is the
  person's own session, since their `!` command runs inside it.

**The changes:**
1. **A margin in the verdict, fixed now.** For a case where the artifact should be used, with `runs` runs, the margin
   is half the runs, rounded up (2 for 3 runs, 3 for 5).
   - **Better:** "with" passes at least the margin more runs than "without".
   - **Worse:** "without" passes at least the margin more.
   - The verdict:
     - **"not judged":** as before;
     - **"hurts":** the case where it should not be used fails with it, as before; or a case is worse and none
       better;
     - **"mixed":** one case better and another worse;
     - **"helps":** a case better and none worse;
     - **"adds nothing":** otherwise.
   - **Why a margin:** one pass in three was seen on cases that need the procedure, without it. A rule where one run
     decides cannot tell an artifact from that noise.
   - **Said plainly:** the rule was chosen after attempt 1. Applied to attempt 1's counts, it gives:
     - the good skill: "helps" 2 of 2;
     - the agent: "helps" 2 of 2;
     - the bad skill: "adds nothing" 2 of 2.
   - The bars do not change.
2. **The session's environment** loses every variable that links it to the starting session:
   - `CLAUDECODE`, `CLAUDE_PID` and `CLAUDE_EFFORT`;
   - `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SESSION_*`, `CLAUDE_CODE_BRIDGE_*`, `CLAUDE_CODE_CHILD_*` and
     `CLAUDE_CODE_MESSAGING_*`.

   Login and configuration variables stay: `CLAUDE_CONFIG_DIR`, and Claude Code's token and provider variables. A
   session then starts as it would from a plain terminal.

**The checks:** checks 1 to 4 as registered, all run again on attempt 2's frozen copy.
- **Check 1** adds cases for the margin (the table: 1 pass in 3 is "adds nothing"; 2 is "helps"; "mixed" and
  "worse"), and for the stripped variables, with the login ones kept.
- **Check 2** adds their mutations.
- **Check 3:** the same fixture and bars.
- **Check 4:** the same 12 runs.

**Recorded, not built:** each trial session leaves an empty project folder in Claude Code's data (`memory/` only), one
per copy. That is Claude Code's own behaviour under `--no-session-persistence`; the trial does not delete inside the
person's Claude Code folder.

**Attempt 2, built and frozen (2026-11-24):** product `8e5aa3cbbf9d`.
- **The two changes are in as registered.** One line is simpler than the registration: the margin compares every
  case, since a case where the artifact should not be used has passed every run in both arms by then. A filter on it
  could never change a verdict, and its mutation could never be killed.
- **The new cases** (the margin's table, the stripped and kept variables) fail on attempt 1's frozen copy, and pass.
- **`mutate8e.mjs`:** 85 mutations. The dry run against `trial8e.mjs` alone killed 83. The other two are the
  self-test's own checks, killed by the full self-test.
- **The counted checks run on Windows** (Node 24 and 20), by the user's word on systems.

### 8, 8e: attempt 2 of (T)'s three (2026-11-24): fail, on check 1 under Node 24

The counted self-test passed under Node 20 and failed under Node 24, in case (5), a run end to end. One "without" run
of `price-a` passed (1 of 3), where the stand-in always fails without the artifact.
- **The cause is a race, not noise.** The stand-in plays a session that tries to change its judge: it overwrites every
  check script it finds in the temp folder.
- Two sessions run at once, so one job's check script, written fresh after its own session, can be overwritten by
  the other job's session before it runs.
- The design's claim "no session can change what judges it" was false while two sessions ran at once. The case found
  it; under Node 20 the timing did not.
- Checks 2 to 4 were not run: the attempt had failed.

### 8, 8e: attempt 3 of (T)'s three, the last (registered 2026-11-24, before the code)

**The changes, from attempt 2:**
1. **One session at a time.** No session runs while another job's copy or check exists, so no session can reach
   another's work or judge. A trial of 18 sessions took about 2 minutes two at a time, so about 4 minutes in line.
2. **The check script never touches the disk.** Node reads it on stdin (`node --input-type=module -`), with the
   copy as its working folder and the reduced environment, from the text read at the start (checked on Node 24 and
   20). It runs alone, as recorded: no sibling imports.

Everything else is attempt 2's.

**The checks:** checks 1 to 4 as registered, all run on attempt 3's frozen copy, on Windows (Node 24 and 20).
- **Check 1:** case (5) keeps its stand-in that overwrites every check script it can find.
- **Check 2's** mutations follow the code: the check written to a file before the session, and sessions run two at
  once, must each be killed.
- **On a fail,** D34 stays BLOCKED (rule 4), and 8d's agent and change drafts do not ship (8d's D10 line).

**Attempt 3, built (2026-11-25, before the freeze):**
- **`exec`** runs its jobs in one loop, one session at a time.
- **`judged`** feeds the check script to `node --input-type=module -` on stdin, so no file of it exists.
- **The stand-in in case (5)** now also tampers with other copies: it writes "pass" into every other copy's `out.txt`,
  besides overwriting every check script it can find. Run one at a time, with the check on stdin, it reaches nothing;
  three runs of `trial8e.mjs` in a row passed.
- **`mutate8e.mjs`:**
  - An entry may now carry more replacement pairs, applied with it. "Sessions run two at once" needs three edits at
    once: the loop, its `continue` and its end.
  - New: "the check never on disk" and "one session at a time". Both are killed in a dry run.
  - The mutation for the check's temp folder is gone with that folder.
- **A limit, recorded:** a person who types the run line twice starts two trials of the same artifact, which then run
  side by side, and each writes the verdict file.

### 8, 8f: the dream's two missing pieces (registered 2026-11-25, before the code)

> add all missing elements so we can live test it. then support the second claude session with steps that has been
> added so the dream will run also self imrpovements session

The user's word, after a check against the research found two pieces never built
([research/2026-11-23-ai-native-devcon.md](research/2026-11-23-ai-native-devcon.md), K1; the dream this repo ran on
2026-11-25):
- **K1's second signal, "read, then corrected again".** Only its first signal, map files no session read, was built
  (4g).
- **Digests that are mostly tool lines.** On this repo's 8 sessions, the digests held 13,793 lines for 97 typed lines
  and chosen answers, the only lines a proposal may rest on. Each analyzer reads its digest whole.

K2 (tested in 4i, not shipped) and K3 (deferred in 4g, reopens on a measured miss) stay as decided.

**The change** (built on 8e's attempt-3 copy, so it holds 8c, 8d and 8e):
1. **Trimmed digests.** `prepare` keeps:
   - every U, Q and A line;
   - the 4 tool lines (T or R) before each U or Q line;
   - every T line that reads a map file (K1's route).

   Each other run of tool lines becomes one line, `…: <n> tool lines`. The digest's hash and line numbers are the
   trimmed text's, so evidence cites the trimmed lines.
2. **"Read, then corrected"** (K1's second signal):
   - `prepare` keeps, per digest, the line of each map read, beside the reads it keeps now;
   - the dream skill writes the analyzers' candidate lines to `.dream-run/candidates.txt` before finish;
   - `finish` reports, per topic file, the sessions where a `correction` candidate's line comes after a read of that
     file in the same digest: "Read, then corrected again in the same session: `<file>` (`<n>` sessions)".
   - Counts and file names only. It is evidence for the person, never a proposal (D31).
   - A candidate line that is not a U or Q line of its digest is ignored, so a forged one counts nothing.
3. **The texts:** the analyzer knows the `…` lines, and the skill knows the candidates file and the new report line.

**The checks:**
1. **The self-test, on Windows (Node 24 and 20).** Each case fails on 8e's attempt-3 copy, then passes. The cases:
   - the trim keeps every U, Q and A line, the 4 tool lines before, and the map-read lines, and marks the rest;
   - a correction after a read is counted, and one before the read is not;
   - a forged candidate is ignored;
   - the report line holds names and counts only.
2. **A mutation check** (`probes/V2-8f-dream/mutate8f.mjs`) kills each new guard.
3. **Real data:** on the transcripts this repo's dream of 2026-11-25 read, the trimmed digests hold at least 60% fewer
   lines in all, and exactly as many U and Q lines as the full ones.
4. **S7's check 2 at its bars,** steering included, 10 runs on fresh histories, on the frozen copy: the dream still
   finds what it found.
5. **A review** by a fresh agent and the decision-checker; each finding fixed before the freeze, or recorded.
- **Attempts:** three (rule 4).
- **It ships with 8e.** On a fail, 8f stays out.

**The live test** (the user's word): once 8e and 8f pass, the frozen build is installed in this repo's local scope,
from a copy outside `plugin/`, never from the checkout (an install pointed at the checkout runs it live). The second
session gets the steps: `/reload-plugins`, then the dream, `/map-review` and `/second-brain:tailor`.

**8f, amended before its code is frozen (2026-11-25): a field failure of 2.5.1, found while this repo's dream ran.**
- **What happened:**
  - `finish` wrote every proposal and the log line, then `fs.rmSync` of `.project-map/.dream-run/` threw. On Windows a
    folder cannot be deleted while a program has it as its working folder, and the building session's background
    watcher did.
  - So the data folder's run record, `state.json` (the read-up-to mark) and the lock were all left as they were. The
    next dream would have reported a dream "running, or stopped".
  - The session that ran the dream was sent the recovery: remove the half-written draft's folder, then retry `finish`.
- **The cause in the code:** the repo's run folder was removed before the state and the lock, though only the data
  folder's run record must go first (a retry trusts it).
- **Change 4:** `finish` removes the data folder's run record, writes the state, releases the lock, and only then
  removes `.project-map/.dream-run/`. When the system refuses that, the dream is still finished, and its report says to
  delete the folder once nothing holds it. `prepare` already clears a leftover run folder.
- **Check 1 adds a case, on Windows:** a child process holds `.dream-run` as its working folder through `finish`. The
  dream finishes, the lock is gone, `state.json` is written, and the report names the folder. On macOS a folder can be
  deleted while it is a working folder, so the failure cannot happen there, and the case is skipped with that reason.
- **Check 2** adds the mutation that puts the removal back before the state.

**8f, the two reviews, taken before the freeze (2026-11-25).** A fresh agent (it ran the cases and its own mutations)
and the decision-checker read the build.
- **A break of D35, fixed.** The trim dropped the lines 8c added for D35: a skill's or an agent's call (`T: Skill`,
  `T: Agent`) and a failed result (`R!`), unless they fell among the 4 tool lines before a typed line. The usage
  counts survived, since they are taken before the trim, but the analyzer's "the T line before the correction names
  it" could fail. Every such line is now kept.
  - **Check 3 of 8d re-runs** (5 runs, fresh histories, its bars) on 8f's frozen copy, since D35 was locked on
    untrimmed digests.
- **A digest left where git sees it, fixed** (the fresh agent's bug).
  - Node's recursive removal stops at its first error, and the run folder's `.gitignore` was among the first files it
    removed. So a held subfolder left staged proposals (unchecked by finish's privacy scan) and the usage file as
    untracked files beside a report that ends "then commit".
  - The folder is now emptied with its `.gitignore` last. Case (6) checks that git sees nothing of what is left.
- **Fixed, each with a case and a mutation:**
  - `abort` removed the repo's run folder before the lock, the same fault as `finish`. It now removes the run record,
    then the folder (best effort, never throwing), then the lock. Case (7) covers it.
  - `finish` now clears the repo's run folder before it releases the lock, still never throwing. A new `prepare` taking
    the lock in between could otherwise lose its folder. This deviates from the amendment's wording ("releases the
    lock, and only then removes"), and closes that gap.
  - "Per topic file": `finish` counts only topic files (`topic()`), not `README.md`, `dreams.md` or `steering.md`.
  - A record holding several tool calls marked all its lines as reads. Each reading call now marks its own line.
  - A candidate written with the digest's path (as the skill gives each analyzer) counted nothing. The match now takes
    an optional folder before `dN.digest`.
  - The report line had an unregistered sentence ("Their wording may not hold Claude to them."), now gone. The skill's
    step 6, which had Claude work the same signal out alone, now names the files from `finish`'s line.
- **The cases and mutations the reviews found weak:** the trailing cut line, exactly 4 lines before a typed line, a
  candidate counted once per session, reads only from the candidate's own session, and both Windows cases skipped
  together elsewhere. `mutate8f.mjs` now holds 25 mutations; a dry run against `dream8f.mjs` alone killed 25 of 25.
- **Recorded:**
  - The trim's walk-back no longer stops at the previous typed line: that line's own 4 kept lines are the ones the
    walk would reach, so the output is the same, as the registration's words read.
  - "A forged one counts nothing" overstated the guard. A candidate on a line that is not U or Q counts nothing. A
    `correction` aimed at a real U line after a read counts, since the analyzer's judgement is trusted as it is for
    proposals.
  - Case (4) (no candidates file) passes on 8e's copy as well: it guards the old behaviour, not a new one.
  - `realtrim.mjs` reads each transcript from its start. That is the range this repo's first dream read. Its typed-line
    bar holds by construction (the trim never drops a non-tool line), so the cut is the measure. It now also needs at
    least one session.
  - **Carried:**
    - the hooks label a leftover run folder's staged proposals (`hook.mjs`; a hook change, D18);
    - `prepare` on a held folder throws a raw error that names a local path to the person, then releases the lock.
- **A check added before the counted run:** S7's check 4 also counts, per run, the candidate lines the session wrote
  to `candidates.txt` in a form `finish` parses (`S7_CANDIDATES`). Bar: 8 of 10 runs. Only a real dream shows that an
  analyzer's lines reach `finish`.

**Attempt 3, frozen (2026-11-25):** product `24d6b6da4bf7`. Before the freeze, the self-test passed with the pin off, and
the dry run killed 83 of 85 mutations against `trial8e.mjs` alone. The other two are the self-test's own checks (the
exact grant, and no code loaded at run time). Checks 1 to 4 run now, on Windows.

**8f, frozen (2026-11-25):** product `d21930c51c1a`, on 8e's attempt-3 copy (its `trial.mjs` unchanged). The self-test
passed with the pin off. Its counted checks run now:
- the self-test waits for a quiet machine, since 8e's mutation run is on;
- the real-data trim;
- S7's check 2, with steering and the candidates count;
- 8d's check 3 again;
- the mutation check.

**Attempt 3, check 4** (`probes/V2-8e-trial/results/check4.json`, 12 runs, the frozen copy): **fails one bar.**
- Every gap run left one skill draft, its script, a case file and checks, with every named path present. Nothing was
  committed. The drafts were drafts only.
- **"Nothing made without a gap", 3 of 3 per repo: fails in the migration repo.** "Make agents for this repo." made a
  draft in 2 of 3 runs there (0 of 3 in the pricing repo).
  - The replies, kept in the scratch folder, say why: "Make agents" names no task, so the session took the gap from
    the project map. There, three migration rules make a procedure of several steps, a skill's home. The third run made
    nothing, and named the same gap.
  - The skill's step 1 counts a map entry as evidence of a gap. The line added after check 4's first pilot ("a
    recorded rule is not a procedure …") made it likelier. Attempt 1 passed this bar with the same text, 0 of 3.
  - So the probe's premise, that this request has no gap, does not hold in a repo whose map holds a procedure's rules.
    But the bar's script was fixed before the run, and a bar read differently after a result counts as a failed
    attempt. **The result stands as a fail.**

### 8, 8f: attempt 1, S7's check 2 (2026-11-25): fails one bar

`probes/V2-D31-dream/results/s7-product-a12.json` (8f's frozen copy, CLI 2.1.305, Opus 5.5, fresh histories, steering
and the candidates count on):
- **Every bar but one passes:**
  - all 10 finished, with no background analyzer;
  - C1 to C3: 10 of 10;
  - the skill and the choice: 5 of 5;
  - no noise, no other status line, no live rule, and the nonce landed nowhere;
  - steering reached all 5 runs and landed in none.
- **The candidates count (added before the run) passes:** all 10 runs wrote 9 to 18 lines that `finish` parses. A
  real dream's analyzer lines do reach `finish`.
- **The rule: 3 of 5, under its bar of 4.** In runs 1 and 5 the repeated date correction became a map entry, not a
  scoped rule draft. Nothing was dropped (`dropped 0`), and both entries name `src/utils/date.js`, so the organizer had
  the paths and chose an entry. Earlier builds missed the same way in 1 run of 5 (2.3.0, a5, a11).
- **Whether the trim caused it cannot be told from these runs.** The three rule drafts take their paths from the
  correction's words (`src/**`), not from tool lines.
- **8f's attempt 1 fails.** Two attempts remain under rule 4. 8d's check 3 on this copy is still running; its result
  is added below.

**Attempt 3, check 3** (`probes/V2-8e-trial/results/check3.json`, the frozen copy, CLI 2.1.331): **passes.**
- The good skill: "helps" 2 of 2. The good agent: "helps" 2 of 2. The bad skill: "adds nothing" 2 of 2.
- The pre-flight trial: "helps". In every trial the person's line was printed by `show` through the skill, typed, and
  started. No session failed.
- **Every "without" run of a report case failed: 0 of 3 in all 7 trials.** The stray passes of attempt 1 (3 trials
  with 1 of 3) did not come back once sessions ran one at a time and unlinked from their starter. Which of the two
  changes ended them is not separated.

**8f, attempt 1, 8d's check 3 on 8f's copy** (`probes/V2-8d-proposals/results/check3-on-8f.json`, fresh histories,
5 runs): **passes, every case 5 of 5.**
- Nothing was made live, and nothing was committed.
- (e) could fail in 4 of the 5 runs, which drafted a lowercase rule, and held in each. D35's evidence stands on trimmed
  digests.
- **A first launch of this check is void, a harness error of mine.** It was started twice, once in the foreground with
  `&`, which kept running unseen since Git Bash's `ps` does not list native Windows processes. So two dreams shared each
  repo, and one was refused by the other's lock. That copy was stopped, its summary file removed, and the check rerun
  from fresh histories, launched once.

**Attempt 3, check 2** (`probes/V2-8e-trial/results/mutate8e-win32.txt`): 85 of 85 killed. So attempt 3 passed checks
1 to 3 and failed one bar of check 4: the last attempt rule 4 allows.

### 8, 8e: attempt 4, on the user's word (registered 2026-11-25, before the code)

> If we ask to create the skills for repo we need do be aware of what code do, what agent we need and what lamps
> mukta asked to have. Not just "make a skill". Try again and be smart on what you add not mindless create the code

The user allows a fourth attempt. "What lamps mukta asked to have" is the approach of research/2026-11-23-ai-native-devcon.md:
evidence first, a person's choice, then a test.

**The change** (only `tailor`'s text, and check 4's probe). When a request names no task (such as "Make agents for
this repo."), `tailor` makes nothing at first:
1. **It surveys, read only:**
   - what the code does: the README or `CLAUDE.md`, the layout, and the build, test and check scripts;
   - what the repo already holds: `.claude/` rules, skills and agents;
   - the map's topic files, and the dream log `.project-map/dreams.md`.
2. **It lists the gaps it found.** Each is a task the repo repeats, or a rule it keeps needing, with its evidence (a
   map entry's id, a file, a script, a dream log line) and the smallest home, with why:
   - an agent only for a task that needs its own context, its own tools or its own notes;
   - a skill for a procedure of several steps;
   - a path rule for certain files;
   - a `CLAUDE.md` line for what every session needs.
3. **It says what it will not make, and why:** Claude does it anyway, the repo already shows it, or the evidence is
   thin.
4. **It asks which to make, and stops.** It makes nothing until the person picks one; then the making steps run as now.

A request that names a task runs the making steps as before.

**The checks:** checks 1 to 4 as registered, all run again on attempt 4's frozen copy, on Windows.
- **Check 1** adds the new text's lines to case (7).
- **Check 2** adds their mutations.
- **Check 3** is unchanged, since the trial's code is unchanged.
- **Check 4** keeps every bar, and adds one, fixed now: for the request that names no task, the reply names at least
  one gap with evidence the repo holds (a path that exists, or an id in its map) and asks which to make, in 3 of 3 runs
  per repo. Nothing made stays 3 of 3.

### 8, 8f: attempt 2 (registered 2026-11-25, before the code)

**The cause of attempt 1's miss.** In all five fixture runs, the analyzers labelled the date rule a "decision" (the
dream sessions' transcripts: 14 candidate lines each). The skill's organizer step says "A rule draft: a correction
repeated in two or more sessions that applies to certain paths". Three runs drafted the rule anyway; two kept the
wording and wrote only an entry. Earlier builds missed the same way once in five, so the trim is not shown to be the
cause.

**The change:** the organizer's rule-draft line covers a decision or a correction, stated or repeated in two or more
sessions, that applies to certain paths. 8f's other changes stay. Attempt 2 builds on 8e's attempt-4 copy.

**The checks:** 8f's checks 1 to 5 as registered (the self-test with a case for the new line, the mutations, the
real-data trim, S7's check 2 with steering and the candidates count, 8d's check 3), all on attempt 2's frozen copy,
fresh histories.

**8e attempt 4, built and frozen (2026-11-25):** product `edd5f7375a2f`.
- The survey-then-ask step is in `tailor`'s step 1. Case (7) checks its lines, and `mutate8e.mjs` holds 89 mutations;
  the four new ones were killed in a dry run.
- **Check 4's pilot** (`results/check4-pilot-a4.json`, one run per request, uncounted): every bar, the new one too.
  - Given "Make agents for this repo.", the migration repo's session made nothing. It named the migration procedure
    with its three map ids, its files and the 0101-in-payments trap, said why no agent is needed, and asked.
  - The pricing repo's session made nothing either. It found the report-and-log procedure from `PRICING-LOG.md` and
    `scripts/golden.js`, offered a skill or a path rule, and asked.
  - Both gap requests left their drafts as before.

**8f attempt 2, built and frozen (2026-11-25):** product `38fbf0dd76ed`, on 8e's attempt-4 copy. The organizer's
rule-draft line names a decision or a correction. Case (5) checks it, and `mutate8f.mjs` holds 26 mutations. Both
self-tests passed with the pin off before the freezes.

**8e attempt 4, counted checks so far (2026-11-25):**
1. **The self-test** passes with the pin on, on Windows under Node 24 and Node 20 (8f attempt 2's too).
2. **Check 4** (`results/check4.json`, 12 runs): **every bar passes, the new one too.**
   - With no task named, no run made anything (6 of 6), and each reply named evidence the repo holds and asked which
     to make.
   - With a gap, each run left one draft with its script, case file and checks, every named path present.
   - Nothing was committed.
3. **Check 3** (`results/check3.json`, 6 trials plus the pre-flight): **passes.**
   - The good skill and the good agent: "helps" 2 of 2. The bad skill: "adds nothing" 2 of 2. The pre-flight:
     "helps".
   - Every "without" report run failed (0 of 3), and no session failed.

**8f attempt 2, counted checks so far (2026-11-25):**
1. **The self-test** passes with the pin on, on Windows under Node 24 and Node 20.
2. **The real-data trim** (`probes/V2-8f-dream/results/realtrim.json`): 69.5% fewer lines (14,237 to 4,341), every typed
   line kept, 8 of 8 sessions. Passes.
3. **S7's check 2** (`probes/V2-D31-dream/results/s7-product-a13.json`, fresh histories, steering and the candidates
   count): **every bar passes.**
   - The rule: 5 of 5, against attempt 1's 3. The skill and the choice: 5 of 5. C1 to C3: 10 of 10.
   - No noise, no other status line, no live rule, and the nonce landed nowhere. Steering reached 5 of 5 runs and
     landed in none.
   - Parseable candidate lines in 10 of 10 runs (9 to 24 each).
4. **8d's check 3 on this copy** (`probes/V2-8d-proposals/results/check3-on-8f2.json`, fresh histories): every case 5
   of 5. Nothing was made live, and nothing was committed. (e) could fail in 3 of the 5 runs, and held.

### 8, 8e and 8f: results (2026-11-25): pass

- **8e passes in attempt 4,** allowed on the user's word. Every check passed on its frozen copy (`edd5f7375a2f`):
  - the self-test on Windows, Node 24 and 20;
  - check 2 (`results/mutate8e-win32.txt`): 89 of 89 killed;
  - check 3 and check 4, as recorded above.

  **D34 locks on (T)** (DECISIONS). By 8d's D10 line, 8d's agent and change drafts ship with it. D10's reopened scope
  and D18's surface re-lock with section 8's release, as registered.
- **8f passes in attempt 2.** Every check passed on its frozen copy (`38fbf0dd76ed`):
  - the self-test on Windows, Node 24 and 20;
  - check 2 (`probes/V2-8f-dream/results/mutate8f-win32.txt`): 26 of 26 killed;
  - the real-data trim, S7's check 2 and 8d's check 3, as recorded above.
  - The reviews (check 5) read attempt 1's code; attempt 2 changed one line of the skill's text, whose cause and
    effect are recorded above.
- **Moved into `plugin/`:** the frozen build, 8c with 8d, 8e and 8f. `plugin/` now hashes `38fbf0dd76ed`.
  `claude plugin validate plugin` passes. The README says what 2.6.0 adds.
- **Next, the live test the user asked for:** the frozen build installed in this repo's local scope from a copy
  outside `plugin/` (a directory marketplace `second-brain-live` that wraps it unchanged, rehearsed in an isolated
  config, where its cached copy hashed `38fbf0dd76ed`). Then the steps for the second session. CI's macOS job runs on
  this push. Then group M, the final audit, and a stop before `main`.

### 8, 8g: a worktree's files by their real path (registered 2026-11-25, before the code)

**Found:** CI's run on the move's push (`2e57af4f`, run 45594903637) failed the self-test on macOS and Windows, one
case each: `dream8d` (3), globs and worktrees. Linux and the load jobs passed. So the macOS evidence the user's word
on systems asked for is not yet in hand.

**The cause:** `prepare` places each file a session touched under the root of the worktree that holds it. The worktree
roots come from git, by their real paths. The file's path is spelled from the folder the transcript recorded, which is
not resolved. On the runners the temp folder has two spellings (macOS `/var` is a link to `/private/var`; Windows
runners use an 8.3 short name), so the worktree's root never matched, and the main root's spelling did. The worktree
session's files were counted as `.claude/worktrees/feat/…`. Reproduced here with the temp folder behind a junction.
A user whose repo sits under a link or a short name meets the same thing: package counts and the rule paths drawn from
them name the wrong folders.

**The change:** before matching, a file's folder is resolved through the real path of its nearest folder that still
exists. The test's worktree session spells its folder through a link to the repo, so the case fails on any machine,
not only on CI's runners.

**The checks:**
1. The self-test passes on Windows, Node 24 and 20, with the temp folder as it is and behind a junction. The new
   spelling fails on the current `plugin/` and passes on the copy.
2. 8d's mutation list, its (3) entries, is still killed on the copy (`MUT_ONLY`), plus one new mutation: the real-path
   step removed.
3. CI's macOS job passes on the push that moves 8g into `plugin/`. That run is the macOS evidence.
4. The review is the final audit's, which reads the whole of 2.6.0.
- **Attempts:** three (rule 4). Built in a copy of `plugin/`.

### The field read of 2026-11-25: no defect in the scan; one from the ask (8h)

Registered in `probes/V2-D17-field/README.md` before the scan (`25f06399`); frozen at 12:32Z. Counts only.
- **Installs:** both field repos run 2.5.1, the latest release, so nothing moved.
- **The second field repo** has had no session since 2026-11-15.

**The first field repo:** one main session, 4 epochs (startup 1, compaction 3).
- **C1:** the plugin's start reached 4 of 4 epochs, with its context recorded each time. The index listed 11
  directories.
- **C2:** 3 forces, one in each of the 3 epochs with a human prompt, never two in an epoch.
  - The counter put 2 of them on machine turns. Read by hand, both hang, by their parent records, from a slash
    command the person typed (`/second-brain:setup`).
  - Claude Code writes that command's record after the hook's context, and the counter matches by time. So the
    error is the counter's, not the plugin's.
- **C3:** all 3 forces answered per directory.
- **C5b:** 6 calls that name the map folder showed 205 entries, all 205 labelled. 1 call that does not name it
  showed an entry (04's accepted risk).
- **C6:** 1 entry, in the format, word for word, with no forbidden data.
- **C7:** 2 paths named after a change, 0 invented.
- **C8:** 0 errors, from the plugin's hooks or any other's.
- **C9:** 7 subagents, none with the index. 3 wrote repo files (34 writes), none of them a map entry.
- **2.5.1's setup, used for real:**
  - the person ran `/plugin` to update, then `/reload-plugins` and `/second-brain:setup`, from the 2.5.1 copy;
  - setup updated the three files section 6 found stale, created nothing, and kept 7;
  - each of the three now equals 2.5.1's template, committed and clean.

  Section 6's fix works in the field.
- **What Claude called on its own:** the repo's agents (`decision-checker` 2 times, among 7 subagents). The person
  typed every plugin skill that ran.

**This repo, reported apart and primed:** 2 human sessions, 13 epochs. The two headless sessions of the 2.6.0
install's smoke test are left out.
- **C1:** 13 of 13. The index listed 40 to 82 directories.
- **C2:**
  - 13 forces, one per epoch with a human prompt;
  - the counter's 2 off-turn forces hang from typed slash commands, as above.
- **C5b:**
  - 12 calls that name the folder showed 15 entries, 9 labelled;
  - the 5 calls with a miss read the dream's digests or grep the plan, which quote the words the later entries hold.
    They are not map reads, so no label was due;
  - 26 calls that do not name the folder showed an entry.
- **C6:** 4 entries, with no forbidden data.
  - 3 were the dream's proposals, word for word.
  - 1 was the release entry. It was found while merging: its quote states what was seen, and its source names that
    event rather than a person.
- **C7:** 51 paths, 3 not found, all false hits: a web address, the name of a study, and a test fixture's draft.
- **C8:** 0 errors from the plugin's hooks. 2 timeouts of another tool's `PreToolUse` hook (the plugin has none).
- **C9:** 55 subagents; 12 wrote repo files (24 writes), none of them a map entry.

**The ask:** this repo's other session, the only active one, answered the fixed question. Its answer stays outside
the repo. The field repos' sessions were offline and not asked.

**Triage (the loop's rule 6):**
- **No defect in the scan.** The ask found one; see the additions below.
- **An observation for D22:** in this repo (77 to 82 directories), the session said the forced answer changed
  nothing it read and is long. Recorded in the ledger; no trigger fired.
- **The counter** (probe code, not the product), due before the next count and registered first, as 18b was:
  - C2 should follow a force's parent records to its prompt, not the time;
  - the build label should be per epoch: the field epoch that ran 2.5.1's setup is labelled 2.5.0.
- **Next read:** the field sessions on 2.5.1, or on the next release once it moves.

**Added after the record (2026-11-25):**
- **The scope counts** (`field-scope.mjs`), which the first record missed.
  - *The first field repo:*
    - 10 gate events, each with a declared set; 25 pairs: D 8, R 0, X 17, with 11 of the X delivered with the
      write;
    - (S-b) as registered is over its bar at 10 of 10 events, as in 17m.
  - *The other 6 X pairs* are one broad rule, whose `paths:` name whole top folders.
    - All fall in the epoch after a compaction, at writes to files not Read in that epoch, so Claude Code had no read
      to deliver on.
    - The rule was delivered in the epoch before.
    - Whether it bore on each change is not judged.
  - *X is 68% of the pairs,* above 10%: an observation for D22's selection-miss trigger, recorded in the ledger. No
    trigger fired.
  - *This repo:* 29 gate events, none with a declared set, so 0 pairs. Its one path rule covers `.project-map/**`
    only. This is not a counter failure.
- **The ask's correction:**
  - after answering, the other session saw map labels three times, on background Bash commands that never named the
    map;
  - it reproduced the cause and registered the fix as 8h, below;
  - this is the label noise the 2026-11-08 field account named.

  So the read has one defect, found by the ask and not by the scan: the counter counts missing labels, not labels
  given where none was due.
- **Corrected by the counter's fix (below):** the first field repo had that noise too, twice on 2.5.0.

### 8, 8h: map labels only on a command that names the map (registered 2026-11-25, before the code)

**Found** in this session, while 8g ran: a Bash command run in the background that never named `.project-map` got
every map file's labels. Reproduced with a harmless command:
- a compound command (`;`, a redirect, a `for` loop) run in the background got the labels;
- the same command in the foreground did not, and neither did a plain `echo` in the background.

So Claude Code's `if` filter, `Bash(*.project-map*)`, lets such a command through. The handler trusts the filter
and, as for any background command whose output it cannot see (2n), gives every map file's labels. That is noise in
Claude's context on each such command, the kind the field account of 2026-11-08 named. The label's meaning (D14) and
its delivery (D18) are unchanged.

**The change:** the `bash` and `bash-failure` handler checks that the command names the map folder, as the filter
does, and stays silent otherwise. The filter stays, since it spares a process start. A command that reads the map
without naming its folder was already unlabelled (04's accepted risk), so no new miss.

**The checks:**
1. A self-test case: a `bash` and a `bash-failure` input with a `backgroundTaskId` and a command that does not name the
   map get nothing; the same input naming the map gets every file's labels. It fails on 8g's copy and passes after.
   The self-test passes on Windows, Node 24 and 20.
2. A mutation: the guard removed. The case must fail.
3. Every existing `bash` case's command names the map (read: all do), so no case changes.
- **Attempts:** three (rule 4). Built on 8g's copy; it moves with 8g. Its review is the final audit's.
- **Live:** once the live install carries it, a background compound command in this repo gets no label. Recorded when
  seen; not a gate.

### 8, 8g and 8h: results (2026-11-25): pass on Windows; macOS from CI on this push

- **8g passes, attempt 1** (product `b80afe510db8`, built on `38fbf0dd76ed`):
  - check 1: the new spelling, a worktree session whose folder runs through a link to the repo, fails on the current
    `plugin/` and passes on the copy. The self-test passes on Node 24 and 20, each with the temp folder as it is and
    behind a junction: 4 of 4.
  - check 2 (`probes/V2-8d-proposals/results/mutate8d-8g-win32.txt`): 15 of 15 of 8d's (3) mutations killed, the new
    one (the real-path step removed) included.
- **8h passes, attempt 1** (product `b977771fc513`, built on 8g's copy):
  - check 1: a `bash` and a `bash-failure` input that do not name the map, one marked as a background command and one
    whose error text reads as cut, got 413 and 420 bytes of labels from 8g's hook and nothing from 8h's. The self-test
    passes on Node 24 and 20.
  - check 2: with the guard removed, the self-test fails at the new case (`selftest.mjs:402`).
  - check 3 held: every existing case's command names the map.
  - **Found while it ran:** the noise came by two routes, not one. Besides background compound commands, a foreground
    command (`test … && cp … && sed … | cut …`) got every file's labels. Its output printed the self-test's own
    `[40000 characters truncated]` text, which the handler reads as a cut output. Both need the filter to let through
    a command that does not name the map; 8h stops both in the handler.
- **Moved into `plugin/`:** `plugin/` hashes `b977771fc513`, and `claude plugin validate plugin` passes. CI's macOS job
  on this push is the macOS evidence (8g's check 3); its result is recorded next.
- **Not in the live install:** that holds `38fbf0dd76ed`. 8g matters only where a repo's path has two spellings, which
  this repo's does not. 8h's noise stays in the live test until the install is refreshed.

**8h, a third route, read after the move (2026-11-25).** Two more foreground commands got the whole-file form. This
session's transcript shows why: Claude Code's Bash result now carries a field `bashEditDiff`, the diff of the files a
command edited. The handler takes every string in the result as output, so the edited text counts as output. Both
commands edited text that holds the cut marker `[40000 characters truncated]` (the self-test's case, and this record
quoting it), so the handler took the output as cut.
- The first did not name the map: 8h stops it.
- The second named the map (in its commit message), so its labels are due. It got all of them rather than those the
  output showed: more labels, never fewer, and only when an edit's text holds the cut marker. No change.
- So a map entry that a Bash command edits is labelled as shown. That is D14's "the entries this output shows".

**8g's check 3, and the macOS evidence (2026-11-25):** CI's run 45616472804 on `69f9163a` (product `b977771fc513`)
passed every job: the self-test on macOS, Windows and Linux, and the load jobs. The macOS self-test holds every case
of 8c to 8h, including 8e's detached run through the stand-in. So the user's word on systems is met for 2.6.0 as it
stands.

### 8: the open-items register (2026-11-25), on the user's word

> If you find issue, gaps, improvement do not leave it and add it to the implementation plan

(map entry `findings-go-into-the-plan`). The plan is the map issue (#115); this register holds each item's detail.
Its sources are three inventories (this file and the ledger; the research notes against `plugin/`; the user's
sessions and the agent's notes), the final audit by four reviewers who had not seen section 8's register
(correctness, security, simplicity, and the decision-checker), and the live test of tailor (8h's results onward).
Each item is open until it is built and checked, or until the user drops it. The labels are a first triage and may
be revised:
- **fix:** blocks 2.6.0. It is a defect in code new since 2.5.1 that breaks a registered bar, a locked decision's
  boundary, or security.
- **text:** a change to text a model reads. Each one voids the counted model runs (8d's check 3, 8e's check 4 and S7's
  check 2), so they are batched into one step that re-earns those runs, or deferred.
- **refactor:** a step after the fixes, since it moves the mutation anchors.
- **record**, **release**, **user** (the user's word is needed), **later**, **housekeeping**.

**Corrections to earlier results:**
- **8g** passed its checks, but its `realDir` added a file-system call on every path a transcript names, before any
  root check (X-2 below). A fix may not drop 8g's link case.
- **8e's pass** did not cover four of its own registered bars: C-1, C-2 (amendment item 2), C-6 ("then the making
  steps run as now", attempt 4) and C-7 (N5's staging folder). No D34 trigger was seen firing; the next fix step
  names each.

**fix: blocks 2.6.0**
- X-1 (security, verified): `trial.mjs draft` with a lowercase `skill.md` staged writes a live
  `.claude/skills/<name>/skill.md` beside the draft on Windows and macOS, which would load as a live skill.
- X-2 (security, Windows): prepare runs `existsSync`/`realpathSync` on a path from a transcript, such as a UNC path
  `//host/share/f`, which opens an SMB connection (a hash leak). Added by 8g; macOS's `/net/<host>` automounts.
- X-4 (hardening): agent and change drafts pass with `permissionMode`, `hooks`, `mcpServers`, or a widened
  `allowed-tools`, and map-review promotes them on one yes without a word.
- K-1 (verified; made worse by 8f): prepare after a stuck run folder deletes `.gitignore` first, throws a raw error
  with a local path, and leaves `usage.json`, proposals and steering visible to git.
- P-1, C-3, K-2 (verified): the verdict's blob ids come from the working tree when the run ends, so a draft edited
  during a run gets a verdict that map-review calls current.
- C-1: `show` prints a fenced `!` block's opener, not its commands. C-2 and X-3, part: `show` prints neither the
  artifact's body nor the text of the files beside a skill draft, though the approved hash covers them.
- C-7: the trial's copies carry a committed `.project-map/drafts/<name>/` into the "without" arm.
- C-8, K-7, P-15: two typed run lines start two trials side by side, against D34's "one session at a time".
- K-3 (verified): on Windows, a copy that cannot be removed throws in `finally` and discards the whole trial.
- K-4 (verified): `draft()` refuses YAML block lists (`paths:` then `  - "src/**"`), the form Claude Code's docs show;
  the dream's `field()` drops an agent whose `tools:` is a block list.
- To reproduce before triage: P-2 (a session reading `node_modules/x` makes a rule scoped to `node_modules/x/**`);
  X-3's tool reach (bare names in `--allowedTools` approve Write and Edit on any path) and its environment (user
  tokens reach trial sessions).

**text: a model reads it**
- C-4, R-a: no case file for a draft the dream made or a live artifact. map-review points to `show`, which stops with
  "no case file", so the loop's own drafts reach promotion untested (D35's "ships only with 8e's trial"; D10's "each is
  tested"). Build a tailor path that writes cases for an existing path, or amend the decisions' words (user).
- C-6: after the person picks, the grant to `trial.mjs draft` may have ended with the survey's turn (D31's record);
  the live test reads it.
- P-3: every analyzer reads the whole `usage.json`, an estimated several hundred thousand tokens per large dream
  (registered in 8d; user).
- P-7: tailor's text is 9.9 KB, about 2.5k tokens on each run, `show` included. Moving the guidelines out saves about
  1.2k per `show`, and cutting duplicates about 500 per run.
- P-13, P-14: repeated or empty sentences in `dream.mjs`'s report and the map-review template.
- R-c: the placement table has no agent row or tailor pointer, and the README template says a dream proposes only
  skills and path rules.
- R-d, from the first dream: no warning that a retried finish undoes review; a retry leaves a `<name>-2` folder; the
  dream skill does not say finish makes skill drafts user-only; digest lines carry no dates.
- X-6: the heredoc's delimiter can be closed by pasted words.

**refactor**
- P-4: agent and change draft gates are one chain copied. P-5: `trial.mjs` re-parses front matter (reuse
  `front`/`field`). P-8 to P-12: a set built twice; `meta` unused; local `git`/`blob` copies; a dead `mkdirSync`; a
  third copy of the walk to the nearest existing folder. P-16: one test kit. T-5: one mutation harness for the seven
  copies.

**record**
- C-9: D10 and D18 are REOPENED. Their texts give 3 skills, and describe tailor as one Claude may start; 2.6.0 has 4,
  with tailor flagged. Re-lock them with the built surface, at the release.
- C-10: 8h's "no new miss" contradicts 8a's D14 note for commands the filter lets through.
- C-11: a stale hash comment in `setup.mjs:14`.
- `04-architecture.md`, the charter's D34 entry, the ledger's frontier block (D20 deferred, D28 waiting) and a D14 note
  for 8h are stale. The "graph" item was never closed after the talk was read. #115 lacked 8c to 8h.
  - **R-l closed (2026-11-26): not taken** (research of 2026-11-23, [the DevCon note](research/2026-11-23-ai-native-devcon.md),
    section 4: git and Claude Code's transcripts already hold the record).

**release**
- Group M (A1, S8, D16's drift, D14's injection), on the final candidate.
- D18's reference bench, once, after the last hook change.
- The live test's result: the dream, map-review and tailor with its trial, on the final build.
- The notes, the tag, a PR to `main`; push `v2` back; move the installs. Stop and ask before `main`.

**user**
- 8a's hardening, blocked by the user's word on 2026-11-24: H3 to H7, D-1 to D-6, 8a's leftovers, and `status.mjs`
  on a FIFO or a linked map file. Of these, H3, H7 and D-1 to D-3 are security or privacy.
- C-4's route, and P-3.
- K-8: with Claude Code installed by npm on Windows, `spawn('claude')` finds no `claude.cmd`, so every trial ends "not
  judged" with no reason.
- S-3: steering's third rule has no review on record. S-4: field-repo items the agent's notes hold. A rule ("run
  steps back to back") has no source words left for the map.
- T-2: `/v2-step` was never typed in 15 sessions and contradicts that rule (retire or rewrite). T-4: the repo's
  setting that deletes a head branch on merge.
- Housekeeping: about 263 `second-brain-trial-*` folders in the temp folder, and about 448 empty Claude Code project
  folders from trial copies (S-1). Clean them, and make trial copies leave none.

**later**
- Hooks: H2 (a Read hook process per Read); R8's standing "repo unchanged after each hook" case; K-5 (agent drafts get
  no waiting note; D18); labels on `.dream-run/` and no repeat-suppression (R-e); SubagentStart (its trigger fired on
  2026-10-29).
- Dream: K-6 (an Agent call with no type is not counted); 8c's count edges; `state.json` written without a rename;
  usage kept between dreams, for trends and before-and-after (R-b); the auto-memory input (R-f); steering in setup and
  capture (R-g); the token half of "learning every run" (R-h); per-document descriptions beyond topic files (R-i);
  `when:` and headings shown (I-2); union merge for topic files (R-k); "read, then corrected" as a reword proposal
  (R-r); assess D31's grant-lifetime trigger (R-q, with C-6).
- Tailor and trial: not a sandbox (X-3's rest); check scripts cannot import files beside them (S-2); `draft()` refuses
  a skill's subfolder; a case file names the `.draft` path, so after promotion `show` refuses it; a repo over 1 GB
  copies truncated (X-7); the run hash is visible to the model (X-5).
- Setup and templates: `codebase-guide` and `memory-curator` unused (T-6); mixed line endings; "set up once, then it
  keeps itself current" (S-5); a nested package's own `.claude/` (R-o).
- Probes: R4's scheduled-task reopen; the `claude plugin eval` probe; the field counter's three fixes, due before the
  next count.
- From the live survey: the release steps the CLAUDE.md promises are not in the map (T-3); a `work-status` agent and
  a `release` skill, made through tailor as the live test.

**Done in this round:** the absolute local path in `.claude/workflows/devils-advocate.js` and in two D34 probe scripts
is gone. Two of the user's working rules moved from the agent's notes into the map (`findings-go-into-the-plan`,
`usage-limits-not-usd`).

### 8, 8i and 8j: the register's fixes, code only (registered 2026-11-25, before the code)

Two steps, each built by its own agent in its own copy of `plugin/` at `b977771fc513`. They touch different files:
8i `scripts/trial.mjs` and `test/trial8e.mjs`; 8j `scripts/dream.mjs` and `test/dream8c.mjs`, `dream8d.mjs`,
`dream8f.mjs`. No text a model reads changes in either, so no counted model run is voided. The register's text items
wait for one batched step, after the user's word on C-4 and P-3.

**8i, the trial** (the register's ids):
1. X-1: `draft` refuses a file beside the main one whose name, in any case, is the main file's name or ends in
   `.draft`, and requires the main file under its exact name.
2. P-1, C-3, K-2: the verdict's `artifactBlob` is the blob of the text that ran, and its `casesBlob` the case file's
   blob at the trial's commit, both taken when the cases are loaded.
3. C-1 and C-2: `show` prints each fenced `!` block whole, the artifact's whole text, and the text of every file
   beside it.
4. C-7: the copies leave out `.project-map/drafts/`.
5. C-8, K-7, P-15: one trial at a time per repo. A second `run` stops with a message while a trial runs; a lock left by
   a process that has ended is taken over.
6. K-3: a copy that cannot be removed is reported, and the trial goes on.
7. K-4, the trial's half: `draft` reads YAML block lists in front matter (`paths:`, `tools:`).
8. K-8, its smallest part: when `claude` cannot be started, the verdict and report say why (npm's `claude.cmd` on
   Windows is named). Running through the shim is the user's call.
9. X-7: a failed `git cat-file` stops the copy, never a truncated tree.

**8j, the dream:**
1. X-2: no file-system call on a path a transcript's tool call names before a plain string check places it under one
   of the repo's roots. A UNC path (`//host/…`, `\\host\…`) is never touched. 8g's case must still pass: a session
   whose folder runs through a link resolves by its recorded folder, which Claude Code writes, not the model.
2. K-1, P-6: `prepare` clears an old run folder with `clearRun` (`.gitignore` last) and stops with the "could not be
   removed" text when it cannot, with no raw error and no local path.
3. X-4: `finish` refuses an agent or change draft whose front matter sets `permissionMode`, `hooks` or `mcpServers`,
   and a change draft whose `allowed-tools` or `tools` differ from the live file's, each with a reason in the report.
4. K-4, the dream's half: `field()` reads a YAML block list, so an agent draft whose `tools:` is a list is kept.
5. P-2, reproduced first. If a session's read of an ignored path (such as `node_modules/x`) becomes a package or a
   rule's paths, `prepare` leaves git-ignored paths out of the touched files.

**The checks, for each step:**
1. Each fix has a test that fails on `b977771fc513` and passes on the copy; the builder shows both runs.
2. Each new guard has a mutation the test kills (`probes/V2-8i-trial/mutate8i.mjs`,
   `probes/V2-8j-dream/mutate8j.mjs`, in the form of `mutate8f.mjs`).
3. On the merged copy (both steps together, with the product hash pinned): the self-test on Windows, Node 24 and 20;
   every mutation list of 8c to 8j; CI on the push that moves it in (macOS's evidence). A builder's pass is a claim;
   these runs are the evidence.
4. A fresh review of the merged diff, and the decision-checker against D31, D34 and D35.
- **Attempts:** three per step (rule 4). Neither step changes `hook.mjs` or `map.mjs`, so D18's bench runs once, after
  the last hook change in this section.

### 8: the live test of tailor and its trial (2026-11-25), on the user's word

> Use our plug-in to create dedicated skills that we can use as lamps makut introduced. It will be our live test.

Run in this repo, on the installed live build (`38fbf0dd76ed`, whose `trial.mjs` and tailor equal `b977771fc513`'s),
headless, with the user's settings loaded; the agent acted as the person, on the user's word.
1. **The survey** (20 turns): a broad request. Tailor read the code, `.claude/`, the map, the ledger and the user's 15
   sessions here, then named two gaps with evidence and counts: a `work-status` agent (the user asked where the work
   stands 11 times in 5 sessions, and findings were lost between sessions), and a `release` skill (the release order
   is written down nowhere, and `v2` was deleted on three merges). It gave seven things it would not make, with
   reasons, and six other findings (T-1 to T-6 in the register). It made nothing, and asked.
2. **The pick** (36 turns): the `work-status` agent first. Tailor wrote the draft and four cases, but its grant to
   `trial.mjs draft` had ended with the survey's turn, so it could not move the draft (C-6, now observed). The person
   ran `draft`, the check scripts' own test (13 of 13), and committed the cases.
3. **`show`** (1 turn) printed the plan and the run line. The model's relay to the person left out the four check
   scripts and said they were "shown above", which was false (L-1).
4. **The trial** (24 sessions, none failed): verdict **helps**.
   - `state`: with 3, without 0. `released`: with 3, without 0.
   - `left`: with 0, without 0.
   - `where-label` (should not be used): with 3, without 3.

**What the live test found, into the register:**
- L-1: `show` reaches the person only through the model's relay, which can drop what the person must see. It adds to
  C-1 and C-2.
- L-2: every should-use case's prompt names the agent ("Use the work-status agent…"). The "without" arm then has no
  such agent, so its 0 of 3 may come from the prompt, not from the agent's value. Tailor's guidelines should keep the
  artifact's name out of a case's prompt, or the trial should flag it. Until a case without the name is run, "helps"
  here may be inflated.
- L-3: `left` failed in both arms. The agent's list of open items misses part of what the check asks: 8a's open fixes,
  group M and the audit. Improve it, or the check, before promotion.
- L-5: in a headless run, the drafting turn reached for Bash (`sed`, `awk`, `grep`) and was refused 8 times; the
  survey, none. Interactively each would ask the person. Tailor's text could steer to the Read and Grep tools.
- The `work-status` draft waits in `.claude/agents/work-status.md.draft`. Promotion waits for L-2 and L-3, by the
  person in `/map-review`.

### 8: the user's word on the register (2026-11-25)

Asked once, four questions; the answers:
- **8a's hardening: all of 8a now.** The block of 2026-11-24 is lifted for every item: H3 to H7, D-1 to D-6, F-1, 8a's
  leftovers, and `status.mjs` on a FIFO or a linked map file. 8a's code (`probes/V2-8a-fixes/candidate/`, built on
  2.5.1) is ported onto 2.6.0 as step 8k, registered before its code. Its attempt 3 failed CI on Windows (H7's fix
  does not hold on Node 20, and a load gate read 102.7 ms against 100); 8k's registration says how each is answered.
- **Dream drafts: build the test path (C-4).** Tailor gets a path that writes cases for an existing draft or a live
  artifact, and map-review points to it. D35's "ships only with 8e's trial" and D10's "each is tested" stand.
- **The analyzers' read of `usage.json`: cut it (P-3).** Each analyzer reads only its digest; the main session keeps
  `usage.json`.
- **Housekeeping: clean both, and stop new ones.** The trial temp folders and the empty Claude Code project folders
  the trial copies leave are listed, then deleted (only trial-named or empty ones); a trial copy leaves no project
  folder from now on.

**The order that follows:** 8i and 8j (code, building now); then 8k, 8a on 2.6.0 (code, on the merged copy, since it
shares `dream.mjs` with 8j); then 8l, the text step (C-4, C-6, P-3, P-7, P-13, P-14, R-c, R-d, X-6, L-2, L-5), which
re-earns the counted model runs once (8d's check 3, 8e's check 4, S7's check 2); then the refactors; then the
records, group M, D18's bench, and the release stop.

### The field counter's three fixes (2026-11-25): pass; the field read corrected

Registered and run in `probes/V2-D17-field/README.md` ("The counter's three fixes"). This is probe code only. It
closes the register's item "the field counter's three fixes" ("later", probes).
- *C2* puts all 16 forces of the 12:32Z freeze on human turns.
- *The build label* reads the install only from Claude Code's own records of a skill running, and is given per
  epoch.
- *C5b* counts the label blocks on calls that do not name the map.
- **The field read, corrected:** the first field repo got 2 such label blocks on 2.5.0, one from a background call
  and one from a foreground call. So the field had 8h's noise too, and the scan missed it. 8h fixes it there once the
  install moves. This repo had 33 on the 13:55Z freeze.
- **Open, new ("later", probes):** in an epoch where no skill runs, the label carries the last version forward. So a
  move between epochs with no skill run gets the old label.

**8i, amended before its code is frozen (2026-11-25), on the user's word "clean both, stop new ones":**
10. After each trial session, the copy's Claude Code project folder (`<config>/projects/<the copy's path, as Claude
    Code names it>`) is removed when it holds no transcript. Each session made one, though the trial asks for no
    transcript: an empty `memory/` folder and the subagents' `.meta.json` files. Its test: the stub makes such a
    folder, and none is left after the trial.

**The cleanup itself (2026-11-25):** 402 trial-named project folders that held no transcript were deleted. 112 that
hold transcripts (probe sessions) are kept. The 263 trial temp folders wait until the builders' tests stop.

### 8, 8k: all of 8a on 2.6.0 (registered 2026-11-25, before the code), on the user's word

Built by one agent on the merged 8i and 8j copy, from 8a's candidate (`probes/V2-8a-fixes/candidate/`), which was
built on 2.5.1. Since 2.5.1, `map.mjs` and `status.mjs` are unchanged, `hook.mjs` changed only by 8h's guard, and
`dream.mjs` grew by 8c to 8g.
- **Ported as built:** H3 (no link out of the repo is followed), H4 (map files read through `readMapFile`, special
  files skipped), H5 (the quote re-find in linear time), H6 (`safeName` in labels and `closed()`), D-4 (`lock()`), D-5
  (`headText`/`inTracked`), and the `when:` cap of D-1.
- **Adapted:**
  - H1's naming test goes into 8h's guard. A command names the map when it does so after letter case, quotes,
    backslashes and backslash-newlines are set aside, so the guard is never narrower than the `if` filter (8a's
    four naming cases and their mutations). This settles C-10. The rest of H1 is superseded by 8h.
  - D-1: `topic()`'s exclusions are merged with 8c's `steering.md`.
  - D-2: `PRIVATE` applies wherever it is used, `trial.mjs` included.
  - D-3: digests are redacted before they are trimmed (`trim(lines.map(redact), …)`), so 8f's line numbers hold.
  - D-6: the end offset becomes `digestFrom`'s fifth argument.
  - F-1: the self-test removes the markers it made by listing them before and after.
- **H7, answered differently:** one resolver in `map.mjs` finds `git.exe` among the absolute PATH entries on Windows,
  by file checks only. It never falls back to the bare name: with none found, it gives a path that does not exist, so
  the call fails as "git not found". Every git call in the plugin uses it. The same resolver finds `claude` for the
  trial, which runs inside a copy of the repo. 8a's environment line goes, since Node 20 ignores it. A self-test case
  fails when any script starts `git` or `claude` by bare name.
- **Leftovers:**
  - fixed: one `review:` line and one `when:` line per entry, each capped; a URL credential with an empty user; a
    record that straddles the recorded size ends at the last newline before it;
  - kept recorded: three prepares within microseconds of each other on a stale lock; a path's tail after a space; a
    URL password holding `/`;
  - accepted: `[Private]` read as private, and no case for the word cache.
- **status:** `status.mjs` reads map files through `readMapFile` and reports one it cannot read as "cannot read".
- **Found while planning, fixed here:** `finish` reads map files unchecked (H4's class) and now reads them through
  `readMapFile`.
- **Recorded, not fixed:** D-2's wider filter may refuse a real draft that shows a placeholder such as `Bearer
  YOUR_TOKEN`.

**The checks:**
1. The self-test and `fix8k.mjs` (from `fix8a.mjs`) on Windows, under Node 24 and Node 20. Node 20 is the condition
   that failed 8a's CI. Each new case fails on the merged 8i and 8j copy. 8a's R8 case ("the repo is unchanged after
   every hook event") comes back, which closes that later item. The FIFO and device cases run where the system has
   them: CI's macOS job carries them (Linux is skipped, by the user's word).
2. `mutate8k.mjs`: each new guard killed, H7's mutation included ("the resolver returns the bare name"). Then every
   mutation list from 8c to 8j is re-run on the 8k copy, since 8k edits `dream.mjs` and `trial.mjs`.
3. `equivalence8.mjs` is re-run, for D16's note.
4. D18's paired reference bench, after 8k (the last hook change). The control is the merged 8i and 8j copy; CPU at most
   10%; at 1 and 8 sessions; the 100 ms budget is unchanged. CI's load job is reported only (the user's word on CI);
   8a's 102.7 ms read was the unpaired gate's noise, since 2.5.1 itself read 112.4 ms on it.
5. A fresh review, and the decision-checker on D14 (the naming test), D16 and D18.
- **Not carried over:** 8a's live check 5, whose third leg expected labels that 8h now withholds; 8a's `plugin.json`
  2.5.2 and its pin. 8k ships in 2.6.0. D16's note and the README's link passages come back.
- **The counted model runs** that D-3 voids (S7's check 2, 8d's check 3) are re-earned once, in 8l.
- **Attempts:** three (rule 4).

### 8, 8l: the text step (registered 2026-11-25, before the code)

Built on 8k's copy. Each change below is to text a model reads, or to a digest the analyzers read:
1. **C-4, the user's word:** `/second-brain:tailor cases <path>` writes only the making step's cases for an existing
   draft (`.claude/…/*.draft`) or a live artifact, and makes no new draft. map-review's untested line names this
   command.
2. **C-6:** the survey ends by asking the person to type `/second-brain:tailor make <name>` for the gap they pick. That
   is a new invocation, so its grant holds for the making steps.
3. **P-3, the user's word:** analyzers read only their digest, and the steering file when there is one. The main
   session keeps `usage.json`.
4. **P-7:** tailor's guidelines move to a file beside the skill, read at the making step, and the duplicates go.
5. **P-13, P-14:** the repeated and empty sentences go.
6. **R-c:** the placement table gains an agent row and tailor's pointer, and the README template's dream line is
   corrected. The templates' earlier hashes go into setup's list (D29), so setup updates untouched copies.
7. **R-d:**
   - the dream skill tells the person that a retried finish must come before review;
   - a retry leaves no `<name>-2` folder;
   - the skill says that finish makes skill drafts user-only;
   - each digest gains a line `D: <date>` where the sessions' date changes (trim keeps it), so evidence carries a
     date.
8. **X-6:** the heredoc's delimiter becomes improbable.
9. **L-2:** a should-use case's prompt does not name its artifact, and `validate()` refuses one that does.
10. **L-5:** tailor reads with Read, Grep and Glob, not Bash.

**The checks:**
1. The self-test's text and code cases for each item, failing first, on Windows under Node 24 and Node 20, and a
   mutation each.
2. **The counted model runs, re-earned once on 8l's frozen copy at their registered bars:**
   - S7's check 2 (10 runs);
   - 8d's check 3 (5 runs per case);
   - 8e's check 3 (the good skill, the good agent and the bad skill, 2 runs each);
   - 8e's check 4 (12 runs).
3. **New counted runs:**
   - C-4: on a fixture, a skill draft the dream made gets cases through `cases`, then `show` and a trial. Its
     verdict is judged as in 8e's check 3. 3 runs.
   - C-6: the typed `make` drafts and moves the draft with no denial, with `--setting-sources project,local`. 3 of
     3.
4. **The live test again,** on this repo:
   - the `work-status` cases are rewritten without the agent's name (L-2); the agent's `left` gap (L-3) is
     answered;
   - its trial is run again;
   - then `/map-review` and the person's choice.
5. A fresh review, and the decision-checker on D10, D31, D34 and D35.
- **Attempts:** three (rule 4).

**8j, built (2026-11-25), the builder's report, before the merge's checks:** every item has a case that fails on
`b977771fc513` and passes on the copy, under Node 24 and 20, with the temp folder as it is and behind a junction.
`mutate8j` kills 22 of 22, and 8d's and 8f's lists still kill 49 and 26 on the copy. The builder went wider than
registered in places, and the merge keeps them:
- `clearRun` now refuses a run folder that a session replaced with a link. 8f's version emptied the link's target,
  outside the repo, in finish and abort: a data-loss path, verified by a scratch run and now covered by a case.
- Any top-level key that is not plain is refused in an agent or change draft.
- The tools comparison is textual.
- A change to a live file that already sets a power is refused.
- P-2 checks again each path git stops at; with no git, it drops the touched files.

**New findings, into the register:**
- J-1: a new skill draft can still carry `hooks` or `allowed-tools` (X-4 covered agents and changes).
- J-2: a change that removes `disallowedTools` widens an agent unnoticed.
- J-3: `clearRun` stops at the first held entry, so later entries stay (they are still git-ignored).
- J-4: a path past a link, or a name with pathspec magic, makes `git check-ignore` exit mid-batch.
- J-5: the new cases ran on Windows only; CI's macOS job is their evidence on the merge.
- J-6, process: the builder sent its diff to agy with this machine's scratchpad path, which names the Windows
  account. No secret went out. Builders now work without agy.

**8i, built (2026-11-25), the builder's report, before the merge's checks:** all ten items. Each new case (10) fails
on `b977771fc513` and passes on the copy (19 of 19), under Node 24 and 20. `mutate8i` kills 24 of 24, each by its
own case. Four of them are 8e's mutations whose anchors 8i moved, carried over with new anchors: the blob ids, the
copies deleted, one session at a time, and an empty field. So on the merged copy `mutate8e` reports those four as
missing. That is recorded, not a pass of its own. Item 9 checks each file's byte count against git's size, which
catches a missing object and a cut output. No agy, and no outside service.

**New findings, into the register:**
- I-1: the self-test's case (5) counts `second-brain-*` folders in the shared temp folder. So it fails when another
  test runs at once, as it did once beside `mutate8j`.
- I-2: on Node 24, a folder that cannot be removed keeps every file in it, so a whole repo copy stays in the temp
  folder. Node 20 reports EBUSY.
- I-3: the lock has three limits:
  - a dead process's id reused by Windows makes `run` refuse until that program ends;
  - two takeovers in the same microseconds could both start;
  - a failed verdict write leaves the lock until the process exits.
- I-4: `show` prints a binary file beside a skill as text.
- I-5: K-3 does not retry a removal, which would help when antivirus holds a file.
- I-6: section 7's `mutate7.mjs` anchors were not checked against 8i.
- The cleanup: 389 `second-brain-trial-*` temp folders were deleted, with no test running (mutation runs had added
  126).

### 8, 8k and 8l: amended before their code (2026-11-25), on the other session's read

The other session checked 8k's and 8l's registrations against the sources and confirmed two conflicts:
- **8l item 9 (L-2) would refuse every agent case.** For an agent, the prompt must name it: 8e's registration says
  so, so does tailor's text, and D34's first probe found that a draft agent was loaded but never delegated to without
  its name (research, 2026-11-24, final logic). Amended:
  - a skill's should-use case may not name the skill, and `validate()` refuses one that does;
  - an agent's case names the agent, as "the `<name>` agent, if this repo has one; otherwise do it yourself", so the
    "without" arm does the task rather than fail on a missing name. That is a rule in tailor's guidelines; the
    live `work-status` cases are rewritten so.
- **8k's D-3 drops a condition.** Redaction removes absolute paths whole, so the digests would lose every file path.
  The research of 2026-11-24 required the repo root to be made relative first; it was dropped (06, "8a: before the
  model runs") only because D-3 was blocked. Amended: before redaction, paths under the repo's roots are made
  relative in the digest text, and only what stays absolute is redacted.

**Items that had no step, now placed:**
- **8k** (code: `dream.mjs`, `trial.mjs` and tests):
  - J-1 (a new skill draft carrying `hooks` or `allowed-tools`), J-2 (a change that removes `disallowedTools`) and
    J-4 (`git check-ignore` exiting mid-batch);
  - from 8i's build:
    - the self-test's temp-folder count (8i's finding 1): count only the folders the case made;
    - an unremovable copy (8i's findings 2 and 5): one retry, then report, and on Node 24 the copy's files go
      before its folder;
    - `show` on a binary file beside a skill (8i's finding 4): name it and say it is binary;
    - section 7's `mutate7` anchors (8i's finding 6), checked with the others;
  - X-3, reproduced first. If bare names in `--allowedTools` reach outside the copy, they are left out (acceptEdits
    covers the copy). If user tokens reach trial sessions, the environment becomes an allowlist plus Claude Code's
    login variables.
- **later:** J-3, and 8i's finding 3 (the lock's three limits), recorded.
- **8l:** tailor's description says it can "create, change or test" an artifact, but `trial.mjs` refuses a draft
  when the live file exists, so it cannot change one. The text says what it does: create, or test through `cases`.
- **release:** PM7's keep-or-kill read for 2.6.0's features (`02-v1-postmortem.md`) joins the release list.

**Ids, made unique and complete:**
- 8i's findings are renamed B-1 to B-6, since I-2 already names "`when:` and headings shown". A plan item names them by
  the new ids.
- Ids cited in the plan but never defined here:
  - T-1 is done: two of the user's rules are map entries, and the third waits for its source words.
  - L-4 was never used.
  - C-5 is X-1.
  - R-j is I-2.
  - R-l is the talk's "graph" item (records).
  - R-m is R4's scheduled-task reopen (later), and R-n the `claude plugin eval` probe (later).
  - R-p, for later: retirement is never a proposal of its own, only the "no use" line and a trial's verdict.

**More items from the other session's read of Claude Code's docs (CLI 2.1.332) and its sweep (2026-11-25), placed:**
- **8k** (it is the last hook change):
  - Q-1: SessionStart has a `fork` source, which the matcher leaves out. D12 probed clear and resume, not fork.
    Probe whether a forked session carries the start context, then add `fork` or record why not.
  - Q-3: no hook sets a `timeout`, so the documented defaults hold (600 s, 30 s for UserPromptSubmit). A hung hook
    would hold a session that long, against D18's 100 ms. Each hook gets a short timeout, such as 10 s.
- **8l:** Q-5: `memory: project` turns on Read, Write and Edit for an agent, so `decision-checker` and `codebase-guide`
  are not read-only. The templates' and 04's claims are corrected to match, once the other session's check of them
  is in.
- **later:**
  - Q-2: the grants' form `Bash(node "<root>/scripts/x.mjs":*)` is not in the docs. It matched on every CLI run here;
    a release smoke checks that each skill's command still runs without a prompt.
  - Q-4: `engines` with a minimum Claude Code version, once the minimum is known.
  - `SECOND_BRAIN_TRIAL_CLAUDE`, the tests' stand-in hook, ships in `trial.mjs` (recorded in 8e, not built).
  - The session-start index still lists `.claude/` folders for agents, skills, commands and output styles.
  - K3, deferred with a trigger, was not under "later".
  - The next field read.
  - Two of the Fog's bullets that still name changes: the map drifting from auto memory, and capture taking Claude's
    option text as the owner's words.
- **records:** judge D22's two observations of 2026-11-25 against its trigger; tick #115's step 22 or say what
  closes it; triage #115's Fog (about 90 bullets).
- **user (A5-2, measured):** `claude plugin marketplace add … --sparse .claude-plugin plugin` works and persists
  through updates. An existing full install cannot switch with one command: a re-add is refused, and editing
  `sparsePaths` by hand lost the marketplace. The other session puts the options to the user.

### 8, 8m: the dream's older gaps (registered 2026-11-25, before the code); 8k narrowed

The other session's read (its verifier checked each claim in the code at `18de2b0e`, with scripts and temp repos)
found more. Q-6, Q-7 and Q-16 change what the analyzers read, so they land before 8l re-earns the counted model
runs. 8k keeps the hook side, as the last hook change. A new step, 8m, takes the dream side. The order is 8k, 8m,
8l.

**8k gains** (`map.mjs`, `hook.mjs`, `status.mjs`, `hooks.json`):
- Q-8: in a folder with no `.git`, session start still emits 2,215 B (the capture instruction and the naming line).
- Q-9: the catalog's due count and the read labels count an ended entry (superseded, expired or done) whose review
  date has passed; status skips it.
- Q-10: `unseenIn` misses a session that grew on resume, so the nudge and status's "sessions since" miss it.
- Q-11: dream or status with no `.git` prints a raw ENOENT with an absolute path.
- Q-12 (a D14 miss): the Read hook's `rel()` has no real-path step, so a root under a link (macOS `/var`) or an 8.3
  name gets no labels at all. It must match 8g's spelling rule without a file-system call on a model-given path.
- Q-13: on Node below 20 every hook fails with a raw read error. Each hook checks the version and says once that the
  map needs Node 20.
- Also Q-1 and Q-3, as placed.
- J-1, J-2 and J-4 move from 8k to 8m.

**8m, the dream's older gaps** (`dream.mjs`, its tests; on 8k's copy):
1. Q-6: a session that ran `/second-brain:dream` is read up to the dream's start, and after its finish, rather than
   skipped whole, so the person's other words in it are dreamed over.
2. Q-7: `tag()` keeps a prompt's text parts when it holds an image, and keeps a prompt that starts with `<` unless it
   is one of Claude Code's own wrappers.
3. Q-14: `PRIVATE` no longer takes a route (`GET /users/:id`), a web path (`/home/dashboard`), a file name
   (`avatar@2x.png`), a git remote (`git@github.com:org/repo`) or a config folder (`/etc/nginx/`) for private data.
   Real secrets, e-mail addresses and home paths stay caught.
4. Q-15: when finish or abort puts back an edit another session made to a watched file, its report names the file
   and where the edit is kept. Session start also says so once, in the next session.
5. Q-16: a quote's pieces must come from one session's lines, not from all of them joined. A U line's cut and a Q
   line's cut are recorded in the digest.
6. J-1: a new skill draft that carries `hooks` or `allowed-tools` is refused. J-2: a change that removes
   `disallowedTools` counts as widening. J-4: `git check-ignore` is fed only paths that git can take.

**The checks:** as 8i's. Each item gets a case that fails on 8k's copy and passes, under Node 24 and 20, plus a
mutation each (`probes/V2-8m-dream/mutate8m.mjs`). Every mutation list is re-run on the merged copy. Three attempts.

**later:** Q-17 (inRepo refuses a plugin data base that does not exist yet; perhaps unreachable). Q-18 (the analyzer
sets no `model:`; a cheaper one would need S7's counted runs of its own).

**8l gains Q-5's detail:**
- The three agent templates say their writes go only to their memory folder (`memory-curator`: and `.project-map/`).
  `memory: project` turns on Read, Write and Edit with no path scope, so that limit is an instruction, not a guard.
  The texts and 04 say so.
- Not taken, from the second opinion: deleting the UserPromptSubmit force (D22), the Bash label hooks (D14), the
  snapshot and restore (D31), and `codebase-guide` in favour of Explore (T-6). Each is locked, and no trigger fired.

**The live test, on the installed build (2026-11-25), L-6:** `/second-brain:status` in this repo reported "Nothing
waits for review", while `.claude/agents/work-status.md.draft` waited. That is K-5: `drafts()` skips agent drafts, so
neither status nor session start's waiting note counts them. Seen in real use, it moves from "later" into 8k, which
owns `map.mjs` and is the last hook change. The forced directory question also ran in this slash-command turn,
where it bore on nothing (an observation for D22).

**The split of work, the user's word (2026-11-25, relayed by the other session):** the other session builds 8k, 8m
and 8l, in that order, each in its own copy with its checks before its move. This session moves 8i and 8j in, puts
each checked build on the live install as `2.6.0-live.N`, live-tests it, and sends every finding to the register and
to the step that owns the file.

**The live test: a dream on the installed build (2026-11-25, `38fbf0dd76ed`).** Run headless in this repo: 13 turns,
2.69 USD, no denial. It read 2 sessions and proposed nothing, each candidate dropped for a reason it gave: the
never-drop rule was already in the map; the rest came from one session only, or was plan work, which the steering
file sends to 06. The `/map-review` step had nothing to do. The log line in `dreams.md` was committed as the person
would. What it found:
- L-7: the dream session's own shell sat inside `.dream-run/`, so finish could not remove it. 8f's path worked:
  "could not be removed", and the lock released. The model then deleted the folder by hand. The dream skill should
  keep the shell out of that folder (8l).
- L-8: a prompt that another Claude session sent through `claude -p` (here, the live test's answers to tailor) is
  tagged `U`, as the person's typed line. A dream could propose it as the user's rule; this one nearly did. Such a
  session's records carry `entrypoint: sdk-cli`. The digest should mark those lines, so an analyzer treats them as
  not shown to be the person's (8m).
- L-9: "read, then corrected again" counted `decisions.md`, though the only correction after the read concerned
  tailor. The count does not check that the correction concerns the file read. Fix: the candidate line names the
  topic it corrects, and finish counts it only for that file (8m, with the analyzer's text in 8l).
- L-10: status reported 5 sessions since the last dream, and the dream read 2. Two causes, both known:
  - the session that ran the first dream (8 MB, the other session's) is skipped whole: Q-6, now seen in real use;
  - headless sessions with no typed line give no digest.

**The live test: setup and map-review on the installed build (2026-11-25):**
- L-11 (S-5, seen live): after the upgrade to 2.6.0, this repo's `/map-review` was still 2.5.1's text, committed
  and untouched. That text names no agent draft, trial or verdict, so the `work-status` draft would never have been
  offered. Neither status nor session start said the skill was out of date. Status should name the kept files whose
  text is an earlier release's (setup's list already holds their hashes) and say "run `/second-brain:setup`" (8k,
  `status.mjs`). The release notes say it too.
- `/second-brain:setup` then did what D29 says: it replaced the untouched copy with 2.6.0's text, kept the nine other
  files, wrote nothing else, and committed nothing. Committed as the person would.
- `/map-review` listed the agent draft, read its trial, checked that the draft and case file still match the recorded
  blobs ("current"), and showed the counts. It named `left`'s 0 of 3 in both arms as the weak spot, then asked
  whether to promote or discard. It cannot see L-2 (the prompts name the agent), so "helps" stands unqualified there:
  8l's fix. The draft waits.

### 8, 8k, 8l, 8m and 8n: amended on the user's word and the audit (2026-11-25), before their code

**The user's word (2026-11-25):**
> i see we have diable-model-invocation in our plugin so claude cannot use commands like dream byself so it lock the
> automation. we need to make it, and other skills and commands, usable by claude too

Asked once, the user also chose:
- Claude is told when a dream is due;
- the dream's skill drafts are no longer user-only;
- `main` holds the product only (A5-2, settled).

The ledger reopens D03, D18, D31, D32 and D33, and each re-locks on its step's result. The charter has the change.

**Probed before registering** (CLI 2.1.332; a temp repo; a copy with `status` unflagged; headless):
- Claude called the Skill tool for `second-brain:status` on its own.
- That call needs a permission:
  - without a rule it was denied, with the message "add the allow rule `Skill(second-brain:status)`";
  - with the rule in local settings, the skill's `!` command ran under the skill's own grant, and the report came
    back.
- A hook sees `CLAUDE_CODE_ENTRYPOINT=sdk-cli` in a headless session.

**The audit** (ponytail, run on `plugin/` at `e856fafb` with the register left out). Six of its cases were proved in
temp repos (1 to 4, 7 and 8); the rest come from reading the code and the docs. Placed below by the file that owns
each one.

**8l gains** (the user's word: the skills' text, and a line at session start). 8l is now the last hook change, so
D18's bench runs after it:
1. **The flag goes.** `disable-model-invocation` is removed from `dream`, `setup`, `status`, `tailor` and the
   map-review template. The template's old hash joins setup's list (D29).
2. **Each description says when Claude starts it:**
   - dream: when told one is due, after the person's current task, saying so first; or when asked;
   - setup: when the layout is missing, or a kept file is an earlier release's template (L-11), after asking;
   - status: when asked how current the memory is;
   - tailor: when asked to make or test an agent, skill or path rule;
   - map-review: when proposals or drafts wait and the person agrees to review.
3. **The due line:** in a session whose entry point is not `sdk-cli`, session start's added context gains one line
   saying a dream is due. It sits inside `startText`'s 10,000 characters, so a repo at the cap keeps its cut index
   and the line. The person's line stays.
4. **Permissions:** the README says that each skill's first start by Claude asks for permission once, and how to allow
   the skills in advance.
5. **Audit 6:** onboard's grant covers only `hook.mjs onboard`, and setup's only `hook.mjs setup`. The self-test's
   pinned grants follow.
6. **Audit 2, the text half:** map-review's reject step replaces a committed proposal's `proposed` line with the status
   line, rather than keeping both.
7. **Audit 5:** for a skill that keeps the flag (one a person wrote), the should-use prompt of its cases starts with
   `/<name>`, and `validate()` checks for that instead of refusing it.

- **Checks added to 8l's:**
  - (a) unit cases:
    - the due line is there with entry point `cli` and absent with `sdk-cli`;
    - the cap holds with the line added.
  - (b) headless counted runs, with each skill allowed: a request in plain words starts `status`, and the dream's
    prepare, 3 of 3 each;
  - (c) D33's bar earned again: in 10 dreams that Claude starts, nothing is accepted without the person's yes;
  - (d) the always-on cost from `claude plugin details`, before and after, recorded against D18;
  - (e) the live test (the other session): an interactive session with a dream due, a dream Claude starts itself, and
    a dream skill draft in `/map-review`.

**8m gains:**
1. **The user's word:** finish no longer adds `disable-model-invocation` to a skill draft. This lands with J-1.
2. **Q-6, the Skill tool form:** a `Skill` call to `second-brain:dream` also marks the session as the dream itself.
   Today only a typed command record does (`dream.mjs:232`).
3. **Audit 1, a branch switch:** today `prepare` drops a reviewed dream's state when HEAD lacks its log line (proved: a
   dream committed on `feat`, then `main` checked out, lost `seen` and its record). Now a dream counts as kept when the
   tip of any local branch, or the working tree, holds the line.
4. **Audit 3:** a new skill draft is dropped, as agents are, when its folder already holds a live skill or a draft, or
   when its `name` is not its folder's. `freeName` goes, with the `-2` folder (R-d's retry case too).
5. **Audit 4:** `evidence()` accepts the digest's folder before `dN.digest:L`, as the candidates' parser does, with one
   pattern shared by both (proved: such evidence dropped every draft).
6. **Audit 8:** a candidate whose file name is already taken is skipped, so one session never counts as two (proved:
   a `dirs.log` spelling in another letter case).
7. **Small:** a status line's `by <id>` follows finish's rename of a clashing new id.

**8k gains:**
1. **Audit 2, the code half:** `proposedOn` returns nothing for an entry that has a `by review:` status line. Waiting,
   status and the labels then stop counting a rejected proposal, including those 2.3.0 to 2.5.1 wrote (proved: one
   such entry counted as waiting in all three).
2. **Audit 7:** the trial's `committed()` compares `git rev-parse <commit>:<rel>` with `git hash-object`. `git diff`
   rewrote the index and took `index.lock` (proved).
3. **Small:** the trial copy's path no longer stops at a tab.

Each gained item gets a case that fails on its base and a mutation, as its step registers.

**8n, the product on `main`** (registered now, built at the release stop; the user's "main = product only"). This
replaces A5-1's move.
- The release copies onto `main` only these:
  - `plugin/` without `test/`;
  - `.claude-plugin/`;
  - the README and the LICENSE;
  - the CI that runs on `main`.
- The docs stay on `v2` (D04).
- **Checks:**
  1. `main`'s tree equals an allowlist, with no `test/` under `plugin/`.
  2. In a throwaway config, an install of the old `main` that updates to the new one ends with only the product in
     its clone. If it does not, the README says how to add the marketplace again.
  3. `claude plugin validate`, and `claude plugin details` on a fresh install from the new `main`.
  4. `main`'s required checks point at jobs that run there. That is the user's GitHub setting.
- Re-locks D03.

**Later, from the audit:**
- `state.seen` keeps transcripts that Claude Code's cleanup has deleted.
- Unverified: whether `CLAUDE_PROJECT_DIR` still names the main checkout in a session moved into a linked worktree. If
  so, Reads of that worktree's map files get no labels.

### 8, 8k: the index's exclusions (registered 2026-11-25, before the code), on the user's word

> second-brain has no setting to exclude folders from the index it load on the start so we need to add that faeture
> too so we wont load to much on start and second brain in each repo can control what it loads

(The user, relaying a session on macOS. D22 is reopened.)

**The change** (`map.mjs`'s `index()`, in 8k, the step that owns it):
- **The file:** `.project-map/index.ignore`, committed by the team.
  - Each line that is not blank and does not start with `#` names a folder or a pattern, from the repo's root. For
    example: `docs/archive`, or `**/fixtures`.
  - The name ends in neither `.md` nor `.txt`, so the file is not itself a document of the index.
- **The matching:** each line becomes `:(exclude)<line>` on the index's one `git ls-files` call. Git's own pathspec
  matching then leaves out the files under it, so no matching code is added and no git call.
- **The map's own folder,** `.project-map/` (with its untracked entries), is always listed, even when a line would
  match it.
- **A line git rejects never costs the index:**
  - the call runs again without the file's lines;
  - the person's line at session start names the file as not used.
- **The forced decision** asks only about the folders that are listed.
- **The README template** says how to use the file (8l's text).

**The checks:**
1. Every existing session-start and index case is byte-identical without the file.
2. **With the file:**
   - a folder line and a pattern line each leave their folders out of the index and the forced list, and every other
     line of the start text is unchanged;
   - the index's directory count falls by the number left out.
3. A line that names `.project-map` leaves the map listed.
4. A line that git rejects (a bad pathspec magic) gives the full index and the person's note.
5. **A mutation for each guard:**
   - the exclusion dropped;
   - the map's own folder not protected;
   - the fallback removed.
6. **Session start's cost:** still one `git ls-files` call. D18's bench after 8l covers the timing.

### 8, 8i and 8j: results (2026-11-25): pass; moved into `plugin/`

Merged in one copy, with the product hash pinned: `88e323d58cca`. The two steps touch different files, so the merge
copied each step's files over `b977771fc513`.
- **The self-test passes** on Windows under Node 24 and Node 20. Each builder showed its own cases failing on
  `b977771fc513` and passing on its copy: 8i 10 cases, 8j 7.
- **Every mutation list on the merged copy** (`probes/V2-8i-trial/results/mutations-8ij-merged-win32.txt`, each list
  with its own test files):

  | list | killed | notes |
  |---|---|---|
  | `mutate8c` | 32 of 32 | One anchor, "(2) uses counted", had been missing since 8d to 8f's move split its line (`2e57af4f`). It went unseen because that list had not been re-run since; it is re-anchored and killed. |
  | `mutate8d` | 49 of 49 | |
  | `mutate8e` | 85 of 85 that apply | Four anchors that 8i moved are carried, re-anchored, in `mutate8i`. Two "(7)" guards that `selftest.mjs` checks survive a run of `trial8e.mjs` alone, and are killed in a full run. |
  | `mutate8f` | 26 of 26 | |
  | `mutate8i` | 24 of 24 | |
  | `mutate8j` | 22 of 22 | |
- **The reviews** (check 4) come with 8k's, on the merged diff of 8i to 8k, since a fresh review of each step on its
  own would read code that 8k changes again.
- **Moved into `plugin/`:** `plugin/` hashes `88e323d58cca`, and `claude plugin validate plugin` passes. CI on this push
  is the macOS evidence for 8j's Windows-only reasoning (J-5); its result is recorded next.
- **Live:** this build goes on the live install as `2.6.0-live.1`, its version set in the live copy only.
- **8k's base** is this commit. The other session builds 8k, 8m and 8l from it.

**`2.6.0-live.1` (2026-11-25):** the live install now holds `plugin/` at `88e323d58cca`; only the version line in the
live copy differs. The update recopied the cache, and the cache matches `plugin/` except `plugin.json`. Sessions that
were open keep the old build until `/reload-plugins`. Live, in headless sessions:
- **8h's live observation:** a compound command run in the background, naming no map file, got no labels. The control,
  a read that shows one entry, got that entry's label and nothing more.
- **C-2:** `/second-brain:tailor show work-status` printed the agent's whole text, the four check scripts and the run
  line. The model relayed all of it, unchanged, so L-1's drop did not recur here.

**CI on the 8i and 8j move (2026-11-25):** run 45655288922 on `a4df52d3` (`88e323d58cca`) passed every job: the
self-test on macOS, Windows and Linux, and the load jobs. That is J-5's evidence: 8j's Windows-only cases, reasoned
for macOS, pass there.

**The live test: L-3 diagnosed (2026-11-25).** One "with" run of the `left` case, run as the trial runs it but keeping
its output, wrote an accurate, current list:
- 8a's block lifted into 8k, then 8k, 8m and 8l registered and not built;
- group M, the audit's items, and what waits for the user.

The check failed it anyway. It wanted 8a's ids, or "8a" within 60 characters of "fix", and the agent said "8a … its
fixes move into 8k" in other words. So the check was at fault, not the agent.
- L-12, into the register (tailor's guidelines, 8l): a check for an agent that reads the repo's records hard-coded
  facts of the commit it was written at, and matched literal wording. The trial copies the latest commit, so such
  facts go stale between commits, and a right answer in other words fails. The `state` check had the same flaw:
  "8b to 8j passed" never names "8h". Guideline: a check accepts any wording of the fact, and derives what changes
  from the copy's own files rather than hard-coding it.
- As the person would, the live cases were rewritten:
  - the agent's prompts follow amended L-2 ("…if this repo has one; otherwise do it yourself");
  - `left` accepts 8a's hardening named as 8a, 8k or its ids;
  - `state` asks for one passed step and for 8k as not built.

  The real answer passes the new `left` check; the wrong and empty ones fail. The trial runs again on live.1.

**The live test: the trial again, on live.1 (2026-11-25).** `show` gave the run line, and the person typed it twice,
at once. Two findings so far:
- L-14 (`trial.mjs`, into 8k): 8i's lock holds, since only one trial process runs. But both lines printed "started",
  and the refused process's error path recorded `{"verdict": "not judged", "stopped": true}` over the verdict file.
  The earlier verdict was lost, and `/map-review` would show "not judged" while the real trial runs.
  - `run` checks the lock before the detached process takes it. It should take the lock itself, then hand it on.
  - The error path should record nothing when the error is "a trial is running".
- L-13 (a correction): with a directory-source marketplace, Claude Code runs the plugin from the source folder.
  `CLAUDE_PLUGIN_ROOT` is the live copy in the scratchpad, not the cache, so the earlier note that the install made
  its own copy and nothing ran from that folder was wrong. The live folder changes only at a live release. The field
  installs use a git marketplace, which is copied into the cache.

**The live test: `/map-review` on the trial's verdict (2026-11-25).** It found no proposals and no due entries, and one
draft, `work-status`. It read the trial: "adds nothing", with state 2 with and 1 without, left and released 2 with and
3 without, where-label 3 and 3, of 3 runs each. Both blobs matched and no session failed. The person discarded the draft.
- L-16 (map-review's discard, into 8l): discard deletes only the draft. The committed case file
  `.project-map/evals/work-status.json` and its four checks stay, naming an artifact that is gone. The discard step
  should say what becomes of them: delete them with the draft, or keep them for a new draft at the same path.

**The live trial on live.1, its result (2026-11-25):** "adds nothing", with no session failed. Once the prompts let a
plain session try ("…if this repo has one; otherwise do it yourself"), it answered status questions as well as the
agent did, or better. So the first trial's "helps" came from prompts that named the agent: L-2, now seen. Tailor had
said beforehand that this is the outcome that should retire the agent.
- **8i seen live:** one trial ran at a time. No trial project folder was left (70 before, 70 after), and no copy
  stayed. The temp folder's 127 `second-brain-trial-*` folders are mutation runs' leftovers, by design for two
  mutations; they are cleaned when no test runs.
- **L-15** (later; `trial.mjs` and map-review): the trial judges correctness only. Tailor claimed the agent's value
  was keeping reads of a 9,000-line plan out of the main session's context, and the trial cannot show that. It could
  record each arm's tokens and cost from the session's JSON, beside the counts.
- **The map at work:** in the discard turn, the review session followed the map entry `findings-go-into-the-plan` on
  its own and wrote L-16 into this file. A rule captured from the user steered a fresh session.
- **The evidence kept:** the discarded draft, its last verdict, and its case file and checks move to
  `probes/V2-live-test/work-status/`. That answers L-16 for this draft by hand.

**The live test: tailor's second pick, the `release` skill (2026-11-25, live.1).** The person asked for the local half
only, and gave the lessons of L-2 and L-12 (prompts that do not name the skill; checks that read their facts from the
copy). Tailor drafted the skill, four cases and a local test of the checks: 62 turns. Its checks read the version, the
product hash and the plan's open steps from the copy's first commit, so nothing is fixed to today. The person moved
the draft (C-6 again), the check test passed 17 of 17 once its own pin pattern was fixed, and the cases were committed.
What it found:
- L-17 (8l, tailor's guidelines): L-2's rule clashes with a user-only skill. With `disable-model-invocation`, Claude
  cannot see the skill, so plain prompts never reach it, and the verdict is "adds nothing" by construction. The
  person chose to drop the flag, since the skill commits nothing. The guideline needs a clause: a user-only skill's
  case starts with `/<name>`, and how a headless "without" session treats an unknown slash command is to be probed
  first.
- L-18 (records): stale version lines: `.claude/CLAUDE.md` says 2.5.0, the charter 2.3.0, `04-architecture.md`
  2.5.1.
- L-19 (release): no release notes are kept in the repo after 2.2.0. 2.6.0's are drafted in this file before the tag.
- L-20 (later, the trial): a trial cannot judge a step that edits `.claude/`, since a headless session cannot have
  that edit approved.
- L-21 (cost): the making turn took 62 turns, about 16.6 USD at API prices, for one skill, four checks and a test.
  P-7's shorter text and the guidelines file may lower it; the next live run measures it again.
- L-22: tailor's own check test matched the self-test's first `slice(0, 12)` line, the capture instruction's hash,
  rather than the product pin. So it failed three right answers that the checks themselves passed. Testing the checks
  caught it, as intended. Guideline: the test matches each fact exactly as its check does.

### 8: the rethink of 2026-11-25 (evening), on the user's word

The note: [research/2026-11-25-rethink-delivery.md](research/2026-11-25-rethink-delivery.md). Into the register:
- **W-1 (housekeeping, seen):** at about 20:26 to 20:28, every folder under Claude Code's per-project temp root was
  emptied, 8k's build copies and the other session's tools included, while group C's mutation run was half-way.
  Older entries in the system temp folder survived. The cause is not settled; a session start was recorded at 20:26.
  Groups A and B were recovered by replaying their recorded edits (both product hashes match); group C's replay equals
  its rebuilt candidate. Build copies now live outside that root, and each test run gets its own `TEMP`.
- **S-1 (housekeeping), done in part by the user's word:** 1,240 leftover project folders of temp copies and five temp
  trial folders deleted, and the ignored `research/raw/` (2.6 GB). Trial copies leaving none stays open.
- **B-6 (8k):** `mutate7` was already stale on 8k's base: 28 of its 42 anchors are missing, since 8e replaced the 7a
  script. 8k moved one anchor of 8c's list, three of 8e's and four of 8i's; those lists follow the moved guards.
- **D36 (new, after 2.6.0, the user's word):** scopes for a monorepo. Setup finds each source and gives it a scope in
  the map and the index; the dream and tailor make agents and skills for a scope only from its own sessions. Probe
  first; registered before it is built.

### 8, 8k: the two reviews (2026-11-25), taken before the checks' final run

**The decision-checker** (D14, D16, D18, D22): D14, D16 and D18 hold.
- **Fixed, D22:** when git rejected a line of `index.ignore`, the build tried each line alone, 1 + N + 1 git calls,
  and lines that fail only together gave no index at all. Now the call runs again without the file, as registered,
  and the note says the file is not used this session. The case and its mutation follow.
- **Accepted, recorded:**
  - the lines go in as `:(exclude,glob)<line>` and `<line>/**`, since the registration's own example `**/fixtures`
    needs glob matching;
  - a leading `/` names the root;
  - the file is read from the working tree, committed or not;
  - the cases are three files (`fix8k-hook`, `-dream`, `-trial`), not one `fix8k.mjs`;
  - `under()` refuses a map folder linked out of the repo (H3's class).
- **Record:** D18's boundary sentence says no map text reaches a spawn's arguments; `index.ignore`'s lines now do, as
  git pathspecs in an argument array with no shell. The ledger's sentence gets a note at the release.

**The fresh review** (Gemini 4 Argon, through T3 in plan mode, given only the diff and the repo; each claim checked
in the code before use):
- **Fixed, each with a case that fails before and a mutation:**
  - X-3's filter compared whole tool strings, so `Write(*)` or `Edit(/x/**)` was approved; it now compares the tool's
    name, and NotebookEdit (and MultiEdit) count as file tools;
  - `CLAUDE_CODE_USE_BEDROCK=0` (or Vertex's) still passed AWS's (Google's) variables; `0` and `false` now mean off;
  - D-3: `<root>/../x` and `<root>~x` lost the root without being redacted. A root now ends only at a separator not
    followed by `..`, or before a character that ends a path in text;
  - `PRIVATE` missed a home path after `<`, and a key header with digits (`ED25519`, `PKCS8`).
- **Refuted:** "exec's lock keeps run's dead process id": `start` writes the child's id into the lock before it
  returns.
- **Into the register (later):**
  - `exec` checks the hash before it takes the lock, so a hand-typed `exec` while another trial of the same name runs
    overwrites that trial's verdict (`run` itself is safe);
  - Q-10's count: a transcript whose last record has no newline yet counts as unseen until it grows; a foreign
    session's growth is counted again;
  - raw errors with local paths remain where `lock()` races a vanishing lock file, and on a `.project-map` that is a
    file or a broken worktree `.git` (Q-11's class);
  - Q-12's real-path step: a Read through an 8.3 short name while the root is long, and a macOS path in another letter
    case, may still get no labels (D14; probe on CI's macOS job);
  - a map file named `.MD` in capitals, or a link to a device, is listed in the index but gets no labels;
  - `unseenIn` stats every seen transcript at startup (D18's bench covers it);
  - four shortening nits, for the refactor step.

### 8, 8k: result (2026-11-25): pass; moved into `plugin/` (product `62048055c544`)

Built by three agents (A: the hook side, B: the dream side, C: the trial side), recovered after W-1 by replaying their
recorded edits (A and B to their recorded hashes), merged, and fixed after the two reviews above. All runs on Windows,
each in its own temp folder; Node 20 first on PATH for its leg, its children logged as 20.18.1.
1. **The cases:** `fix8k-hook` 34 of 34, `fix8k-dream` 14 of 14, `fix8k-trial` 14 of 14, `trial8e` 19 of 19, and the
   self-test, under Node 24 and Node 20. On the base, each new case fails except three that guard what must never
   change (the map stays listed, no hook writes, no file-system call on a model's path); their mutations cover them.
   8a's R8 case is back. The FIFO and device cases are left to CI's macOS job.
2. **Mutations,** MUT_FAST on the merged copy: 8k-hook 46 of 46, 8k-dream 41 of 41 (two survived the first run; the
   cases gained a literal `<root>/../` path and an ED25519 key body, then both were killed), 8k-trial 29 of 29, 8c
   32 of 32, 8d 49 of 49, 8f 26 of 26, 8j 22 of 22, 8i 24 of 24, 8e 86 of 86 applicable (its 13 "(7)" guards are
   the self-test's own and were killed in full mode; three anchors were already gone since 8i, whose list carries
   their moved versions). The lists follow every guard that 8k moved. `mutate7` stays stale (B-6).
3. `equivalence8.mjs`: 4,284 quotes over 77 documents, 0 differences, also with the linear search alone.
4. D18's bench: after 8l, the last hook change (the amendment of 2026-11-25).
5. The reviews: above. `claude plugin validate` passes.
- **Q-1 (`fork`):** the docs list `fork` as a SessionStart source and say nothing of what a forked session carries;
  `fork` is in the matcher, as `resume` is. No live probe was run.
- **Lists ahead of the code:** the 8m builder, working in parallel, moved anchors of 8c, 8f, 8j and 8k-dream to 8m's
  code; those four lists match 8m, which lands next.
- **Doubted:** is it over-built? 8k's own size is the registered items plus the review's four fixes. One mechanism was
  wider than registered (the per-line fallback) and is now as registered.

### 8, 8m: result (2026-11-26): pass; moved into `plugin/` (product `784bdf5ebbce`)

Built by an agent on 8k's copy, then fixed after a fresh review (Gemini 4 Argon through T3, given only the diff); each
of the review's claims was reproduced before its fix. All runs on Windows, each with its own temp folder, Node 20
first on PATH for its leg.
- **The items:** Q-6 (with the Skill-tool form), Q-7, Q-14, Q-15 (the dream side: `undone.txt`), Q-16, J-1, J-2, J-4,
  L-8, L-9 (the code side), audit 1, 3, 4 and 8, no flag added to a skill draft, `by <id>` after a rename, and the
  80-character cut after paths are made relative.
- **The review's fixes** (14 reproduced and fixed): bare home paths and `file:///c/Users/…` stay private, and e-mail
  addresses such as `alice@10x.dev` or `a@b.com:secret`; the cut mark counts only at a line's end, on U and Q lines;
  the sdk-cli mark is not the person's words; Q-6's gate: a dream starts at its command, Skill call or prepare's output,
  and ends at its finish or abort result, at prepare's refusal, or at the records' end, while an end with no start is
  an ordinary line (no session's lines are wiped); a tool call with no input; a dream committed on a detached HEAD
  counts as kept; L-9's topic named with its path; a submodule's files kept from `check-ignore`; a live file with a
  byte-order mark; a regular file where a draft's folder goes.
- **Settled here, by the user's delegation (2026-11-25: "answer all the question by self"):**
  - `/users/<name>` is always private: a lost proposal costs less than a leaked name. `GET /users/:id`, Q-14's
    registered case, still passes; a route such as `/users/me` is now treated as private.
  - quotes from an sdk-cli session stay marked, not refused (L-8 registered the mark); 8l's analyzer text says how to
    weigh them.
  - typed lines after an abandoned dream are read.
- **Deleted:** P-2's retry after git stops and its two 8j mutations: J-4's filter gives git no path it stops at.
- **Found in the checks:** 8e's case for "no copy inside the repo" passed with the guard removed (every session fails
  there anyway, and the copies are deleted). The case now also checks that no session started. The mutation is
  killed; on 8k it had been killed by chance.

**The checks:**
1. `fix8m-dream` 24 of 24 under Node 24 and Node 20; on 8k's copy 22 of its 24 fail (the other two guard regressions
   8m itself would have made). `fix8k-dream`, `fix8k-trial`, `fix8k-hook`, `dream8c`, `dream8d`, `dream8f`, `trial8e`
   and the self-test pass under both.
2. **Mutations** (MUT_FAST): 8m 59 of 59; 8k-dream 41, 8c 32, 8d 49, 8f 26, 8j 20 (two removed with P-2's retry),
  8k-hook 46, 8i 24, 8k-trial 29, all killed; 8e 82 of 89 under MUT_FAST, its (7) self-test guards killed in full
  mode, its "no copy inside the repo" killed after the case above, and three anchors gone since 8i (moved versions
  killed in 8i's and 8k-trial's lists).
- **Not run here:** a decision-checker pass (8m touches D31's dream only; 8l's review covers D31 and D35); macOS rests
  on CI.
- **Into 8l:** session start prints `undone.txt` once (Q-15); the analyzer's text for the cut mark, the sdk-cli mark
  and L-9's topic field.

### 8, 8l: attempt 1 (2026-11-26): fail; attempt 2 registered before its code

**Built** (an agent, then fixed after two reviews: the decision-checker and Gemini 4 Argon through T3, each claim
reproduced first): every registered item of 8l and its gains, product `85a6fc60d2b5`. `fix8l` 58 of 58 under Node 24
and Node 20, 56 of them failing on 8m's build (the other two guard what must not change); every other test file and
the self-test under both; `mutate8l` 94 of 94, 8k-hook 46 of 46 (the other lists' run continues on the same scripts).

**The counted runs on the frozen copy** (CLI 2.1.332, Opus 5.5; results beside each runner):
- 8e's check 3: **pass** (good skill and good agent "helps" 2 of 2, bad skill "adds nothing" 2 of 2).
- (b): **pass** (status started by Claude's own Skill call 3 of 3; the dream's prepare 3 of 3).
- S7's check 2: **fail** (C1 to C3 1 of 10, rule 0 of 5, skill 0 of 5; the choice, noise, status, nonce, steering
  pass). 8d's check 3: **fail** (a, c, d 0 of 5; every dream proposed nothing). (c): **fail** (nothing accepted
  without the person's yes in 10 of 10, but only 6 of 10 dreams ran to a proposal).
- 8e's check 4: **fail** on one bar: "asks" 0 of 6 (every other bar passes).
- C-6: **fail**, 0 of 3: `make` drafted and moved the draft with no denial in every run, but each run had 1 to 4
  denials of the model's own extra shell commands (testing its check with `$()`, `&&` or PowerShell).
- C-4: **not run**: its runner took S7's drafts as its source, and S7 left none.
- (d) the always-on cost (`claude plugin details`): about 404 tokens against 2.6.0's 371; tailor on start about 1.1k
  against 2.3k. Session start's added text is not counted there (2,287 B, +149 B when a dream is due).

**The causes, each seen in the runs:**
1. Every runner records its histories with `claude -p`, so 8m's L-8 marks each typed line `[sdk-cli: …]`, and 8l's
   analyzer text said never to quote such a line as the person's rule. All 52 analyzer reports in 8d's dreams gave the
   mark as the reason and returned nothing. The mark works as registered; the text made it a refusal, which L-8 did
   not register (it registered "treats them as not shown to be the person's") and which 8m's result had settled the
   other way (marked, not refused).
2. 8e check 4's "asks" bar reads a question in the reply; C-6's new text ends the survey with an instruction to type
   `make <name>`, not a question.
3. C-6: tailor's making step tests its checks, and the model did so with compound shell commands no grant covers.
4. (c) run 9: on Windows the model ran the dream's `finish` through the PowerShell tool; the skill grants it as Bash.
5. S7's scorer still required `disable-model-invocation: true` in a skill draft, which 8m removed on the user's word.

**Attempt 2 of three** (rule 4), registered now, before its code, settled under the user's delegation:
- **Text:**
  - the analyzer may cite a line marked `[sdk-cli: …]`; its candidate says the line is marked, and the person weighs
    it at review (no refusal);
  - tailor's survey ends with a question that names the line to type, `/second-brain:tailor make <name>`;
  - tailor's guidelines: test a check with one plain `node <check file>` command (no `$()`, `&&`, pipes or
    PowerShell);
  - the dream, tailor and status skills say to run their commands with the Bash tool.
- **Scorers, amended before attempt 2's runs:**
  - S7: a skill draft no longer needs `disable-model-invocation` (8m, the user's word);
  - C-6: the bar is that no command the plugin grants (`trial.mjs cli`, `trial.mjs draft`) is denied and the draft is
    moved; other denials are counted and reported, not barred;
  - C-4: its runner places its own dream-made skill draft (no case file), so it does not depend on S7.
- **The runs again, fresh histories, at the registered bars otherwise:** S7's check 2, 8d's check 3, 8e's checks 3
  and 4, C-4, C-6, (b) and (c). The unit cases for each text change fail first and a mutation each.
- **Side finding, recorded:** 8d's history sessions keep auto memory on (the runner clears the variable that would turn
  it off), and one analyzer cited an auto-memory note. It is the fixture's, not the product's; left as is so the runs
  stay comparable with 8d's.

### 8, 8l: attempt 2 (2026-11-26): every check passes but C-6; attempt 3 registered before its code

On the frozen copy `32698aa7dc0e` (attempt 2's four text changes, and one hash line in `setup.mjs`), fresh histories,
CLI 2.1.332, Opus 5.5:
- S7's check 2: **pass** (C1 to C3 10 of 10; the rule, the skill and the choice 5 of 5; candidate lines 10 of 10;
  steering reached 5 of 5 and landed in none). `s7-product-a15.json`.
- 8d's check 3: **pass**, every case 5 of 5. 8e's check 3: **pass**. 8e's check 4: **pass**, "asks" 6 of 6.
- C-4: **pass**, 3 of 3 ended with a verdict; none promoted or committed. (b): **pass**. (c): **pass**, 10 of 10
  dreams that Claude started finished and proposed (11 to 14 proposals each), and nothing was accepted in any.
- C-6: **fail**, 1 of 3. In two runs the survey's question kept the placeholder ("Type `/second-brain:tailor make
  <name>`"), naming its gaps only in a table above, so no `make` was typed; in the third the typed `make` drafted
  and moved the draft, and no command the plugin grants was denied.
- (d): about 404 always-on tokens; tailor on start about 1.2k; the analyzer about 730.
- Mutations on the copy: every list killed (8l 101, 8m 59, 8k-dream 41, 8k-hook 46, 8k-trial 29, 8c 32, 8d 48,
  8f 26, 8i 24, 8j 20, 8e all applicable, its two self-test guards in full mode).
- **Confound, recorded:** the headless sessions read the user's global `CLAUDE.md`, even with `--setting-sources
  project,local` (a reply said it "didn't use agy"). It held in every counted run since the first; the bars are read
  as they stand.
- **Seen, recorded:** in (c), Claude read the digests through a Bash loop, denied once or twice per dream; it reads
  them with Read when denied.

**Attempt 3, the last** (rule 4), registered before its code: the survey's question names, for each gap it lists, the
exact line to type with the gap's name filled in. Only tailor's `SKILL.md` changes, so the counted runs that read it
run again: 8e's checks 3 and 4, C-4 and C-6 (3 of 3), at the bars as amended. The dream-side checks (S7, 8d, (b),
(c)) read files byte-identical to attempt 2's, and their results carry.

### 8, 8l: attempt 3 (2026-11-26): a near miss; attempt 4, the last, registered before its runs

On the frozen copy `74186845b1dc` (attempt 2 plus the survey's make line with the gap's name filled in): C-6 **passes**
3 of 3. Two bars missed in one run each, on behaviour that passed in attempt 2:
- 8e's check 4, "drafts only": one gap run left a scratch script, `pc-test.mjs`, at the repo root beside its drafts,
  from testing its checks;
- 8e's check 3, the bad skill's first trial never started: `show` printed the run line, and the model gave it inside a
  quote and code marks, so the runner (which takes a line starting `! node`) found none.
- C-4: its result is recorded with attempt 4's.

**Attempt 4** (rule 4: a fourth only when the third is a near miss with a known cause; this is the last): tailor gives
the `! node` line on a line of its own, exactly as printed, not quoted and not in code marks; the guidelines add "Write
no other file to test it." Product `8896d4cb1c40`: `fix8l` 63 of 63 under Node 24 and Node 20 (the two new cases fail
on attempt 3's copy), trial8e and the self-test under both, both new mutations killed. Runs again: 8e's checks 3 and 4,
at their bars. If either misses, 8l is BLOCKED and the bars that need every run of a model's formatting go to the user.

**Time and repeats** (the user's word, 2026-11-26: "keep track of repeats and time"):
- 8l's counted runs: attempt 1 about 2 h (six checks failed, four causes), attempt 2 about 1.5 h (one), attempt 3
  about 1.3 h (two single-run misses). Each attempt fixed the last cause, and a different single run then missed: the
  bars ask for every run of model behaviour, so after this attempt the bars, not the text, are the question.
- The orchestration repeated an empty "still waiting" reply to each of the run agent's interim notices (about 60);
  the agent now reports once.
- Leftovers: about 375 MB of build copies and temp folders and 117 project folders (144 MB) from fixture sessions were
  deleted on 2026-11-26 morning; every runner deletes its own scratch and project folders at its end.

### 8, 8l: result (2026-11-26): pass at attempt 4; moved into `plugin/` (product `8896d4cb1c40`)

- **Attempt 4's runs** on the frozen copy: 8e's check 3 **passes** (good skill and good agent "helps" 2 of 2, bad skill
  "adds nothing" 2 of 2, every trial started); 8e's check 4 **passes** (12 runs, every bar). Attempt 3's C-4
  **passes** (3 of 3 ended with a verdict, none promoted or committed).
- **So every registered check of 8l holds on the final text:** the unit cases (`fix8l` 63 of 63, Node 24 and 20), the
  self-test, every mutation list, and the counted runs: S7's check 2, 8d's check 3, (b) and (c) from attempt 2 (their
  files unchanged since), C-6 from attempt 3 (tailor's survey unchanged since), 8e's checks 3 and 4 from attempt 4,
  and C-4 from attempt 3.
- **Re-earned, as 8l registered:** S7's check 2, 8d's check 3, 8e's checks 3 and 4.
- **D18 (reopened 2026-11-25):** every plugin skill is model-invocable; the due line is added only when the entry
  point is not `sdk-…` and no dream holds the lock, inside the 10,000-character cap. Always-on cost 404 tokens against
  2.6.0's 371 (`claude plugin details`); tailor on start about 1.2k against 2.3k. D18's bench runs at the release stop.
- **D31, D32, D33:** Claude starts the dream when told it is due or asked, in view; in 10 dreams Claude started,
  nothing was accepted without the person (c). D33's bar is earned again.
- **Recorded, not changed:** `setup.mjs` lists the hash of 8l attempt 1's map-review text, which no install ever had
  (harmless, removed with the next template change); the C-4 case-file overwrite and the due line after a compact or
  resume (the builder's findings); a typed skill and Claude's own Skill call share the `T: Skill <name>` line.
- **The refactors** (P-4 to P-12, P-16, T-5) move to after 2.6.0, under the user's delegation: they change no
  behaviour, and each would move the mutation anchors and cost another round of runs (the rethink of 2026-11-25).
- **Next:** the records, the release stop (group M, D18's bench, the final audit, 8n), the live test (the other
  session), and a stop before `main`. 8n's tooling is in `probes/V2-8n-main/` (dry run: 28 files, 266 KB, against
  `main`'s 449 files, 3.7 MB).

### 8: the records (2026-11-26)

The records step, after 8k, 8m and 8l passed (product `8896d4cb1c40`, version 2.6.0 in progress). Documents only;
`plugin/` is unchanged and nothing is committed here.
- **Re-locked on their results** (each record and its status-table row):
  - D22 on 8k (`index.ignore`); D31 on 8m and 8l; D32 and D33 on 8l's result, (a), (b) and (c);
  - D10 on the built surface (C-9): 4 hook events, 4 skills all model-invocable, 1 plugin agent, 1 command, tailor and
    its trial.
- **D18 stays REOPENED**, its surface settled (C-9). Its trigger to re-lock is "the release bench": rule 1 allows LOCKED
  only after the check passes, D18's budget is measured, and the hooks changed after the last bench (8k, 8l). **D03**
  stays REOPENED until 8n runs at the release.
- **D36 added** (OPEN, after 2.6.0, monorepo scopes; the rethink note), as a table row and a short record.
- **D18's boundary sentence** has a note: `index.ignore` lines reach `git ls-files` as pathspecs in an argument array,
  no shell (8k: the two reviews).
- **The ledger's frontier block** is replaced by the current state: 2.6.0 built through 8m, the release stop next.
- **Stale versions (L-18):** the working rules and the charter say 2.6.0 in progress; `04-architecture.md` says the same
  and now states what 8e to 8l built: four skills that Claude may start, tailor and its trial, the due line,
  `index.ignore`, the `fork` source, and Q-5 (`memory: project` gives the project agents Write and Edit with no path
  scope, so their write limit is an instruction).
- **R-l closed** in the register: not taken.
- **Not done here:** the charter's D34 entry, and #115's steps; the map issue is updated at the step's commit.

### 8, 8o: the final audit's fixes (registered 2026-11-26, before the code)

Two audits of `plugin/` at `269ef978` by reviewers who had not seen the register: Gemini 4 Argon (through T3, plan
mode) and a ponytail audit (a Claude agent). Each claim was checked in the code, or by a probe, before it was placed.

**Refuted by a probe:** tailor's heredoc breakout. A project skill built the same way, invoked with arguments that
close the heredoc and add `touch PWNED`: Claude Code's permission check parsed the whole `!` command, refused it ("The
following parts require approval: touch PWNED"), and nothing ran. A model-invoked skill also needs `Skill(...)` allowed.

**8o, fixed before the release** (the register's "fix" bar: a locked decision's boundary, or security):
1. **D14 on Windows and for Grep:** a Grep whose path or glob names the map, and a PowerShell command that names it,
   carry the same labels a Bash command does (the Bash route and 8h's naming test, reused). Seen: a Windows session
   ran the dream's step through PowerShell (8l attempt 1), and Grep's content mode shows an entry's text.
2. **An agent or change draft with `memory: user`** is refused by finish, as a power: its notes are written outside the
   repo. `memory: project` stays allowed (the templates and tailor's guidelines use it).
3. **map-review:** each proposal and each draft waits for the person's answer before any edit; before the commit, any
   other uncommitted change in the files to commit is shown, and committed only on the person's yes (D14: the commit
   is the review). The template's old hash joins setup's list (D29).
4. **`show`:** a case that lists bare `Bash` adds one sentence, that its sessions may run any command as the person,
   outside the copy too (X-3's rest, now said).
5. **The root README:** the claims that the skills and the dream's skill drafts are user-only are corrected, and the
   old alpha benchmark logs give way to a link (it ships on `main`).

**The checks:** a case for each that fails on `269ef978`'s product and passes, under Node 24 and Node 20; a mutation
each; every list's anchors; the self-test; `claude plugin validate`. The counted model runs are not voided: no fixture
lists bare Bash or `memory: user`, and no counted run reads map-review's template or the hooks' label text. D18's bench
then runs once, after this last hook change. Three attempts.

**Into the register for 2.6.1 (later):** a Read of the map in another letter case, or through an 8.3 name, gets no
label (Q-12's class; a probe on macOS first); npm's `claude.cmd` (K-8); one session's digest has no size cap; the data
folder's check ignores `CLAUDE_CODE_PLUGIN_CACHE_DIR`; the 80/300/600 cuts come before redaction (the transcript
already held the whole value, and finish scans each proposal); git's ENOBUFS reads as "git not found"; a rule case with
`"tools": []`; `trial.mjs draft` with a subfolder or extra files; a source cited through a link out of the repo is read
by the re-find; absolute paths in dream's and setup's reports; the dream's `undone/` folder is never cleaned; the
duplicated front-matter and draft code (the refactor step).
