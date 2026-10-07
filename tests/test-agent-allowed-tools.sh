#!/bin/bash
# Guard: an agent whose body invokes `node` or a `bash "$CLAUDE_PLUGIN_ROOT/…"` script must
# DECLARE the matching grant in its `tools:` frontmatter, else the call prompts/denies mid-run.
# This is the same missing-grant class that hid the maintainer's missing Bash(node *) for ~10
# releases (skills are guarded by test-skill-allowed-tools.sh; agents had no guard until now).
# Body-scan matches invocation patterns (node + quote/$, bash + ${CLAUDE_PLUGIN_ROOT}) to avoid
# matching prose mentions. Known (currently-unused) blind spots, by design, to keep it
# false-positive-free: a script exec'd directly without a leading `bash ` prefix, and `node`
# captured via `$(…)`. No agent uses either today; widen the patterns if one ever does.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; A="$ROOT/agents"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -d "$A" ] || fail "agents/ dir missing"

checked=0
for f in "$A"/*.md; do
  name=$(basename "$f" .md)
  tools=$(grep -m1 '^tools:' "$f" || true)
  # node invocation: `node "` or `node '` or `node $`
  if grep -qE 'node ["'\''$]' "$f"; then
    printf '%s' "$tools" | grep -qE 'Bash\(node ' \
      || fail "$name: body invokes node but tools: lacks Bash(node *)"
  fi
  # bash-script invocation: `bash "$CLAUDE_PLUGIN_ROOT` or `bash "${CLAUDE_PLUGIN_ROOT`
  if grep -qE 'bash "\$\{?CLAUDE_PLUGIN_ROOT' "$f"; then
    printf '%s' "$tools" | grep -qE 'Bash\(bash ' \
      || fail "$name: body invokes a plugin bash script but tools: lacks Bash(bash *)"
  fi
  checked=$((checked + 1))
done
pass "all $checked agents declare the tools their bodies invoke (node / bash scripts)"

# R3-B X1: the dream-runner's Bash grants are the commands its documented steps run. Only its
# Write/Edit/MultiEdit are path-confined (protocol-guard.sh pg_dream_confine), so a grant that can
# write or execute anywhere undoes that: find (-exec/-delete), sed (-i, e), awk (system(),
# print >), cp, touch, mkdir, sort (-o), uniq (output file), and `bash` on ANY plugin script
# (dream-accept.sh would self-accept the dream). mv and rm stay (status/heartbeat, renames,
# removing a merged page) and are the residual its Constraints state.
DR="$A/dream-runner.md"
DRT=$(grep -m1 '^tools:' "$DR" || true)
DR_BAD=$(printf '%s' "$DRT" | grep -oE 'Bash\((find|sed|awk|cp|touch|mkdir|sort|uniq|chmod|ln|tee|xargs|perl|python[0-9]*|node)( [^)]*)?\)|Bash\(bash \$\{CLAUDE_PLUGIN_ROOT\}/scripts/\*\)' | tr '\n' ' ')
[ -z "$DR_BAD" ] || fail "dream-runner: write/exec-capable Bash grant(s) in tools: $DR_BAD"
DR_N=0
for s in $(grep -oE 'bash "\$\{?CLAUDE_PLUGIN_ROOT\}?/scripts/[a-z0-9-]+\.sh' "$DR" | sed 's#.*/scripts/##' | sort -u); do
  printf '%s' "$DRT" | grep -qF "Bash(bash \${CLAUDE_PLUGIN_ROOT}/scripts/$s" \
    || fail "dream-runner: the body runs scripts/$s but tools: has no pinned Bash(bash \${CLAUDE_PLUGIN_ROOT}/scripts/$s…) grant"
  DR_N=$((DR_N + 1))
done
[ "$DR_N" -ge 4 ] || fail "dream-runner: expected >=4 plugin scripts in the body, found $DR_N (the scan broke?)"
grep -q 'not path-confined' "$DR" || fail "dream-runner: Constraints do not state the Bash residual (\"not path-confined\")"
pass "dream-runner: no write/exec-capable Bash grant beyond mv/rm; each of its $DR_N plugin scripts has a pinned grant; the residual is stated"
echo; echo "ALL PASS"
