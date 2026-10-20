# Research: what "a complex project" means in numbers, and what v1 held for it

Question: A1 ran on a 16-file fixture. The user's real projects are large, their documentation holds the important
rules and criteria, and v1 failed on them (and on its own repo). How large are they, how much does the native
setup load for one task, and how much of their knowledge did v1's store hold? It feeds a new scale decision
(V2-D19) and the draft checks of V2-D13, D15 and D18.

Sources, all read on 2026-10-20 and read only:
- **P1:** a private TypeScript monorepo (a web app with a scoring engine), at its HEAD, read locally.
- **P2:** a private C# game server and client whose design follows a fictional-universe canon, at its HEAD, read
  through the GitHub API (file tree and sizes; its rule documents were downloaded to count headings and items).
- **v1's store:** the local `~/knowledge` wiki that v1 wrote (frontmatter `project:` fields, entry counts, sizes).
- **v1-final:** this repository at tag `v1-final`.

Both repos are private and this repository is public, so this note holds aggregate numbers and generic shape only:
no names, paths, rule text or entry text from them. Tokens are estimated as bytes / 4.

## 1. P1: what one task loads

- 801 tracked files, 560 TypeScript source files. About 4.1 MB of TS/TSX source.
- **Always on:** the root instruction file is 29.5 KB (115 lines), about 7,400 tokens in every session.
- **Path rules:** 29 rule files, 578 KB in all (5 to 71 KB each; 818 list items), every one scoped with `paths:`.
  One 34.5 KB rule matches every file under the packages folder.
- **Cost of touching one file** (rule bytes whose globs match it, loaded at first touch, once per session): median
  34.5 KB, p90 82 KB, max 156 KB over the 560 source files; 111 files pull three or more rules.
- **One plausible task** touching five files (a UI panel and the engine code behind it) pulls 8 rules, 265 KB, about
  66,000 tokens, on top of the 29.5 KB always on, before any source file is counted.
- 1.15 MB of research notes (33 files) are not loaded; Claude reaches them by search when it needs them.

The native mechanism works as documented (V2-D12: a path rule arrives with the first read or write of a matching
file), but it is whole-file and the globs overlap, so a task receives every rule of every area it touches, all of
each file, whether or not one paragraph applies.

## 2. P2: canon-led, with knowledge mostly in documents

- 8,057 files; 7,415 C# files, 6,740 of them server scripts (the game's items, creatures, skills and so on).
- **Always on:** the root instruction file is 9.9 KB; 15 of its lines point into the documentation folder.
- **Documentation folder:** 127 Markdown files, 1.9 MB: vision 905 KB (75 files), plans 460 KB, systems 345 KB,
  rules 152 KB (13 files, 397 headings, 599 list items), and an 18 KB pointer index written by hand.
- **Tooling:** 12 commands, 4 skills, 5 validator hooks that check canon and historical accuracy.
- Nothing is path-scoped: the documents are read on demand, and "what already exists" among 6,740 scripts can only
  be found by search. The canon is the project's leading knowledge area (the kind D10 names).

## 3. What v1's store held for them

| | P1 | P2 |
| --- | --- | --- |
| Decisions | 1 file of 264 KB: an archive "rotated out of the hot tier", 683 lines over six weeks: 114 tagged as decisions, 171 tagged auto-captured (mostly session-change records), 386 untagged | 2 (one helper's design and its plan) |
| Learnings | 62 | 1 |
| Concepts / entities / issues | 28 / 30 / 220 | 6 / 19 / 0 |
| The repo's own rule documents, for scale | 29 files, 818 list items | 13 files, 599 list items, plus 1.75 MB of vision, plan and system documents |

- In P2, v1 held 3 decision and learning entries against about 600 rule items and 1.75 MB of design documents in
  the repo. That fits the user's account (2026-10-20) that v1 kept only a small part of the important decisions.
- In P1, v1 held many lines, but a quarter were automatic session records, and the decisions sat in an archive that
  was rotated out of what sessions load. The rules that mattered were written into the repo's own rule files.
- Not measured here: how many of the repos' important decisions v1 held in substance. That needs an entry-by-entry
  match, which would quote private text.

## 4. What fills the context

1. **Whole-file rules with overlapping scopes** (P1): 265 KB for a five-file task.
2. **Documents too large to load** (P1's research, P2's 1.9 MB): Claude searches and reads them in pieces, which
   costs tool calls and tokens, or it misses the rule.
3. **No inventory of what exists** (P2's 6,740 scripts): found only by search, or re-created.
4. **Compaction:** native root files are re-read after compaction, but path-scoped rules come back only when a
   matching file is read again (D12's compaction note), and hook text is only summarised (prior research A8).

## For v2

Hypotheses, each with the check that would test it. None is a decision; they go to D13, D15, D18 and D19.

- **Rules and criteria as small cards:** one rule each, with an id, what it binds (paths, topics, entities), its
  source anchor (document and heading) and its area, delivered by relevance within a byte budget. Check: delivered
  bytes per task against the repo's own native setup, with no planted rule missed.
- **Concept and vision documents stay whole, indexed by pointer and read by section** (the two cadences of prior
  research Q3: implementation context tiny and always loaded, planning context consulted in bursts). Check:
  navigation tasks reach the right section.
- **An inventory generated from the code**, compact and grouped by area, queried rather than loaded (prior research
  rule "structure computed on demand"; the Vercel index was pipe-delimited paths, 8 KB). Check: no duplicate created,
  fewer search calls.
- **Delivery at the right moment:** routing at the prompt, before the first Write (D12); briefs for subagents
  through `SubagentStart` (3 of 3 in every subagent type); the task's cards again after compaction through
  `SessionStart` with the `compact` matcher (3 of 3). Check: D18's latency budget and arrival.
- **The baseline at scale is the repo as it is run today** (its instruction file, rules, hooks and skills), with
  and without auto memory, not an empty repo.

## Limits

- List items and headings are proxies for "rules"; one item can hold several rules or none.
- The five-file task is one plausible example chosen by its files, not a measured session.
- "Loaded once per session" follows D12's observations, not a documented guarantee.
