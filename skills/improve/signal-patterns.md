# Signal Categorization Reference

Used by the self-improvement engine to analyze session transcripts.

## Negative Signals (Problems to Fix)

These indicate something went wrong and should be learned from:

- **User corrections**: "no", "that's wrong", "I said...", "not what I meant"
- **Repeated requests**: User asks for the same thing multiple times
- **Fix requests**: "fix this", "there's a bug", "broken", "error"
- **Retries**: "again", "retry", "redo", "try again"
- **Tool failures**: Commands that fail, wrong tool choices
- **Implementation errors**: Wrong API usage, missing imports, type errors
- **Divergence from standards**: Code that doesn't match project conventions
- **Security issues**: User catches security vulnerabilities
- **Incomplete work**: TODO/FIXME left behind, partial implementations

## Positive Signals (What Works)

These indicate successful patterns worth reinforcing:

- **Silent acceptance**: User proceeds without correction
- **Forward progress**: "yes", "good", "continue", "next"
- **Praise**: "perfect", "exactly", "great", positive feedback
- **Commits without changes**: User commits code as-is
- **Reuse requests**: User asks to apply the same approach elsewhere
- **No friction**: Complex task completed without corrections

## Neutral Signals (Emerging Patterns)

These indicate new patterns worth tracking:

- **New use cases**: Tasks or domains not previously encountered
- **Edge cases discovered**: Situations not covered by existing rules
- **Tool discovery**: New tools or approaches found during the session
- **Constraint refinement**: User clarifies preferences or requirements
- **Project conventions**: Patterns specific to this codebase

## Analysis Rules

1. **Frequency matters**: A single occurrence is noise. Recurring patterns are signal.
2. **Token budget**: Only create learnings that justify their context cost.
3. **Specificity**: "Handle errors" is too vague. "Check for empty array before .map()" is actionable.
4. **Distinguish project-specific vs universal**: Project-specific patterns go to learnings.md. Universal code quality issues go to quality-rules.md.
5. **Include the WHY**: Every learning needs reasoning — "User corrected twice" > "just because".
