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
