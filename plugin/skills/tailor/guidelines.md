# Guidelines

These come from Claude Code's documentation (subagents, skills, memory, the features overview) and Anthropic's skill
authoring guide, re-read on 2026-11-24. They are principles, not a field list.

## Make nothing without a gap

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

## Choose the smallest home

| What it is | Its home |
| --- | --- |
| Something every session needs | One line in `CLAUDE.md` ("Keep CLAUDE.md under 200 lines") |
| A rule for certain files only | A path rule, `.claude/rules/<topic>.md`, with `paths:` globs; it loads only when Claude works on matching files |
| A procedure needed sometimes, of several steps | A skill, `.claude/skills/<name>/SKILL.md` ("when you keep pasting the same instructions, checklist, or multi-step procedure into chat") |
| A task that needs its own context, its own tools or its own notes | An agent, `.claude/agents/<name>.md` ("when you need context isolation or when your context window is getting full") |
| Something that must happen every time, without judgment | A hook or a check (a test, a lint rule). An instruction "is a request, not a guarantee" |

## Ground it in this repo

- Check every path, command, script and name it states: open the file, list the folder, read the command's help.
- A script it calls must exist, or be written beside it and named in it. One plausible skill failed because the
  script it called was not in the repo.
- Write only what Claude cannot infer: the project's non-standard ways, the order of steps, what counts as done.
  Repository overviews did not help in the AGENTS.md study.

## A skill

- **`name`** is the folder name, lowercase with dashes.
- **`description`** says what it does, then when to use it, with the words a user would type.
  - Put the key use case first. Description and `when_to_use` together are cut at 1,536 characters.
  - Too broad, and it fires on the wrong tasks. Too narrow, and it never fires.
- **`disable-model-invocation: true`** for a procedure with side effects or a chosen moment, such as a deploy: then
  only the user starts it, Claude never sees it, and its cases start with `/<name>`.
- **The body:**
  - the steps for the kind of task, not one past instance, each ending with how to tell it is done;
  - under 500 lines, with longer material in files one level below it;
  - a step that must be exact goes into a script the skill runs.
- **A rule that must hold every time** goes into a hook, since Claude may stop following a skill later in a session.

## An agent

- **One task.** "Each subagent should excel at one specific task." An agent is a task agent, never a persona for a
  role, and its name holds no `:`.
- **`description`** says when to delegate to it, briefly, in words that single it out from the other agents. Add "use
  proactively" only when it should run unasked.
- **`tools`** names only what it needs. Left out, the agent inherits every tool.
- **`memory: project`,** when it should keep notes across sessions. They live in `.claude/agent-memory/<name>/`, and
  the first 200 lines (25 KB at most) of its `MEMORY.md` load at its start. It also turns on Read, Write and Edit with
  no path scope, whatever `tools` says: a body's "your writes go only to …" is an instruction, not a guard.
- **The body:** one line on its job; its steps; when it is done; what it returns, a short result, not its whole work.

## A path rule

- `paths:` front matter with the globs it covers, one topic per file, and the rule in one or two sentences.

## Cases, before anyone keeps it

- **Three or more,** taken from real sessions or the user's own examples, and one where it should not be used.
- **A should-use case's prompt** reaches the artifact as a person would. A skill's says the task, never the skill's
  name (the trial refuses one that names it), since a prompt that names it tests the name. A skill only the user
  starts is the exception: its prompt starts with `/<name>` (the trial checks). An agent's prompt names it, as "the
  `<name>` agent, if this repo has one; otherwise do it yourself": Claude hands a new agent a task only by its name,
  and the run without it then does the task itself.
- **The case where it should not be used** (`use: false`) never invokes it: no `/<name>`, and no agent's name.
- **Each judged by a check script:** it exits 0 or 1 on what was produced, a file or a value, never on the path
  taken, and never by a model.
- **A check accepts any wording of the fact,** and reads what changes (a version, a step's state) from the copy's own
  files, never from today's values: the trial copies the latest commit.
- **A test of the checks** matches each fact exactly as its check does. Run each check with one plain
  `node <check file>` command: no `$()`, `&&`, pipes or PowerShell. Write no other file to test it.
- **Don't tune it to its cases.** A change that only makes these cases pass is not a better artifact.
- **Retiring it.** When the trial says it adds nothing or hurts, /map-review offers to remove it, on the user's yes.
