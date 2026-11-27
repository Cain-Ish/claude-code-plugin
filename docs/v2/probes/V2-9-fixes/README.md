# V2-9: 2.6.1, the audit's fixes

See `docs/v2/06-first-slice.md`, section 9. The cases are `plugin/test/fix261.mjs` (one per AU item, run against the
plugin folder given; the self-test runs it).

- `mutate261.mjs <plugin folder> <work folder>`: each mutation of a guard 2.6.1 adds must fail its case. `MUT_FAST=1`
  runs only the case named with the mutation (`FIX261_ONLY`); `MUT_ONLY=<regex>` is a dry run. The case that counts
  git's calls at session start stands in for git with a script on PATH, so its mutation does not run on Windows.
- `bench7.mjs <plugin folder> ...`: AU-7's check, the Bash hook on a command that names 8 topic files with entries,
  against an empty Node, 30 paired runs at 1 session.
- `results/`: the mutation run on Windows; `bench7-win32.txt`; `pairbench-reference.json`, D18's bench
  (`probes/V2-D30-entries/pairbench.mjs`, 200 calls per kind at 1 and 8 concurrent, 2.6.0 as the control) on the
  fixture of `plugin/test/fixture.mjs`, `benchmap.mjs` and `probes/V2-D30-entries/benchprep.mjs`.
