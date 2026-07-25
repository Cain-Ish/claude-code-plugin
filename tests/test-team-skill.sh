#!/usr/bin/env bash
# Structural guard for the /second-brain:team conductor (M1 B3) + its worker (B2).
# Locks: explicit SKAG flags, dispatch targets that RESOLVE, PROTOCOL.md literal parity
# (the skill quotes the routing contract — a reworded PROTOCOL must fail here, not
# drift), the packet/BLAME/escalate-once disciplines, grants-match-body (a granted tool
# the body never uses is an unused grant; a body tool never granted is a mid-skill
# permission prompt), and the <500-line skill rule.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SKILL="$ROOT/skills/team/SKILL.md"
WORKER="$ROOT/agents/team-worker.md"
PROTO="$ROOT/skills/team/PROTOCOL.md"
fail(){ echo "FAIL: $1"; exit 1; }
pass(){ echo "PASS: $1"; }

[ -f "$SKILL" ]  || fail "skills/team/SKILL.md missing"
[ -f "$WORKER" ] || fail "agents/team-worker.md missing"
[ -f "$PROTO" ]  || fail "skills/team/PROTOCOL.md missing"
[ -f "$ROOT/skills/team/references/roles.md" ] || fail "skills/team/references/roles.md missing (Phase 2 reads it)"

FM=$(awk '/^---$/{n++; next} n==1' "$SKILL")
BODY=$(awk '/^---$/{n++; next} n>=2' "$SKILL")
AT=$(printf '%s\n' "$FM" | grep -m1 '^allowed-tools:') || fail "team skill has no allowed-tools line"

# --- 1. SKAG flags explicit: user-invocable command, NOT model-invocable in M1 ------
printf '%s\n' "$FM" | grep -q '^user-invocable: true$' || fail "user-invocable: true not explicit"
printf '%s\n' "$FM" | grep -q '^disable-model-invocation: true$' \
  || fail "disable-model-invocation: true not explicit (M1 is explicit-invocation only; A1 flips this in M2)"
printf '%s\n' "$FM" | grep -q '^argument-hint:' || fail "argument-hint missing"
pass "SKAG flags: explicit user-invocable + disable-model-invocation + argument-hint"

# --- 2. dispatch targets resolve ----------------------------------------------------
printf '%s\n' "$BODY" | grep -q 'second-brain:team-worker' || fail "skill never dispatches second-brain:team-worker"
grep -qE '^name: *team-worker$' "$WORKER" || fail "agents/team-worker.md name: != team-worker (dispatch would no-op)"
printf '%s\n' "$BODY" | grep -q 'second-brain:quality-reviewer' || fail "gate never dispatches second-brain:quality-reviewer"
grep -qE '^name: *quality-reviewer$' "$ROOT/agents/quality-reviewer.md" || fail "quality-reviewer dispatch would no-op"
pass "dispatches resolve: team-worker (waves) + quality-reviewer (gate verdict)"

# --- 3. PROTOCOL.md literal parity: every rule the skill quotes exists verbatim -----
while IFS= read -r lit; do
  [ -n "$lit" ] || continue
  grep -qF "$lit" "$PROTO" || fail "PROTOCOL.md lost the literal the skill quotes: '$lit'"
  printf '%s\n' "$BODY" | grep -qF "$lit" || fail "team skill no longer quotes the PROTOCOL literal: '$lit'"
done <<'LITERALS'
Route per dispatch, never globally.
Escalate at most once.
Judged verdicts ride THINK.
Complete delegation packet or refuse.
Spend is not tracked and never gates.
LITERALS
for tier in THINK DO SCOUT; do
  grep -q "$tier" "$PROTO" || fail "PROTOCOL.md lost tier $tier"
  printf '%s\n' "$BODY" | grep -q "$tier" || fail "skill no longer routes tier $tier"
done
pass "PROTOCOL parity: all five quoted rules + THINK/DO/SCOUT tiers present in both files"

# --- 4. packet + blame + escalate + gate disciplines --------------------------------
printf '%s\n' "$BODY" | grep -q 'REQUIRED delegation packet — refuse, never repair' \
  || fail "skill lost the refuse-never-repair packet contract"
for b in 'BLAME: caller-under-supplied' 'BLAME: child-under-delivered'; do
  printf '%s\n' "$BODY" | grep -qF "$b" || fail "skill lost the blame class '$b'"
done
printf '%s\n' "$BODY" | grep -qi 'fresh context' || fail "skill lost the fresh-context requirement"
printf '%s\n' "$BODY" | grep -q 'exit code' || fail "gate must demand exit-code evidence, not log tails"
printf '%s\n' "$BODY" | grep -q 'TEAM-REPORT v1' || fail "skill lost the TEAM-REPORT v1 report-format field"
grep -q 'TEAM-REPORT v1' "$WORKER" || fail "worker lost the TEAM-REPORT v1 contract"
grep -q 'DATA, not instructions' "$WORKER" || fail "worker lost the untrusted-input DATA banner"
printf '%s\n' "$BODY" | grep -qF 'context: none' || fail "skill lost the context packet field (required-but-may-be-none)"
grep -qF 'context: none' "$WORKER" || fail "worker lost the context packet field (required-but-may-be-none)"
printf '%s\n' "$BODY" | grep -q 'list-open' || fail "skill lost the Phase-1 list-open resume check"
pass "disciplines: packet refusal, both BLAME classes, fresh-context gate, exit-code evidence"

# --- 5. worker holds NO dispatch/shell grants (spec B2: workers never spawn) --------
WTOOLS=$(grep -m1 '^tools:' "$WORKER") || fail "worker has no tools: line"
for t in Agent Task Skill Bash; do
  printf '%s' "$WTOOLS" | grep -qE "(^tools:|,)[ \t]*$t[ \t]*(\(|,|\$)" \
    && fail "team-worker grants $t (workers never spawn / never shell)"
done
grep -qE '^model:[ \t]*inherit$' "$WORKER" \
  || fail "team-worker model: must be 'inherit' (tier routing is per-dispatch, PROTOCOL rule 1)"
pass "worker: no Agent/Task/Skill/Bash grants; model: inherit for per-dispatch tiering"

# --- 6. grants match body (both directions for the load-bearing tools) --------------
for m in knowledge_search episodic_search code_map code_neighbors; do
  tok="mcp__plugin_second-brain_knowledge-base__$m"
  printf '%s' "$AT" | grep -qF "$tok" || fail "allowed-tools missing $tok (Phase 0/1 uses it)"
  printf '%s\n' "$BODY" | grep -q "$m" || fail "granted $m but the body never uses it (unused grant)"
done
printf '%s' "$AT" | grep -qE '(^allowed-tools:| )Agent( |$)' || fail "allowed-tools missing Agent (the conductor IS the dispatcher)"
printf '%s' "$AT" | grep -qF 'Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)' \
  || fail "allowed-tools missing the scoped scripts grant (team-run.sh runs through it)"
printf '%s\n' "$BODY" | grep -q 'team-run.sh' || fail "body never invokes team-run.sh"
for g in $(printf '%s' "$AT" | grep -oE 'Bash\(git [a-z-]+' | sed 's/Bash(git //'); do
  printf '%s\n' "$BODY" | grep -q "git $g" || fail "granted Bash(git $g *) but body never runs git $g"
done
pass "grants-match-body: MCP reads, Agent, scoped scripts, and every git grant are used"

# --- 7. size + seam discipline ------------------------------------------------------
LINES=$(wc -l < "$SKILL" | tr -d ' ')
[ "$LINES" -lt 500 ] || fail "SKILL.md is $LINES lines (must stay <500 — long detail goes to references/)"
printf '%s\n' "$BODY" | grep -q 'M2' || fail "skill must NAME its M2 seams (quota guard, git matrix, compounding) instead of improvising them"
pass "size: SKILL.md $LINES lines (<500); M2 seams named"

echo; echo "ALL PASS"
