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
  grep -qiE 'surface|suggest|recommend|report' "$f" || fail "$b: no surface-only language"
  grep -q 'SB_DREAM_AI_BLOCKS' "$f" || fail "$b: missing SB_DREAM_AI_BLOCKS kill switch"
  grep -qiE 'do not author|never author|not.*hand-author|maintainer' "$f" || fail "$b: does not defer authoring to the maintainer"
  pass "$b: ai-block surface-only, defers to maintainer, kill-switch present"
done
echo; echo "ALL PASS"
