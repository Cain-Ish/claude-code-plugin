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
