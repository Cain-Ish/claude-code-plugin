# V2-D15 probe: onboarding, the blind converter's output under review

Question ([DECISIONS.md, V2-D15](../../DECISIONS.md#v2-d15--onboarding-bootstrap)): is the converter that D13 ran
blind on the three test-bed repos ([../V2-D13-selection/convert.mjs](../V2-D13-selection/convert.mjs), unchanged)
faithful, binding and complete enough to build on?

`onboard.mjs` runs the six parts of the pre-registered check:

1. `fidelity`: every entry's quote against the blocks it cites, with no model involved.
2. `sample`: seeded sections, written out as two Gemini pastes per repo. Pass A asks for the rules only; pass B
   adds the entries.
3. and 4. are the two Gemini passes, done by hand in the browser. The answers are saved next to the private config,
   and `score` counts them.
5. `plant`: eight planted rules per document, each as its own block, converted again.
6. `pm4`: R0's entries rendered as Markdown, one plain text edit, parsed back.

`a1` converts the A1 fixture's two docs for the review.

Entries, sections, pastes, Gemini's answers and the planted text stay in the private `research/raw/d15/`. This
folder holds only the script and counts (`results/`).

```
node onboard.mjs selftest
node onboard.mjs fidelity|a1|sample|pm4|score <config>
node onboard.mjs plant <config> <planted>
```

## Results (2026-10-21): BLOCKED after three attempts

The pass condition, the attempts and the full tables are in [DECISIONS.md, V2-D15](../../DECISIONS.md). Counts per
attempt are in `results/` (`-a2` and `-a3` suffixes for attempts 2 and 3).

| Attempt | The change | Verbatim | Precision | Recall (P1 / P2 / R0) | Planted | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | D13's converter as is (inputs up to 40 KB) | 96.6-99.1% | 0.92-0.98 | 0.79 / 0.48 / 0.73 | 24 of 24 | fail: recall |
| 2 | inputs of one 4 KB section window | 98.5-99.7% | 0.81-0.97 | 0.86 / 0.96 / 0.73 | 24 of 24 | fail: R0 recall |
| 3 | plus the user's rule scope, one rule per item, one reviewer | 98.7-100% | 0.85-0.96 | 0.82 / 0.98 / 0.94 | 23 of 24 | fail: one planted rule |

The reviewer was Gemini Pro in attempts 1 and 2, except R0 in attempt 2 and every repo in attempt 3, which were
reviewed by a fresh Claude (Opus) subagent. The yield per KB falls with input size, inside rule files too. In attempt
3 a table row quoted without its header lost its meaning. The PM4 round trip (`results/pm4.json`) passed.
