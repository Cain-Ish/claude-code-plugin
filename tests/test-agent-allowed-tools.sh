#!/bin/bash
# Guard: an agent whose body invokes `node` or a `bash "$CLAUDE_PLUGIN_ROOT/…"` script must
# DECLARE the matching grant in its `tools:` frontmatter, else the call prompts/denies mid-run.
# This is the same missing-grant class that hid the maintainer's missing Bash(node *) for ~10
# releases (skills are guarded by test-skill-allowed-tools.sh; agents had no guard until now).
# Body-scan matches invocation patterns (node + quote/$, bash + ${CLAUDE_PLUGIN_ROOT}) to avoid
# matching prose mentions.
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
echo; echo "ALL PASS"
