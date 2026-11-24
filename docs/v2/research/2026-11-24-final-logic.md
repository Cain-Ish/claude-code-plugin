# One final logic: what the dream and the trial can stand on (2026-11-24)

For section 8's group N (06): the user's agreed list, read against Claude Code's documentation, against what this
machine's transcripts hold, and against 7a's failures. Sources are the documentation pages named below (read by a
`claude-code-guide` subagent on 2026-11-24, quoted in its reading) and field names observed locally on CLI 2.1.331.
No transcript text is quoted.

## 1. The agreed list

1. Decide from evidence, not at setup: what was used, what failed, what was corrected after use, plus the team's
   steering.
2. Make a draft only on a gap; retire what adds nothing.
3. Self-evaluation with a strict judge: outcomes a script checks, at least 3 runs per case.
4. Monorepos: place an artifact where its evidence clusters.

## 2. Platform facts

**A skill's `!` commands** ([skills](https://code.claude.com/docs/en/skills.md)):
- each "runs under the Bash tool's default 2-minute timeout". A command the Bash tool does not background is killed at
  the timeout, and "That failure aborts the invocation";
- "Injected commands never prompt for permission while the skill renders", and are checked against the permission rules;
  `allowed-tools` "grants permission for the listed tools during the turn that invokes the skill";
- output past the inline ceiling (about 30,000 characters) arrives as a file path and a preview.

So a trial of several nested sessions cannot run inside a skill's `!` line. A command that starts it detached and
returns at once can.

**Subagent transcripts** ([sub-agents](https://code.claude.com/docs/en/sub-agents.md)):
- stored in `~/.claude/projects/{project}/{sessionId}/subagents/` as `agent-{agentId}.jsonl`, and deleted after
  `cleanupPeriodDays` (30 by default);
- a name lookup is documented: "look for that name in the `agent-{agentId}.meta.json` files".
- Observed here, on CLI 2.1.331 (field names only):
  - each `meta.json` holds `agentType` and the parent's `toolUseId`;
  - the transcript's records carry `isSidechain: true` and `agentId`.

  The fields themselves are undocumented, so a reader must count a missing field as "unknown", never as zero.

**Nested `.claude/` folders** ([skills](https://code.claude.com/docs/en/skills.md),
[memory](https://code.claude.com/docs/en/memory.md), [sub-agents](https://code.claude.com/docs/en/sub-agents.md)):
- a subdirectory's skills "load the first time Claude reads or edits a file in that subdirectory";
- rules in nested `.claude/rules/` and a subdirectory's `CLAUDE.md` load on demand;
- project agents are found "by walking up from the current working directory", so a package's `.claude/agents/` loads
  only when a session starts at or below it.

So placement by package suits rules and skills. An agent draft stays at the root.

**Drafts:** no page says that `SKILL.md.draft` or `name.md.draft` is never loaded. Discovery is described by `SKILL.md`
and by `.md` files, and D31's probe showed a root agent draft is not loaded. A nested draft needs its own small probe.

**Nested `claude -p`** ([headless](https://code.claude.com/docs/en/headless.md)):
- without `--bare` it loads the working directory's settings and hooks;
- since v2.1.302 it "start[s] in Manual mode when nothing sets a permission mode";
- inheritance from a parent session is not documented.

## 3. What 7a's failures say about the trial

From 06, section 7: the trial failed on
- reads outside the repo (the guidelines file, records in the data folder);
- the guarded `.claude/` write in a headless harness;
- a model repairing a draft it was asked to test;
- the case file, with its expected outcomes, reaching the "without" arm, and the wrong yardstick;
- a promotion step after the user's yes, when the skill's one-turn grant had ended.

Each failure sits where a model session runs or judges the trial. The level up is to take the model out of both:
- the user's own command is the yes;
- a script runs both arms, detached, in scratch copies without the case file;
- each case's `check` command decides by its exit code;
- `map-review` only reads the recorded verdict.

## 4. Consequences for the design

- **Telemetry** reads what the transcripts already hold:
  - each Skill's name and each Agent's `subagent_type` in the main transcript;
  - a tool result's `is_error`;
  - the typed line that follows a use;
  - runs per agent type from the `meta.json` files, with a watermark so the next dream does not count them again.
- **Counts are per machine:** a dream reads only this machine's sessions. Any "unused" line has to say so, or its counts
  have to live in the tracked log, since one person's unused skill may be a teammate's daily tool.
- **"Adds nothing"** means the run without it does as well, which is the trial's verdict. "Unused" is a different
  signal: no use in N sessions. The report keeps the two apart.
- **D-3's redaction** removes absolute paths whole (8a's pre-flight: 306 of 380 tool lines). Placement needs repo paths,
  so the repo's root has to be made relative before redaction.
- **A case's `check` command is text from the repo,** which is D14 and D18's boundary. One option is to run only a case
  file that HEAD holds unchanged, so a commit, which is a person's review, has seen it.
- **An agent draft cannot be trialled as is:** D34's probe 1 found a draft agent loaded but not delegated to. Its cases
  must name it, or agents stay outside the trial.
- **Steering:** setup never replaces a repo's `dreams.md`, so a steering section must work when it is absent.
