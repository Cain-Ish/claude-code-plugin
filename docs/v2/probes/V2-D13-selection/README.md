# V2-D13 probe: selection over a blind map

Question ([DECISIONS.md, V2-D13](../../DECISIONS.md#v2-d13--shape-of-the-project-map)): without a hand-made list,
do the entries that bind a task reach Claude, within a byte budget? D20 stage 2 delivered 27 hand-picked rules and
Claude followed them. Here a script picks them.

- `map` builds each test-bed repo's map from its own doc files at D20's pinned commits. It reads only the repos and
  commits of the private config, never the tasks or the cards, so nothing in the map is fitted to the tasks. Each
  block of a doc file becomes an entry with its source (path and heading path) and its file's `paths:` scope, if
  any.
- `score` ranks each task's prompt against the map (BM25, no model) and counts the D20 cards that the entries
  delivered under each byte cap hold (80% of a card's word trigrams).

The check, the pass condition and the planned attempts were registered in `DECISIONS.md` before this script
existed. The maps, the delivered entries and the task text stay in the private `research/raw/d13/`; this folder
holds only the script and counts (`results/summary.json`).

```
node select.mjs selftest
node select.mjs map   <config>
node select.mjs score <config> <cards>
```

Shortcuts, by design: no stemming beyond a trailing `s`; a line longer than 1,200 bytes stays one entry; a reference
counts only when it names a doc file by path (not a folder).

## Attempt 1 (2026-10-21)

Config hash and card hash are in `results/summary.json`. All docs, cards held at each cap:

| Task | Cards | 2 KB | 4 KB | 8 KB (pass cap) | 16 KB | 32 KB | Whole corpus, 80% bar |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P1 build | 6 | 0 | 1 | 2 | 2 | 2 | 5 |
| P2 build | 8 | 0 | 0 | 0 | 0 | 1 | 3 |
| R0 build | 8 | 0 | 0 | 1 | 1 | 1 | 8 |
| P2 plan | 5 | 0 | 0 | 3 | 3 | 4 | 5 |
| **All** | **27** | **0** | **1** | **6 (0.22)** | **6** | **8** | **21** |

Native (D20 stage 1, the rule in context before the first write): 0.60 of rule-runs. **Fail.** The pointed corpus
gives the same picture (6 at 8 KB).

- The whole corpus holds 21 cards at the 80% bar. Five P2 cards stitch a heading to its body, so their trigrams
  across the seam are in no single entry, and P1 R1 is in a config file. At a 60% bar the corpus holds 26 and the
  ranker still 6 at 8 KB, so the miss is in the ranking.
- In ranked order, the first entry that holds a card lies beyond 60 KB, or scores 0, for 13 of those 21 cards.
- Sections (h1, h2) that hold a task's cards: 14 to 32 KB per task; whole files: 14 to 186 KB. A selector coarser
  than one block cannot fit the 10,000-character `additionalContext` limit with the sources' own blocks as entries.
- Index build 100 to 300 ms, query 2 to 7 ms per prompt, in Node on Windows.

## Attempt 2 (2026-10-21)

`convert.mjs` sent each doc file's blocks, numbered, to a fresh Sonnet 5.5 call (no tools, no settings), which
returned the file's rules as entries: a trimmed verbatim quote, the blocks it came from, an area and applies-when
terms. It never saw the tasks or the cards. The ranker is attempt 1's, over area, applies-when, quote and source;
held is judged on the blocks the delivered entries cite. Counts in `results/summary-attempt2.json`.

| Repo | Calls | Entries | Compact entries | Cost |
| --- | --- | --- | --- | --- |
| P1 | 87 | 1,834 | 531 KB | 6.23 USD |
| P2 | 201 | 2,756 | 765 KB | 10.51 USD |
| R0 | 133 | 1,777 | 525 KB | 5.61 USD |

| Task | Cards | 2 KB | 4 KB | 8 KB (pass cap) | 16 KB | 32 KB | Source converted (80% bar) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P1 build | 6 | 2 | 2 | 3 | 4 | 5 | 5 |
| P2 build | 8 | 0 | 0 | 0 | 0 | 0 | 1 |
| R0 build | 8 | 0 | 0 | 0 | 1 | 1 | 4 |
| P2 plan | 5 | 0 | 0 | 3 | 3 | 4 | 5 |
| **All** | **27** | **2** | **2** | **6 (0.22)** | **8** | **10** | **15** |

**Fail.** Of the 21 cards the corpus holds, the converter cited the source of 15. For P1 and the plan the best entry
citing each converted card ranks within about 9 KB; for R0 and P2 build at 5 to 125 KB, among hundreds of entries on
the same topics. Five P2 build cards stitch a heading to its body and cannot reach the 80% bar against any corpus, so
that task could not pass under any selector; this is fixed before any further attempt and changes neither result.

## After attempt 2: corrected held rule, ceiling, R0 by hand (2026-10-21)

The registered scores stand. Corrected rule (`corrected.mjs`, `results/held-corrected.json`): a card is holdable when
the whole corpus covers at least half of its trigrams, and held when the delivered blocks cover at least 0.8 times
that. 26 of 27 cards are holdable (not P1 R1, which is in a config file).

| Task | Attempt 1 at 8 KB | Attempt 2 at 8 KB | Attempt 2 ceiling (every cited block) | Pass needs |
| --- | --- | --- | --- | --- |
| P1 build | 2 | 3 | 5 | 5 |
| P2 build | 0 | 1 | 6 | 7 |
| R0 build | 1 | 0 | 5 | 7 |
| P2 plan | 3 | 3 | 5 | 4 |
| **All** | **6** | **7 (0.26)** | **21** | |

On attempt 2's entries no selector can pass: both build tasks have a ceiling below 7 of 8. A third attempt would mean
converting again with a prompt changed after seeing which rules it missed (fitting), so D13 locks the entry's shape
and selection moves to V2-D22, behind D15.

By hand (R0 is public): of the 26 entries attempt 2 delivered at 8 KB for the R0 task, 5 bind it (where hooks are
registered, the hook script conventions, line-oriented `jq`, the timing wrapper, the `_comment` convention) and 21
are on the same topics without binding it. The task does not need more than 8 KB; the selector does not separate
rules inside the repo's own topic.
