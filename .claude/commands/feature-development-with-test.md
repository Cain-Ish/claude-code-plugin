---
name: feature-development-with-test
description: Workflow command scaffold for feature-development-with-test in claude-code-plugin.
allowed_tools: ["Bash", "Read", "Write", "Grep", "Glob"]
---

# /feature-development-with-test

Use this workflow when working on **feature-development-with-test** in `claude-code-plugin`.

## Goal

Implements a new feature or enhancement, updating implementation files and adding or updating associated tests.

## Common Files

- `agents/*.md`
- `skills/*/SKILL.md`
- `tests/test-*.sh`

## Suggested Sequence

1. Understand the current state and failure mode before editing.
2. Make the smallest coherent change that satisfies the workflow goal.
3. Run the most relevant verification for touched files.
4. Summarize what changed and what still needs review.

## Typical Commit Signals

- Edit or create implementation files (e.g., agent or skill markdown files).
- Update or add corresponding test scripts to validate the new or changed behavior.

## Notes

- Treat this as a scaffold, not a hard-coded script.
- Update the command if the workflow evolves materially.