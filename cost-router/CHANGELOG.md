# cost-router changelog

## 0.2.2 — 2026-06-24

- Route deep-review prompts to `/second-brain:code-review-deep` (the self-tiering
  multi-pass reviewer) instead of emitting a tier nudge. Conservative word-bounded
  REVIEW detector in `classify-prompt.sh` (never matches bare "review"); detect-&-
  degrade to `/cost-router:orchestrate` when second-brain is absent; exempt from the
  25-char nudge floor. cost-router recognizes + points at the skill, never tiers or
  decomposes it. The detector is deliberately conservative — multi-word phrases only,
  never bare "review"; covers `code review`, `review this/the/my pr`, `review pr <N>`,
  `review pull request`, `review the diff`, `review my/the changes`, `thorough review`,
  `deep code review`; the standalone `deep review` phrase was deliberately excluded to
  avoid over-matching (e.g. "deep review of Q4 goals").
- Fix: `$HOME` references in the skill-detection loop guarded as `${HOME:-}` so a
  missing HOME does not crash the hook under `set -u` (violated the never-fail
  contract); degraded `/cost-router:orchestrate` path taken instead.
- Advise-only pointers added to `/cost-router:orchestrate` and `/cost-router:model-route`.
