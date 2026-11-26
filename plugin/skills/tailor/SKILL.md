---
name: tailor
description: Makes an agent, skill or path rule for this repo from a gap its sessions show, as a draft, and writes the cases that test a draft or an artifact against a run without it, judged by the repo's own check scripts. Use when asked to make or test an agent, skill or path rule here.
allowed-tools: Bash(node "${CLAUDE_PLUGIN_ROOT}/scripts/trial.mjs" cli:*), Bash(node "${CLAUDE_PLUGIN_ROOT}/scripts/trial.mjs" draft:*)
argument-hint: "[what to make] | make <name> | cases <path> | show <name>"
---
# Tailor

```!
node "${CLAUDE_PLUGIN_ROOT}/scripts/trial.mjs" cli <<'SECOND_BRAIN_WORDS_q7Xk2Vw9'
$ARGUMENTS
SECOND_BRAIN_WORDS_q7Xk2Vw9
```

The output above is the script's. If it shows a trial, or says the trial stopped, give it to the user as it is and
stop, with the `! node` line on a line of its own, exactly as printed: not quoted, not in code marks. Never run `trial.mjs` yourself except `draft` in step 4: a trial starts only when the person types the line that
begins with `! node`, which `show` printed, after reading it. Read the repo with Read, Grep and Glob, not Bash.
Run `draft`, and any test of a check, with the Bash tool, never PowerShell: the grant covers Bash.

If it says to write only the cases, do steps 5 and 6 for that artifact. Otherwise, this is a request to make one agent,
skill or path rule: $ARGUMENTS

A made artifact stays a draft, which Claude Code never loads, until the person promotes it in `/map-review`, which
shows its trial verdict first. This skill promotes nothing and commits nothing. Follow the guidelines printed above.

## Making

1. **The gap.** Name what shows it:
   - the user's typed words in this repo's sessions;
   - a map entry;
   - the user's request in this session.

   A request counts only when it names a task the artifact will do, and at least one example or rule of how this repo
   does it. Then go on to step 2. So does `make <name>`: the person's pick of a gap a survey listed, with its evidence.

   **A request that names no task** ("make agents for this repo", "make skills here") asks for a survey. Make nothing
   yet:
   1. **Survey, read only.** What the code does: the README or `CLAUDE.md`, the layout, and the build, test and check
      scripts. What the repo already holds: `.claude/` rules, skills and agents. The map's topic files, and the dream log
      `.project-map/dreams.md`.
   2. **List the gaps you found.** Each is a task the repo repeats, or a rule it keeps needing, with its evidence (a map
      entry's id, a file, a script, a dream log line) and its smallest home by the guidelines' table, with why.
   3. **Say what you will not make, and why,** by the guidelines' first section.
   4. **Ask which to make, and stop.** Make nothing until the person picks one: end with the question "Which one
      should I make?" and, for each gap listed, the exact line to type with its name filled in, such as
      `/second-brain:tailor make add-migration`.

   With no gap in the request, the code or the map, say what evidence you would need, and stop.
2. **The home.** Pick the smallest home that holds it, by the guidelines' table, and check that nothing in the repo
   already does it (`.claude/`, `CLAUDE.md`, `.project-map/`). For a `CLAUDE.md` line, a check or a hook, there is no
   draft form: show the user the exact text and where it goes, write it only on their yes, and stop here.
3. **Grounding,** as the guidelines say.
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
   - Its prompts follow the guidelines' cases section.
6. **Tell the user:** the draft's path, the case file, and that a trial runs only from what the last commit holds.
   Ask them to commit the case file and its checks, then type `/second-brain:tailor show <name>`, read what it will
   run, and type the `! node …` line it prints, themselves. Stop here.
