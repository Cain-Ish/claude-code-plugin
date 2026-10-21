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
