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

## Volume check (2026-10-22): does a bigger push cost following?

Input to the user's budget decision; the check and result are in [`DECISIONS.md`](../../DECISIONS.md) under V2-D22,
"Volume check". The harness is D20's ([`native.mjs`](../V2-D20-adherence/native.mjs), arms `v8` and `v32`, which
deliver the binding cards plus a word-matching selector's false positives at the first prompt, in several hook outputs
under the 10,000-character cap). Counts, with every two-turn arm:
[`../V2-D20-adherence/results/summary-stage3.json`](../V2-D20-adherence/results/summary-stage3.json).

| | P1 build | P2 build |
| --- | --- | --- |
| Delivered | 32.7 KB (6 binding cards among 79 others) | 32.5 KB (8 among 107) |
| Rules lost against the 2 KB baseline | none | none |
| Median USD, baseline then 32 KB | 1.01 then 1.28 | 3.63 then 3.05 |
| Median tokens, baseline then 32 KB (all turns and subagents; corrected 2026-10-22) | 1.24M then 1.41M | 7.1M then 5.0M |

The filler was checked before any run. In P2 it held 10 stale entries contradicting a binding rule and 13 restating
one; all were removed, so contradiction in the delivered set is untested.

## Pull check (2026-10-22): does an always-on index of the repo's documents reach the rules?

Rethink 2's first option for D22. The check and result are in [`DECISIONS.md`](../../DECISIONS.md) under V2-D22,
"Pull check". The harness is D20's ([`native.mjs`](../V2-D20-adherence/native.mjs)), with three arms:
- `n0`: native;
- `p`: plus a document index from session start (built by D21's
  [`inventory.mjs`](../V2-D21-inventory/inventory.mjs) and delivered by
  [`inventory-hook.mjs`](../V2-D21-inventory/inventory-hook.mjs));
- `pf`: `p` plus a fixed forced-decision text at the first prompt.

Counts are in [`../V2-D20-adherence/results/summary-stage3.json`](../V2-D20-adherence/results/summary-stage3.json).

| Rules native misses, followed of 5 | `n0` | `p` | `pf` | `o0` (push) |
| --- | --- | --- | --- | --- |
| P1 R6 | 0 | 1 | 5, source read first in 5 | 5 |
| P2 R5 | 1 | 3 | 2 (3 sessions stopped) | 4 (1 stopped) |
| P2 R7 | 1 | 4, read first in 2 of the 4 | 2 (3 stopped) | 4 (1 stopped) |

In P2, the stopped `pf` sessions asked about a canon fact. P2's rules require checking that kind of fact against an
outside source, and the harness turns the web off.
