#!/usr/bin/env bash
# Verify all user-invoked scripts in the repo carry the executable bit in git.
# Why: shipping a CLI without the exec bit means every install (or cache
# refresh) produces a non-executable file. Caught v2.11.0 → 2.11.1 regression
# where bin/sb was stored as 0644 in git and silently broke the documented
# `ln -s bin/sb ~/.local/bin/sb` install path.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Files that MUST have the exec bit set in git. Add new entrypoints here.
EXEC_FILES=(
  "bin/sb"
  "bin/sb.cmd"
  "bin/install-vector-deps.sh"
  ".githooks/pre-push"
  "tests/run-all.sh"
)

failed=0
for f in "${EXEC_FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: $f does not exist (test list is stale)"
    failed=1
    continue
  fi
  mode=$(git ls-files --stage "$f" 2>/dev/null | awk '{print $1}')
  if [ -z "$mode" ]; then
    # Not tracked yet — fine (e.g., new entrypoints not yet added).
    continue
  fi
  if [ "$mode" != "100755" ]; then
    echo "FAIL: $f stored in git as $mode (expected 100755)"
    echo "      fix: git update-index --chmod=+x \"$f\""
    failed=1
  else
    echo "PASS: $f → 100755"
  fi
done

if [ "$failed" -eq 0 ]; then
  echo "ALL PASS"
fi
exit "$failed"
