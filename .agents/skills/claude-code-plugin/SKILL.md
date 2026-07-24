```markdown
# claude-code-plugin Development Patterns

> Auto-generated skill from repository analysis

## Overview
This skill teaches the core development patterns and conventions used in the `claude-code-plugin` TypeScript repository. You'll learn how to structure code, write and organize tests, follow commit and file naming conventions, and execute common workflows for feature development, documentation, releases, and testing.

## Coding Conventions

- **File Naming:**  
  Use kebab-case for all file names.
  ```
  // Good
  agent-behavior.ts
  cost-router/skill-handler.ts

  // Bad
  AgentBehavior.ts
  agentBehavior.ts
  ```

- **Import Style:**  
  Use relative imports.
  ```typescript
  import { doSomething } from './utils/do-something';
  ```

- **Export Style:**  
  Use named exports.
  ```typescript
  // In skill-handler.ts
  export function handleSkill() { ... }
  ```

- **Commit Messages:**  
  - Freeform style, but often prefixed with: `spec`, `plan`, `fix`, `release`
  - Keep messages concise (~72 characters on average)
  ```
  fix: correct agent response for edge case
  spec: add design for cost router
  ```

## Workflows

### Feature Development with Test
**Trigger:** When adding or modifying a feature or agent behavior  
**Command:** `/feature-with-test`

1. Edit or create implementation files (e.g., agent or skill markdown files).
2. Update or add corresponding test scripts to validate the new or changed behavior.

**Files involved:**
- `agents/*.md`
- `skills/*/SKILL.md`
- `tests/test-*.sh`

**Example:**
```bash
# Edit the implementation
vim agents/new-agent.md

# Add a test
vim tests/test-new-agent.sh
```

---

### Documentation Spec/Plan Cycle
**Trigger:** When planning or designing a new feature or bundle  
**Command:** `/new-spec-plan`

1. Create or update a design spec in `docs/specs/`.
2. Create or update a plan in `docs/plans/`.

**Files involved:**
- `docs/specs/*.md`
- `docs/plans/*.md`

**Example:**
```bash
# Add a new spec
vim docs/specs/new-feature.md

# Add a plan
vim docs/plans/new-feature-plan.md
```

---

### Release Version Bump and Changelog
**Trigger:** When ready to release a new version of a plugin or bundle  
**Command:** `/release`

1. Update the plugin or marketplace version in `plugin.json` and/or `marketplace.json`.
2. Update the `CHANGELOG.md` with release notes.
3. Commit all related release metadata together.

**Files involved:**
- `.claude-plugin/plugin.json`
- `.claude-plugin/marketplace.json`
- `cost-router/.claude-plugin/plugin.json`
- `cost-router/CHANGELOG.md`
- `CHANGELOG.md`

**Example:**
```bash
# Bump version
vim .claude-plugin/plugin.json

# Update changelog
vim CHANGELOG.md

# Commit together
git add .claude-plugin/plugin.json CHANGELOG.md
git commit -m "release: v1.2.0 and update changelog"
```

---

### Test Enhancement or Fix
**Trigger:** When fixing a bug or adding new test coverage  
**Command:** `/add-test`

1. Edit or add test scripts (e.g., `test-*.sh`) to cover new or fixed functionality.
2. Optionally update implementation files if needed for the test.

**Files involved:**
- `tests/test-*.sh`
- `cost-router/scripts/*.sh`

**Example:**
```bash
# Add a new test script
vim tests/test-bugfix.sh

# (Optional) Update implementation
vim cost-router/skill-handler.ts
```

## Testing Patterns

- **Test File Naming:**  
  Test files follow the pattern `*.test.*` or `test-*.sh`.

- **Location:**  
  Tests are located in the `tests/` directory or within relevant submodules (e.g., `cost-router/scripts/`).

- **Framework:**  
  No specific testing framework detected; shell scripts (`.sh`) are commonly used for tests.

**Example test file:**
```bash
# tests/test-skill-behavior.sh
#!/bin/bash
# Test for skill behavior
node skills/my-skill/handler.js | grep "expected output"
```

## Commands

| Command             | Purpose                                                      |
|---------------------|--------------------------------------------------------------|
| /feature-with-test  | Start a new feature or enhancement with corresponding tests  |
| /new-spec-plan      | Add or update a design spec and plan for a new feature       |
| /release            | Perform a release: bump version and update changelogs        |
| /add-test           | Add or update test scripts for new or fixed functionality    |
```
