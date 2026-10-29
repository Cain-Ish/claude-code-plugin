# second-brain v2 (alpha)

A Claude Code plugin that keeps Claude aware of what your project has already decided. At every session start, its
hooks give Claude an index of the repo's own documents. At the first prompt they give it an instruction to say which
of those documents bear on the task, and to read them before changing anything. It also tells Claude to record the
decisions stated during your sessions in plain Markdown files. You review and commit those files like any other
change. These are instructions Claude follows, not locks: no hook blocks a write.

**Status:** `2.0.0-alpha.3`, a pre-release from branch `v2`.
- It has been tested in live Claude Code sessions on Windows only.
- On macOS and Linux, only its self-test has run, in CI.
- v1 (0.57.1) is frozen on [`main`](https://github.com/Cain-Ish/claude-code-plugin).

## What it does

- **At session start**, and again after `/clear`, a resume or a compaction, Claude gets two things:
  - an index of the repo's documents, by directory: every tracked `.md`, `.mdx`, `.markdown`, `.txt` and `.rst`
    file, plus every Markdown file in `.project-map/`, even one that is not committed or that `.gitignore` excludes;
  - a short instruction to keep the project's decisions in `.project-map/`.
- **At the first prompt you type**, and at the first after each compaction, Claude is told to state for each document
  directory whether it bears on the task (yes or no), and to read the yes ones before it changes anything. A
  background subagent's report or another Claude session's message does not count as that prompt.
- **When someone states a decision or rule in passing**, or Claude reads a document of requirements, Claude is told
  to add it to `.project-map/captured.md`, with its source and date.
- **When Claude reads a map file with the Read tool in the main session**, a hook labels its entries:
  - "unreviewed, not yet committed", until you commit them;
  - an entry whose source names a repo file has each stretch of three or more words in its quote checked against that
    file now. If the file is missing, or a stretch is not there word for word, the label says so, and a file that
    cannot be read gets a label too. Shorter quotes, or stretches between ellipses, are not checked, and get no
    label once committed;
  - an entry whose source names no repo file is labelled "unverified quote", with its capture date;
  - if the map file itself cannot be read, one label says to treat every entry in it as unreviewed and unverified.

  Reads by subagents, and text met through Grep or Bash, are not labelled.
- **When it finishes a change**, Claude is told to name the recorded decisions it followed and where each came from.

It calls no model and uses no network, MCP server or agent. The hooks run Node and start only `git`. Nothing leaves
your machine.

## What was measured, and what was not

The plugin was measured on Claude Code 2.1.305 with Opus 5.5, against Claude Code's own auto memory.
- *A1:* a front-end scenario run over several sessions, 10 runs per arm. It was re-run on alpha.2's code. alpha.3's
  two fixes were checked by the self-test only.
- *A2:* build, plan and question tasks in three real repos (two private ones, and this plugin's own v1 repo), 10 runs
  per task.
- *Three harder shapes,* 5 runs each: a first prompt that names a symptom, two compactions, and a task switch.

A2 and the three shapes ran on an earlier build. Three later changes kept the hooks' output byte-identical on those
repos:
- a faster quote check: 123 library comparisons, including 20,400 random quotes;
- alpha.1's fixes: the same 123, plus 36 hook-process comparisons.

  The one difference is by design: in 102 of the 123, a 200-entry map file's labels pass 10,000 characters, and are
  now cut, with the rest of their text unchanged.
- alpha.2's changes: the same 123 and 36, with no difference.
- alpha.3's changes were not run through those comparisons. The self-test's existing cases pass unchanged.

Those changes alter the output only in edge cases that the self-test covers:
- a session started in a subdirectory;
- a map file or cited source that cannot be read;
- a byte-order mark, or a UTF-16 map file;
- a missing temp folder;
- a map file renamed only in letter case, now folded as git's `core.ignorecase` says;
- a map file that `.gitignore` excludes;
- a session-start text past 10,000 characters (an index of about 8,880 characters or more);
- a map file whose labels pass 10,000 characters;
- a document path holding a control character, now listed with `?` in its place;
- a turn that is a subagent's report or another session's message, which no longer takes the forced decision.

**Where it helped:**
- *A designer's spec, read in an earlier session:* kept in 10 of 10 runs (auto memory: 2), and followed in a fresh
  session before the first write in 10 of 10 (auto memory: 0).
- *Naming the decisions followed, with their sources:* 10 of 10 (auto memory: 0).
- *A second person on the same repo* got the same decisions through the committed map. Auto memory is per user.
- *Build and plan rules in the two repos whose rules are prose documents* were followed more often. One rule that auto
  memory never followed was followed in 10 of 10 runs.
- *Across A2's 57 rule cells,* the plugin was above auto memory's count in 17 and level in 31. It was below in 9:
  seven of those by one run of ten, two by two, and five of the nine on question tasks.

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
them are in [docs/v2/DECISIONS.md](docs/v2/DECISIONS.md). The release review is in
[docs/v2/research/2026-10-27-release-review.md](docs/v2/research/2026-10-27-release-review.md). alpha.3 had no
release review, by the user's choice. Its two fixes come from a check of the plugin in the user's own sessions, in
[docs/v2/probes/V2-D17-field/README.md](docs/v2/probes/V2-D17-field/README.md).

## Requirements

- Claude Code: the evals ran on 2.1.305, and live checks on Windows on 2.1.305 to 2.1.311.
- Node 20 or later.
- git. Outside a git repo the index is empty.
- On Windows, Git Bash: the session-start hook runs through bash, as Claude Code itself needs on Windows.

## Install

```
claude plugin marketplace add Cain-Ish/claude-code-plugin#v2.0.0-alpha.3 --scope project
claude plugin install second-brain@second-brain-v2 --scope project
```

- `--scope project` writes `.claude/settings.json`, which your team shares once it is committed.
- To try the plugin only for yourself in one repo, use `--scope local` for both commands instead.
- Start Claude at the repo's root. With a project-scope install, the plugin does not load when Claude starts in a
  subdirectory (checked on 2.1.311). A local-scope install keeps its settings in the same root `.claude/` folder, so
  expect the same.
- `/second-brain:onboard` reports what the index holds.

## Review is the commit

- The map is plain Markdown in `.project-map/`. Claude's changes to it stay in the working tree. You review them in
  `git diff` and commit them with the work.
- Until an entry is committed, a Read of its file labels it unreviewed. That is how text Claude captured from a
  document it read stays visible as unchecked.
- If you leave `.project-map/` out of your commits, its entries stay in your working tree only, still labelled. No
  other clone or teammate sees them.
- Edit or delete entries as you like. The plugin keeps no other state.

## What it writes

- *At run time:*
  - `.project-map/*.md` in your repo, written by Claude under the capture instruction;
  - one empty marker file per session in the OS temp folder (`project-map-<session>.pending`). The session's first
    prompt removes it, so a session that ends before any prompt leaves its marker behind.
- *Installing and uninstalling* change `.claude/settings.json` (or `settings.local.json`) and Claude Code's plugin
  cache.

## What it costs your machine

- *Hook latency,* measured on alpha.2. alpha.3 adds one pattern match per prompt and one per listed path, not timed.
  "Added" is the p95 over an empty Node process. "Wall clock" includes Node's start, which each hook
  pays. The repo had 8,057 files and 190 documents, or was a synthetic repo of the same shape, with map entries citing
  1.26 MB of documents. Figures are ms, added / wall clock:

  | Where | Session start | Map read | Other hooks |
  | --- | --- | --- | --- |
  | 1 session, GitHub's Windows runner (4 cores, 2 runs) | 66 to 69 / 116 to 122 | 70 to 87 / 118 to 148 | 17 / 68 at most |
  | 1 session, GitHub's macOS runner (3 cores, 2 runs) | 30 to 58 / 62 to 120 | 33 to 56 / 64 to 105 | 14 / 68 at most |
  | 1 session, GitHub's Linux runner (4 cores, 2 runs) | 18 to 25 / 37 to 50 | 21 to 32 / 41 to 56 | 11 / 36 at most |
  | 8 at once, a 32-thread Windows machine (3 runs) | 37 to 44 / 118 to 126 | 51 to 61 / 135 to 136 | 25 / 103 at most |
  | 8 at once, the same three runners | 61 to 209 / 137 to 396 | 86 to 217 / 165 to 436 | 97 / 253 at most |

  - Session start also starts bash once, since its hook runs in shell form: about 22 ms more at one session on the
    32-thread machine.
  - CI fails the build when the one-session added time passes 100 ms.
  - The 8-at-once added time on the 32-thread machine was checked at 100 ms before alpha.1 and alpha.2, with the machine
    idle: CPU at most 10% before each run.
  - One CI run in alpha.2's checks went over 100 ms at one session (114 ms at session start on Windows) through
    a few slow calls; its median was as usual. Timed in pairs on the same runner, alpha.2 costs no more than
    alpha.1.
  - On the small runners at 8 at once, the heavier hooks are over that budget. On a 3- or 4-core machine that runs
    many sessions at once, expect each session start and map read to take a few tenths of a second.
- *Context, always on:* 904 B and 212 B per session plus the index (2 to 6 KB in the tested repos), and 227 B for each
  forced decision.

## Known issues

- **Without Node,** session start says so once. After that, every prompt and every file read shows a hook error.
  Install Node 20 or later, or disable the plugin.
- **A large index is cut.** Claude Code documents a 10,000-character limit for one hook's output. Once the
  session-start text would pass it (an index of about 8,880 characters, roughly 250 one-document directories), the
  index lists as many directories as fit, and says how many more there are. Onboarding warns. The forced decision
  then covers only the listed directories. On 2.1.311 the real limit sat higher, between about 12,400 and 16,300
  characters. Past it, Claude saw only a 2,000-character preview.
- **A very large map file's labels are cut.** Past the same 10,000-character limit (about 150 or more labelled
  entries in one file), the read hook lists as many labels as fit. It then tells Claude to treat every later entry in
  that file as unreviewed and unverified. Splitting a long `captured.md` into several files keeps every label.
- **The forced decision** adds a step at the start of each session and after each compaction, even for a question.
- **Claude often reads only some of the directories it marks yes.** In two real sessions with alpha.2, each of three
  checked context windows marked 6 to 8 directories yes. Before changing code, Claude opened documents from 0 to 3 of
  them with the Read tool (3 to 4, counting reads through Bash and the rule files Claude Code loads on its own).
- **Map reads through Bash or Grep get no label.** In the same sessions, Claude read map entries 11 times: 2 through
  the Read tool, labelled, and 9 through Bash (`cat`, `tail`, `grep`), which reached it without "unreviewed".
- **A turn nobody typed** is told apart by its first words, as Claude Code's transcripts record them: a background
  subagent's report or another session's message. If Claude Code passes such a turn in another form, it takes the
  forced decision, as in alpha.2, and your next prompt gets none. If the first turn after a compaction is a
  subagent's report and Claude goes on working from it, that work comes before the forced decision.
- **An automatic compaction in the middle of a turn** lets that turn keep writing before the next prompt brings the
  forced decision back.
- **The closing line** about decisions followed appears even where nothing applies ("none").
- **Letter case** in map file names is folded as git's `core.ignorecase` says, ASCII letters only, as git does. It
  is read from the repo's own config file, where `git init` and `git clone` set it. A value set only in your global
  or system git config, in an included file or in `config.worktree` is not read. Only plain spellings are read: a
  bare `ignorecase`, `true`, `yes`, `on` or a whole number other than 0 count as true. Git's other spellings of true,
  such as `1k`, `0x1` or a value continued with `\`, count as false here, and a partly quoted value is skipped, so
  the line above it stands.
- **For contributors:** a copy installed from a local checkout and one installed from GitHub share the marketplace
  name `second-brain-v2`, so only one of them can be registered on a machine.

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
