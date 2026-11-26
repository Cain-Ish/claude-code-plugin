---
name: status
description: Shows how current this repo's team memory is - when it last changed, the last dream and the sessions since, what waits for review, and which entries are stale. Use when asked how current the team memory is.
allowed-tools: Bash(node "${CLAUDE_PLUGIN_ROOT}/scripts/status.mjs":*)
---
!`node "${CLAUDE_PLUGIN_ROOT}/scripts/status.mjs" "${CLAUDE_PLUGIN_DATA}"`

Show the user the report above as it is. Then name the next step in one or two lines: `/map-review` for stale entries
or what waits for review, `/second-brain:dream` when a dream is due. Change no file. Run any command with the Bash tool, never PowerShell.
