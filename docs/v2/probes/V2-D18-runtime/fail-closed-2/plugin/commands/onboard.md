---
description: Index this project's documents for the project map, and check that Node and git are present.
allowed-tools: Bash(node:*)
---

!`node "${CLAUDE_PLUGIN_ROOT}/scripts/hook.mjs" onboard`

Report the result above to the user in at most four lines. The index is rebuilt from git's file list at every session
start, so nothing else needs to run.
