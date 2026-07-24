---
name: release-version-bump-and-changelog
description: Workflow command scaffold for release-version-bump-and-changelog in claude-code-plugin.
allowed_tools: ["Bash", "Read", "Write", "Grep", "Glob"]
---

# /release-version-bump-and-changelog

Use this workflow when working on **release-version-bump-and-changelog** in `claude-code-plugin`.

## Goal

Performs a release by bumping version numbers and updating changelogs and marketplace metadata.

## Common Files

- `.claude-plugin/plugin.json`
- `.claude-plugin/marketplace.json`
- `cost-router/.claude-plugin/plugin.json`
- `cost-router/CHANGELOG.md`
- `CHANGELOG.md`

## Suggested Sequence

1. Understand the current state and failure mode before editing.
2. Make the smallest coherent change that satisfies the workflow goal.
3. Run the most relevant verification for touched files.
4. Summarize what changed and what still needs review.

## Typical Commit Signals

- Update the plugin or marketplace version in plugin.json and/or marketplace.json.
- Update the CHANGELOG.md with release notes.
- Commit all related release metadata together.

## Notes

- Treat this as a scaffold, not a hard-coded script.
- Update the command if the workflow evolves materially.