---
name: setup
description: Sets up this repo for Claude in Anthropic's recommended layout, with CLAUDE.md, a path-scoped rule, a review skill, three project agents with project memory, and the team memory folder. It creates what is missing, adds its section to an existing CLAUDE.md, .claude/CLAUDE.md or .gitattributes that is committed and unchanged, and updates a file that is an earlier version's template, committed and unchanged.
disable-model-invocation: true
allowed-tools: Bash(node "${CLAUDE_PLUGIN_ROOT}/scripts/hook.mjs":*)
---
!`node "${CLAUDE_PLUGIN_ROOT}/scripts/hook.mjs" setup`

The report above lists what setup created, what it kept as it was, what it added to files that existed, what it
updated to this version's templates, and what it leaves to the user.

1. If it created `CLAUDE.md`, fill its "Check your work" lines with this repo's real commands. Find them in its build
   files (package.json scripts, a Makefile, pyproject.toml, a .csproj and the like). Delete each line you cannot fill.
2. If it added to files that existed, show the user the lines it added. Do not add them again.
3. For each "For you" item, show the user the exact text and where it goes. Add it with an edit once they agree.
4. For each file that differs from this version's templates, the report shows its diff against the template: lines
   marked `+` are the template's, lines marked `-` are the file's own. Show the user the `+` lines, and add them with
   an edit once they agree, keeping the file's own lines.
5. Tell the user, in at most eight lines: what was created, added or updated, what it could not update and why, any
   warning, the branch it was written
   on and any uncommitted changes that were already there, each file that differs from this version's templates, and
   whether anything was written. They review the diff, then commit it.
