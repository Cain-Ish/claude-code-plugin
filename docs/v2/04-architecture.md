# v2 architecture

**Status:** 2.3.0, built only from locked decisions ([DECISIONS.md](DECISIONS.md), every decision LOCKED as of
2026-11-22). Rewritten for the redesign onto Anthropic's layout (06, section 3; D29-D32). The 2.2.0 page is in git
history. One page by design (charter, definition of done item 3).

## What runs

A Claude Code plugin with 4 hook events, 3 skills, 1 command and 1 read-only plugin agent. It has no MCP server and
makes no model call in a hook (V2-D18). Setup puts Anthropic's layout into the repo: `CLAUDE.md`, a path-scoped rule,
a review skill, three project agents and the team memory in `.project-map/` (V2-D29). The repo's own documents and
that memory stay the source of its knowledge.
- Claude sees an index of them, is made to decide which bear on its task, and reads those itself (V2-D22).
- What a session decides, and no document holds, Claude writes as versioned entries in topic files (V2-D13, D14,
  D30). Uncommitted entries are labelled until a commit reviews them.
- A dream, run on demand, reads this repo's past sessions and proposes what the memory missed (V2-D31). Nothing it
  proposes binds until the user accepts it and commits it.

Everything a person needs is readable and correctable with the plugin off (PM4).

## Files

| Path | What | Who writes it | Decision |
| --- | --- | --- | --- |
| the repo's documents (`.md`, `.mdx`, `.markdown`, `.txt`, `.rst`) | the project's own rules and knowledge | the project's people | D15, D22 |
| `CLAUDE.md`, `.claude/rules/project-map.md` (`paths: .project-map/**`), `.claude/skills/map-review/`, `.claude/agents/{decision-checker,codebase-guide,memory-curator}.md`, `.gitattributes` (`dreams.md merge=union`) | the layout. Each file is created with `wx` only when missing. An existing `CLAUDE.md` (or `.claude/CLAUDE.md`) or `.gitattributes` that lacks setup's section or line gets it appended when git shows the file committed and unchanged; otherwise setup shows the user the lines to add (4b). Nothing is committed | `/second-brain:setup` | D29 |
| `.claude/agent-memory/<agent>/` | the project agents' notes (`memory: project`; needs Claude Code's auto memory on) | the agents | D21, D29 |
| `.project-map/*.md` | topic files with `name` and `description` front matter, holding entries: a heading, the quote, `id`, `source` ending in a date, `when`, `verified`, and optionally `review`, `status` (naming the replacing `id`), and `proposed` (a dream's, until accepted; then `origin`). `README.md` explains the format, and `dreams.md` logs each dream. `captured.md` from 2.2.0 stays valid | Claude under the capture instruction; a dream's proposals; committed with the work | D11, D13, D14, D16, D28, D30 |
| `.claude/rules/*.md.draft`, `.claude/skills/*/SKILL.md.draft` | a dream's rule and skill drafts. Claude Code loads only names ending in `.md`, so a draft binds nothing until `/map-review` promotes it | the dream's finish step | D31 |
| `.project-map/.dream-run/` | one dream's digests and staged proposals, removed when it closes; never listed | `/second-brain:dream` | D31 |
| `${CLAUDE_PLUGIN_DATA}/repos/<repoKey>/` | per machine: `dirs.log` (the transcript folders session start has seen), `state.json` (sessions a dream has read, the last dream), `dream.lock`, `undone/` (snapshots a failed dream restores) | session start (one `dirs.log` line); the dream | D31, D32 |
| no cache | the index is built at each session start from git's file list, plus the untracked files under `.project-map/` | the plugin | D15, D18 |

## Hooks

Node 20, exec form. Each hook takes the git toplevel as the repo's root. At most 100 ms of added p95 at 1 session on
every CI machine, and at 8 concurrent on the reference machine in its reference state: a CPU sample of at most 10%
before each run, and empty Node at most 100 ms p95 (V2-D18). `SessionStart` runs in shell form once and says when Node
is missing.

| Event | What it does | Bytes | Reaches (D12) | Decision |
| --- | --- | --- | --- | --- |
| `SessionStart`: `startup`, `clear`, `resume`, `compact` | the capture instruction, then the document index by directory. Once map files have front matter, the map's line is a catalog: each topic file's description and its counts of entries, due entries and proposals. Past Claude Code's 10,000-character cap, the index is cut at a directory, with the map's line kept first. Then the line asking Claude to name the decisions it followed | 1,794 B + the index + 304 B | Claude's context | D13, D14, D22, D23, D30 |
| the same, `startup` and `clear` only | for the user, in `systemMessage`: what waits for review (proposals, drafts); a dream that is due (10 or more new sessions; 7 days with 3 or more; sessions Claude Code's cleanup deletes within 5 days); a dream that did not finish. On any source, a line while v1's shims are on disk | 0 in Claude's context | the user only | D27, D32 |
| `UserPromptSubmit`, the first typed prompt and the first after each compaction (a subagent's report or another session's message is skipped) | the forced decision: per index directory yes or no, then read the yes ones before changing anything | 227 B | Claude's context | D22 |
| `PostToolUse` after a Read of a `.project-map/*.md` file | labels its entries. Uncommitted: "unreviewed, not yet committed". A source naming a repo file is re-found in it now: found, no label; not found, "not found word for word in <path>". Any other source: "unverified quote" (committed ones share one line of ranges). Also: "cannot read <path>"; `status: …`; "proposed by a dream <date>, not yet accepted"; "review due since <date>"; "replaced by <id>, which the map does not hold". A file that fails to parse gets one fail-closed label. Past the cap, labels are cut, and the last line says to treat every later entry as unreviewed | per read | Claude's context | D14, D16, D28, D30 |
| `PostToolUse` and `PostToolUseFailure` on Bash, started by `if: Bash(*.project-map*)` | every uncommitted entry's labels, and the labels of committed entries the command's output shows | per command | Claude's context | D14 (06, 2o) |

No `Write`, `Edit` or `Stop` hook: D20's write-time net is the `decision-checker` project agent, which Claude hands
a decision check to. Not used: `PreToolUse` (D18), `SubagentStart` (subagents do not see the index), MCP.

## Skills, command and agents

Each skill and the command grants Bash only for its own script. The skills set `disable-model-invocation`, so only
the user starts them.

| Name | What it does | Decision |
| --- | --- | --- |
| `/second-brain:setup` | creates the layout above at the top of a git repo. Refuses a home folder, and any target a link would carry out of the repo. Warns when auto memory is off. Its report names the branch and the uncommitted work already there (N9), the kept plugin files that differ from this version's templates (N10), and where the agents keep notes (N11) | D29 |
| `/second-brain:dream` | *prepare*: lock, snapshot, and turn unread transcripts into tagged digests. *Analyze*: one `dream-analyzer` call per digest. *Stage*: the main session writes proposals. *Finish*: format lint, privacy and secret scan, and provenance (a proposal must rest on the user's typed lines, a chosen answer or a tracked file); committed entries are never changed; drafts are written. *Close*: compare with the snapshot, write the log line, move the watermark. All in one turn, since the skill's grant ends with it | D31 |
| `/second-brain:status` | the report: stale entries (the read hook's states, plus a source committed after its `verified` date, and a repo path the entry names that is gone (N12)), what waits for review, the last dream and the sessions since, uncommitted agent memory. Changes no file | D30, D32 |
| `/second-brain:onboard` | checks that Node and git are present and reports the index, with a count of uncommitted map files | D15 |
| `dream-analyzer` (plugin agent) | reads one digest and returns candidates, each resting on a typed or chosen line. Tools: Read, Grep, Glob | D31 |
| `decision-checker`, `codebase-guide`, `memory-curator` (project agents, from setup) | check a change against the recorded decisions; keep navigation notes; flag due and duplicate entries. `memory: project`, no Bash | D20, D21, D29 |
| `/map-review` (project skill, from setup) | walks the user through proposals, drafts and due entries, then the commit | D29, D31 |

## Budgets (PM8)

- Always on, per session: 1,794 B of instruction, 304 B of naming, and the index: 0.3 KB in a fresh repo after setup,
  2 KB in P1, 6 KB in P2. Plus 227 B per forced decision.
- Hooks: added p95 at most 100 ms (V2-D18). 2.3.0's release bench: at most 62.7 ms at 8 concurrent (06, S8).
- Surface: 4 hook events, 3 skills, 1 command, 1 plugin agent, 0 MCP servers.

## Known weaknesses, each with its trigger

- **Cost.** In the document-heavy repo, the route spent about three times push's tokens, mostly in subagent
  research. It reopens D22 if the eval puts v2 above M1's no-worse ceiling.
- **A change named after the epoch's first prompt** (2e; outside D22's claim since 2026-10-26). On P2, R5 was missed
  after a vague first prompt in 4 of 5 runs, and after a task switch following a compaction in 3 of 5. Bringing these
  back into scope reopens D22.
- **Untested shapes.** Investigation tasks, and an index past 86 directories or past 6.1 KB. These are D22's
  triggers. A cut index has had no forced decision measured on it.
- **Letter case** in the map folder is folded as the repo's config file says, ASCII only (06, 2h). A value set only in
  a global, system, included or worktree config is not read.
- **Unlabelled reads.** Subagents, project agents included, do not see the index, and their reads of the map arrive
  unlabelled (D12). So does a map file met by the Grep tool, a repo-wide search, a script, or PowerShell. A dream's
  proposals therefore carry their `- proposed:` line in the file itself (D30). These are accepted risks.
- **An automatic compaction inside a turn** is followed by writes before the next prompt, so the re-forced decision
  comes too late. A D22 trigger.
- **Capture may copy repo rules** into the map. D14's accepted risk, watched by its noise trigger.
- **Stale documents.** A stale document that contradicts a binding rule is not flagged. Only map entries are labelled.
- **Session start builds the index each time:** 41 ms (2.2.0) and 55 ms (2.3.0, with the nudge's worst case) of
  added p95 at 8 concurrent on P2's shape. A repo with a much larger file list may pass 100 ms; a cache is the fallback.
- **Small machines with many sessions.** On a 4-core runner at 8 concurrent, session start and a map read added 143
  to 260 ms p95 in 2.0.0's alpha builds (D18's two-part budget, by the user's choice).
- **Friction.** A forced decision at the session's first prompt and after each compaction.
- **Claude Code's rule folder is left to Claude Code** (06, 2k). After a compaction, an edit made without a new Read
  gets no re-delivery of a `paths:` rule. Watched by D22's selection-miss trigger. A nested `.claude/rules/` stays
  listed.
- **Pattern rules on Opus.** P1 R2 was missed under every pull arm; only a fed-back check held it. Whether the
  `decision-checker` holds it is not measured.
- **2.3.0's doubted items** (06, S8):
  - the dream loop scored 4 of 5, its bar, in both acceptance attempts. Each miss filed a repeated correction as an
    entry;
  - the agent rate was measured only in the acceptance repo;
  - the index still lists `.claude/agents`, `skills`, `commands` and `output-styles`.
- **Template text reaches new setups only.** Setup never overwrites a file, so a repo set up before 2.4.0 keeps the
  old rule, skill, agents and map README. Since 2.4.0 setup's report lists the kept files that differ (N10); the
  user compares them by hand.
- **The session-start index in a large repo** (the field report of 2026-11-23): about 850 documents in 179
  directories listed 71. D22 is reopened for a size budget or a summary mode.

## Not v2

Everything in the charter's non-goals. Also: no per-language code parser (V2-D21: `codebase-guide`'s notes are the
inventory aid), no conversion of documents (V2-D15), no selector, and no rule text pushed for a document's rules
(V2-D22). The dream keeps no copy of a transcript (D10).
