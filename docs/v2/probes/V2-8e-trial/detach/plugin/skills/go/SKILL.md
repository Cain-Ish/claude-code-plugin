---
name: go
description: Starts the 8e detach probe. Used only by the probe.
allowed-tools: Bash(node:*)
disable-model-invocation: true
---
!`node "${CLAUDE_PLUGIN_ROOT}/start.mjs"`

Reply with the single word done.
