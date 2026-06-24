# cost-router changelog

## 0.2.2 — 2026-06-24

- Route deep-review prompts to `/second-brain:code-review-deep` (the self-tiering
  multi-pass reviewer) instead of emitting a tier nudge. Conservative word-bounded
  REVIEW detector in `classify-prompt.sh` (never matches bare "review"); detect-&-
  degrade to `/cost-router:orchestrate` when second-brain is absent; exempt from the
  25-char nudge floor. cost-router recognizes + points at the skill, never tiers or
  decomposes it.
- Advise-only pointers added to `/cost-router:orchestrate` and `/cost-router:model-route`.
