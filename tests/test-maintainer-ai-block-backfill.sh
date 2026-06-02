#!/bin/bash
# Guard: the knowledge-maintainer knows how to backfill ai-blocks (Phase 4b), uses the
# deterministic candidate script + render path, and inherits the closed-vocab / cap /
# explicit-invocation boundary. Prompt-only guard (greps the agent contract).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; M="$ROOT/agents/knowledge-maintainer.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -f "$M" ] || fail "knowledge-maintainer.md not found"
grep -qiE 'Phase 4b|ai-block authoring|backfill' "$M" || fail "no Phase 4b / backfill section"
grep -q 'kb-ai-block-candidates.sh' "$M" || fail "does not reference the candidate work-list script"
grep -qiE 'renderAiBlock|ai-block-render-cli|render CLI' "$M" || fail "no render path referenced"
grep -qiE 'validateAiBlock|knowledge_validate' "$M" || fail "no self-validation referenced"
grep -qiE 'six (structured|known) types|closed[- ]vocab' "$M" || fail "closed-vocabulary boundary not stated"
grep -qiE 'never invent|extract.*from.*(prose|existing)|do not hallucinate' "$M" || fail "never-invent-values rule absent"
grep -qiE '50.*change|counted against|cap' "$M" || fail "cap inheritance not stated"
grep -qiE 'explicitly invoked|explicit-invocation|only on an explicit' "$M" || fail "explicit-invocation boundary not stated"
# The Autonomous Dispatch section must carve out Phase 4b (else it contradicts the boundary).
grep -qiE 'skip.*Phase 4b|Phase 4b.*skip' "$M" || fail "Autonomous Dispatch does not carve out Phase 4b (contradiction)"
pass "maintainer Phase 4b contract present (candidate script + render + validate + closed-vocab + cap + never-invent + explicit-invocation + dispatch carve-out)"
echo; echo "ALL PASS"
