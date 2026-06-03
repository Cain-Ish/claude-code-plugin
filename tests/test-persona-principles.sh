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

echo; echo "ALL PASS"
