# The plugin rethink (2026-11-25): status, platform fit and packaging

The user's request of 2026-11-25:
- a full status check of every feature, improvement and change against what was planned;
- add what is missing;
- a rethink of the whole plugin, with research, on whether it is right and will fully work with Claude Code;
- a ponytail audit;
- "make sure that we do not expose all repo as plugin just required to work code".

This note covers the status, the platform fit and the packaging. The items it finds go into 06's register.

**What was read.** All reads are at `18de2b0e`, through a `git archive` export: another session was moving 8i and 8j
into `plugin/` at the time.

**Sources:**
- Claude Code's documentation, read 2026-11-25. The pages cited below are under `code.claude.com/docs/en/`.
- The installed CLI, 2.1.332, run against two throwaway config folders, with counts only.
- A sweep of the charter, the ledger, the register, #115 and the research notes since 2026-11-20 against `plugin/`.
- An outside review by Gemini 4 Argon, through `agy` in plan mode, given one brief file of the shipped files and two
  docs. Its findings were checked in the code before use (section 4).

## 1. Status against the plan

**Is everything planned built?** No, and the plan says so itself. 2.6.0 is not released.
- 8i and 8j are built in copies, by the builders' reports. They are not in `plugin/`.
- 8k (all of 8a on 2.6.0) and 8l (the text step) are registered and not built.
- Still to come: the refactors, the records (C-9: D10 and D18 re-locked on the built surface), group M, D18's bench,
  and the release stop.

**What the charter and the ledger promise,** against `plugin/` at `18de2b0e`:
- Built:
  - setup (D29);
  - the document index at session start, cut at the cap (D15, D22);
  - the capture instruction and versioned entries (D13, D14, D30);
  - the forced per-directory decision (D22);
  - Read and Bash map labels (D14, D16, D28, 8h);
  - the naming line (D23) and the v1 notice (D27);
  - the dream's prepare, analyze, finish and close (D31);
  - the review in the same session (D33);
  - use and steering in the dream (D35);
  - status (D30, D32) and onboard (D15);
  - the project agents and map-review with the trial verdict (D20, D21, D29, D34).
- Partly built:
  - the waiting note leaves out agent drafts (K-5);
  - tailor cannot change an existing artifact, though its description offers to. `trial.mjs` refuses when the live
    file exists. The wording goes into 8l's text.
- Not met, on record: A1's "fewer tokens and steps" (the charter, 2026-10-25), and labels on a subagent's map read
  (04, accepted risk).
- Not yet measured: D18's 100 ms on 2.6.0. It is a release item.

## 2. Platform fit (the docs, and CLI 2.1.332)

**Holds:**
- **The hook output cap** (`hooks.md`) is 10,000 characters for additional context, with a 2,000-character preview
  past it. `startText` caps the whole session-start text, not only the index, at 10,000 (`map.mjs`, `CAP`).
- **The hook forms:**
  - `args` is the documented exec form: no shell, one element per argument;
  - `shell` is a documented field, ignored when `args` is set;
  - `${CLAUDE_PLUGIN_ROOT}` is substituted in `command` and in each element of `args`.
- **`additionalContext`** under `hookSpecificOutput` is documented for SessionStart, UserPromptSubmit, PostToolUse
  and PostToolUseFailure. PostToolUseFailure's input carries `error`.
- **The `if` field** (`hooks.md`) is evaluated on PostToolUse and PostToolUseFailure, and for Bash on each
  subcommand. The docs call it best-effort. 8h's guard in the handler already covers the commands it lets through.
- **Skills** (`skills.md`):
  - `${CLAUDE_PLUGIN_ROOT}` is expanded in `allowed-tools`;
  - `disable-model-invocation` still lets the person type the skill;
  - an `allowed-tools` grant lasts the turn that invokes the skill, which is C-6, now documented. 8l's `make` (a new
    invocation) follows it.
- **Plugin agents** ignore `permissionMode`, `hooks` and `mcpServers` (`sub-agents.md`). The fields matter in a
  project agent, which is where the dream's and tailor's drafts land (X-4, J-1, J-2).
- **Path rules** load when Claude reads, writes or edits a matching file, and on a single-file `cat` or `head` through
  Bash (`memory.md`). D22's choice to leave `.claude/rules/` to Claude Code stands.
- **Native auto memory** is per machine and outside git, and the docs describe no dreaming or consolidation. So the
  plugin's team map and dream do not duplicate a platform feature.
- **Version pinning** (`plugins/loading.md`): with `version` in `plugin.json`, a push does not reach installs until the
  version changes, which is how releases already work.

**New, from the docs** (items Q-1 to Q-5):
- **Q-1:** SessionStart now has a `fork` source (startup, resume, clear, compact, fork). The plugin's matcher leaves it
  out, so a forked session gets no start context unless the copied transcript carries it. D12 probed `clear` and
  `resume`, not `fork`. 06 has one unexplained field sighting that may come from a fork (the 2.5.0 field read).
- **Q-2:** the skills' grants use `Bash(node "<root>/scripts/x.mjs":*)`, a quoted path and the `:*` suffix. The docs
  show `Bash(<root>/scripts/x.sh *)`. The quoted form works on every CLI version the probes ran, but it is not
  documented, and if it stopped matching, every skill would fall back to a permission prompt.
- **Q-3:** `hooks.json` sets no `timeout`. The documented defaults are 600 s, and 30 s for UserPromptSubmit, so a hook
  that hangs holds the session that long. D18's budget is 100 ms.
- **Q-4:** `engines: {"claude-code": ">=…"}` is documented. The plugin relies on the `if` field, the exec form and
  PostToolUseFailure, and nothing stops an older CLI from loading it.
- **Q-5:** `memory: project` turns on Read, Write and Edit for an agent (`sub-agents.md`). So the decision-checker and
  codebase-guide templates (`tools: Read, Grep, Glob`) can edit files, not only their notes. This repo's agent listing
  shows decision-checker with Write and Edit. The checks in section 4 hold what the templates and 04 claim.

## 3. Packaging: what an install downloads

Measured on CLI 2.1.332, in throwaway config folders:

| Install | Marketplace clone | Plugin cache |
| --- | --- | --- |
| As the README says (`marketplace add Cain-Ish/claude-code-plugin`) | Shallow clone of all of `main`: 449 files, 390 of them under `docs/v2`. The working tree holds `.claude/`, `.project-map/`, `.github/`, `docs/` and `plugin/`; 5.8 MB with `.git` on the user's machine | Only `plugin/`, with `test/` (185 of its 307 KB tracked) |
| With `--sparse .claude-plugin plugin` | `.claude-plugin/`, `plugin/` and four root files: about 450 KB, plus a 290 KB `.git`. The paths are kept as `sparsePaths` in the marketplace's source and in settings, and an update keeps the sparse checkout | Unchanged |

- **What the docs say:**
  - only the plugin's folder is copied to the cache ("Files outside the plugin directory aren't copied");
  - nothing like an ignore file or a `files` list is documented;
  - the ways to fetch less are `--sparse` (or `sparsePaths`), a `git-subdir` plugin source (sparse, one folder), and a
    marketplace hosted as one `marketplace.json` file whose plugins use object sources (`plugins/marketplace-reference.md`).
- **Nothing in `plugin/test/` is read at runtime.** Setup keeps earlier templates' hashes in its own code; the
  `earlier/` texts serve only the self-test.
- **An existing install cannot switch to sparse with one command:**
  - adding the marketplace again with `--sparse` is refused, because its source no longer matches the entry in user
    settings;
  - adding `sparsePaths` to that settings entry made the CLI report the marketplace as not found, and the clone stayed
    full.

  So the two field installs and the user's own keep a full clone until something else changes.
- **The options** (the user's word; D03 and D25 bear on them):
  - **(T) Tests out of `plugin/`:** the cache then holds runtime files only. A check compares the shipped file list
    with an allowlist. It belongs to the refactor step, since it moves the tests 8i to 8k are editing.
  - **(A) The README's install line gains `--sparse .claude-plugin plugin`:** this reaches new installs only, and only
    those added that way. No decision moves.
  - **(B) `main` holds only the product** (`plugin/`, `.claude-plugin/`, README, LICENSE, CI), and the docs stay on
    `v2`:
    - every install, old or new, downloads only that at its next marketplace update;
    - a release copies the product onto `main` instead of merging `v2`.

    D03 (which branches carry v1 and v2) changes. D25's name and in-place reach hold.
  - **(C) A separate marketplace repo, or a hosted `marketplace.json` with a `git-subdir` source:** existing installs
    must add it again, which breaks D25's in-place reach.

## 4. The outside review (Gemini, via agy), checked

**How it was run:**
- Gemini read one brief file: the shipped files except the tests, the manifest, the charter and 04.
- Its 24 findings were checked in two ways. Where a claim was about Claude Code, against the docs in section 2.
  Otherwise in the code at `18de2b0e`, by a verifier using `node` snippets and temporary repos.
- Its line numbers were the brief's, not the files'.

**Confirmed and new** (items Q-5 to Q-18):
- **Q-5:** the agent templates say "Your writes go only to your memory folder", in codebase-guide and decision-checker.
  memory-curator says "only there and to `.project-map/`". `memory: project` turns on Write and Edit with no path scope
  in the docs, so the limit is an instruction and is not enforced.
- **Q-6:** prepare skips a session that ran `/second-brain:dream` whole, and for good. Its turns before the dream and
  after the review are never read.
- **Q-7:** the digest drops a typed prompt whole when it has any part that is not text, such as an image. It also
  drops one whose text starts with `<`, which includes prose that opens with a tag and the arguments typed after a
  slash command.
- **Q-8:** in a folder without `.git`, session start still adds the capture instruction and the naming line, 2,215
  bytes.
- **Q-9:** the catalog's due count and the read labels count an entry already ended by a status line once its review
  date has passed. The status report leaves such entries out.
- **Q-10:** the due nudge and the status report's "sessions since" do not count a session that an earlier dream read
  and that has grown since it was resumed. Prepare does read it.
- **Q-11:** dream and status in a folder without `.git` print a raw `ENOENT` message holding an absolute path.
- **Q-12:** the Read hook's relative path has no real-path step. So `/var/…` against `/private/var/…`, or an 8.3 short
  name, gives no labels, and the hook fails open. A drive letter's case does not matter. 8g's real-path step is in
  prepare only.
- **Q-13:** nothing checks the Node version, and only session start checks that `node` exists. On Node 16 on Windows,
  every event exits 1 with a raw read error, so there is no index and map reads go unlabelled. The "needs Node 20"
  message never shows once `node` starts.
- **Q-14:** the private-data filter rejects ordinary project text, such as `GET /users/:id`, `/home/dashboard`,
  `avatar@2x.png`, `git@github.com:org/repo` and `/etc/nginx/`. So finish drops such entries and drafts.
- **Q-15:** finish and abort restore the watched files from prepare's snapshot. So an edit another session makes to
  them while a dream is open is reverted and moved to the data folder. The finish report says so; the session that
  made the edit is never told.
- **Q-16:** finish checks a quote against all the digests' typed lines joined together. So a quote trimmed with "…"
  can match halves from two sessions. Typed lines are cut at 4,000 characters, so the dream never sees the end of a
  long prompt.
- **Q-17 (low):** the data folder's check fails when the plugins' data folder does not exist yet. It may never happen,
  since the docs say Claude Code creates it on first reference.
- **Q-18 (low):** the dream-analyzer sets no `model`, so it runs on the main session's. The first dream's 8 analyzers
  used about 610k tokens. A cheaper model would have to re-earn S7's counted runs.

**Already in the register:**
- `claude` through npm's `.cmd` on Windows (K-8);
- the grant ending with the turn (C-6);
- the removal inside `finally` (K-3);
- the whole-repo `headText` (D-5, in 8k);
- agent drafts missing from the waiting note (K-5);
- a skill's subfolder in `draft()`;
- the heredoc's delimiter (X-6);
- the trial's settings sources and tool reach (X-3).

**Refuted:**
- "`args` is not a documented hook field": it is the documented exec form.
- "A dream in `app` reads the sessions of `app-backend`": prepare lists that folder, but it skips each session whose
  working folder resolves to another repo.

**Not taken** (each argues against a locked decision, and none names a trigger that fired):
- delete the forced per-directory decision and the prompt hook (D22);
- delete the Bash label hooks and keep review state only in the entries (D14);
- delete the dream's snapshot and restore (D31);
- drop codebase-guide for Claude Code's built-in Explore agent. T-6 already records the agent as unused.

## 5. Where the items went

The other session keeps the register, and placed every item in 06 and in #115's step 28:
- **Into 8k,** the last hook change: Q-1 (`fork`) and Q-3 (timeouts).
- **Into 8l's text:** Q-5.
- **Under "later":** Q-2 (the grant's form), Q-4 (`engines`) and the sweep's low items.
- **Under records:**
  - D22's two field observations, judged against its trigger;
  - #115's step 22;
  - a triage of #115's Fog.
- **Under A5-2:** the packaging measurements of section 3, which wait for the user's choice.
- **From the sweep, taken into 8k and 8l before their code:**
  - L-2's rule, which applies to skills only: an agent's case names the agent;
  - D-3's redaction, which makes repo paths relative first;
  - tailor's "change" wording;
  - PM7's keep-or-kill read at the release;
  - the ids cited but never defined.
- **Q-6 to Q-18** were sent to the register's keeper after the checks in section 4.
