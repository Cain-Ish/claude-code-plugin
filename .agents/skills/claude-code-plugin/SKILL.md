```markdown
# claude-code-plugin Development Patterns

> Auto-generated skill from repository analysis

## Overview
This skill teaches the core development patterns and conventions used in the `claude-code-plugin` TypeScript codebase. You'll learn about file naming, import/export styles, commit message conventions, and how to write and organize tests. This guide is ideal for contributors seeking to maintain consistency and quality in the project.

## Coding Conventions

### File Naming
- **Style:** camelCase
- **Example:**  
  - `userProfile.ts`
  - `apiClient.ts`

### Import Style
- **Relative imports are used throughout the codebase.**
- **Example:**
  ```typescript
  import { fetchUser } from './userProfile';
  ```

### Export Style
- **Named exports are preferred.**
- **Example:**
  ```typescript
  // In userProfile.ts
  export function fetchUser(id: string) { ... }
  ```

### Commit Message Conventions
- **Type:** Conventional Commits
- **Prefixes:** Only `fix` detected
- **Format Example:**
  ```
  fix: resolve issue with user authentication flow
  ```

## Workflows

### Code Fix Workflow
**Trigger:** When you need to fix a bug or issue in the codebase  
**Command:** `/fix-bug`

1. Identify the bug or issue in the code.
2. Create a new branch for your fix.
3. Make the necessary code changes, following the coding conventions.
4. Write or update corresponding tests (see Testing Patterns).
5. Commit your changes using the `fix:` prefix in the commit message.
   - Example: `fix: correct null pointer in apiClient`
6. Push your branch and open a pull request.

## Testing Patterns

- **Test File Naming:** Test files follow the `*.test.*` pattern.
  - Example: `userProfile.test.ts`
- **Testing Framework:** Not explicitly detected; follow the `*.test.ts` convention for test files.
- **Test Example:**
  ```typescript
  import { fetchUser } from './userProfile';

  test('fetchUser returns correct user', () => {
    // ...test implementation
  });
  ```

## Commands
| Command    | Purpose                                   |
|------------|-------------------------------------------|
| /fix-bug   | Start the standard bug fix workflow       |
```
