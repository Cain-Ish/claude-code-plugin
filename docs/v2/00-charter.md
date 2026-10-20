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

**The main idea**, which every step is checked against ([01-process.md](01-process.md), rule 9): a Claude Code plugin
that keeps a **project map** (the "mindmap") per repo, puts the right part of it in front of Claude when a task needs
it, and holds Claude to it.

- **The project's own knowledge.** The map holds what a project's key people know and the code does not show. Which
  areas matter is per project (V2-D10): the lead developer, PM and designer of a product team (A1); the canon of an
  app built on books or a fictional universe; the brand and audience of a marketing-led product; the engineering
  decisions of a pure development project. Typical content: structure and conventions; goals, scope and priorities;
  design and UX rules; decisions with the rejected options and the reason.
- **On demand, cheap.** Claude always sees a small index and reads a branch of the map only when the task touches
  it. Token cost is a design constraint, measured per task.
- **Starts from what the project has** (user, 2026-10-20). The plugin's first act in a repo turns the project's
  existing rules and documents (instruction files, rule files, docs, skill bodies) into the map's one standard
  format, each entry anchored to its source; in a project with none, it maps what the code shows. From then on that
  format is what is delivered and enforced, and new knowledge enters in it (V2-D15, D13).
- **Followed, not only shown** (user, 2026-10-20). Claude is held to the rules that bind its task, not merely given
  them; V2-D20 decides how. Only the project's own rules in the map are enforced: general code review stays a
  non-goal.
- **Checked, not trusted.** A claim points at the code or doc it describes and is checked before use. Stale
  knowledge is flagged, never delivered as current.
- **Grows from work.** Decisions and lessons are recorded when they are made, with little friction.

**Acceptance scenario A1** (the user's, 2026-10-20). In earlier sessions in a front-end repo, three things happened
that the code does not show. The lead developer and Claude agreed that every component keeps all its files in its
own folder and follows the client's style guide. Claude read the designer's document, kept outside the repo, on
exactly how avatars look and behave. A week later the PM said avatars never load from the CDN, even when a CDN
address exists, because the client keeps them local. Nobody told Claude to remember any of it: Claude judged each
worth keeping and added it to the map. In a later session with a clear context, "create a UserAvatar component"
makes Claude, before it writes anything, (1) recall all three; (2) put the component in its own folder and follow
the style guide; (3) build the avatar as the designer's document says; (4) load the image locally, never from the
CDN; and (5) name each decision it followed and where it came from. It spends fewer tokens and steps than the same
task without the plugin. The eval plan (V2-D17) turns this into checks.

## What v2 is not (confirmed by V2-D10)

Not an orchestrator, a model router, a code reviewer, a security guard, a persona or companion, a transcript archive,
or a background process that rewrites knowledge without a reviewable diff. v1 shipped most of these; see
[02-v1-postmortem.md](02-v1-postmortem.md).

## Success means measured outcomes

Every claim of value is an eval result against two baselines: no memory between sessions, and Claude Code's own auto
memory, the native way Claude remembers across sessions (V2-D17). The baselines run first: they need no v2 code, and
they show what Claude gets wrong today. Thresholds are then set as improvements over the measured baseline (V2-D17),
before any v2 feature is built. v1 built a 2,710-line outcome harness and never ran it; a harness counts only once
it has run.

| Outcome | Measure |
| --- | --- |
| Onboarding | Share of a repo's existing rules that reach the map with their source anchor and unchanged meaning; planted rules lost |
| Capture | Share of the decisions made in earlier sessions that are in the map afterwards, and what was kept that should not have been |
| Consistency | Share of acceptance tasks whose output follows the recorded decisions |
| Orientation | Tool calls and files read before the first correct file |
| Cost | Tokens per task; always-on bytes per session |
| Arrival | Every delivery channel proven by a nonce probe to reach the main session and subagents before it carries content |
| Freshness | Zero stale claims delivered as current (mechanism: V2-D16, deterministic anchors) |

**Test bed** (user, 2026-10-20). v1's own repo, P1 and P2 (two private repos, published here as numbers only) are
tested as one combined example, each from a scratch clone. They hold three shapes of existing knowledge: no
`CLAUDE.md`, with the rules in project-knowledge skills, concept documents and a store outside the repo (v1);
path-scoped rule files, a large root file and post-write hooks (P1); large prose documents with validators and nothing
path-scoped (P2). End projects will have other rules and shapes, so nothing is fitted to these three: each check says
which part of its result depends on one repo's shape.

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
