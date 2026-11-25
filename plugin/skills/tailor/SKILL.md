---
name: tailor
description: Makes an agent, skill or path rule for this repo from a gap its sessions show, as a draft, and tests a draft or an artifact against a run without it, judged by the repo's own check scripts. Use when you want to create, change or test an agent, skill or rule here.
allowed-tools: Bash(node "${CLAUDE_PLUGIN_ROOT}/scripts/trial.mjs" cli:*), Bash(node "${CLAUDE_PLUGIN_ROOT}/scripts/trial.mjs" draft:*)
argument-hint: "[what to make] | show <name>"
disable-model-invocation: true
---
# Tailor

```!
node "${CLAUDE_PLUGIN_ROOT}/scripts/trial.mjs" cli <<'SECOND_BRAIN_WORDS'
$ARGUMENTS
SECOND_BRAIN_WORDS
```

The output above is the script's. If it shows a trial, or says the trial stopped, give it to the user as it is and
stop. Never run `trial.mjs` yourself except `draft` in step 4: a trial starts only when the person types the line that
begins with `! node`, which `show` printed, after reading it.

Otherwise, this is a request to make one agent, skill or path rule: $ARGUMENTS

Each made artifact starts from a gap, stays a draft, and is tested against a run without it before anyone keeps it.
This skill promotes nothing and commits nothing.

## Making

Follow **Guidelines**, at the end of this file.

1. **The gap.** Name what shows it:
   - the user's typed words in this repo's sessions;
   - a map entry;
   - the user's request in this session.

   A request counts only when it names a task the artifact will do, and at least one example or rule of how this repo
   does it. Then go on to step 2.

   **A request that names no task** ("make agents for this repo", "make skills here") asks for a survey. Make nothing
   yet:
   1. **Survey, read only.** What the code does: the README or `CLAUDE.md`, the layout, and the build, test and check
      scripts. What the repo already holds: `.claude/` rules, skills and agents. The map's topic files, and the dream log
      `.project-map/dreams.md`.
   2. **List the gaps you found.** Each is a task the repo repeats, or a rule it keeps needing, with its evidence (a map
      entry's id, a file, a script, a dream log line) and its smallest home by the table below, with why. An agent only
      for a task that needs its own context, its own tools or its own notes.
   3. **Say what you will not make, and why:** Claude does it anyway, the repo already shows it, or the evidence is
      thin.
   4. **Ask which to make, and stop.** Make nothing until the person picks one; then take that gap through the steps
      below.

   With no gap in the request, the code or the map, say what evidence you would need, and stop.
2. **The home.** Pick the smallest home that holds it, by the guidelines' table, and check that nothing in the repo
   already does it (`.claude/`, `CLAUDE.md`, `.project-map/`). For a `CLAUDE.md` line, a check or a hook, there is no
   draft form: show the user the exact text and where it goes, write it only on their yes, and stop here.
3. **Grounding.** Check every path, command, script and name you will state. Keep only what Claude cannot infer from
   the repo.
4. **The draft.**
   1. Write it in `.project-map/drafts/<name>/`:
      - `SKILL.md` for a skill, with any script it calls beside it, named in it;
      - `agent.md` for an agent, with `name`, `description` and `tools`;
      - `rule.md` for a path rule.
   2. Run `node "${CLAUDE_PLUGIN_ROOT}/scripts/trial.mjs" draft <name> <skill|agent|rule>`. It moves the files into
      `.claude/` as a draft, which Claude Code never loads, and refuses to overwrite anything. This skill grants that
      one command, so run it even when other commands in this session wait for approval. The draft's path is
      `.claude/skills/<name>/SKILL.md.draft`, `.claude/agents/<name>.md.draft` or `.claude/rules/<name>.md.draft`.
5. **The cases.** Write `.project-map/evals/<name>.json`:
   ```
   { "artifact": "<the draft's path>", "runs": 3, "cases": [
     { "id": "<a-slug>", "prompt": "<what a person would type>", "tools": ["Read", "Edit", "Skill"],
       "check": ".project-map/evals/checks/<name>-<id>.mjs" }, …,
     { "id": "<a-slug>", "prompt": "<a task where it should not be used>", "tools": ["Read", "Edit", "Skill"],
       "use": false, "check": "…" } ] }
   ```
   - `runs` is 3 to 5. A session has only the tools its case lists, so every case of a skill lists `Skill`, and every
     case of an agent lists `Agent`. List `Bash` only when the task needs it.
   - Each check is a Node script that exits 0 when the work in its working folder meets the case, and 1 when it does
     not. It reads what the session produced; it never asks a model. It runs alone, so it imports no file beside it.
   - For an agent, each prompt names it: "use the `<name>` agent to …".
6. **Tell the user:** the draft's path, the case file, and that a trial runs only from what the last commit holds.
   Ask them to commit the case file and its checks, then type `/second-brain:tailor show <name>`, read what it will
   run, and type the `! node …` line it prints, themselves. Stop here.

## Guidelines

These come from Claude Code's documentation (subagents, skills, memory, the features overview) and Anthropic's skill
authoring guide, re-read on 2026-11-24. They are principles, not a field list.

### Make nothing without a gap

Context that Claude writes for itself, untested, has measured as a loss. Skills Claude generated for itself scored
below having no skill at all (SkillsBench, 2026). Context files written by a model raised cost by over 20% without
raising success (the AGENTS.md study, 2026).

So an artifact starts from something that went wrong, or that a person asked for and explained. Leave it out when
any of these holds:
- the map, `CLAUDE.md` or a rule already says it;
- the repo shows it: its files, its scripts, its existing examples;
- Claude would do it anyway.

A recorded rule is not a procedure. When the map holds a task's rules but doing it takes several steps in a set
order, or a step that must be exact, the procedure is the gap, and its home is a skill that follows those rules.

### Choose the smallest home

| What it is | Its home |
| --- | --- |
| Something every session needs | One line in `CLAUDE.md` ("Keep CLAUDE.md under 200 lines") |
| A rule for certain files only | A path rule, `.claude/rules/<topic>.md`, with `paths:` globs; it loads only when Claude works on matching files |
| A procedure needed sometimes, of several steps | A skill, `.claude/skills/<name>/SKILL.md` ("when you keep pasting the same instructions, checklist, or multi-step procedure into chat") |
| A task that needs its own context, its own tools or its own notes | An agent, `.claude/agents/<name>.md` ("when you need context isolation or when your context window is getting full") |
| Something that must happen every time, without judgment | A hook or a check (a test, a lint rule). An instruction "is a request, not a guarantee" |

### Ground it in this repo

- Check every path, command, script and name it states: open the file, list the folder, run the command's help.
- A script it calls must exist, or be written beside it and named in it. One plausible skill failed because the
  script it called was not in the repo.
- Write only what Claude cannot infer: the project's non-standard ways, the order of steps, what counts as done.
  Repository overviews did not help in the AGENTS.md study.

### A skill

- **`name`** is the folder name, lowercase with dashes.
- **`description`** says what it does, then when to use it, with the words a user would type.
  - Put the key use case first. Description and `when_to_use` together are cut at 1,536 characters.
  - Too broad, and it fires on the wrong tasks. Too narrow, and it never fires.
- **`disable-model-invocation: true`** for a procedure with side effects or a chosen moment, such as a deploy or a
  release: then only the user starts it.
- **The body:**
  - the steps for the kind of task, not one past instance, each ending with how to tell it is done;
  - under 500 lines, with longer material in files one level below it;
  - a step that must be exact goes into a script the skill runs.
- **A rule that must hold every time** goes into a hook, since Claude may stop following a skill later in a session.

### An agent

- **One task.** "Each subagent should excel at one specific task." An agent is a task agent, never a persona for a
  role, and its name holds no `:`.
- **`description`** says when to delegate to it, briefly, in words that single it out from the other agents. Add "use
  proactively" only when it should run unasked.
- **`tools`** names only what it needs. Left out, the agent inherits every tool.
- **`memory: project`,** when it should keep notes across sessions. They live in `.claude/agent-memory/<name>/`, and
  the first 200 lines (25 KB at most) of its `MEMORY.md` load at its start.
- **The body:**
  - one line on its job;
  - its steps;
  - when it is done;
  - what it returns: a short result, not its whole work.

### A path rule

- `paths:` front matter with the globs it covers, one topic per file, and the rule in one or two sentences.

### Cases, before anyone keeps it

- **Three or more,** taken from real sessions or the user's own examples, and one where it should not be used.
- **Each judged by a check script:** it exits 0 or 1 on what was produced, a file or a value, never on the path
  taken, and never by a model.
- **Don't tune it to its cases.** A change that only makes these cases pass is not a better artifact.
- **Retiring it.** When the trial says it adds nothing or hurts, /map-review offers to remove it, on your yes.

### It stays a draft

A made artifact is written by `trial.mjs draft`, with `.draft` at the end, which Claude Code never loads, and nothing is
committed. The person promotes it in `/map-review`, which shows its trial verdict first.
