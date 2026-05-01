---
name: improve
description: Manual deep-dive on the current/most-recent session. Proposes up to 3 grounded "pin" candidates the user can accept/reject/edit. No autonomous critic.
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Write Edit Bash(git log:*) Bash(jq *) Bash(date *) WebSearch mcp__knowledge-base__knowledge_search mcp__knowledge-base__pin_to_user mcp__knowledge-base__pin_to_project mcp__knowledge-base__archive_to_wiki
---

# Improve

Generate up to 3 candidate "pins" from this session and let the user accept/reject/edit each.

## Steps

### 1. Collect signals

Read session activity since SessionStart. Identify:
- Explicit user feedback ("don't do X" / "always Y") → candidate for USER.md or PROJECT.md Conventions
- Decisions explicitly stated ("we picked X over Y because...") → candidate for PROJECT.md Recent decisions
- Blockers added or resolved → candidate for PROJECT.md Open blockers or archive_to_wiki

### 2. Filter

For each candidate, ask: "Would the user want to remember this in 2 weeks?" If no, drop. Keep at most 3 candidates.

### 3. Present each candidate

For each surviving candidate, show:
- Proposed text
- Destination (USER.md / PROJECT.md:section / wiki/<category>/)
- Single Y/N/edit prompt

### 4. Apply accepted

For each accepted candidate, call the appropriate MCP tool: `pin_to_user`, `pin_to_project`, or `archive_to_wiki`. For wiki entries that don't fit the pin tools, write directly via `Write` tool.

### 5. Done

Report what was pinned. No critic-log, no decay tracking, no auto-extraction.
