#!/bin/bash
# Guard: /second-brain:maintain is a user-invocable skill that (1) dispatches the
# knowledge-maintainer for consolidation + ai-block authoring, (2) LOOPS the raw-drainer worker
# until the inbox makes no further progress (the truncation-safe drain), and (3) reindexes at the
# end. The loop is what fixes the in-context drain truncation.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
S="$ROOT/skills/maintain/SKILL.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

[ -f "$S" ] || fail "skills/maintain/SKILL.md missing"
grep -q '^name: maintain$' "$S" || fail "name is not 'maintain'"
grep -q '^user-invocable: true$' "$S" || fail "not user-invocable"
grep -qE '^allowed-tools:.*[[:space:]]Agent([[:space:]]|$)' "$S" || fail "allowed-tools must include Agent (to dispatch agents)"
pass "maintain skill is user-invocable + declares Agent"

# Stage 1: consolidation via the NAMESPACED maintainer subagent_type.
grep -q 'second-brain:knowledge-maintainer' "$S" \
  || fail "must dispatch via the namespaced subagent_type second-brain:knowledge-maintainer"
grep -qE '4c|raw[- ]inbox' "$S" || fail "body does not mention the raw-inbox drain"
pass "dispatches second-brain:knowledge-maintainer (consolidation) + names the raw drain"

# Stage 2: the looped raw-drainer worker — the truncation-safe drain.
grep -q 'second-brain:raw-drainer' "$S" \
  || fail "must dispatch the namespaced subagent_type second-brain:raw-drainer for the drain loop"
# Non-vacuous: assert the concrete loop control flow in the BODY (the frontmatter description
# mentions 'looped' — don't let that string alone satisfy the check).
grep -qiE 'dispatch the worker again|loop, up to' "$S" || fail "does not describe the re-dispatch loop body"
grep -qE '30[- ]iteration|hard cap of \*\*30' "$S" || fail "missing the 30-iteration fail-loud cap"
grep -qE 'DRAINED|REMAINING' "$S" \
  || fail "does not key the loop on the worker's DRAINED/REMAINING report"
pass "loops second-brain:raw-drainer until no progress (DRAINED/REMAINING, 30-iteration cap)"

# Stage 3: a final reindex after the drain added pages — the MCP tool must be allowed + invoked.
grep -qE '^allowed-tools:.*knowledge_reindex' "$S" \
  || fail "allowed-tools must include the knowledge_reindex MCP tool for the final reindex"
# Non-vacuous: the allowed-tools line already contains knowledge_reindex, so assert the BODY's
# Stage 3 invocation distinctly.
grep -qE '## Stage 3' "$S" || fail "missing the Stage 3 (final reindex) section"
grep -qiE 'call the .knowledge_reindex. MCP tool' "$S" \
  || fail "Stage 3 does not invoke the knowledge_reindex MCP tool in the body"
pass "final reindex is allowed + invoked (Stage 3 body call)"

echo; echo "ALL PASS"
