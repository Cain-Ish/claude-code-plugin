# P2 — Grounded Learning → Active Guardrail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task is independently committable; respect the dependency order.

**Goal:** Close the P2 gap from the constitution+diet spec (§6 P2): a *learned* practice must resolve to **either** a `PROJECT.md` decision **or** a `persona-rules` guardrail that fires at **PreToolUse** — and every learned guardrail must carry a **citation to its transcript evidence**; **contradicted rules auto-retire** (reversibly, history-preserving). Today only the USER.md half of graduation exists; there is no signal→guardrail pipeline, no provenance field on a rule, and no contradiction/retire mechanism.

**Architecture:** Keep the shipped `persona-rules.default.json` **pristine** (defaults are the trust floor). Introduce a *separate* runtime learned-rule store `~/.second-brain/persona-rules.learned.json` that the existing `scripts/persona-tool-guard.sh` **merges on top of** the base file at hook time. Synthesis stays where graduation already runs autonomously — the Stop-hook path through `scripts/merge-persona-signals.sh` — extended so that a *structured, rule-shaped* high-confidence signal graduates to a **citation-carrying learned rule** instead of (or in addition to) a USER.md prose line; prose-only signals keep going to USER.md exactly as today. Retirement mirrors the proven bi-temporal pattern already in `scripts/merge-edges.sh` (append-only `valid_to`/`op` semantics, conflict log, last-record-wins fold): a contradicting new rule sets `valid_to` on the older rule (soft-retire, reversible) rather than deleting it. The loader filters to `valid_to == null` so retired rules stop firing but stay on disk for rollback.

**Tech Stack:** bash (POSIX-ish, git-bash/MSYS + BSD/macOS + Linux) + `jq` only — no `awk` (the codebase deliberately uses `jq` for all JSON work; mawk/BSD-awk divergence is a known footgun). LLM extraction contract lives in `scripts/extract-prompt.txt`. Tests are bash harness files under `tests/` (`test-*.sh`), run by `tests/run-all.sh`. No new runtime dependency; no native code.

This plan is spec workstream **P2** (`docs/superpowers/specs/2026-06-26-second-brain-constitution-and-diet-design.md` §6 P2, §4 autonomy resolution, §8 success criteria). It is **gated by P0** (the surface-budget ratchet + single-source resolution are already live and must stay green) and is independent of P1/P3/P6.

---

## Constitution compliance (hard constraints this plan is measured against)

- **Fully autonomous — zero required user interaction.** Synthesis runs inside the already-autonomous Stop-hook graduation step (`merge-persona-signals.sh`); no `/command`, no accept gate. Safety comes from *grounded* rules (every learned rule cites evidence), *conservative* action capping (learned rules emit `action:"ask"` only — never auto-`deny`/`rewrite` in P2), and *reversible* soft-retire — **not** a manual gate. (Spec §4.)
- **Cross-platform.** bash + `jq` only; cross-platform `date` via the existing `date -u -v-Nd 2>/dev/null || date -u -d "...ago"` fallback already in `merge-persona-signals.sh`; `mktemp -d` isolation in tests; no `awk`, no `perl`, no GNU-only flags. Verified by the portability + BSD/Linux CI gates.
- **Reversible auto-consolidation.** Retirement sets `valid_to` (append-in-place), never hard-deletes; a kill switch `SB_PERSONA_LEARNED=off` disables the entire learned layer while leaving defaults intact; nothing learned can ever weaken a shipped default (merge is additive — learned rules can only add `ask` friction, never remove a default rule).
- **Untrusted-content isolation.** Learned rules are synthesized from transcript-derived signals (untrusted). They are capped to `action:"ask"` (advisory friction, non-destructive, user sees the prompt), the evidence quote is already invisible-char-stripped at raw-inbox ingest (P6a), and the citation is stored as **data** (surfaced verbatim in the `permissionDecisionReason`, never executed). A learned rule cannot grant/allow anything the defaults didn't.

## Global Constraints

- **Version lockstep:** any shipped change bumps `version` in `.claude-plugin/plugin.json` AND the `second-brain` entry in `.claude-plugin/marketplace.json` AND adds a `CHANGELOG.md` entry — same commit. Current version: `0.33.29` → target `0.33.30`.
- **Surface-budget ratchet (`docs/surface-budget.json`, enforced by `scripts/validate-plugin.sh` R8):** the gate counts `scripts/*.sh` and `tests/test-*.sh` at `maxdepth 1`. `persona-rules.learned.json` is **runtime data in `$BRAIN_DIR`** (like `persona-signals.jsonl`) — it is NOT in the repo and does NOT count. This plan adds **no new script** (synthesis + retire fold into `merge-persona-signals.sh`; loader change is in-place in `persona-tool-guard.sh`) and adds **3 test files** → `tests` baseline `151 → 154` (bump in the same commit). If you choose the optional separate-script variant (see Task 3 note), also bump `scripts` `52 → 53`.
- **Fail-loud (project convention, MEMORY feedback):** route real failures through `sb_log_error`/`log_gate`; do not add new `2>/dev/null` silent-exit paths. The guard's fail-*soft* behavior (never block a tool call on its own bug) is the one deliberate exception and is preserved.
- **Backward compatibility is a test, not a hope:** default rules have no `citation`, no `valid_to`. The loader and the guard MUST treat both as valid/active. A green suite that never exercises the no-learned-file path is a silent failure (MEMORY feedback: test the fallback branch).

---

### Task 1: Provenance contract — `citation` on the rule schema + slug plumbing for transcript path

**Precondition / idempotent check:** `grep -q '"citation"' scripts/persona-rules.default.json` → expect NO match (defaults stay citation-free). `grep -q 'CLAUDE_PROJECT_SLUG\|--slug' scripts/merge-persona-signals.sh` → if already present, the plumbing step is done.

**Files:**
- Modify (doc/contract only): `scripts/extract-prompt.txt` (extend the `persona_signals[]` object with an OPTIONAL `rule` hint + keep `evidence` as-is).
- Modify: `scripts/stop-extract.sh` (pass the project `$SLUG` into `merge-persona-signals.sh` so the citation can build a transcript path) and `scripts/pre-compact.sh` (same call site — verify parity).
- Modify: `scripts/merge-persona-signals.sh` (accept `--slug`/`CLAUDE_PROJECT_SLUG`; record `slug` into each evidence entry so a transcript path is reconstructable later).
- No code change to `persona-rules.default.json` — citation is **optional**; this task only *defines* the shape and ensures the data needed to populate it is captured.

**The change — citation shape (the contract for Tasks 2–4):**
```jsonc
// a learned rule (in persona-rules.learned.json) extends the existing rule schema:
{
  "name": "learned-...",
  "tool": "Bash",                       // existing
  "match_command": "...",               // existing (or match_path)
  "action": "ask",                      // P2: capped to "ask"
  "reason": "...",                      // existing plain reason (kept for back-compat)
  "citation": {                         // NEW, optional. Absent on default rules.
    "session_id": "abc123",
    "transcript_path": "~/.second-brain/transcripts/abc123_<slug>_2026-06-30.txt",
    "line": null,                       // optional int or "start-end"; null = whole-session
    "date": "2026-06-30",
    "evidence_text": "user: \"never force-push main\""
  },
  "valid_from": "2026-06-30",           // NEW (Task 4 bi-temporal)
  "valid_to": null,                     // NEW; null = active
  "confidence": "high",                 // carried from the signal
  "source": "persona-signal-graduation" // provenance of the synthesis
}
```
- `transcript_path` is derivable from `session_id` + project `slug` + `date` via the shipped archive naming (`sb_archive_transcript` writes `$BRAIN_DIR/transcripts/${session_id}_${slug}_${date}.txt`). The slug is the missing datum today (`merge-persona-signals.sh` has `CLAUDE_SESSION_ID` but not the slug), hence the plumbing.
- **Extractor `rule` hint (optional)** added to `extract-prompt.txt` `persona_signals[]`:
  ```jsonc
  "rule": {                 // OPTIONAL — emit ONLY for an enforceable tool-level constraint
    "tool": "Bash",         // the tool the constraint applies to
    "match_command": "...", // OR "match_path"; a conservative regex
    "reason": "why, in one line"
  }
  ```
  Prompt guidance to add: "Emit `rule` ONLY when the user expressed a hard, tool-specific constraint that a PreToolUse check could enforce (e.g. 'never run X', 'always confirm before Y on path Z'). Style/verbosity/approach preferences must NOT carry a `rule` — they belong in USER.md. When unsure, omit `rule`." This is the *rule-worthy vs USER.md-worthy* discriminator: **structured rule-hint present ⇒ guardrail candidate; absent ⇒ USER.md prose (unchanged behavior).**

**TEST to add (in this task's commit, folded into the Task 3 test file or a focused unit):**
- Assert `extract-prompt.txt` still parses as a coherent prompt (the file is plain text; assert the new keys are documented: `grep -q '"rule"' scripts/extract-prompt.txt`).
- Assert `merge-persona-signals.sh` invoked with `--slug demo` records `slug` into a new signal's evidence entry: feed one signal, then `jq -e '.evidence[0].slug == "demo"'` over the written JSONL line.

**Risks:**
- **Slug source ambiguity.** `merge-persona-signals.sh` runs from the Stop hook where `$SLUG` is known, and from `pre-compact.sh`. If a call site forgets to pass slug, fall back to `CLAUDE_PROJECT_SLUG` then to empty (transcript_path becomes a session-only pointer — degraded but valid; do NOT fail). Cover the empty-slug fallback in the test.
- **Prompt drift.** The `rule` hint is advisory to the LLM; a poorly-shaped hint is caught by Task 3 validation (reject hints that don't form a valid `{tool, match_command|match_path}`), so a bad hint degrades to "no rule" (→ USER.md), never to a malformed rule.

**Effort:** ~0.5 day.

---

### Task 2: Learned-rule store + loader merge in `persona-tool-guard.sh` (+ citation surfacing, kill switch)

**Precondition / idempotent check:** `grep -q 'persona-rules.learned.json' scripts/persona-tool-guard.sh` → if present, loader merge already wired. The guard today (lines 33–41) picks **exactly one** rules file: `$BRAIN_DIR/persona-rules.json` if it exists, **else** `$PLUGIN_ROOT/scripts/persona-rules.default.json`. It is an either/or selection, NOT a merge — confirmed at `scripts/persona-tool-guard.sh:33-41`. Every downstream `jq` read (tool_scope `:58`, resource_scope `:90-95`, `MATCH_COUNT :139`, per-rule extraction `:144`) targets that single `$RULES_FILE`.

**Files:**
- Modify: `scripts/persona-tool-guard.sh` (build a merged rules view; surface citation in the reason; add `SB_PERSONA_LEARNED` kill switch).
- Test: `tests/test-persona-learned-rule.sh` (NEW).

**The change (loader merge):** after the base-file resolution block (`:33-41`), add:
```bash
LEARNED_RULES="$BRAIN_DIR/persona-rules.learned.json"
EFFECTIVE_RULES="$RULES_FILE"          # default: today's single-file behavior (back-compat)
CLEANUP_MERGED=""
if [ "${SB_PERSONA_LEARNED:-on}" != "off" ] && [ -s "$LEARNED_RULES" ]; then
  # Merge ONLY the .rules arrays. tool_scope/resource_scope stay from the base file.
  # Learned rules are appended AFTER defaults (defaults match first), filtered to active
  # (valid_to == null). Fail-soft: if either file is malformed, fall back to base.
  MERGED_TMP=$(mktemp 2>/dev/null) || MERGED_TMP=""
  if [ -n "$MERGED_TMP" ] && jq -s '
        (.[0]) as $base | (.[1]) as $learned
        | $base
        | .rules = ((($base.rules) // [])
            + ((($learned.rules) // []) | map(select(.valid_to == null))))
      ' "$RULES_FILE" "$LEARNED_RULES" > "$MERGED_TMP" 2>/dev/null \
     && [ -s "$MERGED_TMP" ]; then
    EFFECTIVE_RULES="$MERGED_TMP"; CLEANUP_MERGED="$MERGED_TMP"
  else
    [ -n "$MERGED_TMP" ] && rm -f "$MERGED_TMP" 2>/dev/null
  fi
fi
trap '[ -n "$CLEANUP_MERGED" ] && rm -f "$CLEANUP_MERGED" 2>/dev/null' EXIT
```
Then **rename every `"$RULES_FILE"` read below the merge to `"$EFFECTIVE_RULES"`** (tool_scope/resource_scope can stay on `$RULES_FILE` since learned files don't carry those, but using `$EFFECTIVE_RULES` everywhere is simpler and harmless because the merge preserves the base `tool_scope`/`resource_scope`). The rule-iteration block (`:139-214`) MUST read `$EFFECTIVE_RULES`.

**Citation surfacing:** in the `ask`/`deny`/`rewrite` emit blocks, when the matched `rule` has a `citation`, append a compact provenance suffix to `reason`:
```bash
cite=$(printf '%s' "$rule" | jq -r '
  if .citation then " [learned " + (.citation.date // "?")
    + "; evidence: " + ((.citation.evidence_text // "") | .[0:160]) + "]"
  else "" end' | tr -d '\r')
reason="$reason$cite"
```
so the user sees *why* the guardrail exists and can trace it. (Defaults have no citation → suffix empty → byte-identical to today.)

**Kill switch:** `SB_PERSONA_LEARNED=off` skips the merge entirely (defaults-only) — a finer lever than the existing `SB_PERSONA_GATE=off` (which disables ALL guard output).

**TEST `tests/test-persona-learned-rule.sh` (bash + jq + grep, mktemp-isolated, fail-loud):**
1. **Learned rule fires + citation surfaced.** Write a `persona-rules.learned.json` into an isolated `$BRAIN_DIR` with one `ask` rule (`tool:Bash`, `match_command:"curl .*\\| *sh"`, `valid_to:null`, a `citation`). Pipe a matching Bash call through the guard. Assert `permissionDecision == "ask"` AND `permissionDecisionReason | test("learned")` AND it contains the evidence snippet.
2. **Backward-compat — no learned file.** With NO `persona-rules.learned.json`, re-run an existing default-rule case (e.g. `rm -rf` → ask). Assert behavior is unchanged (proves the merge is a no-op when the learned file is absent — the critical fallback branch).
3. **Retired rule does NOT fire.** Add a second learned rule with `valid_to` set (non-null). Pipe its matching call. Assert silent (the loader filtered it out). (This also pre-stages Task 4.)
4. **Malformed learned file is ignored, defaults still work.** Write `persona-rules.learned.json` = `not json`. Assert a default-rule case still fires (fail-soft to base).
5. **`SB_PERSONA_LEARNED=off`** with a matching learned rule present → learned rule silent, default rules still active.
6. **Defaults still take precedence / merge ordering** — a default `ask` and a learned `ask` on overlapping input both resolve to `ask` (no crash from two matches; first match wins, exits 0).

**Risks:**
- **Hook latency:** one extra `jq -s` + a temp file per PreToolUse invocation. The guard already runs ~6 `jq` calls per call; the learned file is tiny (cap it at e.g. 200 rules in Task 4). Acceptable. The `trap … EXIT` cleanup must not clobber any existing trap (the script has none today — verify before adding).
- **Over-firing guardrails:** mitigated structurally — learned rules are `action:"ask"` only (Task 3 cap), so worst case is an extra confirmation prompt, never a block or a silent rewrite. Noise is observable in `audit-log.jsonl` (rule_name is logged) for a future dismissal-driven retire.
- **Temp-file on read-only/locked FS:** `mktemp` failure falls back to base (`EFFECTIVE_RULES="$RULES_FILE"`). Covered by the fail-soft branch.

**Effort:** ~1 day.

---

### Task 3: Signal → citation-carrying learned rule synthesis (in `merge-persona-signals.sh`)

**Precondition / idempotent check:** `grep -q 'persona-rules.learned.json' scripts/merge-persona-signals.sh` → if present, synthesis is wired. Today graduation (`:87-124`) only calls `sb_pin_to_user` (USER.md). The synthesis is **additive** to that block.

**Files:**
- Modify: `scripts/merge-persona-signals.sh` (carry the optional `rule` hint through the merge/dedup; at graduation, branch on rule-hint presence).
- Test: `tests/test-persona-rule-synthesis.sh` (NEW).
- (Depends on Task 1 contract + Task 2 store/loader.)

**The change:**
1. **Carry the hint through merge.** In the `reduce` that appends a new signal (`:64-73`), copy `rule: $sig.rule` (may be null) into the stored signal object. In the update branch (`:58-61`), keep the existing rule hint (do not overwrite with null). This is purely additive to the schema; existing signals without `rule` are unaffected.
2. **Branch at graduation** (`:95-124`). For each graduation candidate (`count >= 2 && confidence == "high" && graduated == false`):
   - **Validate the rule hint.** A hint is *rule-worthy* iff: `rule` is an object AND `rule.tool` is a non-empty known tool AND exactly one of `rule.match_command` / `rule.match_path` is a non-empty string AND that string is a sane regex (defensive length cap, e.g. 3–200 chars, and it must compile: test with `printf '' | grep -qE "$pat"` — `grep -E` returning 2 means a bad pattern → reject).
   - **If rule-worthy → write a learned rule** (action capped to `"ask"`) into `$BRAIN_DIR/persona-rules.learned.json`, carrying a `citation` built from the signal's newest evidence entry (`session`, `slug`, `date`, `text`) + `transcript_path` reconstructed from the archive naming. Use a deterministic `name` = `learned-<sanitized-signal-slug>` (via `sb_sanitize_slug`) so re-graduation is **idempotent** (upsert by name — Task 4 owns the contradiction/duplicate logic; here, if an active rule with that name already exists, skip). Mark the signal `graduated = true` (mirror the existing dedup-aware graduation marker at `:107-121`).
   - **Else (no valid hint) → USER.md as today** (`sb_pin_to_user`), unchanged. A signal MAY do both only if it is genuinely prose+constraint; default to one destination to avoid double-surfacing — prefer the rule when a valid hint exists, USER.md otherwise.
3. **Writer shape.** Add a small pure-`jq` helper inside the script (no new file): read-or-init the learned file (`{ "rules": [] }`), append the new rule, write atomically via `tmp + mv` (mirror the existing atomic write at `:138-145`). Cap total rules (e.g. keep newest 200 active) so the file can't grow unbounded — ratchet for the loader-latency risk.

**Autonomy note (spec §4):** this runs inside the Stop-hook `merge-persona-signals.sh` which already executes with zero user interaction every session end. No new trigger, no accept gate. The out-of-band dream/`knowledge-maintainer` reflection pass (spec P4) is a *future enrichment* that could cross-check learned rules against clusters — explicitly **out of scope** here; P2 is the deterministic, per-session synthesis only.

**TEST `tests/test-persona-rule-synthesis.sh`:**
1. **Rule-worthy signal → learned rule with citation.** Feed `merge-persona-signals.sh --slug demo` (across two invocations to reach `count>=2`, `confidence:high`) a signal carrying a valid `rule` hint. Assert `persona-rules.learned.json` now has a rule with the expected `match_command`, `action == "ask"`, `valid_to == null`, and a `citation` whose `session_id`/`date`/`evidence_text` match the fed evidence and whose `transcript_path` contains `demo`.
2. **Prose-only signal → USER.md, NOT a rule.** Feed a high-confidence signal with NO `rule` hint twice. Assert `USER.md` gained the line AND `persona-rules.learned.json` has no rule for it (or file absent). (The discriminator works.)
3. **Bad regex hint is rejected (degrades to USER.md / no rule).** Feed a hint with `match_command: "("` (unbalanced). Assert no learned rule is written and the script exits 0 (fail-soft, no crash).
4. **Idempotent re-graduation.** Feed the same rule-worthy signal a 3rd time. Assert the learned file still has exactly ONE active rule of that name (no duplicate).
5. **Empty-slug fallback.** Invoke without `--slug`. Assert a learned rule is still written with a session-only `transcript_path` (degraded, not failed).

All assertions via `jq -e`/`grep`, isolated `BRAIN_DIR=$(mktemp -d)`, no `awk`.

**Risks:**
- **False guardrails from a hallucinated hint** (autonomy vs safety, the core P2 tension). Mitigations stacked: (a) requires `count>=2` distinct high-confidence sessions (same bar as USER.md graduation), (b) requires a *structured, validated, compilable* regex hint, (c) `action` hard-capped to `ask` (non-destructive), (d) citation makes every rule auditable, (e) Task 4 auto-retires contradictions, (f) `SB_PERSONA_LEARNED=off` global escape. A wrong rule costs one extra confirm prompt and is traceable — acceptable under the constitution's "reversible + grounded" doctrine.
- **Double-surfacing** (same lesson in USER.md *and* a rule). Resolved by the prefer-rule-else-USER.md branch; a test could assert mutual exclusivity if desired.
- **Slug not threaded** → covered by Task 1 plumbing + test 5.

**Effort:** ~1.5 days.

**Optional variant (note):** if the reviewer prefers separation of concerns, extract synthesis into `scripts/synthesize-persona-rule.sh` invoked by `merge-persona-signals.sh`. This adds ONE script → bump `scripts` `52 → 53` in `docs/surface-budget.json`. Default recommendation is the fold-in (no surface growth).

---

### Task 4: Auto-retire on contradiction (bi-temporal, reversible) — mirror `merge-edges.sh`

**Precondition / idempotent check:** `grep -q 'valid_to' scripts/merge-persona-signals.sh` (synthesis side) and a `persona-rules-conflicts.jsonl` reference → if present, retire logic exists. This task extends Task 3's writer with contradiction detection BEFORE it appends a new rule.

**Files:**
- Modify: `scripts/merge-persona-signals.sh` (add `detect_rule_conflict` + soft-retire, modeled on `merge-edges.sh:45-85,130-150`).
- Test: `tests/test-persona-rule-retire.sh` (NEW).

**The change:**
- **Contradiction identity (deliberately conservative to avoid false contradictions):** two rules contradict iff they target the **same** `(tool, match_command)` OR `(tool, match_path)` **exact string** but specify a **different `action`/intent** — OR a new high-confidence signal explicitly negates a prior one (the extractor emits `rule` with an opposing `reason`; in P2 with action capped to `ask`, the practical contradiction is *re-graduation that flips the match/intent for the same target*). Exact-string identity (not regex-subsumption) is chosen precisely to prevent the false-contradiction failure mode — regex overlap is undecidable and would retire unrelated rules.
- **On contradiction:** set `valid_to = today` (+ `retired_by = <new rule name>`, `retire_reason`) on the OLDER active rule **in place** (append-in-place; the entry stays in the array — this is the reversible, history-preserving move, exactly like `merge-edges.sh` setting `valid_to`/emitting `op:invalidate`). Then append the new active rule. The loader (Task 2) already filters `valid_to == null`, so the retired rule stops firing immediately.
- **Conflict log:** append one record per retirement to `$BRAIN_DIR/persona-rules-conflicts.jsonl` mirroring `conflicts.jsonl`: `{detected_at, retired_rule, new_rule, kind:"contradiction", reason, status:"open"}`. Use the `already_open`-style last-record-wins fold (`merge-edges.sh:78-85`) so re-runs don't duplicate an open conflict.
- **Reversibility (constitution):** retirement never deletes; flipping `valid_to` back to `null` reactivates a rule. Document a one-liner recovery in `CHANGELOG`/comment. Nothing is hard-deleted; the cap in Task 3 archives oldest *retired* rules only (never an active one).

**TEST `tests/test-persona-rule-retire.sh`:**
1. **Contradicting signal retires the old rule.** Seed `persona-rules.learned.json` with an active rule R1 (`tool:Bash`, `match_command:"X"`, `action:ask`). Run synthesis with a graduated signal whose hint targets the SAME `(Bash, "X")` with a flipped intent (R2). Assert: R1 now has `valid_to` set (present, not deleted), R2 is active (`valid_to:null`), and `persona-rules-conflicts.jsonl` gained a record.
2. **Retired rule does not fire at PreToolUse.** Pipe R1's matching call through `persona-tool-guard.sh` (same isolated `BRAIN_DIR`). Assert silent (filtered by the loader).
3. **New rule fires.** Pipe R2's matching call. Assert `ask` with R2's citation surfaced.
4. **Reversibility.** Flip R1 `valid_to` back to `null` via `jq` in the test, re-run the guard on R1's input. Assert R1 fires again (proves soft-retire is reversible, nothing was lost).
5. **No false contradiction.** Seed R1 `(Bash,"X")`; synthesize a rule for a DIFFERENT target `(Bash,"Y")`. Assert R1 stays active (`valid_to:null`) and BOTH rules coexist — the conservative identity prevents over-retiring.

**Risks:**
- **False contradiction over-retiring** real rules — mitigated by exact-string identity (no regex subsumption). Test 5 guards it; a static note in the code explains why exact-match is intentional.
- **Retire thrash** (two opposing signals ping-ponging across sessions) — bounded because both must independently re-reach `count>=2 high`; the conflict log makes thrash observable. A future dampener (require N-session stability before flipping) is out of scope.
- **History growth** of the learned file — capped (Task 3); only retired rules are archived out, active rules never evicted.

**Effort:** ~1 day.

---

### Task 5: Surface-budget bump, version lockstep, and CI gates

**Files:**
- Modify: `docs/surface-budget.json` (`tests` `151 → 154`; if the Task 3 optional separate-script variant was taken, also `scripts` `52 → 53`).
- Modify: `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` (`version` → `0.33.30`).
- Modify: `CHANGELOG.md` (new top entry).

**Steps:**
- [ ] **Step 1 — Bump the ratchet in the SAME commit as the new tests.** Run `bash scripts/validate-plugin.sh` and confirm R8 passes (live `tests` count == budget). The gate FAILS if you add the 3 test files without bumping; that failure is the ratchet working.
- [ ] **Step 2 — Version lockstep.** Set `0.33.30` in both `plugin.json` and the `second-brain` entry of `marketplace.json`. Add a `CHANGELOG.md` entry:
  ```markdown
  ## 0.33.30 — P2 grounded learning → active guardrail

  - Learned persona signals can now graduate to a citation-carrying PreToolUse guardrail
    (not only a USER.md line): a structured, validated rule-hint on a high-confidence repeated
    signal becomes an `action:"ask"` rule in ~/.second-brain/persona-rules.learned.json, each
    carrying a transcript citation (session_id + transcript_path + evidence quote).
  - persona-tool-guard.sh now merges the learned store on top of the pristine
    persona-rules.default.json (defaults always match first; learned rules can only ADD `ask`
    friction, never weaken a default). Citation surfaced in the confirmation reason.
  - Contradicted learned rules auto-retire bi-temporally (valid_to soft-retire, reversible,
    history-preserving — mirrors the graph edge log) with a persona-rules-conflicts.jsonl trail.
  - Kill switch SB_PERSONA_LEARNED=off disables the learned layer; defaults unaffected.
  ```
- [ ] **Step 3 — Run the full local gate suite (the user's required pre-push gates, per MEMORY):**
  - `cd mcp && npm ci && npm test` (vitest — unaffected, but proves no break).
  - `bash scripts/validate-plugin.sh` (R8 ratchet + shell validation + version lockstep).
  - `bash tests/run-all.sh` (all shell tests incl. the 3 new ones + existing `test-persona-tool-guard.sh` regression).
  - Cross-platform spot-check: the new tests must pass under git-bash (Windows, primary dev) AND not rely on GNU-only `date`/`awk` — visually confirm no `awk`, and `date` uses the existing fallback idiom.
- [ ] **Step 4 — Commit** the version+budget+changelog together.

**Risks:**
- **Forgetting the budget bump** → CI red (the ratchet doing its job). Fix by bumping `tests` in the same commit.
- **BSD/macOS CI catching a portability slip a Windows subagent missed** (known MEMORY pitfall) — pre-empt by running `bash tests/run-all.sh` locally and keeping all date math on the dual `-v`/`-d` fallback.

**Effort:** ~0.5 day.

---

## Sequencing & dependency graph

```
Task 1 (citation contract + slug plumbing)
   └─> Task 2 (loader merge + citation surfacing)      [needs the citation shape]
   └─> Task 3 (synthesis writes the rule)              [needs contract; writes what Task 2 reads]
            └─> Task 4 (auto-retire / contradiction)   [extends Task 3's writer; tested against Task 2's loader]
                     └─> Task 5 (budget bump + lockstep + gates)   [last; ships everything]
```
Task 2 and Task 3 both depend on Task 1 and can be built in parallel by two workers (Task 3's tests need Task 2's loader to assert "fires/doesn't fire", so integrate Task 2 first). **Total effort: ~4.5 days** single-threaded; ~3 days with Task 2/3 parallelized.

## Explicit risk ledger (cross-cutting)

| Risk | Severity | Mitigation (where) |
|---|---|---|
| Auto-generated guardrail is wrong (false belief locks in) | High | `count>=2 high` bar + validated structured hint + `action:"ask"` cap + citation auditability + Task 4 retire + `SB_PERSONA_LEARNED=off` (Task 3) |
| Over-firing (too much friction) | Med | `ask`-only (never block/rewrite); audit-log observability; future dismissal-driven retire (Task 2/3) |
| False contradiction retires a good rule | Med | exact-string identity, NOT regex subsumption; Test 5 guards it (Task 4) |
| Backward-compat break (defaults gain citation/valid_to semantics they lack) | High | loader treats missing citation/valid_to as valid/active; explicit no-learned-file + malformed-file tests (Task 2 tests 2,4) |
| Hook latency from per-call merge | Low | tiny capped learned file; single extra `jq -s`; fail-soft to base on mktemp failure (Task 2) |
| Untrusted transcript content reaching an executable position | High (constitution) | evidence is invisible-char-stripped (P6a) + stored as data + surfaced verbatim, never executed; learned rules can't `allow`/grant (Task 2/3) |
| Cross-platform (awk/date/mktemp) | Med | jq-only, dual `date` fallback, `mktemp -d`; `bash tests/run-all.sh` + BSD CI (Task 5) |
| Surface ratchet trips | Low | bump `tests 151→154` same commit (Task 5) |

## Verification (end-to-end, spec §8 criteria)

1. **"Every learned guardrail carries a transcript citation"** — `tests/test-persona-rule-synthesis.sh` asserts citation written; `tests/test-persona-learned-rule.sh` asserts it surfaces in the PreToolUse reason.
2. **"Contradicted rules auto-retire"** — `tests/test-persona-rule-retire.sh` asserts soft-retire + non-firing + reversibility + conflict log.
3. **"Resolve to PROJECT.md decision OR persona-rules guardrail"** — the synthesis discriminator (rule-hint ⇒ guardrail; else ⇒ USER.md) is tested in synthesis tests 1–2. (Note: USER.md is the existing global-preference destination; PROJECT.md-decision routing for project-scoped constraints is already covered by the separate extraction→`merge-project-update.sh` path and is not regressed here.)
4. **Autonomy** — synthesis runs only inside the already-autonomous Stop-hook path; no new manual command. (Inspect: no new entry in any `SKILL.md`/`hooks.json`.)
5. **Gates green** — `bash scripts/validate-plugin.sh` + `bash tests/run-all.sh` + `cd mcp && npm test`; version `0.33.30` consistent across `plugin.json`/`marketplace.json`/`CHANGELOG.md`.

## Out of scope (deferred)

- **`rewrite`/`deny` learned actions** — P2 caps learned rules to `ask` (non-destructive). Auto-generated command rewrites/blocks need a stronger trust model (defer).
- **Dream/reflection cross-check of learned rules** (spec P4) — out-of-band synthesis/enrichment of guardrails from memory clusters; P2 is per-session deterministic only.
- **Dismissal-driven auto-retire** (retire a rule the user keeps overriding) — needs the `persona_dismiss` signal wired into synthesis; future.
- **PROJECT.md-decision synthesis from signals** — the project-scoped half is already served by the extraction→`merge-project-update.sh` path; P2 adds the guardrail half. Unifying both behind one "learned practice resolver" is a later consolidation.
- **Regex-subsumption contradiction detection** — deliberately avoided (undecidable, false-positive prone); exact-string identity only.
