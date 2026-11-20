---
name: setup
description: Sets up this repo for Claude in Anthropic's recommended layout. It adds CLAUDE.md, a path-scoped rule, a review skill, three project agents with project memory, and the team memory folder. It creates only what is missing.
disable-model-invocation: true
allowed-tools: Bash(node:*)
---
!`node "${CLAUDE_PLUGIN_ROOT}/scripts/hook.mjs" setup`

The report above lists what setup created, what it kept as it was, and what it leaves to the user.

1. If it created `CLAUDE.md`, fill its "Check your work" lines with this repo's real commands. Find them in its build
   files (package.json scripts, a Makefile, pyproject.toml, a .csproj and the like). Delete each line you cannot fill.
2. For each "For you" item, show the user the exact text and where it goes. Add it with an edit once they agree.
3. Tell the user, in at most six lines: what was created, any warning, and that nothing is committed. They review the
   diff, then commit it.
