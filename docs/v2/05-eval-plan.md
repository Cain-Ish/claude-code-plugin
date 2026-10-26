# v2 eval plan

**Status:** A1's baselines run and thresholds set on 2026-10-20 (V2-D17 LOCKED); see Baseline results and
Thresholds. Scenario A2, at scale, added on 2026-10-22 (V2-D19 LOCKED). The eval after the concept phase (Opus, new
epoch, investigation tasks): the last section.
Pre-registered on 2026-10-20, when the user confirmed the scenario, the arms and the capture rules
(V2-D17). The neighbour session, the failure chain, the epoch rule and ten runs per arm were added the same day from
[research/2026-10-20-memory-scenario-guide-and-docs.md](research/2026-10-20-memory-scenario-guide-and-docs.md),
before anything ran, and the scoring details marked "(harness)" below were fixed while the harness was built, also
before anything ran. After the pilot the user gave the go for the remaining runs on the proposed model (Sonnet 5.5)
and run count (ten). A first proposal tested recall from documents written in
advance; it was replaced before anything ran, because the user's scenario is knowledge Claude captured itself in
earlier sessions.

The eval answers one question: does Claude, in a fresh session, know and follow what was decided or read in earlier
sessions, which the code does not show? Every claim of value in the charter is a result of this eval against two
baselines that need no v2 code, so the baselines run first (PM1).

## Scenario A1

The charter's A1, played as headless sessions on one fixture repo. Sessions H1-H3 are the history; T is the test,
and N is its neighbour.

| Session | Who | What happens | Knowledge that appears |
| --- | --- | --- | --- |
| H1 | lead developer | A small refactor of an existing component. In passing the developer says that from now on every component keeps all its files in its own folder under `src/components/` and follows the client's style guide; earlier they had said new components go under `src/widgets/`, and they take that back. They also mention that their dev server runs on another port today | the folder decision; the style-guide decision; a superseded option (`src/widgets/`); a one-off detail (the port) |
| H2 | designer | Claude is asked to check the designer's notes for a new profile page against the existing components and list what is missing. The notes are pasted into the prompt (they live outside the repo). One section says exactly how avatars look: sizes 24, 40 and 64 px, a circle with a `borderSubtle` border, and initials on the `avatarFallback` colour when there is no photo | the avatar specification |
| H3 | PM | A small change to the members list. In passing the PM says the client decided that avatars never load from the CDN, even when a CDN address exists; they are served locally | the no-CDN decision |
| T | anyone | A fresh session: "Create a UserAvatar component." | none: only what was kept |
| N | anyone | Another fresh session from the same memory state: "Create a ProductImage component that shows a product's photo." | none. The folder and style-guide decisions apply; the avatar specification and the no-CDN decision do not, so product images still load from the CDN |

- **No cue:** no history prompt asks Claude to remember. The words "remember", "memorize", "memory", "note this",
  "keep in mind", "for later" and "for future" do not appear in them. Claude decides on its own what to keep (D14's
  user answer).
- **Only memory carries over:** before T and N, every file change from H1-H3 is discarded, so the repo is the
  fixture again. T and N each start from a copy of the memory store as H3 left it. What they know about H1-H3 can
  only come from that store.
- **Why N:** a store that applies everything everywhere would pass T. N is the permitted neighbour (research
  2026-10-20 §4): it shows whether recall is selective.

## Fixture

A small front-end repo built for the eval, under `probes/V2-D17-eval/fixture/` once the harness exists: React and
TypeScript source, no packages installed, scored on files and replies, not builds. Invented names only (the repo is
public).

- **Principle:** the code must not settle any checked decision, and where it leans, it leans the wrong way. Older
  components are flat files, newer ones sit in folders. Some older files use colour literals. Every existing image,
  avatars included, goes through the CDN: the image primitive `Img` loads through the CDN unless it gets the `local`
  prop, and the user type has both `avatarPath` and `avatarCdnUrl`. The client's style guide and the tokens
  (`avatarFallback`, `borderSubtle` among them) are in the repo. The designer's notes are not.
- **If the no-memory arm passes the folder, specification and no-CDN items in every run,** the fixture measures
  nothing and is changed (a failed attempt).

## Arms

| Arm | Memory between sessions |
| --- | --- |
| M0, no memory | None: auto memory off (`autoMemoryEnabled: false`). Only T and N run: with nothing carried over and the repo reset, H1-H3 cannot change them |
| M1, auto memory | Claude Code's own auto memory, on, pointed at an empty directory per run outside the repo (`autoMemoryDirectory` in `settings.local.json`, as in D12). H1-H3 run in order, then T and N |
| v2 | The first slice from the build phase, with the map committed in the repo (D11). Not run in the concept phase |

Not run, because it is known: when a teammate on another machine runs T, auto memory carries nothing (it is per
user and per machine, [the memory docs](https://code.claude.com/docs/en/memory)), so M1 falls to M0. v2's committed
map is meant to close that gap; its arm will run T as a second person too. Auto memory also records no source for a
note, so A1's item (5) rests on Claude's own wording.

## Checks

All deterministic: a script reads the memory store, the files, the git diff and the event stream. No model judges a
run. (harness) Content checks read the new code files (`.ts`, `.tsx`, `.js`, `.jsx`, `.css`, `.scss`) with comments
removed, so a comment that explains a decision ("never from the CDN") is not scored as code.

**Capture** (M1, after H3, on the memory store):
- C1 the folder decision: mentions a folder per component and the style guide.
- C2 the avatar specification: mentions avatar, the sizes 24, 40 and 64, and the initials fallback.
- C3 the no-CDN decision: mentions the CDN and local loading.
- C4 noise: the one-off port is not kept.

**Test session T:**
- T1 folder: every new file is under `src/components/UserAvatar/`, which holds `UserAvatar.tsx`; nothing is written
  under `src/widgets/`.
- T2 style guide: no colour literal (hex, `rgb(`, `hsl(`, a named colour) in new files; colours come from the tokens.
- T3 specification: the sizes 24, 40 and 64 and the tokens `avatarFallback` and `borderSubtle` appear.
- T4 no CDN: no new file mentions `cdn` (any case) or `avatarCdnUrl`; every `<Img` in them has the `local` prop; the
  image comes from `avatarPath`.
- T5 sources: the final reply names each decision with where it came from: the folder and the style guide with the
  developer or lead, the look with the designer, the CDN with the PM or the client. (harness) Scored as: the reply
  names the developer or lead, the designer, and the PM, a product manager or the client.
- **Before writing:** T1-T4 are also scored on the first Write of `UserAvatar.tsx`. Passing there, not only after
  later fixes, is what "recalls before it writes" means. (harness) Scored on every file written up to and including
  that Write; when no `UserAvatar.tsx` is written, the first Write of a file whose path holds `UserAvatar`.

**Neighbour session N:**
- N1 folder: every new file is under `src/components/ProductImage/`.
- N2 style guide: no colour literal in new files.
- N3 no over-application: no new file uses the `local` prop, `avatarFallback` or the avatar sizes as a size scale;
  the image goes through the CDN like the other product images. (harness) Scored as: every `<Img` lacks `local` (or,
  with no `<Img`, the code names the CDN), no `avatarFallback`, and not all of 24, 40 and 64.

**Failure chain** (M1, per decision, after the research note's chain: present, loaded, used): a decision that T
does not follow is classed as *not kept* (its C item failed), *not loaded* (kept, but T neither had it in the
loaded index nor read its topic file before the first Write), or *ignored* (loaded, not followed). Each class
points at a different design decision: capture (D14), recall (D13, D18), or wording.

## Metrics

| Outcome (charter) | Measure here |
| --- | --- |
| Capture | Share of C1-C3 passed per run; C4 failures counted as noise |
| Consistency | T1-T5 and N1-N3 per run, on the final files and on the first Write; a run passes when all pass |
| Orientation | Tool calls (main session and subagents) and distinct files read in T before its first Write of `UserAvatar.tsx` (the "before writing" point above) |
| Cost | Tokens in T (input, output, cache read and cache write, from the result event) and the reported cost; always-on bytes at T's start (the memory loaded; 0 for M0); memory writes in H1-H3 |
| Arrival | Settled by V2-D12 |
| Freshness | V2-D16; here only that the superseded `src/widgets/` is not followed (T1) |

## Protocol

- **Model:** Sonnet 5.5 (`claude-sonnet-5-5`). Results do not transfer across models (prior research Q7), so
  another model is another baseline.
- **Runs:** 10 per arm (the guide's floor for replayed scenarios; 5 gives pass rates in steps of 20 points): 20
  sessions for M0 and 50 for M1. The first M1 run is a pilot: its cost is reported, and it shows that auto memory
  writes in headless sessions at all, before the other runs start. If the pilot's cost makes 10 runs unreasonable,
  the user decides before any further run.
- **Epoch:** each run records the CLI version, the model id and a hash of the fixture and session scripts. A change
  to any of them starts a new baseline; results across epochs are not compared.
- **Session:** `claude -p` in a fresh copy of the fixture, initialised as a git repo; user settings excluded
  (`--setting-sources project,local`); Read, Write, Edit, Glob, Grep and subagents allowed, plus writes to the
  arm's memory directory; Bash, WebFetch and WebSearch denied (no builds, no network, static scoring). (harness) Also
  no MCP server (`--strict-mcp-config`) and no Skill tool, so the user's own skills and connectors stay out; the
  memory directory is passed with `--add-dir` and `acceptEdits` so writing to it needs no prompt.
- **Valid run:** every session ends with a success result event on the planned model, and the harness raised no
  error. An invalid run is re-run and reported. A memory store left empty is a capture result, not an invalid run,
  but only if no write to it was refused: (harness) a memory write refused for permission voids the run, because an
  empty store would then measure the harness, not Claude's judgment.

## Harness

Under `probes/V2-D17-eval/`: Node, no npm packages, at most 400 lines without the fixture and the session scripts
(v1's outcome harness had 2,710 lines and never ran). The session prompts live in the harness's script file, not in
this plan. Before building it, check whether `claude plugin eval` can drive these sessions (several sessions, a
memory store carried between them, per-run settings); if it can, the harness is its suite plus the scorer. (harness)
It cannot: per its `--help` (CLI 2.1.304) it runs one prompt per case against a plugin, with a no-plugin ablation
arm, and M0 and M1 load no plugin and chain five sessions. It may fit the v2 arm. Before any baseline run the harness
passes a smoke check:
- hand-written gold outputs pass T1-T5 and N1-N3, and a gold memory text passes C1-C4;
- each planted wrong output fails exactly its own item;
- the prompts of T and N contain no answer token (a target path, "style guide", "designer", "CDN", "local", a
  size, a token name, "PM"), and no history prompt contains a cue word listed above;
- (harness) on a synthetic event stream, the "before writing" point, the memory reads before it and a refused memory
  write are found.

## Baseline results (2026-10-20)

Ten valid runs per arm, one epoch (Claude Code 2.1.304, Sonnet 5.5, inputs `108861b749cb`), about 4 USD in all.
Per-run records: [probes/V2-D17-eval/results](probes/V2-D17-eval/results/); the numbers below are its
`summary.json`, made by `node eval.mjs --summary`.

| Item (passing runs of 10) | M0, no memory | M1, auto memory |
| --- | --- | --- |
| C1 folder and style guide kept / C2 avatar specification kept / C3 no-CDN kept / C4 port not kept | n/a | 10 / 0 / 10 / 10 |
| T1 folder | 4 | 10 |
| T2 no colour literal | 10 | 10 |
| T3 avatar specification | 0 | 0 |
| T4 no CDN | 0 | 7 |
| T5 sources named | 0 | 0 |
| T1-T4 at the first Write | 4 / 10 / 0 / 0 | 10 / 10 / 0 / 7 |
| N1 folder / N2 no colour literal / N3 no over-application | 0 / 10 / 10 | 10 / 10 / 10 |
| Runs passing every T and N item | 0 | 0 |

| Measure in T (median, range) | M0 | M1 |
| --- | --- | --- |
| Tool calls before the first Write of `UserAvatar.tsx` | 9 (6-9) | 7 (5-10) |
| Files read before it | 5 (5-6) | 6 (4-9) |
| Tokens, all kinds | 132,036 (87,000-133,818) | 97,602 (91,390-126,152) |
| Output tokens | 2,387 (2,068-2,812) | 2,310 (2,064-2,927) |
| Cost, USD | 0.059 (0.049-0.071) | 0.062 (0.056-0.080) |
| Always-on memory, bytes | 0 | 313 (288-366) |
| Memory writes in H1-H3 | 0 | 4 (4-5) |

- **Failure chain (M1):** the folder decision was followed in 10 runs. The avatar specification was not kept in any
  run: in H2 Claude compared the designer's notes with the code and listed the full specification, but wrote nothing
  to memory. The no-CDN decision was followed in 7 runs and scored "ignored" in 3. In 2 of those 3 the component did
  load locally (`Img` with `local`) but took the image path as a prop, so it never named `avatarPath`, which T4
  requires as pre-registered. The third rendered a plain `img` from a prop. The score stands as pre-registered.
- **The fixture measures:** M0 failed T3 and T4 in every run and T1 in six, so the "measures nothing" condition did
  not occur. T2 and N2 passed in every run of both arms, so they do not separate the arms here.
- **M1 did not pass every item.** The pre-decided "v2's case rests on team sharing" outcome does not apply.

## Thresholds

Set on 2026-10-20 from the baseline results above, by the rule below, unchanged since it was pre-registered.

- **Rule:** on counts and tokens, v2 meets an outcome when its median beats M1's by more than M1's own run-to-run
  spread (largest minus smallest of its ten runs); on pass items, v2 passes in no fewer runs than M1. Ten runs that
  show no difference do not show the arms are equal.
- **Orientation:** median tool calls before the first Write of `UserAvatar.tsx` below 2 (M1: 7, spread 5), or median
  files read before it below 1 (M1: 6, spread 5).
- **Cost:** median T tokens of all kinds below 62,840 (M1: 97,602, spread 34,762); median T output tokens below 1,447
  (M1: 2,310, spread 863); median T cost below 0.038 USD (M1: 0.062, spread 0.024). Always-on bytes are not a count
  or a token figure, so the rule sets nothing for them; D13's cap governs them (M1 measured 313).
- **Pass items:** v2 passes in at least as many runs as M1 on each item: C1 10, C2 0, C3 10, C4 10; T1 10, T2 10,
  T3 0, T4 7, T5 0 (the same at the first Write); N1, N2, N3 10.
- **What the rule does not cover:** where M1 passes in no run (C2, T3, T5) its floor is 0, so the rule alone cannot
  show v2's value there, yet those are A1's items (3) and (5) in the charter. The v2 arm reports them as its own
  result. *Target (2026-10-22, V2-D17): v2 passes each in at least 8 of 10 runs, D20's held rule scaled to 10 runs.*
- **If M1 passes every item in every run:** native auto memory already does A1 for one person on one machine. D17
  then records that v2's case rests on team sharing, on the contexts auto memory does not reach (Explore and Plan,
  D12) and on cost, and the user sees that result before any threshold is set.

## Scenario A2: at scale (V2-D19)

A1 runs on a 16-file fixture. A2 measures the user's three test-bed repos as they are run today: v1's own repo (R0),
and two private repos (P1 and P2, published as counts only). The check and its premise count are in
[DECISIONS.md](DECISIONS.md) under V2-D19; the per-task counts are in
[probes/V2-D19-scale/results/a2.json](probes/V2-D19-scale/results/a2.json).

- **Tasks:** D20's four, at pinned commits: a build task in each repo, and a plan task in P2. Their 27 rules have
  deterministic checks. D22's six investigation tasks join when D22 locks.
- **Arms:**
  - **M1, the repo as it is run today:** its instruction files, rules, hooks and skills, plus the user's own auto
    memory where the user has one. Only P1 has one (14 notes), copied fresh into each run (arm `m`). In P2 and R0,
    M1 is the native arm.
  - **v2:** the first slice, in the build phase.
- **Protocol:** as A1, by D20's harness: Sonnet 5.5, CLI 2.1.305, Bash and the web off, 10 valid runs per task. The
  epoch rule holds: another CLI or model is another baseline.
- **Context:** recorded, with no threshold. In 57 runs (A2's and D22's native runs) the largest context of any turn
  was at most 17% of the 1,000,000-token window. No run compacted and none used a subagent. *Rethink 2
  (2026-10-22): a task's context is not a session's. The user's working sessions compacted in 7 of 11, so this
  measure is reset when D19 reopens ([research/2026-10-22-rethink-2.md](research/2026-10-22-rethink-2.md)).*

### Thresholds (2026-10-22, D17's rule, against M1)

**Pass items:** v2 follows each rule in at least as many of its 10 runs as M1.

| Task | Rules (M1's count of 10) |
| --- | --- |
| P1 build | R1 10, R2 4, R3 10, R4 10, R5 10, R6 0; the shared value reused 0 |
| P2 build | R1 10, R2 10, R3a 10, R3b 10, R4 10, R5 0, R6 0, R7 0 |
| R0 build | R1 10, R2a 9, R2b 9, R3 10, R4 4, R5 10, R6 7, R7 10 |
| P2 plan | P1 9, P3a 10, P3b 10, P4 9, P5 5 |

**Counts and tokens:** v2's median must fall below the threshold, which is M1's median minus M1's spread.

| Task | Tool calls before the first write | Files read before it | Tokens, all kinds | Output tokens | USD |
| --- | --- | --- | --- | --- | --- |
| P1 build | below 4 (10, 6) | below 5 (7, 2) | below 261,937 (558,356, 296,419) | below 4,075 (5,633, 1,558) | below 0.220 (0.321, 0.101) |
| P2 build | below 6 (33, 27) | below 3 (10, 7) | none (1,023,126, 1,455,037) | below 6,345 (17,973, 11,628) | below 0.094 (0.537, 0.443) |
| R0 build | below 1 (21, 20) | none (7, 8) | below 194,464 (674,946, 480,482) | below 1,739 (10,059, 8,320) | below 0.120 (0.356, 0.236) |
| P2 plan | no write | none (2, 2) | none (133,615, 186,306) | below 1,694 (3,498, 1,804) | none (0.129, 0.147) |

In brackets: M1's median and spread. Instruction bytes loaded per run (median) are recorded with no threshold:
P1 64.0 KB (plus a 2.6 KB memory index in M1), P2 9.9 KB, R0 0 (it has no instruction file).

**What the rule does not cover:**
- *Floors at 0.* M1 never follows four rules (P1 R6; P2 R5, R6, R7). Their floor is 0, so the rule alone cannot
  show v2's value there. D20 stage 2's delivery arm fixed all four.
- *Thresholds at or below 0.* On five cells ("none" above), M1's spread is at least its median, so no median can
  meet the rule. R0's "below 1" tool call means writing before any look. At this run count, the rule cannot show a
  cost or orientation gain there.
- *Targets (2026-10-22, V2-D19):* each rule at 0 needs at least 8 of 10 v2 runs. On the "none" cells and R0's "below
  1", no gain is claimed: v2's median must be at most M1's median plus M1's spread. P1's shared value is not a v2
  target (D21).

## The eval after the concept phase (2026-10-22)

What changed since A1's and A2's baselines, and how the eval of the first slice runs. The thresholds' rule (D17) and
its gap targets stay. The numbers re-run in the new epoch.

- **Model and epoch: Opus 5.5, the user's model** (rethink 2: every baseline so far ran on Sonnet 5.5). This is a new
  epoch, so D17's and D19's triggers apply. A1's arms M0 and M1, and A2's M1, re-run on Opus at the current CLI before
  the v2 arm runs. That is the first task of the build phase (PM1: baselines first).
- **Session shape for A2's build tasks:** stage 3's three turns (investigate and report, `/compact`, make the change),
  with the web on, because a project's rules may need it (P2). P2's plan task runs as one turn, and its reply is
  scored. A `/compact` turn's empty reply must not be what is scored.
- **Shapes that D22's triggers name** (added at the phase gate, so the triggers can fire). Each build task also runs:
  - with a vague first prompt that names a symptom, and the change only in the second prompt;
  - in a session with two compactions;
  - in a session that switches to the other task of the same repo after the first.

  Each is scored by D20's existing checks. An automatic compaction inside a turn is added once it can be forced in
  headless mode (a low compaction threshold), which is checked first.
- **D22's six investigation tasks join A2** (D19's trigger). They are scored by assertions on the answer, not reach
  against a judge.
  - The assertions are written from the repos' own documents, before the Opus re-baseline, blind to every arm's
    output.
  - They include traps: a stale document or pre-training points one way, and a binding rule points the other.
  - Their thresholds come from that re-baseline, by D17's rule and its gap targets.
- **Measures added:**
  - session tokens of all kinds, subagents included (the last result's `modelUsage`; a `result` event's `usage` is
    its own turn only);
  - always-on bytes per session;
  - stopped sessions, read both ways.
- **Recorded before the v2 arm runs.** This is the one list of expected misses; `06-first-slice.md` cites it.
  - *Expected miss, P1 R2:* a pattern rule that Opus missed under every pull arm. D20's net is deferred: no
    model-written check caught it, and the fed-back check needs a hand-written source.
  - *Expected miss, P2 R4:* a judgment rule that push and pull both missed once the session compacted (`oc` and
    `pfr` 3 of 5).
    - *Widened 2026-10-26 (D22 rethink 4, before its attempt runs; disclosed):* the entry now covers every shape. 2e's
      vague shape missed R4 with no compaction (2 of 5), and native follows it in 6 of 10 (2d's M1).
  - *Expected miss on a condition, P2 R6 in two compactions (added 2026-10-26, before the attempt runs):* listed only
    if native, in the same shape, also misses it in 2 or more of 5 (D22's rethink-4 control). If native holds it, the
    miss is the route's, and D22 cannot re-lock on that attempt.
    - *Not listed (2026-10-26):* the attempt failed at stage 1, so the control never ran. R6 stays a miss of 2e's
      two-compaction shape, under D22's BLOCKED record.
  - *Expected risk:* cost in document-heavy repos, where the route spent about three times push's tokens. That is
    D22's first reopen trigger.
  - *Added 2026-10-25, before any v2 run, from the Opus thresholds* (`06-first-slice.md`, 2c): three cells the rule
    makes unreachable:
    - R0-knowledge files read before the first write;
    - P2 plan output tokens;
    - P2 build output tokens.

### Re-baseline on Opus 5.5 (pre-registered 2026-10-22, before any assertion is written or any run)

The first task of the build phase (06, step 1). D17's and D19's trigger fired: the model changes before the v2 arm
runs.

- **Epoch:**
  - Opus 5.5, with the CLI version as reported at the first run, recorded with the results;
  - the pinned commits; the web on; Bash off (the harness's static scoring).
- **A1:** D17's harness, unchanged except for the model. Arms M0 and M1, 10 chains each (H1 to H3, then T and N).
- **A2, the M1 arm, 10 valid runs per task:**
  - P1 build: native plus the user's own P1 auto memory (a fresh copy per run), in stage 3's three turns with
    `/compact` (a new arm, `mc`).
  - P2 build and R0 build: native, three turns with `/compact`.
  - P2 plan: native, one turn, the reply scored.
  - The six investigation tasks (D22's): native, one turn, the reply scored by frozen assertions.
- **The assertions, written blind and frozen before any Opus run.**
  - *Who writes them:* a fresh agent, given only the six task prompts, the three repos at their pinned commits, and
    the schema. It is told not to open `DECISIONS.md`, `docs/v2/research/` (apart from its input), any probe
    results, or D22's pools, deliveries and grades.
  - *What it writes:* 3 to 6 per task, each anchored to an exact token the repo's documents state, and at least one
    trap per task, where a stale document or pre-training points one way and a binding rule the other.
  - *Form:* D20's reply checks (`where: reply`, `must`, `mustNot`), each with a correct and a wrong sample.
  - *Checks:* `native.mjs checks` must pass every sample. A failing check goes back to the agent with format
    feedback only.
  - *Recorded here before any run:* the private file's sha256, and what the agent saw and did not see.
- **Measures:**
  - D19's: each rule's check, tool calls and files read before the first write, tokens of all kinds (subagents
    included), output tokens, USD;
  - plus stopped sessions, read both ways.
- **Thresholds:** D17's rule against M1, plus the gap-target forms, computed by script into this file.
- **Validity:** D20 stage 3's checks for the three-turn tasks, and D22's native checks for the one-turn tasks.
  Invalid runs are replaced, up to 2 per task.
- **The pilot gate:** one run per task (one chain per arm for A1), costs reported in a progress note with the
  projected total before the rest runs.
- **Estimate:** 300 to 450 USD-equivalent. The pilots correct it.
- **Not in this step:** the added shapes (a vague first prompt, two compactions, a task switch). They feed D22's
  triggers and run with the v2 arm.
- **Assertions frozen (2026-10-22, before any Opus run).**
  - 32 assertions on the six investigation tasks: 3 to 6 per task, 11 of them traps.
  - In the private config's `a2inv/assertions.json`, sha256 `f6bde3ba39ec` (12 characters).
  - *Written by a fresh agent*, given only the six task prompts and the three repos at their pinned commits, and told
    not to open `DECISIONS.md`, `docs/v2/research/` beyond its input, probe results, or D22's pools, deliveries and
    grades. It reports that it opened only those. That is its own report, not a check.
  - `native.mjs checks` passes all 32 correct samples and fails all 32 wrong ones.
  - Every assertion has a `must`, so none passes on an empty reply.
- **Pilot gate (2026-10-22): all 12 pilots valid** (CLI 2.1.305, Opus 5.5), 40.34 USD.
  - A1: M0 0.26, M1 0.77 (one chain each).
  - A2 three-turn: P1 build with memory 1.81, P2 build 7.94, R0 build 2.87.
  - P2 plan 0.30.
  - Investigation: R0-knowledge 3.75, R0-buddy 0.45, P1-skills 5.25, P1-weekly 4.75, P2-crafting 1.43, P2-systems
    10.76.
  - *Projected at 10 runs per task:* about 400 USD-equivalent, inside the registered range. P2-systems is about a
    quarter of it, and the investigation tasks vary the most. The remaining runs (2 to 10) go in six resumable chains.
- **Runs cut off by the usage limit (2026-10-22, disclosed).**
  - The account's usage limit ended sessions mid-run, and the remaining chains were stopped by hand.
  - 27 runs were left with no success result. Most cost nothing; four were cut partway: P2-systems run 7, P2 build
    runs 8 and 9, R0 build run 10.
  - They are an outage, not invalid sessions, so they are re-run under their own run numbers. None counts against
    the two replacements per task.
  - 12 more runs had not started yet.
  - Done once the limit reset (2026-10-23).
- **The CLI changed mid-baseline (2026-10-23, disclosed).**
  - The installed CLI updated itself from 2.1.305 to 2.1.309 a minute before the re-run chains started. The runs'
    own auto-updater switch did not stop it: the update came from outside the harness, and `claude` starts the newest
    install.
  - 39 of the 100 A2 runs (all of that day's) ran on 2.1.309, outside the registered epoch (the first run's CLI).
    They were discarded (142.63 USD-equivalent, records kept privately) and re-run under their own run numbers on
    2.1.305. The harness now starts a pinned binary named in the private config.
  - The usage limit cut off two more runs during the re-run (P1-weekly run 7, R0-knowledge run 7; 3.91 USD). They
    were re-run under their own numbers, like those of 2026-10-22.
  - The pass condition did not change, so this is not a failed attempt.
  - The v2 arm runs on the same pinned CLI. D17's harness (`eval.mjs`) gets the same pin first.
- **Runs (complete 2026-10-25):** A1 20 chains, A2 100 runs, all valid, one epoch (CLI 2.1.305, Opus 5.5), one
  input hash per task. A2's valid runs cost 345.67 USD-equivalent.

### Opus thresholds (2026-10-25, by `V2-D19-scale/tables.mjs`)

Computed from `V2-D17-eval/results/summary-opus.json` and `V2-D19-scale/results/rebase-opus.json` by D17's rule and
its gap targets, as registered above. Nothing in them was set by hand.

#### A1 (M1, 10 valid chains)

- Pass items, M1's count of 10 (v2 needs at least that; at 0, 8): C1 10, C2 2, C3 10, C4 10, T1 10, T2 10, T3 0, target 8, T4 10, T5 0, target 8, N1 10, N2 10, N3 10.
- Tool calls before the first write: below 7 (12, 5). Files read before it: below 5.50 (10.50, 5).
- T tokens, all kinds: below 66,295 (129,365, 63,070). T output tokens: below 2,401 (3,621, 1,220). T USD: below 0.13 (0.19, 0.06).
- Always-on bytes (recorded, no threshold): 450.

#### A2 and the investigation tasks (M1)

| Task | M1 arm, valid runs, stopped | Rules (M1's count of 10) |
| --- | --- | --- |
| P1-build | mc, 10, 0 | R1 10, R2 6, R3 10, R4 10, R5 10, R6 0, target 8 |
| P2-build | n, 10, 0 | R1 10, R2 10, R3a 10, R3b 10, R4 6, R5 3, R6 7, R7 1 |
| R0-build | n, 10, 0 | R1 10, R2a 10, R2b 10, R3 10, R4 9, R5 10, R6 0, target 8, R7 10 |
| P2-plan | a, 10, - | P1 5, P3a 10, P3b 10, P4 3, P5 6 |
| R0-knowledge | a, 10, - | A1 10, A2 0, target 8, A3 0, target 8, A4 4, A5 10, A6 10 |
| R0-buddy | a, 10, - | B1 10, B2 10, B3 10, B4 10, B5 10 |
| P1-skills | a, 10, - | S1 6, S2 0, target 8, S3 10, S4 0, target 8, S5 0, target 8 |
| P1-weekly | a, 10, - | W1 1, W2 3, W3 4, W4 10, W5 8 |
| P2-crafting | a, 10, - | C1 10, C2 6, C3 0, target 8, C4 0, target 8, C5 10, C6 2 |
| P2-systems | a, 10, - | E1 9, E2 6, E3 8, E4 7, E5 10 |

| Task | Tool calls before the first write | Files read before it | Tokens, all kinds | Output tokens | USD |
| --- | --- | --- | --- | --- | --- |
| P1-build | below 8 (17, 9) | below 4 (9, 5) | below 787,467 (1,232,866, 445,399) | below 11,527 (16,863, 5,336) | below 1.37 (1.69, 0.32) |
| P2-build | below 28 (145, 117) | below 10 (36, 26) | no gain; at most 20,458,763 (8,934,782, 11,523,981) | below 1,397 (64,926, 63,529) | no gain; at most 10.85 (5.17, 5.68) |
| R0-build | below 22 (44, 22) | below 7 (11, 4) | below 1,791,711 (3,273,753, 1,482,042) | below 19,541 (40,245, 20,704) | below 2.02 (2.87, 0.85) |
| P2-plan | n/a | no gain; at most 4 (1, 3) | no gain; at most 320,846 (79,757, 241,089) | below 300 (2,860, 2,560) | no gain; at most 0.38 (0.12, 0.26) |
| R0-knowledge | below 38 (39, 1) | below 1 (18, 17) | no gain; at most 7,406,039 (2,444,004, 4,962,035) | no gain; at most 27,333 (11,603, 15,730) | below 0.19 (3.85, 3.66) |
| R0-buddy | n/a | no gain; at most 11 (5, 6) | below 106,284 (396,285, 290,001) | below 3,007 (6,160, 3,153) | below 0.27 (0.52, 0.25) |
| P1-skills | n/a | no gain; at most 16 (8, 8) | no gain; at most 957,925 (102,745, 855,180) | no gain; at most 9,631 (2,465, 7,166) | no gain; at most 10.50 (3.80, 6.71) |
| P1-weekly | no gain; at most 64 (28, 36) | no gain; at most 34 (13, 21) | no gain; at most 18,723,129 (7,495,519, 11,227,610) | no gain; at most 96,237 (42,666, 53,571) | below 3.40 (5.11, 1.71) |
| P2-crafting | n/a | below 4 (8, 4) | below 189,991 (1,058,172, 868,181) | below 7,551 (10,758, 3,207) | below 0.64 (1.12, 0.48) |
| P2-systems | n/a | no gain; at most 173 (70, 103) | no gain; at most 411,908 (169,459, 242,449) | below 1,399 (3,493, 2,094) | no gain; at most 24.89 (6.32, 18.56) |

In brackets: M1's median and spread. Tokens and USD cover the whole session, subagents included.
