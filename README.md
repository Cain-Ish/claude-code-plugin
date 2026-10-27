# second-brain v2 (alpha)

A Claude Code plugin that keeps Claude aware of what your project has already decided. Claude gets an index of the
repo's own documents at every session start. Before it changes anything, it has to say which of them bear on the task
and read those. Decisions stated during your sessions go into plain Markdown files that you review and commit like
any other change.

**Status:** `2.0.0-alpha.0`, a pre-release from branch `v2`, being prepared for release. It has been tested live on
Windows, and its self-test passes on Windows, macOS and Linux in CI. v1 (0.57.1) is frozen on
[`main`](https://github.com/Cain-Ish/claude-code-plugin).

## What it does

- **At session start**, and again after `/clear`, a resume or a compaction, Claude gets two things:
  - an index of the repo's documents: every tracked `.md`, `.mdx`, `.markdown`, `.txt` and `.rst` file, by directory;
  - a short instruction to keep the project's decisions in `.project-map/`.
- **At the first prompt**, and at the first after each compaction, Claude states for each document directory whether
  it bears on the task (yes or no). Then it reads the yes ones before it changes anything.
- **When someone states a decision or rule in passing**, or Claude reads a document of requirements, Claude adds it to
  `.project-map/captured.md`, with its source and date.
- **When Claude reads a map file**, a hook labels its entries:
  - "unreviewed, not yet committed", until you commit them;
  - an entry whose source names a repo file is checked against that file now. If its quote is not there word for
    word, the label says so;
  - any other entry is labelled "unverified quote", with its capture date.
- **When it finishes a change**, Claude names the recorded decisions it followed and where each came from.

It calls no model and uses no network, MCP server or agent. The hooks run Node and start only `git`. Nothing leaves
your machine.

## What was measured, and what was not

The plugin was measured on Claude Code 2.1.305 with Opus 5.5, against Claude Code's own auto memory. There were two
setups: a front-end scenario run over several sessions (A1), and build, plan and question tasks in three real repos
(two private ones, and this plugin's own v1 repo). Each cell is 10 runs.

**Where it helped:**
- *A designer's spec, read in an earlier session:* kept in 10 of 10 runs (auto memory: 2), and followed in a fresh
  session before the first write in 10 of 10 (auto memory: 0).
- *Naming the decisions followed, with their sources:* 10 of 10 (auto memory: 0).
- *A second person on the same repo* got the same decisions through the committed map. Auto memory is per user.
- *Build and plan rules in the two repos whose rules are prose documents* were followed more often. One rule that auto
  memory never followed was followed in 10 of 10 runs.
- *Across 57 rule cells,* the plugin was above auto memory's count in 17 and below it in 9.

**Where it did not:**
- *Cost and steps.* They were the same as auto memory's on A1, not fewer. On the real repos they were mixed: lower on
  4 tasks and higher on 6, with one planning task above the no-worse ceiling.
- *Questions about the project.* The index did not lead Claude to the answer, and ordinary search does as well. The
  claim is for changing, creating and planning a part.
- *A change named after the session's first prompt.* That covers a session that opens on a symptom and names the
  change later, and a second task after a compaction. In one repo a rule was then missed in 3 to 4 of 5 runs.
- *Pattern rules* (a required call or a forbidden one) on Opus. One such rule was followed in only 3 of 10 runs.
- *Subagents* do not see the index.

The results are in [docs/v2/06-first-slice.md](docs/v2/06-first-slice.md) (steps 2c to 2g), and the decisions behind
them are in [docs/v2/DECISIONS.md](docs/v2/DECISIONS.md).

## Requirements

- Claude Code (tested on 2.1.305 to 2.1.311);
- Node 20 or later;
- git. The index lists the files git tracks, so outside a git repo it is empty.

## Install

```
claude plugin marketplace add Cain-Ish/claude-code-plugin#v2 --scope project
claude plugin install second-brain@second-brain-v2 --scope project
```

`--scope project` writes `.claude/settings.json`, which your team shares once it is committed. To try the plugin only
for yourself in one repo, use `--scope local` for both commands instead. Then start Claude in the repo.
`/second-brain:onboard` reports what the index holds.

## Review is the commit

- The map is plain Markdown in `.project-map/`. Claude's changes to it stay in the working tree. You review them in
  `git diff` and commit them with the work.
- Until an entry is committed, every read labels it unreviewed. That is how text Claude captured from a document it
  read stays visible as unchecked.
- If you leave `.project-map/` out of your commits, its entries stay in your working tree only, still labelled. No
  other clone or teammate sees them.
- Edit or delete entries as you like. The plugin keeps no other state.

## What it writes

- `.project-map/*.md` in your repo, written by Claude under the capture instruction.
- One empty marker file per session in the OS temp folder (`project-map-<session>.pending`). The session's first
  prompt removes it.

Nothing else.

## What it costs your machine

- *Hook latency on Windows,* measured as the p95 added over an empty Node process. The repo was one of 8,057 files
  and 190 documents, or a synthetic repo of the same shape, with map entries citing 1.26 MB of documents:
  - *one session, on GitHub's 4-core runner* (CI gates this at 100 ms): session start 49 to 68 ms, a map read 62 to
    80 ms, every other hook under 20 ms;
  - *8 sessions at once, on a 32-thread machine* (checked at 100 ms before each release): session start 42 to 82 ms,
    a map read 51 to 86 ms, every other hook under 35 ms;
  - *8 sessions at once, on the 4-core runner:* session start and a map read take 143 to 260 ms, over the budget. On a
    small machine running many sessions, expect each session start and map read to take a few tenths of a second.
- *Context, always on:* 904 B and 212 B per session plus the index (2 to 6 KB in the tested repos), and 227 B for each
  forced decision.

## Known issues

- **Without Node,** session start says so once. After that, every prompt and every file read shows a hook error.
  Install Node 20 or later, or disable the plugin.
- **The forced decision** adds a step at the start of each session and after each compaction, even for a question.
- **The closing line** about decisions followed appears even where nothing applies ("none").

## Uninstall

```
claude plugin uninstall second-brain@second-brain-v2 --scope project
claude plugin marketplace remove second-brain-v2
```

- Your `.project-map/` files stay.
- `.claude/settings.json` is left with empty `enabledPlugins` and `extraKnownMarketplaces` entries.
- Claude Code removes its cached copy of the plugin after 14 days.

## How v2 is built

It is decided one step at a time, and each decision is checked when it is made:
- the brief: [docs/v2/00-charter.md](docs/v2/00-charter.md);
- the process: [docs/v2/01-process.md](docs/v2/01-process.md);
- the decision ledger: [docs/v2/DECISIONS.md](docs/v2/DECISIONS.md);
- progress: the [map issue #115](https://github.com/Cain-Ish/claude-code-plugin/issues/115).

MIT licensed.
