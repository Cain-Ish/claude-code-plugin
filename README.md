# second-brain v2 (alpha)

A Claude Code plugin that keeps Claude aware of what your project has already decided. At every session start, its
hooks give Claude an index of the repo's own documents. At the first prompt they give it an instruction to say which
of those documents bear on the task, and to read them before changing anything. It also tells Claude to record the
decisions stated during your sessions in plain Markdown files. You review and commit those files like any other
change. These are instructions Claude follows, not locks: no hook blocks a write.

**Status:** `2.0.0-alpha.8`, a pre-release from branch `v2`.
- It has been tested in live Claude Code sessions on Windows only.
- On macOS and Linux, only its self-test has run, in CI.
- v1 (0.57.1) is frozen on [`main`](https://github.com/Cain-Ish/claude-code-plugin).

## What it does

- **At session start**, and again after `/clear`, a resume or a compaction, Claude gets two things:
  - an index of the repo's documents, by directory: every tracked `.md`, `.mdx`, `.markdown`, `.txt` and `.rst`
    file, plus every Markdown file in `.project-map/`, even one that is not committed or that `.gitignore` excludes.
    Files under the root's `.claude/rules/` are left out: Claude Code loads those itself, at launch or, for a rule
    with `paths:`, when Claude reads, writes or edits a matching file;
  - a short instruction to keep the project's decisions in `.project-map/`.
- **At the first prompt you type**, and at the first after each compaction, Claude is told to state for each document
  directory whether it bears on the task (yes or no), and to read the yes ones before it changes anything. A
  background subagent's report or another Claude session's message does not count as that prompt.
- **When someone states a decision or rule in passing**, or Claude reads a document of requirements, Claude is told
  to add it to `.project-map/captured.md`, with its source and date.
- **When Claude reads a map file in the main session** with the Read tool, a hook labels its entries. Every Bash
  command that names the `.project-map` folder carries the labels of every entry not yet committed, whatever it
  printed, and those of the committed entries it printed. A Bash command that exits with an error gets them too:
  - "unreviewed, not yet committed", until you commit them;
  - an entry whose source names a repo file has each stretch of three or more words in its quote checked against that
    file now. If the file is missing, or a stretch is not there word for word, the label says so, and a file that
    cannot be read gets a label too. Shorter quotes, or stretches between ellipses, are not checked, and get no
    label once committed;
  - an entry whose source names no repo file, such as a person's words, is labelled "unverified quote", with its
    capture date. The labels say what that means;
  - if the map file itself cannot be read, one label says to treat every entry in it as unreviewed and unverified.

  When the hook cannot see all of a command's output (a command run in the background, or output past Claude Code's
  limit, which it saves to a file), it gives every map file's labels. Reads by subagents, map text met through the
  Grep tool or PowerShell, and the output of a Bash command that does not name the folder are not labelled: see Known
  issues.
- **When it finishes a change**, Claude is told to name the recorded decisions it followed and where each came from.

It calls no model and uses no network, MCP server or agent. The hooks run Node and start only `git`. Nothing leaves
your machine.

## What was measured, and what was not

The plugin was measured on Claude Code 2.1.305 with Opus 5.5, against Claude Code's own auto memory.
- *A1:* a front-end scenario run over several sessions, 10 runs per arm. It was re-run on alpha.2's code. alpha.3's
  to alpha.8's changes were checked by the self-test, a live smoke session and CI, and alpha.6's and alpha.7's by a
  timing bench as well.
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
- alpha.3's and alpha.4's changes were not run through those comparisons. The self-test's existing cases pass
  unchanged.
- alpha.5's change was compared on the test repos' session-start text: byte-identical on two of the three real repos
  and on A1's fixture. On the third, which keeps its rule files in `.claude/rules/`, only that folder's line is
  gone.
- alpha.6's change: with none of v1's scripts on disk, session start's output is byte-identical to alpha.5's on this
  repo.
- alpha.7's changes, from the release review of 2.0.0: session start's and the prompt hook's output are byte-identical
  to alpha.6's on this repo, on A1's fixture and on the owner's other repo.
- alpha.8's change, labels for what a Bash command printed: session start's and the prompt hook's output are
  byte-identical to alpha.7's on the same three repos.

alpha.5's change is not an edge case: in any repo with a root `.claude/rules/` folder, the index and the forced
decision no longer list it. In the user's own repo, where every one of 30 rule files declares `paths:`, Claude Code
had delivered the rule before the write in 64 of 92 cases, and Claude's reads prompted by the forced decision reached
4 more. The other changes alter the output only in edge cases that the self-test covers:
- a session started in a subdirectory;
- a map file or cited source that cannot be read;
- a byte-order mark, or a UTF-16 map file;
- a missing temp folder;
- a map file renamed only in letter case, now folded as git's `core.ignorecase` says;
- a map file that `.gitignore` excludes;
- a session-start text past 10,000 characters (an index of about 8,880 characters or more);
- a map file whose labels pass 10,000 characters;
- a document path holding a control character, now listed with `?` in its place;
- a turn that is a subagent's report or another session's message, which no longer takes the forced decision;
- a map file read through Bash, which now gets the labels a Read gets;
- v1's statusline or timer script left on disk, which adds one line at session start, shown to you and not to Claude;
- a map file read through Bash by a command that exits with an error, now labelled;
- several map files read in one Bash command whose labels together pass 10,000 characters;
- a document in the root's `.claude/rules/` whose name does not end in `.md`, now listed, since Claude Code does not
  load it;
- map entries printed by a Bash command in a form the command's text did not show as a read (`|` inside quotes, a
  `cd` into the folder, a glob, a loop, `git show`): every uncommitted entry is now labelled on each command that
  names the folder, by the repo's state, and committed entries by what the command printed. A Bash read no longer
  carries the whole file's labels.

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
[docs/v2/research/2026-10-27-release-review.md](docs/v2/research/2026-10-27-release-review.md). alpha.3 and
alpha.4 had no release review, by the user's choice. Their fixes come from a check of the plugin in the user's own
sessions, in [docs/v2/probes/V2-D17-field/README.md](docs/v2/probes/V2-D17-field/README.md).

## Requirements

- Claude Code: the evals ran on 2.1.305, and live checks on Windows on 2.1.305 to 2.1.319.
- Node 20 or later.
- git. Outside a git repo the index is empty.
- On Windows, Git Bash: the session-start hook runs through bash, as Claude Code itself needs on Windows.

## Install

```
claude plugin marketplace add Cain-Ish/claude-code-plugin#v2.0.0-alpha.8 --scope project
claude plugin install second-brain@second-brain-v2 --scope project
```

- `--scope project` writes `.claude/settings.json`, which your team shares once it is committed.
- To try the plugin only for yourself in one repo, use `--scope local` for both commands instead.
- Start Claude at the repo's root. With a project-scope install, the plugin does not load when Claude starts in a
  subdirectory (checked on 2.1.311). A local-scope install keeps its settings in the same root `.claude/` folder, so
  expect the same.
- `/second-brain:onboard` reports what the index holds.

## Coming from v1

Updating from v1 (`0.57.1`) replaces v1's code. It leaves behind what v1 wrote outside the plugin: a statusline and a
timer that runs every 30 minutes.
- Claude Code keeps v1's old copy for 14 days, and until then both still run it.
- After that, the statusline prints "buddy: no second-brain renderer found". That command no longer exists.
- While v1's statusline or timer script is on disk, v2's session start shows you one line that points here. Claude
  does not see it.
- An alpha of v2 installs beside v1, under another marketplace name, and does not replace it. Uninstall v1 first:
  `claude plugin uninstall second-brain@second-brain`.

First quit every running Claude Code session. A session that started before the update keeps v1's hooks, and its
next start, `/clear`, resume or fork puts v1's timer back.

Then remove them in this order:

1. **The statusline.** In `~/.claude/settings.json`, find the `statusLine` entry whose command runs
   `buddy-statusline.sh`, and delete it.
   - If its command starts with `SB_BUDDY_CHAIN='…'` and the quotes hold a command, that was your statusline before
     v1.
   - In that case, set it back instead: `"statusLine": { "type": "command", "command": "<the command>" }`.
   - Copy the command as it appears in the file, so its JSON escapes stay as they are. Where it holds `'\''`, write a
     single `'` instead.
2. **The timer and v1's scripts.**

   macOS:
   ```
   launchctl bootout "gui/$(id -u)/sb-extract-drain"
   rm -f ~/Library/LaunchAgents/sb-extract-drain.plist
   rm -f ~/.second-brain/bin/buddy-statusline.sh ~/.second-brain/bin/sb-extract-drain.sh ~/.second-brain/.extract-timer-env
   ```

   Linux:
   ```
   systemctl --user disable --now sb-extract-drain.timer
   rm -f ~/.config/systemd/user/sb-extract-drain.service ~/.config/systemd/user/sb-extract-drain.timer
   systemctl --user daemon-reload
   rm -f ~/.second-brain/bin/buddy-statusline.sh ~/.second-brain/bin/sb-extract-drain.sh ~/.second-brain/.extract-timer-env
   ```

   Windows, in PowerShell:
   ```
   schtasks /Delete /TN sb-extract-drain /F
   Remove-Item "$HOME\.second-brain\bin\buddy-statusline.sh", "$HOME\.second-brain\bin\sb-extract-drain.sh", "$HOME\.second-brain\bin\sb-extract-drain-hidden.vbs", "$HOME\.second-brain\.extract-timer-env" -ErrorAction SilentlyContinue
   ```

- If you set `BRAIN_DIR` for v1, use that folder in place of `~/.second-brain`. If you set `XDG_CONFIG_HOME` or
  `CLAUDE_CONFIG_DIR`, use those folders in place of `~/.config` and `~/.claude`.
- `.extract-timer-env`, removed above, may have held your `ANTHROPIC_API_KEY`. Until you remove the timer, v1's old
  copy can still use it. What v2 says about making no network calls holds for v2's own hooks, not for v1's leftovers.
- Your data stays: `~/.second-brain` and `~/knowledge` hold what v1 learned. v2 does not read them; keep or delete
  them as you like.
- v1 was installed for your user, so after the update v2 runs in every repo you open. To use it in chosen repos only,
  run `claude plugin uninstall second-brain@second-brain`, then run both Install commands in each of those repos.

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
  alpha.4's Bash handler was timed in CI at one session (Linux, Windows, macOS): a map read through Bash added 25, 70
  and 49 ms, as a Read of it does; a command that names the folder but reads no map file, 7, 17 and 13 ms.
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
  - The 8-at-once added time on the 32-thread machine was checked at 100 ms before alpha.1, alpha.2, alpha.6 and
    alpha.7, with the machine idle: CPU at most 10% before each run.
  - alpha.7, in two windows of 3 pairs against alpha.6: every hook added at most 57.1 ms, with 0 errors. alpha.6's map
    read added 106.8 ms in one pair of the first window and at most 61.9 ms elsewhere.
  - alpha.6, in 3 pairs against alpha.5 on that machine: every hook added at most 92.1 ms, with 0 errors. Session start
    added 52 to 92 ms, against alpha.5's 64 to 66 in the same pairs. The spread between pairs is wider than the
    change. v1's scripts were no longer on the machine, so the path that adds the line was not timed.
  - One CI run in alpha.2's checks went over 100 ms at one session (114 ms at session start on Windows) through
    a few slow calls; its median was as usual. Timed in pairs on the same runner, alpha.2 costs no more than
    alpha.1.
  - On the small runners at 8 at once, the heavier hooks are over that budget. On a 3- or 4-core machine that runs
    many sessions at once, expect each session start and map read to take a few tenths of a second.
- *Context, always on:* 904 B and 212 B per session plus the index (2 to 6 KB in the tested repos), and 227 B for each
  forced decision. Each read of a map file, through the Read tool or Bash, adds that file's labels.

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
- **The forced decision covers the first prompt you type in a session, or after a compaction.** A change you ask for
  in a later prompt gets none. Neither does work in a turn a background task started. In one real session on alpha.5,
  Claude made 45 file writes, and none came in reply to a first prompt that asked for that change:
  - 22 followed a first prompt that was a question: 1 in that turn, and 21 in the next prompt;
  - 6 came in the turn that carried on after a compaction while the session was idle;
  - 17 came in turns that background tasks started.
- **Claude often reads only some of the directories it marks yes.** In two real sessions with alpha.2, each of three
  checked context windows marked 6 to 8 directories yes. Before changing code, Claude opened documents from 0 to 3 of
  them with the Read tool (3 to 4, counting reads through Bash and the rule files Claude Code loads on its own).
- **Some map reads get no label:** through the Grep tool, a script that reads the file, a command that names only the
  folder, PowerShell, or a subagent. In the same sessions, Claude read map entries 11 times: 2 through the Read tool
  and 9 through Bash (`cat`, `tail`, `grep`). alpha.4 labels both kinds. alpha.8 gives every uncommitted entry's
  label on each Bash command that names the folder, whatever the command printed. Still unlabelled: the output of a
  command that does not name the folder, even when it prints map entries (`git diff` or `git show` from the root, `rg`
  or `grep -r` over the repo, a script that builds the path at run time). The labels follow the map as it is after
  the command, so these also get none:
  - a command that reads entries and then removes or reverts them (`rm`, `git checkout`, `git stash`);
  - entries that are only in git's index or a stash (`git show :…`, `git diff --cached`, `git show stash@{0}:…`);
  - map files whose name does not end in `.md`, as for the Read hook;
  - a package's own `.project-map/` below the repo's root;
  - text outside the entry format: a `###` block with no `>` line, an indented `>`, a `####` or `##` block.
- **A committed entry's labels** ("unverified quote", "not found") come with a Bash command only when its output shows
  the entry, and can be missing when the output is reshaped: shown in part (a line cut short or wrapped, `grep -o`,
  colour codes), in an encoded form (`cat -A` or `cat -v` of non-ASCII text or tabs, `od`, JSON escapes), with its
  `>` markers stripped or its spaces changed, or only through a line that other entries of its file share.
- **Another repo's map entries printed through Bash get no label,** as a Read of them gets none. An entry there with
  the same line as one in this repo gets this repo's labels for it.
- **Each read repeats its labels.** A Read carries the whole file's, and a Bash command those of the uncommitted
  entries and of the entries it printed. So until you commit the map, each such command lists its new entries. A line that a map file's only entry holds, such as its when line, labels that entry when another
  file's output shows the same line.
- **Before Claude Code 2.1.85,** which ignores the hook's `if` field, the Bash handler starts on every Bash command. It
  labels the map entries any command prints.
- **A turn nobody typed** is told apart by its first words, as Claude Code's transcripts record them: a background
  subagent's report or another session's message. If Claude Code passes such a turn in another form, it takes the
  forced decision, as in alpha.2, and your next prompt gets none. If the first turn after a compaction is a
  subagent's report and Claude goes on working from it, that work comes before the forced decision.
- **Rules in `.claude/rules/` reach Claude only through Claude Code** (alpha.5). Claude Code delivers a `paths:` rule
  when Claude reads, writes or edits a matching file. After a compaction, an edit made without a new read of the file
  gets no delivery: in the user's own sessions, 22 of 92 rule cases. The forced decision had not covered them either.
- **A repo whose only documents are in `.claude/rules/`** gets an empty index and no forced decision.
- **A `.claude/rules/` folder below the root** (`pkg/.claude/rules/`) stays in the index, since whether Claude Code
  loads one was not checked.
- **An automatic compaction in the middle of a turn** lets that turn keep writing before the next prompt brings the
  forced decision back.
- **The closing line** about decisions followed appears even where nothing applies ("none").
- **Letter case** in map file names is folded as git's `core.ignorecase` says, ASCII letters only, as git does. It
  is read from the repo's own config file, where `git init` and `git clone` set it. A value set only in your global
  or system git config, in an included file or in `config.worktree` is not read. Only plain spellings are read: a
  bare `ignorecase`, `true`, `yes`, `on` or a whole number other than 0 count as true. Git's other spellings of true,
  such as `1k`, `0x1` or a value continued with `\`, count as false here, and a partly quoted value is skipped, so
  the line above it stands.
- **The line about v1's leftovers links to `main`'s README,** which is v1's until v2 moves there. The steps are in
  [Coming from v1](https://github.com/Cain-Ish/claude-code-plugin/tree/v2#coming-from-v1), on branch `v2`.
- **For contributors:** a copy installed from a local checkout and one installed from GitHub share the marketplace
  name `second-brain-v2`, so only one of them can be registered on a machine.

## Uninstall

```
claude plugin uninstall second-brain@second-brain-v2 --scope project
claude plugin marketplace remove second-brain-v2 --scope project
```

- For a `--scope local` install, use `--scope local` in both commands.
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
