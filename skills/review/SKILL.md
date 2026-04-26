---
name: review
description: Deep code review of recent changes. Goes beyond the automatic quality gate to check architecture, design patterns, test coverage, performance, and accessibility. Use when you want a thorough review before shipping.
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Bash(git *) Bash(find *) Bash(grep *) Bash(cat *) Bash(ls *) WebSearch WebFetch
argument-hint: "[file-path or git-range]"
---

# Deep Code Review

Comprehensive review going beyond the automatic quality gate.

## Tool Integration

Read ~/.second-brain/tool-registry.json to discover available tools.
Use documentation tools to verify API usage against current best practices.

For deeper structural review (architecture, performance, subtle bugs), spawn the dedicated subagent:

```
subagent_type: "second-brain:quality-reviewer"
```

It runs with `maxTurns: 20` and returns findings classified CRITICAL / WARNING / INFO.

## What to Review

If `$ARGUMENTS` specifies a file, review that file.
If it specifies a git range (e.g., `HEAD~3..HEAD`), review those changes.
If no argument, review all uncommitted changes (`git diff` + `git diff --staged`).

## Review Dimensions

### 1. Architecture & Design
- Does the code follow existing patterns in the project?
- Are responsibilities clearly separated?
- Is the abstraction level appropriate?
- Any unnecessary coupling or hidden dependencies?

### 2. Correctness
- Do all code paths produce correct results?
- Are error conditions handled appropriately?
- Are there race conditions or concurrency issues?
- Edge cases: null, empty, boundary values, overflow

### 3. Performance
- Any N+1 query patterns?
- Unnecessary re-renders or recomputations?
- Large allocations in hot paths?
- Missing caching where appropriate?

### 4. Security
- Input validation at system boundaries
- Output encoding (XSS prevention)
- Authentication and authorization checks
- Secrets management
- SQL injection, command injection, path traversal

### 5. Testability & Tests
- Are new behaviors tested?
- Are tests meaningful (not just coverage padding)?
- Can the code be tested in isolation?

### 6. Maintainability
- Clear naming and structure?
- Would a new team member understand this?
- Any implicit assumptions that should be documented?

### 7. Architectural review checklist (mandatory for systems touching data-over-time, integrations, or onboarding)

Walk through each dimension explicitly. Surface gaps proactively — these are the questions a careful reviewer should raise without being prompted:

- **Update semantics** — when new info contradicts old, does the system overwrite/merge/append? Is the body the current state or a layered history? Is stale data ever cleaned up?
- **Cross-surface integration** — if there's a user-visible surface (graph view, dashboard, Obsidian vault, IDE panel), does the relevant data actually show up there, or is internal state siloed?
- **Onboarding UX** — what happens between "user installs" and "user runs first useful command"? Hidden manual build steps? Missing init scripts? Features that silently fail without a setup ritual?
- **Cross-platform shells and paths** — how do `~`, `$HOME`, config locations resolve on Linux, macOS, Git Bash on Windows, and native Windows shells? GNU-only flags? `mktemp`/`find`/`sed` behavior differences?
- **Proactive vs lazy context loading** — does the system load relevant context automatically when the conversation shifts, or only on explicit request? If lazy, is the user expected to know what to query?
- **Silent failure modes** — what breaks silently? Missing file no one notices, hook that gets ignored, permission silently dropped, env var that doesn't exist on this version?

If any dimension doesn't apply, name it and skip explicitly. Don't omit it without comment.

## Output Format

```
# Code Review: [scope]

## Summary
[1-2 sentence overview]

## Issues Found

### Critical
- [must-fix before merge]

### Warnings
- [should-fix, but not blocking]

### Suggestions
- [nice-to-have improvements]

## What Looks Good
- [positive callouts]
```

## Learning Integration

After the review, check if any findings should become new quality rules:
- If an issue type would be caught by the quality gate, propose adding it to `~/.second-brain/quality-rules.md`
- This makes the automatic quality gate smarter for future code
