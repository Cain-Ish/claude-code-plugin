# Why Claude does not get better every run, and what fixes it

**Asked (2026-11-23):** "why this plugin do not take Lamis Mukta ecosystem approach so create agents, telemetry, self
improve loops so claude will be better and better in the repo every run? make the research about it and fix it".

## 1. What Lamis Mukta's approach is, from her own words

Two of her sources were read:
- **Her AI Native DevCon 2026 London talk** ([transcript](https://tessl.io/registry/ainativedev/aidevcon-2026-ldn/0.100.14/files/talk-lamis-context-engineering-dreaming/transcript.md)),
  read in full; see the [research of 2026-11-20](2026-11-20-anthropic-memory-and-dreaming.md):
  - memory is plain files in a folder that agents read and write during their work;
  - dreaming runs out of band: an orchestrator sends subagents through past transcripts and proposes changes with
    evidence, and "you as the individual. Can decide where you want to accept changes to the memory and where you
    want to reject them";
  - steering, versioning and provenance.
- **Tessl podcast 113** ([page](https://tessl.io/podcast/113), 7 July 2026). The page summary was read; the episode's
  video was not watched. Its points:
  - agents with their own identity and permissions, scoped per channel;
  - "build for where the model is headed": the harness gets simpler as models improve;
  - dreaming "runs a review pass over session transcripts and memory stores, surfacing hypotheses for what should
    change and pointing to the specific evidence behind each one, leaving a human to decide which changes to apply".

Not yet found: a talk in which she live-codes agents, a graph and telemetry. The Code with Claude 2026 San Francisco
session ["Memory and dreaming for self-learning agents"](https://claude.com/code-with-claude/session/sf-memory-and-dreaming-for-self-learning-agents)
has a recording, but its page names no speaker, and the recording was not watched. It may be the one the user means.

## 2. What the plugin already does of it (2.3.0 and this release)

- **Memory as files:** `.project-map/` topic files, captured during work (D13, D14, D30).
- **Dreaming with evidence and human review:** `/second-brain:dream`. Each proposal rests on what a person typed, and
  waits for `/map-review` (D30, D31).
- **Dedicated project agents** that keep their own notes (`memory: project`): `decision-checker`, `codebase-guide`,
  `memory-curator` (D29). In this repo, the decision-checker wrote its first note on 2026-11-23.
- **Telemetry:** since K1, the dream's report names the map files each session read, and the topic files none read.
- **Versioning and provenance:** git, and each entry's `source`, `id` and `verified` lines.

## 3. Why it still does not get better every run: a trace through the code

One lesson, followed from run N to run N+1:
- **A decision someone states:** the capture instruction (`map.mjs:14-17`) records it in run N. Run N+1 sees the
  index and reads the topic file. **It reaches the next run.**
- **A correction** ("no, not like that, do it this way"), or a problem Claude hit that will trip up the next session:
  the capture instruction names decisions, rules and requirement documents, and nothing else. **The correction is not
  recorded in run N.** It reaches the map only through the dream, and only once it has appeared in two or more
  sessions (`dream/SKILL.md:26`). Then it waits for a typed dream, a review and a commit. **It reaches a later run, if
  the user dreams.**

So the gap is how slowly a correction reaches the next run, not missing agents. Three choices are behind it:
- the capture instruction is frozen at its decision-and-rule scope (D14);
- the dream runs only on demand (D31, the user's answer of 2026-11-20);
- "better every run" has never been measured. The research of 2026-11-20 listed that check, A-4, and it was never
  built.

## 4. The fix, smallest first

1. **K2, a self-update line in the capture instruction.** When the user corrects Claude, or Claude hits a non-obvious
   problem that will trip up a future session, record it as an entry. Paul Stack's instruction at AI Native DevCon
   2026 is the source: "if you hit a non-obvious problem during a session that's going to trip up future users ...
   record it and propose an update". The entry reaches run N+1 at once, labelled "unreviewed" until it is committed,
   as every capture is.
2. **Narrow the instruction's document clause to documents from outside the repo.** The field report of 2026-11-23
   (section 5) shows that, in a repo with many documents, "you read a document that states requirements ... add each
   one" made Claude copy the repo's own rules into the map. That cost about 500k tokens and left two copies to keep in
   step. D15 chose that the repo's documents stay the source and the index points to them. A1's designer document,
   kept outside the repo, still gets captured.
3. **Measure it before it ships: A-4, "the second run".** A fixture repo. Session 1 holds a correction of a mistake.
   Session 2 is a fresh session given the same kind of task. Three arms: the code as it is; with K2; with K2 and a
   dream between the sessions. Read: whether session 2 repeats the corrected mistake. Run count and bars are
   registered in 06 before any run.

Items 1 and 2 change D14's frozen instruction, so D16's trigger "the capture instruction changes" fires, and they need
a re-check like 06's 2s. The user's request of 2026-11-23 is read as the word that reopens D14 for them.

## 5. What is not taken, and why

- **Proposals that count without review (D33's option C).** Both of Lamis's sources leave a person to decide. An
  uncommitted entry already reaches the next session, labelled.
- **A dream that starts itself every run.** On 2026-11-23 the route through the `Stop` hook was rejected: it fires
  after every turn and would take over working sessions (D33, refute round). For hands-off dreaming, the route that
  fits her "out of band, in batches" is a desktop scheduled task (R4). It needs one manual test in the user's desktop
  app.
- **A session graph or a telemetry proxy.** Git and Claude Code's own transcripts hold the record; K1 reads them.
  Until the talk the user means is found and read, its graph is not built.
