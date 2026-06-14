---
name: improve
description: Manual deep-dive on the current/most-recent session. Proposes up to 3 grounded "pin" candidates the user can accept/reject/edit. No autonomous critic.
# Surface-collapse (0.29.0): not a user slash command. Session-insight capture is now automatic
# — dream mines transcripts into wiki pages, and the pin_to_user / pin_to_project MCP tools let
# the model record pins on request. This manual 3-candidate pinning flow is retired as a command.
user-invocable: false
disable-model-invocation: true
allowed-tools: Read Write Edit Bash(git log:*) Bash(jq *) Bash(date *) WebSearch mcp__plugin_second-brain_knowledge-base__knowledge_search mcp__plugin_second-brain_knowledge-base__pin_to_user mcp__plugin_second-brain_knowledge-base__pin_to_project mcp__plugin_second-brain_knowledge-base__archive_to_wiki
---

# Improve

Generate up to 3 candidate "pins" from this session and let the user accept/reject/edit each.

## Steps

### 1. Collect signals

Read session activity since SessionStart. Identify:
- Explicit user feedback ("don't do X" / "always Y") → candidate for USER.md or PROJECT.md Conventions
- Decisions explicitly stated ("we picked X over Y because...") → candidate for PROJECT.md Recent decisions
- Blockers added or resolved → candidate for PROJECT.md Open blockers or archive_to_wiki

### 1b. Check persona signals

Read `~/.second-brain/persona-signals.jsonl` (if it exists). Find entries where:
- `count >= 3` (pattern observed across 3+ sessions)
- `graduated == false`
- Signal text not already present in USER.md (case-insensitive substring match)

For each qualifying signal, create a candidate pin:
- **Proposed text**: the `signal` field, rewritten as a concise USER.md rule
- **Destination**: USER.md, under the section matching the category:
  - `code_style` → ## Approach or ## Hard Rules
  - `communication` → ## Communication
  - `workflow` → ## Approach
  - `tooling` → ## Hard Rules
  - `decision_making` → ## Approach
- **Evidence**: show the `count` and top 2 evidence entries so the user can verify the pattern is real

After user accepts: call `pin_to_user`, then edit `persona-signals.jsonl` to set `graduated: true` on that entry so it won't be re-proposed.

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
