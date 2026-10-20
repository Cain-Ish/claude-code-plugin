# v1 post-mortem: root causes and the v2 rules they produce

Evidence lives in [research/2026-10-19-v1-postmortem.md](research/2026-10-19-v1-postmortem.md) (root causes RC1-RC8,
numbers in §2, rejected candidates in §4; key claims spot-checked at `v1-final` on 2026-10-20). This page keeps only
the causes, the rules and their checks.

A rule here constrains **how** a decision is checked, never **which** option wins: the decisions stay open in
[DECISIONS.md](DECISIONS.md), and each threshold is set by the decision that owns it, from its own check. A check
marked *build* is direction until code exists (charter: a guarantee names its check or is marked as direction).
Decisions cite these rules as PM1-PM8.

## Rules

### PM1. Outcome before input (RC1)
- **Cause:** v1 built capture and storage for months and never ran the experiment that would show whether memory
  changes what Claude does. Its own use metric stayed at zero the whole time.
- **Rule:** no capture, storage or delivery code is written before the outcome eval has run its two baselines. A
  feature ships only with an eval run of its own commit that meets the delta the feature pre-registered.
- **Check:** *concept:* the charter's definition of done, item 4 (`05-eval-plan.md` holds baselines that actually
  ran). *build:* every release cites an eval run of its own commit; no run, no release.
- **Binds:** D17, `06-first-slice.md`.

### PM2. Arrival is probed, not assumed (RC2)
- **Cause:** v1 forbade the native channels (`CLAUDE.md`, rules, `MEMORY.md`) and pushed everything through hooks,
  which reached fewer agents than the native file it had ruled out.
- **Rule:** a channel carries content only after a nonce probe on the installed CLI shows it arrives in every
  context that needs that content (main session, subagents, after compaction). Native and plugin channels face the
  same bar, and the native ones are always among the options.
- **Check:** *concept:* every delivery channel in `04-architecture.md` cites its D12 probe row. *build:* the probe
  re-runs when a CLI release changes how that channel loads.
- **Binds:** D12, D11, D13.

### PM3. Hot-path cost is measured where it hurts (RC3)
- **Cause:** every v1 hook was a bash script forking jq, git and cygpath. Under concurrent load on Windows the hooks
  ran past their timeouts, so pushes never arrived and guards failed open.
- **Rule:** every hook v2 ships states its latency budget and its failure mode, and is measured on Windows (Git Bash)
  under concurrent sessions before it is chosen. A hook is the last resort, chosen only where no native channel does
  the job (PM2).
- **Check:** *concept:* D18 lists each hook with a measured p95 under load below its budget. *build:* a latency test
  on the Windows lane fails the build when a hook exceeds its budget.
- **Binds:** D18.

### PM4. Readable and correctable without the plugin (RC4)
- **Cause:** v1's knowledge lived in one machine-local store built from one person's transcripts. Nobody could read,
  review or correct it outside a working plugin, and it rotted unseen.
- **Rule:** knowledge is kept in plain files that a person can open, read and correct without the plugin running.
  Anything machine-local is a cache that one command rebuilds from those files. Who shares them is D10's and D11's
  question.
- **Check:** *concept:* D11's record shows the home is plain files tracked in git (location), and D13's paper map
  has a person read and correct one entry with the plugin disabled (format). *build:* a test deletes the cache,
  rebuilds it, and the eval scores the same.
- **Binds:** D11, D13.

### PM5. Nothing enters unreviewed, nothing is delivered unchecked (RC5)
- **Cause:** v1 ran an LLM extractor over raw transcripts at every Stop and wrote the result straight into what it
  injected. A learned rule became a persistent prompt injection.
- **Rule:** the charter's two lines are the rule: untrusted text does not enter the map without review, and a claim
  points at what it describes and is checked before use. This cause is why they are there.
- **Check:** *concept:* D14's probe (a poisoned tool output cannot reach the map without appearing in a reviewable
  diff) and D16's seeded-drift check. *build:* a lint fails on a delivered claim with no anchor.
- **Binds:** D14, D16.

### PM6. Every surface serves a measured outcome (RC6)
- **Cause:** guards, workflow gates, a persona advisor, a statusline pet and an environment catalog grew inside a
  memory plugin. They took a quarter of all fixes and most of the last audit's MUST findings.
- **Rule:** every surface (hook, skill, agent, MCP tool, script) names the charter outcome it serves. A surface that
  serves none is out, however useful.
- **Check:** *concept:* the surface budget in `06-first-slice.md` has an outcome column with no blanks, and D10 fixes
  the non-goals. *build:* a manifest lint fails on a surface with no outcome.
- **Binds:** D10, D18, `06-first-slice.md`.

### PM7. Keep or kill before fixing again (RC7)
- **Cause:** each audit produced a list, parallel agents fixed every item, and the next audit found the regressions.
  Most rows of the last audit were made or missed by the previous remediation.
- **Rule:** a subsystem with 5 or more fix commits in 30 days, or any regression of an earlier fix, gets a
  keep-or-kill entry in the ledger, against its outcome metric, before the next fix. Findings are closed by deletion
  where deletion works. This is `01-process.md` rule 4 applied to code.
- **Check:** *build:* release notes count fix commits per subsystem; a subsystem over the line without a ledger
  entry blocks the release. In the concept phase, rule 4 already covers decisions.
- **Binds:** the build phase, through `06-first-slice.md`.

### PM8. Budget real costs; platform facts carry triggers (RC8)
- **Cause:** v1's gates counted files and tests. The file counts stayed flat while the code grew by half, and a
  green suite hid a dead injection gate for the feature's whole life.
- **Rule:** budgets use units that cost something (always-on bytes per session, processes per hook event, p95
  latency, product lines), never file counts; the owning decision sets each number from its check. A decision that
  rests on a Claude Code behaviour carries a reopen trigger for the CLI release that changes it (D01's mechanism, not
  a separate expiry).
- **Check:** *concept:* the budget table in `06-first-slice.md` uses these units, and D12, D13 and D18 each carry a
  CLI-change reopen trigger when they lock. *build:* the budget file is checked in CI.
- **Binds:** D12, D13, D18, `06-first-slice.md`.

## Rejected as root causes

Research §4 settled these. The phase-gate review does not reopen them without new evidence.

- **Token bloat:** v1's always-on injection was small; its cost was processes, latency and zero use per token (PM1,
  PM3).
- **Retrieval ranking:** after the dead gate was fixed, reads stayed near zero while the content was judged good.
- **"A Windows problem":** macOS and BSD shell bugs shipped too. The cause is shell as the runtime; Windows
  amplifies it (PM3).
- **Too few tests:** tests outweighed the product and checked mechanics, not outcomes (PM8).

## What v1 showed works

Native `MEMORY.md` arrived in 3 of 4 probed agents against 1 of 3 for the plugin's own card, and pulls started by the
model were the only non-zero use signal: 13 pulls against 0 reads of 45 pushed items (research §2.6). This is
evidence for D12 and D13, not a decision.
