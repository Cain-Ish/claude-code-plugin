# V2-D22 probe: selection over the full map

Question ([DECISIONS.md, V2-D22](../../DECISIONS.md#v2-d22--selection)): which entries of a repo's map reach Claude
for a task, within 8 KB, without a hand-made list?

The map is each test-bed repo converted in full by D15's locked converter (`../V2-D15-onboarding/onboard.mjs full
--a4`). `route.mjs` runs three prompt-time arms on the user's six tasks:
- (b) BM25 alone;
- (d1) BM25's top 300 entries, then a Sonnet pick;
- (d2) a Sonnet pick of sections, then a Sonnet pick of entries from them.

It then builds, for each task, a pool for a blind Opus judge. The pool is every arm's delivery, plus every entry of
the sections the judge named from the section index before it saw any arm. `score` compares the arms with the
judge's grades and with the native sessions' reads (the D20 harness).

Tasks, maps, deliveries, pools and grades stay in the private `research/raw/d22/`. This folder holds the script and
counts only (`results/summary.json`), with the tasks named by repo and number.

```
node route.mjs selftest
node route.mjs arms|index|native|score <tasks>
node route.mjs pool <tasks> <task-id>
```
