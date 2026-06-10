---
description: Advisory model-tier classifier. Analyses the given task description and recommends Haiku/Sonnet/Opus with confidence and rationale. Does not dispatch any agents — purely advisory. Use before manual dispatch or to understand tier reasoning.
argument-hint: "<task description>"
---

# /cost-router:model-route

Classify `$ARGUMENTS` (or the current request if no arguments) into the optimal model tier and explain why.

## Step 1 — Consult routing history

If the `cost-routing-patterns.md` wiki page exists (written by second-brain's capture hook at `${SB_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-$HOME/knowledge}}/wiki/state/cost-routing-patterns.md`), read it. Use past escalation patterns to adjust the recommendation for similar task shapes.

## Step 2 — Classify using heuristics

Apply the following rules in order:

### Haiku (SCOUT tier) — deterministic, low-risk

Recommend Haiku when the task is:
- Reading, searching, or listing files
- Running tests, lint, or typecheck and reporting results
- Enumerating, diffing, or summarising changes
- Any work with a verifiable ground truth that requires no judgment

**Confidence: HIGH.** Haiku handles all deterministic work. Using a bigger model here is waste.

### Sonnet (DO tier) — implementation, the ~80% default

Recommend Sonnet when the task is:
- Writing or editing code against a clear spec
- Implementing a feature with known patterns
- Fixing a well-described bug with a clear root cause
- Any code change where the approach is unambiguous

**Confidence: HIGH for well-specified tasks; MEDIUM if partially ambiguous.**
Cheaper fallback: use Haiku only if the change is truly mechanical (rename, format, comment).

### Opus (THINK tier) — design, ambiguous, cross-cutting, security

Recommend Opus when the task has:
- **Genuine architectural ambiguity** — multiple valid approaches with real trade-offs
- **Cross-cutting concerns** — changes that ripple across modules, APIs, or contracts
- **Security / correctness trade-offs** — where a wrong call has outsized impact
- **Failed first attempt** — a Sonnet implementation failed verification and the failure is a design issue
- **Decomposition needed** — the task is too large/unclear to implement as a single unit

**Confidence: HIGH only when these signals are present.** Default toward Sonnet when in doubt.

## Step 3 — Output the recommendation

Format:

```
Recommendation: <HAIKU|SONNET|OPUS>
Confidence: <HIGH|MEDIUM|LOW>
Rationale: <1–2 sentences on the primary signal(s)>
Cheaper fallback: <tier if confidence < HIGH, or "none — this is already cheapest">
Routing patterns note: <brief note if cost-routing-patterns.md influenced the recommendation, else omit>
```

Do not dispatch any agents. This command is advisory only.

## Pricing reminder

| Model | Relative cost |
|-------|-------------|
| Haiku 4.5 | 1× |
| Sonnet 4.6 | ~3× |
| Opus 4.8 | ~5× |

Default to Sonnet. Reach for Opus only when the heuristics above clearly apply. Reach for Haiku for anything deterministic.
