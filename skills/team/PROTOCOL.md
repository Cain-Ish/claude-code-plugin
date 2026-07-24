# Team protocol — model routing and dispatch contract

Shared contract for orchestrated work. This file is the single home for the
model-routing facts every dispatching surface (the future `/second-brain:team`
conductor, review skills, ad-hoc subagent fan-outs) must agree on. No runtime
reads this file — skills quote it; contract tests grep it.

## Model tiers

| Tier | Model class | Work shape |
|---|---|---|
| THINK | strongest available (session model / opus-class) | design, architecture, tradeoff decisions, adversarial review, root-cause debugging, anything judged rather than checked |
| DO | mid tier (sonnet-class) | well-specified implementation, mechanical edits across many files, test authoring from a written contract, consolidation |
| SCOUT | small tier (haiku-class) | search, inventory, classification, extraction into a fixed schema, doc lookups |

Signals that a task is THINK regardless of how it is phrased: the correct output
is debatable; a wrong answer is expensive to detect; the task changes a contract
other work depends on; two capable readers could disagree.

## Dispatch rules

- **Route per dispatch, never globally.** Set `model:` on the individual agent
  definition or Agent call. Never set a blanket model floor or a global model
  env override — a blanket floor silently re-routes every subagent, including
  the ones deliberately pinned small.
- **Explicit or inherit — never silent.** Every agent definition carries a
  `model:` line; `inherit` is the sanctioned way to ride the session's best
  model (machine-locked in `mcp/src/prose-locks.test.ts`).
- **Escalate at most once.** A DO/SCOUT dispatch that returns wrong or
  incomplete work gets ONE re-dispatch at the next tier up with the failure
  named in the packet. A second failure stops the lane and reports — repeated
  silent escalation is how budget-shaped work becomes THINK-shaped work without
  anyone deciding that.
- **Judged verdicts ride THINK.** A verdict that gates a merge, release, or
  wiki write is rendered by the strongest available model in a fresh context —
  never by the lane that produced the work (the executing context's own checks
  count as unverified).
- **Complete delegation packet or refuse.** Every dispatch carries: the goal,
  the absolute paths it may touch, its bound (batch size / iteration cap), and
  the exact report format expected back. A dispatch missing a field is refused,
  not repaired by guessing.
- **Spend is not tracked and never gates.** Organize work by tier fit, not by
  cost accounting — there is no ledger, no cap, and no spend-based routing.
