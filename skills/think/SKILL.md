---
name: think
description: Trigger a structured Opus-level advisor brief on a non-trivial topic. Returns intent read, prompt enrichment, clarifying questions, relevant specialists, and risk flags. Use for ambiguous prompts, design decisions, or multi-domain work where the persona's prior context matters. Costs ~$0.11/call with Opus.
user-invocable: true
disable-model-invocation: false
allowed-tools: mcp__knowledge-base__persona_think
argument-hint: "[topic]"
---

# Think

Call `persona_think` with `$ARGUMENTS` as the prompt.

## Output formatting

If the tool returns a brief, format it as a tight block:

- **Intent:** {intent_read}
- **Enrichment:** {prompt_enrichment}
- **Ask user:** numbered list of `clarifying_questions` (if any)
- **Specialists:** comma-separated `relevant_specialists` (if any)
- **Risks:** bullet list of `risk_flags` (if any)

Omit any field that is empty. If all fields are empty, say "(no notable signal — proceed as planned)".

If the response has `budget_skipped: true`, tell the user: "Daily persona budget exceeded ($SB_PERSONA_DAILY_BUDGET). Override with `SB_PERSONA_GATE=off` or wait until tomorrow."

If the response has `error`, surface the error once and proceed without the brief.

## When NOT to use this

- Trivial prompts (a one-verb-on-one-noun edit)
- Pure factual lookups (use `/second-brain:query` instead)
- Active work mid-implementation (only useful before deciding direction)

The persona-context.sh hook also routes the `/?` prefix on a user prompt to this same backing tool — `/? topic` is shorthand for invoking this skill.
