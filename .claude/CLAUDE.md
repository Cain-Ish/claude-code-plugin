# second-brain v2: working rules

This branch holds v2 of the second-brain plugin, in its concept phase. v1 is frozen on `main` and `v1` (tag
`v1-final`). Read v1 with `git show v1-final:<path>` when evidence is needed; never copy v1 code or rules in.

Before any work, read `docs/v2/00-charter.md`, the status table in `docs/v2/DECISIONS.md`, and the map issue
(`gh issue list --label wayfinder:map`). Then follow `docs/v2/01-process.md`: one decision at a time, the check
written before it runs, and the step gate at the end of every step.

- Decisions live only in `docs/v2/DECISIONS.md`. This overrides the ADR path of `/domain-modeling` and v1's
  "knowledge base is the only home" rule.
- A LOCKED decision is not re-argued. Cite its id. It reopens only when one of its triggers fired.
- Research goes in `docs/v2/research/<date>-<topic>.md`, with sources. The repo is public: no secrets, session ids,
  absolute local paths, email addresses or transcript quotes.
- Probes go in `docs/v2/probes/<decision-id>-<name>/`. Nothing else is implemented in the concept phase.

## Agent skills

### Issue tracker

GitHub Issues on `Cain-Ish/claude-code-plugin`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See
`docs/agents/triage-labels.md`.

### Domain docs

See `docs/agents/domain.md`.
