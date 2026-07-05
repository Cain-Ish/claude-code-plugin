# Worked examples — the evidence bar applied

Companion to sb-research-methodology §1. Three episodes from this repo's history, retold as
methodology (what made the diagnosis/decision ACCEPTABLE), not as incident narrative — the
full symptom→root-cause→fix records live in sb-failure-archaeology. All citations verified
2026-07-05 against the working tree (uncommitted 0.33.31; HEAD `6fba312` = 0.33.30).

---

## Example 1 — jq CRLF poisoning: one mechanism, 121 call sites, one negative

**The observations on the table** (Windows / Git-Bash, culminating in 0.30.1):

1. The validator's version-drift loop built a nonsense path `…\r\.claude-plugin\plugin.json`
   (the user-visible "error from version 0.30").
2. Config reads misbehaved: `auto_improve: true` read back as `"true\r"` and silently fell
   through to the default.
3. String comparisons, shell arithmetic, and `grep '^x$'` patterns failed intermittently
   across unrelated scripts.
4. **The negative:** in line-oriented JSONL processing, the LAST record parsed fine while
   non-last records failed. Any candidate mechanism that couldn't produce this asymmetry was
   wrong.

**Candidate partial explanations that were NOT accepted:** "this one script mishandles CR"
(doesn't explain observations at other sites); "the input files have CRLF line endings"
(inputs were clean LF — that's the point). A per-site patch would have been a
partial-explanation fix: green at the patched site, broken at ~120 others.

**The accepted mechanism** (one sentence): the Windows Git-Bash jq build's stdout is
text-mode, so it emits CRLF in `-r` output *even when the input is clean LF* — every
`$(jq -r …)` capture, pipe-to-grep, and config read on Windows is `\r`-contaminated.
It explains all four observations, including the negative: text-mode conversion turns
`\n` into `\r\n`, so a final record not followed by a newline picks up no CR — last-record
passes, non-last fails.

**What the mechanism mandated** (CHANGELOG.md `## 0.30.1`, lines 739-766):

- Fix at the LEVERAGE point: `sb_config_get`/`sb_config_bool` strip `\r` — one fix makes
  every config knob CR-safe.
- Then sweep the class: **121** single-line `$(jq -r …)` captures across **29 scripts**
  CR-stripped. The count is itself evidence the mechanism, not a call site, was the cause.
- A DISCRIMINATING regression lock: `test-jq-crlf-windows.sh` reproduces Windows jq via a
  stub on Linux CI and runs the REAL validator/config-reader under it — the test encodes
  the mechanism, so it fails on any future reintroduction, on any OS.
- The deep-review pass on the same release then found 5 MCP handlers still falling back to
  an uncleaned `HOME` (silent phantom `…\r/.second-brain` writes) — Rule 3 catching the
  residue Rule 1 predicted must exist.

**Methodology takeaways:** (a) the negative observation is the mechanism's fingerprint —
hunt for it deliberately; (b) once the mechanism is one sentence, the fix scope is derivable
(leverage point + class sweep + class-shaped lock), not negotiable.

---

## Example 2 — the active-slug hijack: a partial-explanation fix shipped, and failed

**Round 1 (0.24.29):** observed live — a stale global pin (`~/.second-brain/.active-session-slug`,
rewritten by every SessionStart) let a concurrent session in another project hijack this
session's scoping (a `cainish` pin scoped a `claude-code-plugin` session). Fix shipped:
precedence `CLAUDE_PROJECT_DIR > pin > cwd`. Tests green.

**The fix did not work.** CHANGELOG.md `## 0.24.30` (line 1310) is the repo's canonical
post-mortem, verbatim highlights:

- "live diagnosis showed `CLAUDE_PROJECT_DIR` is **inconsistently present** across
  MCP-server spawns (some processes have it, some don't), so when it was absent the stale
  global pin still beat the correct per-process `cwd`".
- "**Root cause of the miss:** all tests ran in sandboxes that set `CLAUDE_PROJECT_DIR` or
  relied on the pin; no live query against the real env (where it's unset) ran before
  merge; and the doc-sources test regression was 'fixed' by reverting precedence to
  `pin > cwd` (**green tests over real-env correctness**)."

Two evidence-bar violations in one round: the mechanism didn't explain why the hijack could
still occur (the env var's absence was an observation nobody forced the hypothesis to
cover), and a red test — a *refutation* — was silenced by adjusting the code toward the
test instead of asking what the test knew.

**Round 2 (0.24.30, accepted):** mechanism restated to cover ALL observations — per-process
signals (`CLAUDE_PROJECT_DIR`, `cwd`) are trustworthy but not always present; the shared pin
is always present but not trustworthy. That mechanism *derives* the fix: precedence
`CLAUDE_PROJECT_DIR > cwd-if-known-project > pin > cwd` with the known-project gate (`cwd`
trusted only when it names a registered project), one shared resolver, and — decisively —
verified **live in the real env** (no `CLAUDE_PROJECT_DIR`, real stale pin, cwd = known
project → resolves correctly, NOT the pin).

**Round 3 (0.33.0) — the class-level payoff:** the same ambient-authority mechanism
resurfaced as the attribution incident ("a setup deep-scan in `claude-code-plugin` filed 88
docs into `witcherrpg`'s raw inbox" — `docs/specs/2026-06-18-project-scoping-model-design.md:6`).
The design doc opens with 3 agents' *verified findings* (file:line for each claim, :18-37)
before any design — capture destination now derives from the scanned resource, items carry
`origin:` provenance, mismatch fails loud.

**Methodology takeaways:** (a) a green suite is an observation your mechanism must explain,
not a verdict — "why were the tests green?" is a mandatory question; (b) when a fix and a
test disagree, the test might be the one holding the refutation (never "fix" the test to
match the code without a mechanism for why the test was wrong); (c) verification must
include the real environment whose shape caused the bug (house rule: test the branch with
the env UNSET — sb-validation-and-qa owns the pattern).

---

## Example 3 — the P7 graph-boost demote: the measured-negative template

The template for retiring a feature by measurement rather than by taste. Use this shape for
any "does mechanism X actually pay its way?" question.

1. **Standing suspicion with a citation** — GraphRAG-Bench (arXiv 2506.05690): graph RAG
   "frequently underperforms plain RAG" below ~100K docs except genuine multi-hop. Entered
   the spec as workstream P7 "justify-or-demote": instrument FIRST, decide on data.
2. **Outcome classes defined before running** — for each golden query, does the boost
   improve / degrade / leave unchanged the gold page's rank?
3. **Measured on OUR corpus** — the real wiki, 96 pages / 170 edges (not a benchmark):
   improved 6, **degraded 6**, unchanged 80 of 92 — a wash. Plus a structural argument
   sealing it: the boost "provably cannot improve recall (a zero-base page receives zero
   boost)". CHANGELOG.md:162-169 (0.33.22).
4. **Scoped retirement** — demote the *ranking* boost to opt-in (`SB_GRAPH_RANKING_BOOST=1`,
   default off); KEEP the graph mechanisms with independent justification
   (`knowledge_neighbors` blast-radius, bi-temporal `supersedes`). A negative result on one
   role is not a verdict on the whole subsystem.
5. **Machine lock on the negative result** —
   `mcp/src/tools/retrieval-guards.test.ts:114-139`: the boost is OFF by default and
   re-enables only via the flag; the test constructs a corpus where the boost would act and
   asserts it doesn't unless opted in. A cut without a lock regresses silently (the audit
   flagged exactly that gap for the P4b access-boost cut — regression lock still OPEN as of
   0.33.31).
6. **CHANGELOG entry equal in dignity to a feature** — states the numbers, the harm case
   (boost displaced a page's own exact title-match, rank 0→1), and what was deliberately
   kept.

Sibling instances of the same template: the FORGET frequency/recency cut (0.33.25 — with
the near-zero-blast-radius argument made *before* the change) and the P4b search
access-boost cut (0.33.30). Full ranking-corruption history: sb-failure-archaeology.

---

## Re-verification

```bash
grep -n "121" CHANGELOG.md | head -3                      # the 0.30.1 sweep count
sed -n '1308,1311p' CHANGELOG.md                          # 0.24.30 post-mortem verbatim
sed -n '1,10p' docs/specs/2026-06-18-project-scoping-model-design.md   # 88-doc trigger line
sed -n '160,174p' CHANGELOG.md                            # P7 measurement numbers
ls tests/test-jq-crlf-windows.sh                          # discriminating stub test exists
```
