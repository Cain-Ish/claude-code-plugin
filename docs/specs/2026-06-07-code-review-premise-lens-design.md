# Code-review runtime-premise lens + bug-fix verify-step — design

- **Date:** 2026-06-07
- **Status:** approved (brainstorm), pre-plan
- **Skill touched:** `skills/code-review-deep/SKILL.md` + a new reviewer agent
- **Provenance:** post-mortem of the 0.24.29→0.24.30 active-slug fix, which shipped a
  *wrong fix* (`CLAUDE_PROJECT_DIR > pin > cwd`) through a clean `code-review-deep` run.

## Context — the bug class our review is blind to

0.24.29 was reviewed by all three `code-review-deep` lenses (unit, architectural,
history) and merged — yet it did not fix the reported bug, because it rested on a
**false belief about the runtime environment**: *"`CLAUDE_PROJECT_DIR` is reliably
set per session."* It is not (inconsistently present across MCP-server spawns), so
where it was absent the stale pin still won and the concurrent-session hijack
persisted.

Why all three lenses missed it: they are **diff-static** — they read the diff, git
history, and the *stated* design. The bug lived in none of those surfaces; it lived
in the **environment**. No lens looks at the running system, and the skill explicitly
forbids it ("Do not build, typecheck, or run the app — CI handles that"). Worse, the
tests, the code comments, the PR description, and the reviewer dispatch prompts all
originated from the one wrong premise — so the review was a **closed loop over the
author's model**, and three lenses agreeing was one blind measurement repeated thrice.

**Architectural constraint (from the user):** knowledge (the wiki) is *not*
cross-plugin — it is per-install. So the durable fix must live in the **shipped skill
+ agents** (they travel to every install and run unconditionally = enforcement); the
wiki is **support only** (informs when present, can never gate).

## Goal

Catch the *wrong-runtime-premise* bug class structurally, in the shipped
skill+agents, without giving any PR-influenced agent execution rights.

**Non-goals:** a general "run the test suite in review" gate (CI owns that); catching
premise bugs in non-bug-fix changes via execution (the static lens still flags them,
but the run-verify step is bug-fix-only); cross-plugin knowledge propagation (out of
scope by the constraint above).

## Architecture

Two composing mechanisms — the lens *names* a premise, the verify-step *probes* it:

```
Pass 0   classify change-intent → is_bugfix?  (Haiku)
         load ~/.second-brain/review-fragile-premises.md  (support, may be empty)
Pass 2d  NEW agent code-review-premise-reviewer  (read-only, whole-change, wave-1 slot)
         enumerate every load-bearing runtime premise in the diff
         → flag each unproven one  → findings (category: premise) → Pass 3 scoring
Pass 3.5 NEW orchestrator phase  (gated: is_bugfix AND ≥1 flagged premise AND user-confirm)
         per flagged premise: run its proof_probe in the REAL env → holds | BROKEN
         BROKEN → elevate to confirmed critical
         + failure-regime test check (does a test exercise the premise's false case?)
Pass 4   premise findings in numbered/low-conf lists
         + "Runtime-premise verification" subsection (probe results)
         + optional append of a confirmed break to review-fragile-premises.md (user-confirmed)
```

Trust boundary: the **agent is read-only** (no exec over PR content). The only thing
that runs code is **Pass 3.5 in the orchestrator** — the trusted main session, with
explicit user confirmation — the single narrow carve-out from the "don't run the app"
rule.

## Component 1 — the `code-review-premise-reviewer` agent

New file `agents/code-review-premise-reviewer.md`, modeled on
`code-review-history-reviewer.md`.

**Frontmatter:**
- `name: code-review-premise-reviewer`
- `description:` reviews a change for unproven RUNTIME PREMISES — load-bearing
  assumptions about the environment that the diff depends on but does not establish;
  the bug class diff-static review misses. Dispatched once over the changed code files
  by `code-review-deep` (Pass 2d).
- `effort: high`
- `color: yellow` (distinct from the other reviewers)
- `tools: Read, Bash(git diff *), Bash(git log *), Bash(grep *)` — **read-only**. No
  unscoped `Bash`; the read-only constraint is a hard test assertion (exec-over-PR-
  content is the trust risk this whole design avoids).

**Task input** (passed by the skill): unit file union, base ref (`origin/<base>`),
change summary, project conventions (CLAUDE.md + wiki), prior-review note, and the
`review-fragile-premises.md` contents.

**Mandate — the premise taxonomy.** Build the list of every **external precondition**
the changed code depends on but does not itself establish:

1. **Environment variables** — `process.env.X` / `${X:-}` / `$X`: does the code assume
   X is *set / non-empty*? Is that proven, or assumed?
2. **Filesystem** — a path exists / is readable / writable / a symlink resolves.
3. **Process & runtime state** — cwd is the project root; consistency/ordering across
   *separate process spawns*; singletons; one-writer assumptions.
4. **Cross-process shared state another actor can mutate** — global files, pins,
   lockless shared markers (*this is the active-slug pin*).
5. **External services / network reachability.**
6. **Platform** — GNU vs BSD coreutils, bash version, OS.

For each premise: classify **established** (set / checked / defaulted within the
change) vs **assumed**. For each load-bearing *assumed* premise (a wrong value changes
behavior), emit a finding. **Special hunt — the asymmetric trap that caused our bug:**
*"the code has a fallback for when X is unset, but the fallback's own correctness rests
on a different unproven premise"* (fallback-to-pin, pin is racy). Consult
`review-fragile-premises.md`: a flagged premise matching a known-fragile entry for this
repo raises severity.

**Output** (structured findings, category `premise` — no file bodies):
- `file`, `lines`
- `premise` — the assumption in one sentence
- `reliance` — where/how the code depends on it
- `breaks_if_false` — what misbehaves at runtime if the premise is false
- `proof_probe` — concretely how Pass 3.5 would test it in the real env
- `severity` — critical | high | medium | low
- `established` — bool (false = flagged)

"No unproven load-bearing premises found." when clean.

## Component 2 — skill wiring (`skills/code-review-deep/SKILL.md`)

**Pass 0 additions:**
- *Change-intent classification* (Haiku step): from PR title/body or
  `git log origin/<base>..HEAD`, set `is_bugfix` = does the change *claim to fix a
  reported runtime behavior* (vs feature/refactor/docs/test-only)? Record it.
- *Load fragile-premises note*: `Read ~/.second-brain/review-fragile-premises.md` if
  present (else empty); hold for Pass 2d. (Add to `allowed-tools` nothing new — Read
  already permitted.)

**Pass 2d — Runtime-premise pass (scored, parallel).** If ≥1 non-skipped *code* unit
(`docs_only:false`), dispatch exactly one
`Agent(subagent_type:"second-brain:code-review-premise-reviewer")` over the deduped
union of non-skipped code files. It occupies **one wave-1 slot** alongside 2b/2c. Pass
it the base ref, change summary, conventions, prior-review note, and the
fragile-premises note. Its findings (category `premise`) flow into Pass 3 dedup +
scoring exactly like 2c's `regression` findings. Skip if every unit is docs-only.

**Wave-cap accounting — replace the existing note.** 2b (arch) + 2c (history) + 2d
(premise) each take a wave-1 slot. Invariant: wave 1 = unit-reviewers + {2b?,2c?,2d?}
≤ 5 concurrent. Combinations (each skipped pass returns its slot to unit-reviewers):

| 2b | 2c | 2d | unit-reviewers in wave 1 |
|----|----|----|--------------------------|
| ✓  | ✓  | ✓  | ≤2 |
| ✓  | ✓  | –  | ≤3 |
| any two | | | ≤3 |
| any one | | | ≤4 |
| –  | –  | –  | ≤5 |

**Pass 3 — scoring guidance for `premise` findings.** The scorer treats a `premise`
finding as HIGH when the premise is load-bearing AND unproven AND (if Pass 3.5 ran)
shown BROKEN; LOW when Pass 3.5 confirmed it holds, or it is defended/established. A
premise finding Pass 3.5 marked BROKEN is force-promoted to confirmed (≥70) regardless
of the scorer.

**Pass 3.5 — Bug-fix real-env verification (orchestrator, gated).** Runs ONLY when
`is_bugfix` AND Pass 2d flagged ≥1 load-bearing premise.
1. **Confirm with the user** — print exactly what it will run (it executes code). On
   decline: skip, mark the premise findings "unverified (user declined)", continue to
   Pass 4. (Never blocks the review.)
2. **Probe each flagged premise** via its `proof_probe`, exercising the changed code
   path in the **real env** (the actual environment state — *not* a sandbox that sets
   convenient values). Record `holds` / `BROKEN`. A BROKEN premise → elevate its
   finding to confirmed critical ("fix does not hold in the real runtime").
3. **Failure-regime test check** — confirm the change adds/modifies a test exercising
   the premise's *false* regime (e.g. the var UNSET). Missing → a `test-gap` finding
   ("no test covers the regime where the bug occurs").

Pass 3.5 is orchestrator-run (trusted session), **never** a sandboxed PR-influenced
agent. It is best-effort: any probe error is reported, never fails the review.

**Pass 4 — output.** `premise` findings appear in the numbered (≥70) or
lower-confidence (16–69) lists like any scored finding. When Pass 3.5 ran, append a
**"Runtime-premise verification"** subsection: each probed premise with holds/BROKEN +
the one-line real-env evidence. A confirmed BROKEN premise may be appended to
`review-fragile-premises.md` (user-confirmed, same write-back discipline as the FP
store).

**Notes — amend the "don't run the app" line** to carve out Pass 3.5: a narrow,
orchestrator-run, user-confirmed, bug-fix-only premise probe — explicitly NOT a general
build/typecheck/test run (CI still owns those).

## Component 3 — knowledge as support

New optional `~/.second-brain/review-fragile-premises.md` (sibling of
`review-false-positives.md`, created lazily on first write). Header + per-entry format:

```
# Review fragile-premise patterns
<!-- Read by code-review-premise-reviewer to raise severity on known-fragile runtime premises. Append-only. -->

## <short premise title>
- repo: <owner/repo>
- premise: <the assumption that proved fragile>
- why fragile: <one-line: how it fails in the real runtime>
- source: pass-3.5-confirmed | user
- date: <YYYY-MM-DD>
```

Read in Pass 0, passed to the premise agent, grows only from a Pass 3.5 confirmed break
(user-confirmed append). The agent prompt is the **enforcer** (always enumerates the
full taxonomy); the note only **raises severity** on repo-specific known-fragile
premises — it ships nothing cross-plugin and can never gate. This realizes the
"knowledge as support" constraint exactly.

## Error handling / degradation

- Pass 2d follows the skill's existing degradation path: if parallel dispatch is
  unavailable, the single-context fallback review enumerates premises inline (the lens
  reasoning still applies; only the fan-out is lost).
- Pass 3.5 is fully optional and best-effort: missing `is_bugfix`, no flagged premise,
  user decline, or a probe error each cleanly skip it with a one-line note. It never
  fails or blocks the review.
- A missing/empty `review-fragile-premises.md` is the normal case (treated as empty).

## Testing (static guards — no LLM in CI, mirroring `test-agent-allowed-tools.sh`)

- `tests/test-code-review-premise-agent.sh`: the agent file exists; its `tools:` are
  **read-only** (no `Bash` beyond `git diff/log` + `grep` — a hard assertion); its body
  contains the 6-premise taxonomy headings and the `proof_probe` + `established` output
  fields.
- Extend `tests/test-agent-allowed-tools.sh` to cover the new agent's grants.
- `tests/test-code-review-deep-premise-wiring.sh`: `SKILL.md` contains Pass 2d, Pass
  3.5, the `is_bugfix` classification, the amended wave-cap table, the carve-out note,
  and a read of `review-fragile-premises.md`.

## Release

- Version bump `plugin.json` + `.claude-plugin/marketplace.json` in lockstep. **No MCP
  change** → `mcp/src/server.ts` stays `2.6.7`.
- Additive migration row in `skills/upgrade/SKILL.md` (no precondition — the agent +
  skill ship; the wiki note is lazy; behavior is purely additive to the review skill).
- **Dogfood gate:** run the *improved* `code-review-deep` on this very change — the new
  premise reviewer reviews its own introduction — before merge.

## Out of scope (documented for later)

- Running the full project test suite at review time (CI owns it).
- Execution-based verification for non-bug-fix changes (static lens only there).
- Auto-deriving `proof_probe` execution for premises with no clean real-env probe (the
  lens still flags; Pass 3.5 reports "no probe available" and falls back to the
  failure-regime test check).
- A premise-reviewer that *reproduces arbitrary symptoms* from a free-text repro recipe
  (rejected in brainstorm — needs author discipline + arbitrary exec).
