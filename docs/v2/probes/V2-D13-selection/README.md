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
