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
| Added hook p95, Windows | at most 100 ms per hook: at 1 session on every machine CI runs, and at 8 concurrent on the reference machine before each release (D18, re-locked 2026-10-27). On the 4-core CI runner at 8 concurrent: 143 to 260 ms, a stated weakness. Measured at 8 concurrent in 2a: 87 ms at session start (the index from git's file list, on P2), 49 ms or less for the others. After D16's re-lock of 2026-10-26: 60 to 82 ms at session start, and 83 to 86 ms for a map read citing P2's 30 largest documents | D18 |
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
