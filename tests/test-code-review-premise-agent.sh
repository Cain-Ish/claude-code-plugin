#!/bin/bash
# Guard: the runtime-premise reviewer agent exists, is READ-ONLY (no exec over PR
# content — the trust boundary the whole lens depends on), and its prompt carries the
# premise taxonomy + the proof_probe/established output contract.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
F="$ROOT/agents/code-review-premise-reviewer.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -f "$F" ] || fail "agent file missing: $F"

# 1. read-only tools: Read + git diff/log + grep only; NO exec (node / bash script), no bare Bash
tools=$(grep -m1 '^tools:' "$F") || fail "no tools: line"
echo "$tools" | grep -qE 'Bash\((node|bash )' && fail "must be read-only — exec grant found: $tools"
echo "$tools" | grep -qE '(^|[:, ])Bash([, ]|$)' && fail "must not have unscoped Bash: $tools"
for g in 'Read' 'Bash(git diff' 'Bash(git log' 'Bash(grep'; do
  echo "$tools" | grep -qF "$g" || fail "tools: missing read-only grant '$g'"
done
pass "agent is read-only (Read + git diff/log + grep only)"

# 2. the 6-premise taxonomy
for t in 'nvironment variable' 'ilesystem' 'rocess' 'shared state' 'ervice' 'latform'; do
  grep -qi "$t" "$F" || fail "taxonomy item missing: '$t'"
done
pass "6-premise taxonomy present"

# 3. the asymmetric-fallback hunt (our exact bug)
grep -qi 'fallback' "$F" || fail "prompt must call out the asymmetric-fallback trap"
pass "asymmetric-fallback trap present"

# 4. output contract: category premise + proof_probe + established
for k in 'premise' 'proof_probe' 'established'; do
  grep -qF "$k" "$F" || fail "output contract missing field: '$k'"
done
pass "output contract present"

echo; echo "ALL PASS"
