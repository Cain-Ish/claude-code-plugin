# second-brain v2 — charter

**Status:** concept phase, started 2026-10-19. This file is the working brief for v2. It replaces the original request
(quoted at the end) and says what changed and why. Process: [01-process.md](01-process.md). Decisions:
[DECISIONS.md](DECISIONS.md).

## The problem

Claude starts every session in a repo knowing only what `CLAUDE.md` and the code tell it. What makes a senior team
member effective lives in people's heads, scattered docs and old sessions: why the structure is this way, which
options were rejected, what the product is aiming at, which UI patterns are agreed, what is in flight. So Claude
either re-derives it by grep, which is slow and costs tokens, or never derives it, and its output is inconsistent and
re-argues settled decisions.

## What v2 is

A Claude Code plugin that keeps a **project map** (the "mindmap") per repo and puts the right part of it in front of
Claude when a task needs it.

- **Role knowledge.** The map holds what the lead developer, PM, designer (and QA or ops, where a repo has them)
  would know: structure and conventions; goals, scope and priorities; the design system and UX rules; decisions with
  the rejected options and the reason.
- **On demand, cheap.** Claude always sees a small index and reads a branch of the map only when the task touches
  it. Token cost is a design constraint, measured per task.
- **Checked, not trusted.** A claim points at the code or doc it describes and is checked before use. Stale
  knowledge is flagged, never delivered as current.
- **Grows from work.** Decisions and lessons are recorded when they are made, with little friction. A map can be
  bootstrapped from an existing repo.

**Acceptance scenario A1.** In a front-end repo that has a map, the request "create a UserAvatar component" makes
Claude (1) put it where the team's component structure says, (2) reuse the existing avatar or image primitive
instead of writing a new one, (3) follow the styling decision on record (for example design tokens, not inline
colours), and (4) name the decisions it followed. It reads fewer files and spends fewer tokens than the same task
without the plugin. More scenarios (PM, design, lead) are defined in the eval plan (V2-D17).

## What v2 is not (initial list, confirmed or changed by V2-D10)

Not an orchestrator, a model router, a code reviewer, a security guard, a persona or companion, a transcript archive,
or a background process that rewrites knowledge without a reviewable diff. v1 shipped most of these; see
[02-v1-postmortem.md](02-v1-postmortem.md).

## Success means measured outcomes

Every claim of value is an eval result against two baselines: no plugin, and a hand-written native setup
(`CLAUDE.md` only). The baselines run first: they need no v2 code, and they show what Claude gets wrong today.
Thresholds are then set as improvements over the measured baseline (V2-D17), before any v2 feature is built. v1
built a 2,710-line outcome harness and never ran it; a harness counts only once it has run.

| Outcome | Measure |
| --- | --- |
| Consistency | Share of acceptance tasks whose output follows the recorded decisions |
| Orientation | Tool calls and files read before the first correct file |
| Cost | Tokens per task; always-on bytes per session |
| Arrival | Every delivery channel proven by a nonce probe to reach the main session and subagents before it carries content |
| Freshness | Zero stale claims delivered as current (mechanism: V2-D16, deterministic anchors) |

## Constraints carried over from v1

- Runs on Windows (Git Bash), macOS and Linux.
- No heavy native dependencies.
- Untrusted text (transcripts, web pages, tool output) is data, never instructions, and does not enter the map
  without review.
- A guarantee stated in prose names the test or check that enforces it, or is marked as direction. In the concept
  phase, where no code exists yet, the rule is: every claim cites its source (doc, research note) or probe.
- Tests must not disable the thing they test.

## Concept phase: deliverables and definition of done

The concept phase is done when these exist on branch `v2`:

1. `DECISIONS.md`: every spine decision LOCKED, or DEFERRED with a named trigger. Each lock is backed by a check
   that ran when the decision was made.
2. `02-v1-postmortem.md`: v1's root causes, each turned into a checkable v2 rule.
3. `04-architecture.md`: a one-page architecture built only from locked decisions. (The vision lives in this
   charter and the open questions in `DECISIONS.md`; no separate vision document.)
4. `05-eval-plan.md`: acceptance tasks, arms, and thresholds set from baseline runs that have actually happened.
   The harness stays small, and it is the first thing built; the walking skeleton follows and is measured by it.
5. `06-first-slice.md`: a walking-skeleton plan with a surface budget (maximum hooks, skills, tools, scripts).
6. One devils-advocate review of the whole concept, with every surviving finding fixed or accepted on record.

Nothing is implemented in this phase except throwaway probes under `docs/v2/probes/`.

## Original request (2026-10-19, spelling corrected)

> Cut the current claude-code-plugin version as v1 on GitHub and start creating, based on our mistakes and
> solutions, a new v2. Prepare GitHub so v2 is added as "in development" and we can work on it from scratch. Read
> our concept and think deeply about where we made mistakes in v1, then use
> https://github.com/FlorianBruniaux/claude-code-ultimate-guide as additional knowledge, and think about how to make
> a second-brain plugin that expands Claude's existing memory and creates a mindmap of each project Claude works in,
> so every session in each repo (for example repo A) knows exactly what the senior lead developer, PM, UI designer
> and other important people know. If I ask Claude to create a component, it knows from that mindmap what we have
> now, how we decided to structure it, and our previous decisions that can affect the current request, and it can
> find, understand and use them with the best performance and token savings we can achieve. For now we only create
> the draft and concept for v2, to cover all decisions before implementing. Use all plugins, skills and agents as
> needed; you may change this prompt for a better approach to the end product. Make a decision logic that verifies
> each decision during the process, not at the end, and does not re-verify it over and over. If something is not
> right after 3-4 runs, we go back and think about it again. Think about how we should prepare to start, how to
> track and save our research and concept, and what we expect at the end that will let us create the plugin.

### What changed and why

- **"Mindmap" became a project map.** It is a navigable index plus linked notes, not a picture: the
  token-cheap form of a mindmap. "Mindmap" stays the user-facing word.
- **"Knows exactly what the lead, PM and designer know" became "knows what they recorded or what can be derived from
  the repo, and says when it does not know".** Tacit knowledge has to be captured somewhere before any tool can
  deliver it.
- **Added:** acceptance scenario A1, measured success criteria, explicit non-goals, a definition of done for the
  concept phase, and probe-before-decide (01-process.md).
- **"Verify each decision during the process, 3-4 runs then rethink"** became the decision record, the
  pre-registered check and the three-strike rule in 01-process.md.
