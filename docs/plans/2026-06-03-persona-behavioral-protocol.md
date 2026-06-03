# Persona Behavioral Protocol (Four Principles) Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Give the persona a canonical Four-Principles behavioral protocol (`principles.md`) delivered as standing context + a once-per-session just-in-time re-surface on coding intent + one advisory large-diff gate — countering Karpathy's agent failure modes the way a static CLAUDE.md can't.

**Architecture:** A new `skills/using-second-brain/principles.md` (source of truth, full + a marked compact block). `using-second-brain/SKILL.md` references it (standing context). `persona-context.sh` re-surfaces the compact block once per session on the first coding-intent prompt (memo-deduped). New `scripts/simplicity-gate.sh` (PostToolUse, advisory) nudges on large diffs. Surgical/assumption structural gates are deferred (spec §10).

**Tech Stack:** bash hooks (mawk-safe, fail-soft, `SB_*` kill switches), jq, markdown. No TS.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `skills/using-second-brain/principles.md` | canonical Four Principles (full + compact block) | Create |
| `skills/using-second-brain/SKILL.md` | reference the principles file (standing context) | Modify |
| `scripts/simplicity-gate.sh` | PostToolUse advisory large-diff nudge | Create |
| `scripts/persona-context.sh` | once-per-session compact re-surface on coding intent | Modify (4 surgical edits) |
| `hooks/hooks.json` | register simplicity-gate under PostToolUse | Modify |
| `tests/test-persona-principles.sh` | guard the file + skill ref + re-surface | Create |
| `tests/test-simplicity-gate.sh` | guard the gate | Create |

---

## Task 1: Canonical principles.md + its guard

**Files:**
- Create: `skills/using-second-brain/principles.md`
- Create: `tests/test-persona-principles.sh`
- Modify: `skills/using-second-brain/SKILL.md`

- [ ] **Step 1: Write the failing test** — `tests/test-persona-principles.sh`:

```bash
#!/bin/bash
# Guard: the Four-Principles behavioral protocol exists, is complete, carries an extractable
# compact block, and is referenced by the using-second-brain skill (standing context).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
P="$ROOT/skills/using-second-brain/principles.md"
SK="$ROOT/skills/using-second-brain/SKILL.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -f "$P" ] || fail "principles.md missing"
for n in "Think Before Coding" "Simplicity First" "Surgical Changes" "Goal-Driven Execution"; do
  grep -qF "$n" "$P" || fail "principle missing: $n"
done
pass "all four principles present"
[ "$(grep -c 'Test:' "$P")" -ge 4 ] || fail "each principle needs a Test: line (>=4)"
pass "each principle has a Test:"
CB=$(awk '/<!-- compact:begin/{f=1;next}/<!-- compact:end/{f=0}f' "$P")
[ -n "$CB" ] || fail "compact block empty/missing"
[ "$(printf '%s\n' "$CB" | grep -c .)" -le 8 ] || fail "compact block too long (keep it terse)"
printf '%s' "$CB" | grep -qiE 'simplic|surgical|assumption|goal|test first' || fail "compact block missing principle keywords"
pass "compact block present + terse"
grep -q 'principles.md' "$SK" || fail "using-second-brain/SKILL.md does not reference principles.md"
pass "using-second-brain references principles.md (standing context)"
# Boundary: principles must NOT leak into the user identity card seeds (behavioral layer only).
for seed in "$ROOT/skills/setup/SKILL.md" "$ROOT/scripts/persona-context.sh"; do
  grep -qiE 'Simplicity First|Surgical Changes|Goal-Driven Execution' "$seed" 2>/dev/null \
    && fail "$(basename "$seed"): Four-Principles content leaked into a persona-card seed (behavioral != identity)"
done
pass "principles stay in the behavioral layer, not the identity persona-card seeds"
echo; echo "ALL PASS"
```

- [ ] **Step 2: Run it — expect FAIL** (`bash tests/test-persona-principles.sh`) → "principles.md missing".

- [ ] **Step 3: Create `skills/using-second-brain/principles.md`:**

```markdown
# Persona Behavioral Protocol — the Four Principles

Standing guidance for collaborating on code. Loaded as context by `using-second-brain` and
re-surfaced once per coding session by `persona-context.sh`. **Source of truth — edit here.**
(Distilled from Karpathy's Dec-2025 agent-failure-mode post: agents make silent wrong
assumptions, overcomplicate, edit orthogonal code, and accept weak goals.)

## 1. Think Before Coding
Don't assume; surface tradeoffs; push back; stop when confused.
- State load-bearing assumptions explicitly; verify the riskiest from the code/wiki before acting.
- Present multiple interpretations when the request is ambiguous — don't pick one silently.
- Push back when a simpler/safer approach exists; an earned interrupt beats a sycophantic yes.
- Name what's unclear and ask one focused question rather than guessing.
- **Test:** could you defend every assumption your plan rests on?

## 2. Simplicity First
Minimum code that solves the problem. Nothing speculative.
- No features, abstractions, configurability, or "flexibility" that wasn't asked for.
- No error handling for impossible scenarios.
- If 200 lines could be 50, rewrite it.
- **Test:** would a senior engineer call this overcomplicated? If yes, simplify.

## 3. Surgical Changes
Touch only what the task requires; clean up only your own mess.
- Don't "improve" adjacent code, comments, or formatting; match the existing style.
- Don't refactor things that aren't broken.
- Remove only the imports/variables/functions YOUR change orphaned; mention pre-existing dead code, don't delete it.
- Never delete or rewrite comments/code you don't understand.
- **Test:** does every changed line trace directly to the request?

## 4. Goal-Driven Execution
Define success criteria, then loop until verified.
- Transform imperative → verifiable: "add validation" → "write tests for invalid inputs, then pass them".
- For multi-step work, state a brief numbered plan with a verify-check per step.
- Strong success criteria let you loop independently; weak ones ("make it work") force constant clarification.
- **Test:** is there a command whose output proves this is done?

<!-- compact:begin (re-surfaced just-in-time by persona-context.sh — keep <=7 lines, imperative) -->
Coding principles (apply now):
1. Think first — state + verify your load-bearing assumptions, surface tradeoffs, ask when genuinely unclear; don't run on a guess.
2. Simplicity first — minimum code that solves it; no speculative features/abstractions; if 200 lines could be 50, rewrite.
3. Surgical changes — change only what the task needs; don't touch orthogonal code/comments or remove things you don't understand.
4. Goal-driven — define success criteria + write the test first, then loop to green.
<!-- compact:end -->
```

- [ ] **Step 4: Add the reference to `skills/using-second-brain/SKILL.md`** — insert a new section before `## What this skill replaces`:

```markdown
## Behavioral protocol (the Four Principles)

Before writing or changing code, apply the Four Principles in
`${CLAUDE_PLUGIN_ROOT}/skills/using-second-brain/principles.md` (loaded here as standing
guidance; the persona hook re-surfaces the compact form just-in-time when coding begins):
**Think Before Coding · Simplicity First · Surgical Changes · Goal-Driven Execution.**

```

- [ ] **Step 5: Run it — expect PASS** (`bash tests/test-persona-principles.sh` → ALL PASS). `chmod +x tests/test-persona-principles.sh`.
- [ ] **Step 6: Commit** — `git add skills/using-second-brain/ tests/test-persona-principles.sh && git commit -m "feat(persona): canonical Four-Principles protocol + standing-context reference"`.

## Task 2: simplicity-gate.sh (PostToolUse advisory)

**Files:**
- Create: `scripts/simplicity-gate.sh`
- Create: `tests/test-simplicity-gate.sh`

- [ ] **Step 1: Write the failing test** — `tests/test-simplicity-gate.sh`:

```bash
#!/bin/bash
# Guard: simplicity-gate nudges on a large Write/Edit/MultiEdit, stays silent on small ones,
# is advisory-only (never blocks), honors the kill switch, ignores non-edit tools, and fail-softs.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SC="$ROOT/scripts/simplicity-gate.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -f "$SC" ] || fail "script missing"
big=$(yes 'x' | head -200)
EVT=$(jq -nc --arg c "$big" '{tool_name:"Write",tool_input:{content:$c}}')
OUT=$(printf '%s' "$EVT" | bash "$SC" 2>/dev/null)
printf '%s' "$OUT" | grep -q 'Simplicity check' || fail "200-line Write should nudge"
printf '%s' "$OUT" | grep -qiE 'deny|permissionDecision' && fail "must be advisory, never block"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName=="PostToolUse"' >/dev/null 2>&1 || fail "wrong hookEventName"
pass "large Write nudges, advisory PostToolUse only"
SMALL=$(jq -nc --arg c "$(yes 'x'|head -10)" '{tool_name:"Write",tool_input:{content:$c}}')
[ -z "$(printf '%s' "$SMALL" | bash "$SC" 2>/dev/null)" ] || fail "small Write should be silent"
pass "small Write silent"
EDIT=$(jq -nc --arg s "$big" '{tool_name:"Edit",tool_input:{old_string:"a",new_string:$s}}')
printf '%s' "$EDIT" | bash "$SC" 2>/dev/null | grep -q 'Simplicity check' || fail "large Edit should nudge"
ME=$(jq -nc --arg s "$(yes 'x'|head -120)" '{tool_name:"MultiEdit",tool_input:{edits:[{old_string:"a",new_string:$s},{old_string:"b",new_string:$s}]}}')
printf '%s' "$ME" | bash "$SC" 2>/dev/null | grep -q 'Simplicity check' || fail "large MultiEdit (summed) should nudge"
pass "large Edit + summed MultiEdit nudge"
[ -z "$(printf '%s' "$EVT" | SB_SIMPLICITY_GATE=off bash "$SC" 2>/dev/null)" ] || fail "kill switch should suppress"
pass "SB_SIMPLICITY_GATE=off suppresses"
[ -z "$(printf '%s' "$EVT" | SB_SIMPLICITY_GATE_LINES=500 bash "$SC" 2>/dev/null)" ] || fail "raised threshold should suppress a 200-line change"
pass "SB_SIMPLICITY_GATE_LINES tunes the threshold"
[ -z "$(printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | bash "$SC" 2>/dev/null)" ] || fail "Bash should be ignored"
[ -z "$(printf 'not json' | bash "$SC" 2>/dev/null)" ] || fail "malformed should be silent"
pass "non-edit tool ignored + malformed fail-soft"
echo; echo "ALL PASS"
```

- [ ] **Step 2: Run it — expect FAIL** (`bash tests/test-simplicity-gate.sh` → "script missing").

- [ ] **Step 3: Create `scripts/simplicity-gate.sh`:**

```bash
#!/bin/bash
# simplicity-gate.sh — PostToolUse advisory (Principle 2: Simplicity First). When a single
# Write/Edit/MultiEdit writes more than SB_SIMPLICITY_GATE_LINES (default 150) non-blank lines,
# nudge toward a smaller, naive-correct version. Advisory only (additionalContext, never blocks).
# Kill switch SB_SIMPLICITY_GATE=off. mawk-safe (no awk), fail-soft.
set -u
[ "${SB_SIMPLICITY_GATE:-on}" = "off" ] && exit 0
RAW=$(cat 2>/dev/null || true); [ -z "$RAW" ] && exit 0
TOOL=$(printf '%s' "$RAW" | jq -r '.tool_name // empty' 2>/dev/null)
case "$TOOL" in Write|Edit|MultiEdit) ;; *) exit 0 ;; esac
LIMIT="${SB_SIMPLICITY_GATE_LINES:-150}"
# Lines written by this change = Write.content OR Edit.new_string OR sum of MultiEdit new_strings.
LINES=$(printf '%s' "$RAW" | jq -r '
  ((.tool_input.content // .tool_input.new_string // "")
   + "\n"
   + ([.tool_input.edits[]?.new_string // ""] | join("\n")))' 2>/dev/null | grep -c . )
case "$LIMIT" in *[!0-9]*) LIMIT=150 ;; esac
[ "${LINES:-0}" -gt "$LIMIT" ] 2>/dev/null || exit 0
CTX="[Simplicity check — Principle 2] This change writes ~${LINES} lines (> ${LIMIT}). Before continuing: is there a naive-correct version roughly half the size? Drop speculative abstractions/config/flexibility that wasn't requested. Consider /simplify or the code-simplifier. Advisory only — nothing was blocked."
jq -nc --arg ctx "$CTX" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}' 2>/dev/null || true
exit 0
```

- [ ] **Step 4: Run it — expect PASS.** `chmod +x scripts/simplicity-gate.sh tests/test-simplicity-gate.sh`.
- [ ] **Step 5: Commit** — `git add scripts/simplicity-gate.sh tests/test-simplicity-gate.sh && git commit -m "feat(persona): simplicity-gate PostToolUse advisory large-diff nudge (Principle 2)"`.

## Task 3: Register simplicity-gate in hooks.json

**Files:** Modify `hooks/hooks.json` (PostToolUse array).

- [ ] **Step 1: Add the entry.** In `hooks/hooks.json`, the `PostToolUse` array currently has two entries (quality-gate on `Write|Edit`; tool-return-scanner). Append a third object to that array:

```json
    {
      "_comment": "Persona Principle 2 (Simplicity First) — advisory nudge on a large single change. Never blocks. Kill switch SB_SIMPLICITY_GATE=off; threshold SB_SIMPLICITY_GATE_LINES (default 150).",
      "matcher": "Write|Edit|MultiEdit",
      "hooks": [
        {
          "type": "command",
          "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/simplicity-gate.sh",
          "timeout": 5
        }
      ]
    }
```

- [ ] **Step 2: Verify hooks.json still valid JSON + the validator passes:**

Run: `jq -e . hooks/hooks.json >/dev/null && bash scripts/validate-plugin.sh | tail -1`
Expected: `OK: all plugin files valid`

- [ ] **Step 3: Commit** — `git add hooks/hooks.json && git commit -m "feat(persona): wire simplicity-gate into PostToolUse"`.

## Task 4: persona-context.sh once-per-session re-surface (4 surgical edits)

**Files:** Modify `scripts/persona-context.sh`.

The goal: on the first *coding-intent* prompt of a session, append the compact principles to the injected context, once. Reuse the existing per-session memo (`$BRAIN_DIR/.injected/${SESSION_ID}.json`) for the once-per-session flag. Four surgical edits — touch only what's needed (Principle 3).

- [ ] **Step 1: Write the failing test** — append to `tests/test-persona-principles.sh` before `echo; echo "ALL PASS"`:

```bash
# --- persona-context.sh re-surface behavior ---
PCTX="$ROOT/scripts/persona-context.sh"
TMPB=$(mktemp -d); export BRAIN_DIR="$TMPB/.second-brain"; mkdir -p "$BRAIN_DIR"
mk(){ jq -nc --arg p "$1" --arg s "$2" '{prompt:$p, session_id:$s, cwd:"/tmp"}'; }
# coding-intent prompt → principles injected
OUT=$(mk "implement the retry function" "sess-A" | CLAUDE_PLUGIN_ROOT="$ROOT" bash "$PCTX" 2>/dev/null)
printf '%s' "$OUT" | grep -qi 'Coding principles (apply now)' || fail "coding-intent prompt did not re-surface principles"
pass "coding-intent prompt re-surfaces the compact principles"
# second coding prompt, same session → NOT re-injected (once per session)
OUT2=$(mk "now refactor the parser" "sess-A" | CLAUDE_PLUGIN_ROOT="$ROOT" bash "$PCTX" 2>/dev/null)
printf '%s' "$OUT2" | grep -qi 'Coding principles (apply now)' && fail "principles re-injected (should be once per session)"
pass "principles injected once per session (memo dedupe)"
# trivial / non-coding prompt in a fresh session → not injected
OUT3=$(mk "thanks, that looks good" "sess-B" | CLAUDE_PLUGIN_ROOT="$ROOT" bash "$PCTX" 2>/dev/null)
printf '%s' "$OUT3" | grep -qi 'Coding principles (apply now)' && fail "non-coding prompt injected principles"
pass "non-coding prompt does not inject principles"
# kill switch
OUT4=$(mk "implement the cache" "sess-C" | SB_PRINCIPLES_INJECT=off CLAUDE_PLUGIN_ROOT="$ROOT" bash "$PCTX" 2>/dev/null)
printf '%s' "$OUT4" | grep -qi 'Coding principles (apply now)' && fail "SB_PRINCIPLES_INJECT=off still injected"
pass "SB_PRINCIPLES_INJECT=off suppresses the re-surface"
rm -rf "$TMPB"; unset BRAIN_DIR
```

- [ ] **Step 2: Run — expect FAIL** (`bash tests/test-persona-principles.sh`) at "coding-intent prompt did not re-surface principles".

- [ ] **Step 3a: Edit 1 — compute the re-surface before the bail.** In `scripts/persona-context.sh`, immediately BEFORE the bail block:

```bash
# Bail out if nothing useful surfaced.
if [ -z "$PERSONA_ABS" ] && [ -z "$CATALOG_ABS" ] && [ -z "$WIKI_HITS" ] && [ -z "$EPISODIC_HINT" ]; then
  exit 0
fi
```

insert:

```bash
# --- Behavioral principles re-surface (once per session, first coding-intent prompt) ---
# Karpathy: prose in CLAUDE.md drifts; re-surfacing the compact Four Principles at the moment
# coding begins is the salience a static file can't provide. Once per session (memo flag),
# coding-intent only, kill switch SB_PRINCIPLES_INJECT=off.
PRINCIPLES_ABS=""; PRINCIPLES_DONE=""
_PMEMO="$BRAIN_DIR/.injected/${SESSION_ID}.json"
PRINCIPLES_DONE=$(jq -r '.principles // ""' "$_PMEMO" 2>/dev/null)
if [ "${SB_PRINCIPLES_INJECT:-on}" != "off" ] && [ "$PRINCIPLES_DONE" != "1" ] && [ -n "$SESSION_ID" ]; then
  _PLOWER=$(printf '%s' "$P_TRIM" | tr '[:upper:]' '[:lower:]')
  _CODING_RE='implement|refactor|debug|build|coding|\bcode\b|\bfix\b|\bbug\b|\bfunction\b|\bclass\b|\bmethod\b|\bapi\b|endpoint|\bscript\b|\bmodule\b|\bcomponent\b|\bfeature\b|optimi|migrat|\btest\b|add a|add the|add support|write a|write the|create a|create the'
  if printf '%s' "$_PLOWER" | grep -qE "$_CODING_RE"; then
    _PFILE="$PLUGIN_ROOT/skills/using-second-brain/principles.md"
    [ -f "$_PFILE" ] && PRINCIPLES_ABS=$(awk '/<!-- compact:begin/{f=1;next}/<!-- compact:end/{f=0}f' "$_PFILE" 2>/dev/null)
    [ -n "$PRINCIPLES_ABS" ] && PRINCIPLES_DONE=1
  fi
fi
```

- [ ] **Step 3b: Edit 2 — keep going if principles are pending.** Change that same bail condition to also check `PRINCIPLES_ABS`:

```bash
if [ -z "$PERSONA_ABS" ] && [ -z "$CATALOG_ABS" ] && [ -z "$WIKI_HITS" ] && [ -z "$EPISODIC_HINT" ] && [ -z "$PRINCIPLES_ABS" ]; then
  exit 0
fi
```

- [ ] **Step 3c: Edit 3 — append the section to the composed context.** After the EPISODIC compose block:

```bash
[ -n "$EPISODIC_HINT" ] && [ "$SHOW_EPISODIC" = "1" ] && CTX="$CTX
$EPISODIC_HINT"
```

insert:

```bash
[ -n "$PRINCIPLES_ABS" ] && CTX="$CTX

[Coding principles — apply to any code you write or change this session]
$PRINCIPLES_ABS"
```

- [ ] **Step 3d: Edit 4 — persist the once-per-session flag.** Change the memo-update jq (the `jq -nc ... '{persona:$p, catalog:$c, wiki:$w, episodic:$e}'` block) to carry `principles`:

```bash
  jq -nc \
    --arg p "$(sb_hash "$PERSONA_ABS")" \
    --arg c "$(sb_hash "$CATALOG_ABS")" \
    --arg w "$(sb_hash "$WIKI_HITS")" \
    --arg e "$(sb_hash "$EPISODIC_HINT")" \
    --arg pr "${PRINCIPLES_DONE:-}" \
    '{persona:$p, catalog:$c, wiki:$w, episodic:$e, principles:$pr}' > "$MEMO_FILE" 2>/dev/null || true
```

- [ ] **Step 4: Run — expect PASS** (`bash tests/test-persona-principles.sh` → ALL PASS).
- [ ] **Step 5: Run the existing persona-context guard** — `bash tests/test-persona-capability-awareness.sh` (and any `test-session-load*`/persona tests) → must stay green.
- [ ] **Step 6: Commit** — `git add scripts/persona-context.sh tests/test-persona-principles.sh && git commit -m "feat(persona): re-surface compact principles once per coding session"`.

## Task 5: Full suite + portability + release

**Files:** `mcp/`/manifests unchanged in logic; version bump only.

- [ ] **Step 1:** `bash tests/test-script-portability.sh` → ALL PASS (the new bash scripts must be mawk-safe / bash-3.2-safe).
- [ ] **Step 2:** `bash tests/run-all.sh` → ALL GREEN (the known `test-lib-extractor-backend` flake aside — re-run it standalone to confirm).
- [ ] **Step 3:** Deep-review gate — `/second-brain:code-review-deep` on the branch; fix confirmed findings + regression-test.
- [ ] **Step 4:** Version bump 0.24.7 → 0.24.8 (`plugin.json` + `marketplace.json`); add a `0.24.8` row to `skills/upgrade/SKILL.md` (summary: Four-Principles persona protocol + simplicity-gate; no state migration). No MCP server change → server version unchanged.
- [ ] **Step 5:** Commit + open PR + merge.

---

## Self-Review

- **Spec coverage:** principles.md (§2) ✔ Task 1; standing context (§3) ✔ Task 1 Step 4; once-per-session re-surface (§3) ✔ Task 4; simplicity-gate (§3) ✔ Tasks 2–3; goal-driven reuses stop-verify-gate (§3, no new work) ✔; kill switches (§5) ✔ Tasks 2 & 4; behavioral-not-identity boundary (§7) ✔ Task 1 test asserts no leak into seeds; deferred detectors (§10) ✔ not built. Tests (§8) ✔ Tasks 1–2 + 4.
- **Placeholder scan:** none — every step has the literal file content / command / expected output.
- **Type/name consistency:** `principles.md` path, `<!-- compact:begin/end -->` markers, `SB_PRINCIPLES_INJECT`, `SB_SIMPLICITY_GATE`(`_LINES`), the memo field `principles`, and the injected marker string `Coding principles (apply now)`/`[Coding principles —` are used identically in the script, the file, and the tests.
