# Rethink (2026-11-25, evening): disk, process cost, and what is left of the per-repo loop

The user's word, mid-build of 8k:

> Rethink approach to check if 8gb of copies repo are needed when we still has not deliver real product. We have lots
> of elements in the research that still need to be implemented. We need to rethink, plan and split work and make
> sure that our plug-in works and we do not expose all repo just required files and all need to implement [Lamis
> Mukta's] approach per repo

## 1. Where the disk goes (measured with `du`, after the wipe below)

| What | Size | Needed? |
| --- | --- | --- |
| `docs/v2/research/raw/` (gitignored, never pushed or installed) | 2.6 GB | Local evidence behind earlier field counts; 1.7 GB is one folder of frozen field sessions. Nothing builds or runs from it |
| Claude Code project folders left by sessions that ran inside temp copies (probes and trials) | about 1 GB in 1,303 folders | Mostly no. S-1 counted 448 on 2026-11-24. Some hold a probe's transcript (S1's runs, by name), so a delete loses that evidence |
| This repo's own session transcripts | 0.7 GB | Yes: the dream reads them |
| The system temp folder, all of it | 0.5 GB | Build copies are 115 MB of it |
| A build copy of `plugin/` | about 0.3 MB | Yes, and cheap |
| What an install downloads today | a 5.8 MB clone of all of `main` (449 files, 390 under `docs/`), and `plugin/` with its tests in the cache | Only the product: 8n |

This repo accounts for about 4.8 GB, not 8. Measured after the wipe, so what the wipe removed is not counted. None
of it ships; the copies the process needs are small.

**The wipe of 2026-11-25 (about 20:26 to 20:28 local).** Every folder under Claude Code's per-project temp root was
emptied while group C's trial-side mutation run was half-way: the build copies, the briefs, Node 20 and the hash
script. Entries in the system temp folder from before it survived, so a delete of the whole temp folder is ruled out.
A session start was recorded at 20:26. The cause is not settled. The trial's code removes only its own `mkdtemp`
copies and project folders with no transcript. Since then, build copies live outside that root and every test run has
its own `TEMP`.

**Recovered:** groups A and B were replayed from their recorded edits, and both product hashes match (`b78afc32ea78`,
`b18e8f7d0b88`). Group C's replay equals its rebuilt candidate. The merged copy passes the trial side's 14 cases,
D-2 included against B's real `PRIVATE`. It carries X-3's fix: trial sessions get only `Bash(...)` grants and an
allowlisted environment.

## 2. What the process costs

- 8k adds hardening, `index.ignore`, agent drafts in the waiting note, and X-3's fix. 2.6.0 is still unreleased, and
  2.5.1 has no tailor, trial or use reading.
- The cost is wall-clock: each mutation list runs the tests once per mutation, an hour or more per list. It stays
  as registered, and runs in the background, each list with its own `TEMP`, while the next step is written.
- The anchors, on the merged copy: 8d, 8f, 8j and the three 8k lists are found whole. 8k moved one anchor of 8c's,
  three of 8e's and four of 8i's; those lists are updated to the new lines, as a moved guard's list always is.
  `mutate7` was already stale on the base (28 of 42 missing, since 8e replaced the 7a script): B-6's report.

## 3. The per-repo loop (Lamis Mukta's shape): built and missing

Her loop, per the research of 2026-11-24: memory written in the session; a dream over transcripts and tool calls;
steering; evidence with prevalence; a person who accepts each change; skills written "for next time" and improved in
cycles.

| Piece | State |
| --- | --- |
| Memory written in the session | Built (D13, D14, D30) |
| A dream over sessions, tool calls and use; steering | Built (D31, D35: 8c, 8d) |
| Evidence and prevalence per proposal; a person accepts | Built (8d, D33) |
| Make an agent, skill or path rule from a gap, tested against a run without it | Built (D34: tailor and its trial) |
| **Improve an existing skill or agent** | **Missing:** C-4. The dream's drafts and live artifacts have no case file, so they reach promotion untested |
| **Claude starts the loop itself** | **Missing:** 8l |
| **Per repo, and per source in a monorepo** | **Missing.** Setup makes one layout per git root. A nested package's own `.claude/` is "later" (R-o) |

**Still open from the research notes and the register's "later":**
- From the DevCon note: K3, decision-checker reads the code before the change, then the change (deferred).
- From the Pocock note: one home for the entry format (not taken: D14 and D30 freeze it).
- From the 2026-11-24 note and the register: R-b (usage kept between dreams, for trends and before-and-after), R-g
  (steering in setup and capture), R-o (a nested package's `.claude/`), K-6 (an Agent call with no type is not
  counted), the `claude plugin eval` probe, S-5 ("set up once, then it keeps itself current"), T-6 (two agents
  unused), R-c (the placement table's agent row).

**The evidence on the monorepo half** (2026-11-24, section 5): agents and skills generated from a repo alone, before a
session shows a gap, score below no skills at all (SkillsBench: -8.1 points on Claude Code). So "setup determines what
applies" can safely mean: setup finds the repo's sources (each package with its own build file or instructions), gives
each a scope in the map and the index, and the dream and tailor make artifacts for a scope only from that scope's
sessions. Writing agents or skills at setup is what the evidence measures as a loss. This is the user's call.

## 4. The plan, split

**Stream 1, this session (the product to a release):**
1. 8k: the checks as registered (in the background), the reviews, then `plugin/` and `2.6.0-live.2` for the peer.
2. 8m, then 8l, as registered (8m before 8l, so the counted runs are re-earned once), with C-4 in 8l.
3. Release 2.6.0 with 8n: `main` holds only the product, and `plugin/` ships without `test/`, so an install downloads
   only what runs. Stop and ask before `main`.

**Stream 2, the peer (live):** each build as `2.6.0-live.N`; the live loop in this repo (a dream that proposes, tailor
improving an existing skill, map-review promoting); 8n's install measurement on a throwaway config.

**Stream 3, scopes for a monorepo (a new decision, D36):** probe first, on a monorepo with two sources in different
languages. Does a per-scope index and per-scope drafts change what Claude follows, against today's one root?
Registered before it is built. Its place, before or after 2.6.0, is the user's call.

## 5. The user's answers (2026-11-25)

- **Disk:** delete the leftovers and the raw research. Done the same evening:
  - 1,240 leftover project folders of temp copies (876 MB). Folders named "live", this session's, and any touched in
    the last hour were kept; 63 remain.
  - The five temp trial folders left by group C's interrupted runs.
  - `research/raw/` (2.6 GB).

  The peer was not running, so it could not be asked; its live install and folders were not touched. Earlier field
  counts that cite `raw/` now rest on their recorded results only.
- **Monorepo:** scopes, with artifacts made only from gaps. Setup finds each source and gives it a scope; the dream and
  tailor make agents and skills for a scope only from that scope's sessions.
- **Order:** scopes after 2.6.0 (D36, stream 3).
- **The split, on the user's note that T3 runs Anthropic and Gemini models:** independent reviews and read-only
  sweeps go to Gemini (Antigravity, plan mode, repo files only); mechanical edits go to a cheaper Claude model; this
  session keeps the decisions, the checks and the landing.
