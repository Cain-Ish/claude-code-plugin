---
name: documentation-spec-plan-cycle
description: Workflow command scaffold for documentation-spec-plan-cycle in claude-code-plugin.
allowed_tools: ["Bash", "Read", "Write", "Grep", "Glob"]
---

# /documentation-spec-plan-cycle

Use this workflow when working on **documentation-spec-plan-cycle** in `claude-code-plugin`.

## Goal

Adds or updates design specs and planning documents before or alongside feature development.

## Common Files

- `docs/specs/*.md`
- `docs/plans/*.md`

## Suggested Sequence

1. Understand the current state and failure mode before editing.
2. Make the smallest coherent change that satisfies the workflow goal.
3. Run the most relevant verification for touched files.
4. Summarize what changed and what still needs review.

## Typical Commit Signals

- Create or update a design spec in docs/specs.
- Create or update a plan in docs/plans.

## Notes

- Treat this as a scaffold, not a hard-coded script.
- Update the command if the workflow evolves materially.