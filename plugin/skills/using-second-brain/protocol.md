# Working protocol (class 5)

This file is the **source of truth** for the work protocol: the model tiers, and the five-step
discipline (plan → search → verify → record) every session and every delegated subagent follows.
Two things are rendered FROM this file, never authored separately:

- The **SessionStart protocol card** (`scripts/protocol-guard.sh` mode `card`) is the text inside
  the CARD marker pair below, with the placeholders `{SCOUT}`, `{DO}`, `{THINK}` substituted for
  the aliases `sb_resolve_model fast|mid|deep dispatch` resolves right now (so it always names the
  model actually live on this ladder, never a hardcoded literal).
- Each **SubagentStart role card** (mode `subagent`) is one of the three ROLE marker pairs below,
  chosen by the dispatched agent's classified tier, placeholders substituted the same way.

(The literal HTML-comment marker syntax is not spelled out in this prose on purpose — it appears
only at column 0, opening and closing the four blocks below, so a naive text scan of this file
can't mistake a description of the format for the format itself.)

## Tiers

The three tiers are named by `model-ladder.json`'s `protocol_names` (`fast → SCOUT`,
`mid → DO`, `deep → THINK`) and resolved to a live model alias by `sb_resolve_model <tier>
dispatch`. Never hardcode a model name anywhere in a prompt or skill — name the tier
(`SCOUT`/`DO`/`THINK`) and let the ladder resolve it. A `model-ladder.json` change (a new
release, a demotion) then changes every surface with no prompt edit.

## The five-step discipline

1. **Think before implementing.** A plan-first gate: for anything beyond a trivial fix, state
   the approach (and, for an architecture-level call, 2-3 options with tradeoffs) before editing.
2. **Search before creating.** Before writing a new file, module, or wiki page, check whether
   the thing already exists: `code_neighbors`/`code_map` for source, `knowledge_search` for the
   wiki. Don't duplicate what a two-second lookup would have found.
3. **Verify before claiming done.** A change is not done because it was written — run its gate
   (tests, `bash -n`, the relevant `tests/test-*.sh`) and report the exit code, not a log tail.
4. **Record decisions.** A durable choice (an architecture call, a rejected alternative, a
   resolved blocker) goes into the project's memory via `pin_to_project` (`section:
   decisions|conventions`) — not left to be re-derived from a transcript later.
5. **Delegation completion contract.** A subagent's **final message IS the deliverable** — there
   is no follow-up turn to add what was left out. Every subagent, whatever its tier, returns
   findings first, `file:line` references (never a paraphrase of "somewhere in X"), and a
   `Gaps:` section naming what it did NOT check. A `Plan`-tier dispatch must carry the repo's
   HARD (ask/deny) rules explicitly in the prompt — `Plan` never sees `CLAUDE.md`, so if the
   caller doesn't paste the hard rules in, the planner never learns them.

<!-- card:begin -->
Working agreement - tiers: SCOUT={SCOUT} DO={DO} THINK={THINK} (name the tier when
delegating: `model: <alias>`, never a literal like "opus").
1. Think before implementing - state the approach first; 2-3 options for an architecture call.
2. Search before creating - `code_neighbors`/`code_map` for source, `knowledge_search` for wiki.
3. Verify before claiming done - run the gate, report the exit code, not a log tail.
4. Record decisions - `pin_to_project(section: decisions|conventions)`.
5. Delegate right - a subagent's final message IS its deliverable: findings first, file:line,
   a Gaps: section. A `Plan` dispatch must carry this repo's HARD rules in the prompt.
<!-- card:end -->

<!-- role:SCOUT:begin -->
You are dispatched at SCOUT tier ({SCOUT}) - lookups only. Locate, don't change: no edits,
no writes. Return findings as `file:line` references, not paraphrase. Budget <=1k tokens.
End with a `Gaps:` section naming what you did not check or could not confirm.
<!-- role:SCOUT:end -->

<!-- role:DO:begin -->
You are dispatched at DO tier ({DO}) - bounded implementation. Write the test first, then
the surgical, minimal change that makes it pass - no unrelated refactors. End your final
message with a `READY` or `NOT READY` line and the exact files you touched.
<!-- role:DO:end -->

<!-- role:THINK:begin -->
You are dispatched at THINK tier ({THINK}) - architecture / adversarial review. Refute
first: assume the design or claim under review is wrong until you can show otherwise. Name
concretely what evidence would prove you wrong, and whether you found it.
<!-- role:THINK:end -->
