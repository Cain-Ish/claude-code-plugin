#!/bin/bash
# test-jq-e-empty-guard.sh — the suite's own deny-locks must not be neutered by jq 1.6.
#
# jq 1.6's -e flag exits 0 when stdin carries NO JSON value (empty or whitespace-only
# input); jq 1.7+ exits 4. Measured 2026-08-22 on a jq-1.6 host:
#   printf '' | jq -e '.a=="deny"'; echo $?   -> 0
# So a guard assertion shaped
#   echo "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' || fail
# PASSES when the guard SILENTLY ALLOWS (empty $out) on any jq-1.6 host — the one
# direction a guard lock exists to catch. Found 2026-08-22: the wiki-write-guard
# case-bypass produced empty output and 2 of 4 new locks "passed" against the broken
# guard for exactly this reason; 74 assertions across 8 guard-lane test files shared
# the shape. Rule: every piped-VARIABLE jq -e assertion in tests/ must require
# non-empty input on the same line:
#   [ -n "$out" ] && echo "$out" | jq -e ...
# (Under jq 1.7+ this changes nothing: empty already exits 4. The guard makes 1.6
# behave like 1.7.)
#
# Scope: tests/ only. scripts/ hooks pipe into jq -e too, but they deliberately
# fail OPEN on unparseable/empty input — that is their documented contract, not an
# assertion, so they are out of scope here.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SELF="test-jq-e-empty-guard.sh"

# Piped-variable forms: echo "$var" | jq -e   /   printf … "$var" | jq -e
PIPE_RE='(echo|printf)[^|]*"\$[A-Za-z_][A-Za-z0-9_]*" \| jq -e'
GUARD_RE='\[ -n "\$[A-Za-z_][A-Za-z0-9_]*" \] &&'

h=$(grep -nE "$PIPE_RE" "$ROOT"/tests/test-*.sh 2>/dev/null \
  | grep -v "$SELF" \
  | grep -vE ':[0-9]+:[[:space:]]*#' \
  | grep -vE "$GUARD_RE" || true)

if [ -z "$h" ]; then
  echo "PASS: every piped-variable jq -e assertion requires non-empty input first (jq-1.6 -e empty-input hole)"
  echo
  echo "ALL PASS"
else
  echo "FAIL: piped-variable jq -e assertion with no same-line [ -n \"\$var\" ] guard —"
  echo "on jq 1.6, -e exits 0 on empty input, so this assertion passes when the subject"
  echo "under test emits NOTHING (e.g. a guard that silently allows):"
  printf '%s\n' "$h" | sed 's/^/    /'
  exit 1
fi
