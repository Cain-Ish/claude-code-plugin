#!/bin/bash
# Guard: the runtime-premise reviewer agent exists, is READ-ONLY (no exec over PR
# content — the trust boundary the whole lens depends on), and its prompt carries the
# premise taxonomy + the proof_probe/established output contract.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
F="$ROOT/agents/code-review-premise-reviewer.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -f "$F" ] || fail "agent file missing: $F"

# 1. read-only tools — ALLOWLIST (not a denylist): every Bash(...) grant must be a
#    read-only git/grep form. A denylist (reject node/bash) would let Bash(sh *), Bash(*),
#    Bash(./x) slip through and hand this PR-influenced agent exec rights — the exact trust
#    boundary the lens depends on.
tools=$(grep -m1 '^tools:' "$F") || fail "no tools: line"
bad=$(echo "$tools" | grep -oE 'Bash\([^)]*' | grep -vE 'Bash\((git (diff|log|blame)|grep)' || true)
[ -n "$bad" ] && fail "non-read-only tool grant(s) — exec over PR content breaks the trust boundary: $bad"
echo "$tools" | grep -qE '(^|[:, ])Bash([, ]|$)' && fail "must not have unscoped (bare) Bash: $tools"
for g in 'Read' 'Bash(git diff' 'Bash(git log' 'Bash(grep'; do
  echo "$tools" | grep -qF "$g" || fail "tools: missing read-only grant '$g'"
done
pass "agent is read-only (allowlist: Read + git diff/log/blame + grep only)"

# 2. the 6-premise taxonomy — anchored to the ENUMERATED BODY (bold headers), not the
#    one-line description (which abbreviates the same words and would pass vacuously).
for t in '**Environment variables**' '**Filesystem**' '**Process & runtime state**' '**Cross-process shared state' '**External services' '**Platform**'; do
  grep -qF "$t" "$F" || fail "taxonomy header missing from the enumerated body: '$t'"
done
pass "6-premise taxonomy present (anchored to the enumerated body)"

# 3. the asymmetric-fallback hunt (our exact bug)
grep -qi 'fallback' "$F" || fail "prompt must call out the asymmetric-fallback trap"
pass "asymmetric-fallback trap present"

# 4. output contract: category premise + proof_probe + established
for k in 'premise' 'proof_probe' 'established'; do
  grep -qF "$k" "$F" || fail "output contract missing field: '$k'"
done
pass "output contract present"

echo; echo "ALL PASS"
