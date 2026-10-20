# v2 eval plan

**Status:** tasks, arms, metrics and protocol proposed on 2026-10-20. They become pre-registered when the user
confirms them (V2-D17). The thresholds are not set yet; they come from baseline runs that have not happened.

The eval answers one question: does a project map change what Claude does? Every claim of value in the charter is a
result of this eval against two baselines that need no v2 code, so the baselines run first (PM1).

## Fixture

One front-end repo built for the eval, under `probes/V2-D17-eval/fixture/` once the harness exists. It is React and
TypeScript source with no packages installed. Runs are scored on files and replies, not builds.

- **Principle:** the code alone must not settle any decision a task checks. For each checked decision, older files
  follow the rejected option and newer files follow the chosen one, so reading code cannot tell which is current.
  If the no-plugin arm passes every item anyway, the fixture measures nothing and is changed.
- **Knowledge:** decisions with their rejected options and reasons, each attributed to the lead, the PM or the
  designer (D10), written as a team would: decision records under `docs/decisions/`, a design-system note and a
  roadmap. Proposed volume: a realistic team's, about 40 decisions across the three roles, of which the tasks check
  six.
- **Hygiene:** invented names only; no real people, emails or paths (the repo is public).

## Arms

| Arm | What the run sees |
| --- | --- |
| B0, no plugin | The fixture with its docs, and no `CLAUDE.md`. Claude has to find the knowledge itself |
| B1, native | B0 plus a hand-written root `CLAUDE.md` that states every recorded decision in one line with its id and points at the docs: the strongest native setup, not a straw man |
| v2 | The first slice from the build phase. Not run in the concept phase |

## Tasks

The full prompts are below. When the harness exists, the prompts live in `probes/V2-D17-eval/tasks.json` and this
table points there instead of repeating them. No prompt names a path, a primitive or a decision id.

| Id | Role | Prompt | Check items (deterministic) | Target files |
| --- | --- | --- | --- | --- |
| A1 | designer, lead | Create a UserAvatar component that shows a user's photo, or their initials when there is no photo. | (1) the component sits where the structure decision says (`src/components/UserAvatar/UserAvatar.tsx` and `index.ts`); (2) it renders the image through the image primitive `Img`, with no raw `<img`; (3) no colour literal (hex, `rgb(`, a named colour) in new files; (4) the reply names at least two recorded decisions it followed (id or title) | `src/components/UserAvatar/` |
| L1 | lead | Show the signed-in user's display name in the header. The profile comes from the backend. | (1) the request goes through the API client (`apiGet`), with no `fetch(` or `axios` in changed lines; (2) loading lives in a hook under `src/hooks/`; (3) the reply names the API-client decision | `src/hooks/`, the header component |
| P1 | PM | Add Google sign-in to the login page. | (1) no code for Google or OAuth sign-in: no changed line matches `google`, `oauth` or `gsi` (any case); (2) the reply names the scope decision that puts social login out of this release | none: no write is expected |
| D1 | designer | Show an error message on the login form when sign-in fails. | (1) the error uses the `Alert` component with `tone="danger"`; (2) no colour literal in changed lines; (3) the error text has no exclamation mark and is in sentence case; (4) the reply names the error-display decision | the login form |

Headless runs have no one to ask, so P1's expected behaviour is "writes no code for the out-of-scope feature and
names the decision", not "asks first".

## Metrics

| Outcome (charter) | Measure here |
| --- | --- |
| Consistency | Per run, each check item passes or fails; a run passes when all its items pass. Per arm and task: the share of runs that pass, and the share of items |
| Orientation | Tool calls (main session and subagents) and distinct files read before the first Write or Edit to a target file. Not scored for P1 |
| Cost | Tokens per run (input, output, cache read and cache write, from the run's result event) and the reported cost; always-on bytes per session (the root `CLAUDE.md` and its imports; 0 for B0) |
| Arrival | Settled by V2-D12, not measured here |
| Freshness | V2-D16, not measured here |

## Protocol

- **Model:** Sonnet 5.5 (`claude-sonnet-5-5`), proposed. Results do not transfer across models (research Q7), so
  another model is another baseline.
- **Runs:** 5 per task and arm: 40 runs. The cost of the first run is measured before the rest start.
- **Session:** `claude -p` on a fresh copy of the fixture, initialised as a git repo; user settings excluded
  (`--setting-sources project,local`); Read, Write, Edit, Glob, Grep and subagents allowed; Bash, WebFetch and
  WebSearch denied (no builds, no network, static scoring).
- **Valid run:** the session ends with a success result event and the harness raised no error. An invalid run is
  re-run and reported.
- **Scoring:** a script reads the final files, the git diff and the event stream. No model judges a run.

## Harness

Under `probes/V2-D17-eval/`: Node, no npm packages, at most 400 lines without the fixture and the task file (v1's
outcome harness had 2,710 lines and never ran). Before any baseline run it passes a smoke check: every gold answer
passes all items of its task, each planted wrong answer (one per check item) fails exactly that item, and no task
prompt contains an answer token (a target path, a primitive name, a decision id).

## Thresholds

Not set: the baselines have not run.

- **Rule:** v2 meets an outcome when it beats B1 on that task and metric by more than B1's own run-to-run spread
  (largest minus smallest of its five runs), and is no worse than B1 on consistency. The numbers go here once B0 and
  B1 have run.
- **If B1 passes every item in every run:** this fixture shows no consistency gap for v2 to close. D17 records that
  v2's case then rests on orientation and cost alone, and the user sees that result before any threshold is set.
