# The release review of `2.0.0` (2026-11-07)

**What ran:** the devils-advocate workflow (`.claude/workflows/devils-advocate.js`), on the user's "continue as we
plan" (06, 18f).
- *The workflow:* five lenses (wire, saboteur, contract, historian, minimalist), then a refute-first verifier for each
  finding.
- *The target:* branch `release-2.0.0` at `aa5b909`. The scope was everything since the last reviewed release,
  alpha.2: `git diff v2.0.0-alpha.2 release-2.0.0 -- plugin/ README.md .claude-plugin/`, with nine claims to falsify.
- *The size:* 44 agents. 39 findings were raised, 21 were refuted, and 18 survived: wire 3, saboteur 6, contract 3,
  historian 6, minimalist 0.

Several findings were confirmed by a live run on CLI 2.1.319 or by running the hook on a scratch repo. Others were
traced in the code; the table says which.

## Dispositions

Rule 8: each finding fires a named reopen trigger, is fixed, or is recorded as an accepted risk. Findings 1 and 2 are
one defect, as are 6 to 8, 10, 14 and 17, and 11 and 15.

| # | Finding | Severity | How it was confirmed | Disposition |
| --- | --- | --- | --- | --- |
| 1, 2 | A Bash map read that exits non-zero is a `PostToolUseFailure`, which no hook handles, so its entries reach Claude unlabelled | high | live, CLI 2.1.319 | **Fires D14.** Fixed in 2m: the Bash handler is registered under `PostToolUseFailure` too |
| 3 | The README's Uninstall removes the marketplace with no scope, which on 2.1.319 removes it from every scope, a user-scope one included | medium | live, isolated config | **Fixed** in the README: `--scope project`, as Install adds it |
| 4 | The Bash handler joins several files' labels with no cap, so past 10,000 characters they reach Claude without the cut's fail-closed line | medium | the hook run on a scratch repo: 12,830 and 13,610 characters | **Fixed** in 2m: the joined labels are cut as one file's are |
| 5 | A v1 session still running when the cleanup runs re-installs v1's timer at its next start, clear or resume | medium | traced in v1's code | **Fires D26.** Fixed in the README: quit every running session first |
| 6, 7, 8 | The Bash handler gives this repo's labels to any `.project-map/X.md` in the command: a sibling repo's map, a `pkg/` map, a file after a `cd`, `captured.md.bak` | medium, low | the hook run on a scratch repo | **Fires D14** (a sibling repo's uncommitted entry gets no "unreviewed"). Fixed in 2m: only a path that resolves to this repo's own map file is labelled, as a Read of it is |
| 9 | On Windows, a custom `HOME` in Git Bash puts v1's files where neither D27's check nor the PowerShell cleanup looks | low | run, narrower than raised | **Accepted risk:** Git Bash sets `HOME` to the user's profile folder unless told otherwise |
| 10, 14, 17 | The cleanup names only `~/.config` and `~/.claude`; v1 honoured `XDG_CONFIG_HOME` and `CLAUDE_CONFIG_DIR` | low | traced in v1's code | **Fires D26.** Fixed in the README, beside the `BRAIN_DIR` line. Finding 10's other part, the `settings.json.bak-*` files, was refuted |
| 11, 15 | The `.claude/rules/` filter also drops `.txt`, `.rst`, `.mdx` and `.markdown` files there, which Claude Code does not load | low | the index run on a temp repo; the pinned CLI's rule walker | **Fixed** in 2m: only `.md` files there are left to Claude Code |
| 12 | 2l's check 6 called the session-start difference D27's cost, but v1's shims were removed at 21:47:03Z, before the first pair | low | file times | **Fixed** in the records: 06 and the map issue are corrected |
| 13 | "Install it there with `--scope project`" after an uninstall declares no marketplace in the repo, so a teammate's clone cannot install | low | live, isolated config | **Fixed** in the README: run both Install commands in that repo |
| 16 | PM7's count went unreported since alpha.2, and the labels reached 5 fix commits in 30 days with no keep-or-kill entry | low | the commit log | **Fixed:** the count and the entry (keep, with a kill trigger) are in DECISIONS.md under D14, before 2m's code |
| 18 | The self-test's comment says the pinned hash is what the eval ran; no eval has run since alpha.2 | low | the records | **Fixed** in 2m: the comment says what the release checks ran |

## What this changes

- `2.0.0` gets a new product build, 06's step 2m, and ships it first as `2.0.0-alpha.7`, with the user's install
  moved, so that the field runs the code that ships. D24's corpus clause is amended for this (DECISIONS.md, D24).
- D14 and D26 reopen. Each re-locks unchanged when 2m's checks pass.
- *A second round* checks each fixed finding against alpha.7's code: one refute-first verifier per finding, and the
  live failure-route probe. The 44-agent workflow does not run again.

## Not examined

- No live session on macOS or Linux.
- The interactive display of D27's line: the owner's machine no longer holds v1's shims (finding 12).
- Collaborator installs: finding 13's effect on a teammate is inferred from the docs. Its CLI test in the review
  failed in both repos.
