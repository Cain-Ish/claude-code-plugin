# Second opinion: Gemini Pro on the charter and the process (2026-10-19)

**Method.** Gemini Pro (gemini.google.com, Pro model) received `00-charter.md` (without the quoted original request)
and `01-process.md` as pasted text, with this instruction: attack them for over-engineering, failure and stall
modes, gaps, and the product framing; at most 12 ranked points, each as claim / why / concrete change; no praise. A
first attempt by URL failed (Gemini cannot open GitHub URLs) and a second attempt reset without an answer; the third
returned 10 points. Rule 10 of the process applies: the answer is evidence to weigh, not a vote.

## Points and verdicts

| # | Gemini's claim (paraphrased) | Verdict | Reason |
|---|---|---|---|
| 1 | A bespoke "project map" fights the host; make the plugin a background worker that curates native `.claude/rules` and docs from terminal activity | Split. Native files: already the leading hypothesis (V2-D11/D12, to be probed). Background auto-curation: **rejected** | Unreviewed automatic extraction is v1 root cause 5 (it became a persistent prompt injection) |
| 2 | Prove what the plugin API can inject before any architecture | Already the frontier: probe P1 (V2-D12) | — |
| 3 | "Zero stale claims" is magic without a deterministic code-to-claim mapping | Accepted as wording: the charter now names the mechanism (V2-D16, deterministic anchors) | The mechanism was already in the D16 draft |
| 4 | The 11-field ledger is bureaucracy; use ADR files (Context, Options, Decision, Rationale) | Partly. Records are now "a few bullets"; ADR-per-file **rejected** | One ledger file is one read for an agent; fifteen ADR files are fifteen |
| 5 | Delete the three-strike rule; trust people to pivot | **Rejected** | The user asked for it explicitly; it is one counter, not bookkeeping |
| 6 | Ledger plus one issue per decision is a split source of truth; decide in PRs instead | **Accepted.** No child issues by default; the map issue keeps steps, decisions, fog | One home per fact (rule 7) |
| 7 | Thresholds set before a baseline are guesses | **Accepted.** Baseline arms run first; thresholds are improvements over measured numbers (V2-D17, charter) | Also matches v1's lesson: a harness counts only once it has run |
| 8 | Step-gate notes in an issue are micromanagement; rely on commits and PRs | Form **accepted**, gate kept: it moves into each step's commit body | The user asked for a doubt check per step; commit bodies are already where history lives |
| 9 | An eval harness before any UX tests vaporware; build the walking skeleton first | Partly. Baselines need no v2 code, so they run first; the skeleton comes next and is measured by the same harness | Reconciles the point with v1's never-run harness |
| 10 | "A guarantee names its check" cannot apply to concepts | **Accepted.** In the concept phase every claim cites a source or a probe | — |

## What it did not raise

Token budget per channel, security of an in-repo map that any contributor can edit, team versus solo use, and the
measured v1 evidence (it was not given the post-mortem). These remain with V2-D11, D13, D14 and D17.
