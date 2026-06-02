#!/bin/bash
# Guard: dream is ai-block AWARE but surface-only (never authors blocks in staging), and gates
# behind SB_DREAM_AI_BLOCKS. Both the skill and the runner agent must agree (inline/background parity).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
S="$ROOT/skills/dream/SKILL.md"; R="$ROOT/agents/dream-runner.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
for f in "$S" "$R"; do
  b=$(basename "$f")
  [ -f "$f" ] || fail "$b not found"
  grep -qiE 'ai-block|ai:begin' "$f" || fail "$b: no ai-block awareness"
  grep -qiE 'surface|count|recommend|report' "$f" || fail "$b: no surface-only language"
  grep -q 'SB_DREAM_AI_BLOCKS' "$f" || fail "$b: missing SB_DREAM_AI_BLOCKS kill switch"
  # require the literal do-NOT-author negation (not a loose 'maintainer' match that an
  # author-in-staging instruction would also satisfy)
  grep -qiE 'do not author|never author|not author' "$f" || fail "$b: missing the explicit do-NOT-author-in-staging negation"
  grep -qiE '/second-brain:maintain|run .*maintain' "$f" || fail "$b: does not point at the maintainer for authoring"
  pass "$b: ai-block surface-only, defers authoring to maintainer, kill-switch present"
done
echo; echo "ALL PASS"
