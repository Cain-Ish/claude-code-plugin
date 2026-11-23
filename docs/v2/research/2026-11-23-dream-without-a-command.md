# Can a dream start without a typed command? (D33, option B)

**Asked (2026-11-23):** the user's goal after a live test is that setup runs once, and from then on the plugin keeps the
memory current by itself. 2.3.0 starts a dream only when the user types `/second-brain:dream` (D31), and tells only
the user that one is due (D32). This note is the feasibility read registered in
[06](../06-first-slice.md), section 4, step 4d. Its four criteria were fixed before the read:
1. the dream starts without a typed command;
2. no hook process calls a model or the network, or starts a process that does (D18);
3. it runs on the user's machine, where the transcripts are;
4. a dream's proposals still wait for review. Option (C) is the user's answer alone.

**How it was read.** The question went to the Antigravity CLI (agy, Gemini 4 Argon, plan mode). Its four key claims
were then checked against the pages themselves on 2026-11-23. One of them was wrong (item 3 below). Only what the
pages say is kept here.

## What the documentation says

1. **Hooks** ([hooks](https://code.claude.com/docs/en/hooks)).
   - A hook "receives the event's JSON input on stdin and communicates results back through exit codes and stdout".
   - No hook output starts a skill, a slash command or a session.
   - A `Stop` hook can return `decision: "block"` with a `reason`, which keeps Claude from stopping, and Claude goes on
     working from that reason. The check read this in the page's tables as summarised, not word for word.
   - **The default timeout of a command hook is 600 seconds.** It is lowered to 30 on `UserPromptSubmit`. This bears
     on N5: on macOS, a `bash` hook stuck the way the self-test's was would hold a session for up to 10 minutes.
2. **Skills** ([skills](https://code.claude.com/docs/en/skills)).
   - `disable-model-invocation: true` removes the skill's description from Claude's context, and Claude cannot invoke
     it through the Skill tool.
   - The dream skill has this flag (06, section 3's budget), so no instruction to Claude can start it.
3. **`/loop` and session cron** ([scheduled tasks](https://code.claude.com/docs/en/scheduled-tasks)).
   - "You can also pass a skill as the prompt, for example `/loop 20m /review-pr 1234`".
   - But "a scheduled fire only runs skills that Claude is allowed to invoke on its own". A
     `disable-model-invocation` skill reaches Claude as plain text instead of running.
   - Both are session-scoped: they stop when the session ends, and the user starts them.
   - agy said the opposite, that a scheduled prompt runs such a skill. The page contradicts it.
4. **Desktop scheduled tasks** ([desktop scheduled tasks](https://code.claude.com/docs/en/desktop-scheduled-tasks)).
   - A local task "runs on your machine with direct access to your files and tools, but only fires while the app is
     open and your computer is awake".
   - It runs in a chosen working folder.
   - It is created in the desktop app ("New task", or by describing it in a desktop session). Creating one from the
     CLI or from a file is not documented. The prompt lives in `~/.claude/scheduled-tasks/<task-name>/SKILL.md`, but
     its schedule and folder do not.
   - Whether a desktop task's fire runs a `disable-model-invocation` skill is not stated.
5. **Headless `claude -p`** ([headless](https://code.claude.com/docs/en/headless)). It runs one prompt on the user's
   machine and exits. Started by the operating system's scheduler, it needs no typed command.
6. **Background memory consolidation.** No "auto dream" is on the
   [memory](https://code.claude.com/docs/en/memory) page as read on 2026-11-23. Auto memory is written during
   sessions, and no plugin event hooks into a consolidation pass. The research of 2026-11-20 cites a collaborator's
   remark on an issue, not the documentation.

## The routes, against the four criteria

| Route | 1. no typed command | 2. D18 | 3. local | 4. review kept | What it changes or fires |
| --- | --- | --- | --- | --- | --- |
| R1. The `Stop` hook blocks the stop once while a dream is due; its reason tells Claude to run the dream | yes, at the end of a turn | yes: the hook only returns JSON | yes | yes | The dream skill must lose `disable-model-invocation`, so its description costs listing context. D32's trigger fires: the due notice reaches Claude. The dream runs in the user's working session, using its time, context and usage |
| R2. `SessionStart` context says a dream is due and to run it | yes, at the start | yes | yes | yes | As R1, but before the user's first task |
| R3. `/loop` or session cron with `/second-brain:dream` | no: the user types `/loop`, or Claude makes the cron only when told | yes | yes | yes | Needs the skill's flag off (item 3), and is session-scoped |
| R4. A desktop scheduled task, created once by the user, running `/second-brain:dream` in the repo's folder | yes, after one creation | yes: no hook involved | yes, while the app is open | yes | Needs the desktop app open. Setup cannot create the task. Whether the fire runs a flagged skill is unknown |
| R5. The operating system's scheduler running `claude -p "/second-brain:dream"` | yes | yes: no hook involved | yes | yes | Setup would install a system task: v1's timer, which D26 and D27 had to clean up. Headless permission prompts. The charter's non-goals since 2026-11-20 |
| (N) Claude Code's own consolidation | — | — | — | — | Not documented on 2026-11-23 |

**Result of the read:** routes R1, R2, R4 and R5 meet all four criteria. Each one changes a recorded decision or the
charter, as the last column says. Under the registration, the next step is a rethink, then a refute-first agy round on
the best route, before any design.

## Rethink: which route serves the user's goal best

**The goal:** setup is run once; then the memory stays current without the user remembering a command. The review
stays: option (C) is the user's to answer.

**What the talk and the decisions favour.**
- The talk runs dreaming out of band, in batches, with its own budget (research of 2026-11-20, T16).
- D32 kept the due notice out of Claude's context, so a session's work is not steered by upkeep.
- D18 keeps every hook to `git` and no model.
- The charter's non-goals, since 2026-11-20, say the dream runs only on demand. The user's goal of 2026-11-23 is what
  changes that, and only for starting a dream.

**The candidates:**
- **R4, a desktop scheduled task,** is the closest to the talk: out of band, its own session, no hook change, nothing
  in the user's working context. But setup cannot create it; the user would create it once in the desktop app. It
  runs only while the app is open, and the user works in the CLI. Whether its fire runs a flagged skill is unknown,
  and no session of ours can check it.
- **R1, the `Stop` hook,** is the most automatic in the CLI, where the user works. Its costs:
  - a fifth hook event. D18's surface budget names four, and a `Stop` hook runs at the end of every turn, so its
    latency is paid on every turn (D18's 100 ms bar);
  - the dream skill loses `disable-model-invocation`, so its description enters the listing, and Claude could start it
    unasked at another time;
  - the dream runs inside the user's session after their task, using its time, context and usage;
  - in headless `-p` sessions, such as scripts or CI that run Claude in the repo, it would hijack the run.
- **R2, at session start,** has R1's costs, and delays the user's first task. Rejected for R1.
- **R5, the system scheduler,** is v1's timer. D26 and D27 exist because v1 left one behind. Rejected.

**The candidate to attack: R1, with these guards.**
- **Due state:** session start already computes it (D32). It writes a marker in the plugin's data folder, so the
  `Stop` hook only reads a file: no `git`, within D18's bar.
- **Once:** the `Stop` hook blocks at most once per due state: never when `stop_hook_active` is set, never while the
  dream's lock is held, and never again after a dream starts.
- **Interactive only:** never in a headless `-p` session. How a hook tells them apart is not yet verified.
- **The reason** names the dream and says it is due, so the user sees why Claude goes on, and can stop it.
- **The skill's description** says to run it only when the plugin says a dream is due.
- **What stays:** a dream's proposals still carry `- proposed:` and wait for `/map-review`. D31's provenance and
  injection bars stand.

**Open for the refute round:** whether R1's cost to a working session (time, context, usage, an unasked run in a
session the user meant for something else) outweighs R4's dependence on the desktop app; and whether a middle route
exists, such as the `Stop` hook asking the user one yes-or-no question instead of starting the dream.

## The refute round (agy, Gemini 4 Argon, 2026-11-23): R1 rejected

agy was given the criteria, the route table and the rethink above, and asked to break R1. Its findings, with what
backs each one:
1. **`Stop` fires at the end of every turn, not when the user's task is done.** The due state exists from session
   start, so R1 would start the dream after the session's first reply. That includes a reply in which Claude has just
   asked the user a question. R1 collapses into R2. *Backed by* the hooks page: `Stop` runs when Claude finishes
   responding.
2. **Dropping `disable-model-invocation` swaps a platform guard for prose.** Any text Claude reads during ordinary work
   could tell it to start the dream. *Backed by* the skills page (item 2 above). The injection path itself is agy's
   reasoning, not a probe.
3. **A hook cannot tell a headless `-p` run from an interactive one.** The `Stop` input has no documented field for it,
   so scripts and CI that run Claude in the repo would get a dream instead of their output. *Backed by* the documented
   input fields. The test of the hook's stdio is agy's reasoning.
4. **The once-per-due guard has no safe owner.** If the dream clears the due state, an interrupted start blocks every
   later turn. If the hook clears it, an interrupted dream is dropped. Two sessions inside the same few seconds both
   start one. *agy's reasoning;* each case is observable.
5. **The dream would run on the working session's whole context:** usage billed on that prefix at every step, a
   possible compaction of the user's work, and D32's guarantee broken. *agy's reasoning,* consistent with how sessions
   bill.
6. **The yes-or-no middle route pays the same costs.** It still needs the `Stop` hook, the unflagged skill and the
   extra turn.

**The route it proposes (M), and why it fits:** a dream's proposals count only after review, whatever the route, so
starting the dream earlier gains nothing before the user reviews. The dream and the review can be one step:
- the user runs one command when the due notice says a dream is due;
- the dream stages its proposals, then walks them with the user in the same session, as `/map-review` does;
- `disable-model-invocation` stays on, the four hooks stay, D18 holds, and no working session is touched.

agy also claimed that a desktop task's prompt starting with a flagged skill runs it. That is not verified, and the
scheduled-tasks page says the opposite for `/loop` fires (item 3 above).

**What this leaves for D33:**
- (B), a dream started without any command, is rejected on R1's findings: R2 shares them, and R5 was rejected in the
  rethink. R4 remains possible only for users who keep the desktop app open, with the flagged-skill question
  untested.
- The upkeep can come down to one command when it is due, (M). Fully hands-off upkeep needs (C), proposals counting
  without review, which is the user's answer alone.
