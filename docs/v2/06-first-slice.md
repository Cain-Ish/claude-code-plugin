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
