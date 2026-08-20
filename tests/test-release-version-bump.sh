#!/usr/bin/env bash
# Release version-bump tripwire — the gap that let #79 ship 0.30.2's code as
# "0.30.1". The existing guards are blind to it: test-upgrade-migration-row.sh
# only checks migration-file hygiene against plugin.json's version (stale-but-
# consistent passes), and validate-plugin.sh's drift check only compares
# plugin.json against marketplace.json (both stale -> they agree -> pass). Neither
# has a notion of "the previous release", so "changed shipped code without bumping
# the version" sails through a fully-green suite.
#
# Independent oracle (per the repo convention: tests verify a real fact, never
# re-assert the implementation through its own reader): the *previous release* is
# the base branch (origin/main) — a git fact, not something this code computes.
# Contract: if the working tree changes any SHIPPED second-brain source versus the
# base, plugin.json's version MUST be strictly greater than the base's version.
#
# Base ref resolution: $SB_RELEASE_BASE_REF -> origin/main -> SKIP (a clone with
# no base ref, e.g. a shallow CI checkout, can't compare; CI fetches it — see
# .github/workflows/ci.yml). SKIP never blocks; it just can't assert.
#
# Portability: bash 3.2 / BSD-safe (no `sort -V`, no bash-4 isms); jq output is
# CRLF-stripped (Windows Git-Bash jq emits CRLF even on LF input).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
fail() { echo "FAIL: $1"; exit 1; }

# SHIPPED second-brain surface — a change here is a release and must bump the
# version. Excludes: docs/ (narrative), tests/ (a test-only change is not a
# release), package-lock.json (npm churn), marketplace.json (its second-brain
# entry mirrors plugin.json, which is already a trigger).
# model-ladder.json is behaviour-defining DATA, not config: every model the
# plugin spawns resolves through its ladders, so editing a rung changes shipped
# behaviour exactly like a scripts/ edit and must force a bump.
TRIGGERS="mcp/src mcp/dist mcp/package.json model-ladder.json scripts hooks skills agents bin systemd .claude-plugin/plugin.json .claude-plugin/mcp.json"

# --- resolve the base (previous release) ref ------------------------------------
BASE_REF="${SB_RELEASE_BASE_REF:-}"
if [ -z "$BASE_REF" ] && git -C "$REPO_ROOT" rev-parse --verify -q origin/main >/dev/null 2>&1; then
  BASE_REF="origin/main"
fi
if [ -z "$BASE_REF" ] || ! git -C "$REPO_ROOT" rev-parse --verify -q "$BASE_REF" >/dev/null 2>&1; then
  echo "SKIP: no base ref to compare against (set SB_RELEASE_BASE_REF or fetch origin/main)"
  exit 0
fi

# --- did any shipped source change vs the base? ---------------------------------
# Two-dot `git diff <base> -- <paths>` compares base against the WORKING TREE, so
# this fires pre-commit (local) and on the committed PR head (CI) alike.
CHANGED=$(git -C "$REPO_ROOT" diff --name-only "$BASE_REF" -- $TRIGGERS 2>/dev/null || true)
if [ -z "$CHANGED" ]; then
  echo "PASS: no shipped second-brain source changed vs $BASE_REF — no version bump required"
  exit 0
fi

# --- versions: current (working tree) vs base (the release we'd be shipping over) --
CUR_VER=$(jq -r '.version // empty' "$PLUGIN_JSON" 2>/dev/null | tr -d '\r')
# MSYS_NO_PATHCONV=1 on the `git show` ONLY: Git-Bash rewrites the `<ref>:<path>` argument into
# a Windows path ("origin\main;.claude-plugin\plugin.json"), git errors, BASE_VER comes back
# empty, and the fallback below silently turned it into 0.0.0 — so ANY version compared greater
# and this tripwire reported PASS on every Windows run since it was written. A release gate that
# always passes is worse than none: it is exactly how 0.43.0's code shipped unbumped through a
# fully-green local suite. Scoped to this one call because exporting it script-wide breaks the
# `rev-parse --verify origin/main` probe above.
BASE_JSON=$(cd "$REPO_ROOT" && MSYS_NO_PATHCONV=1 git show "$BASE_REF:.claude-plugin/plugin.json" 2>/dev/null)
if [ -z "$BASE_JSON" ]; then
  # Distinguish "no plugin.json at base" (legitimate: a very old base, any release is a bump)
  # from "the read FAILED" (a broken gate). Only the first may default to 0.0.0.
  if (cd "$REPO_ROOT" && MSYS_NO_PATHCONV=1 git cat-file -e "$BASE_REF:.claude-plugin/plugin.json") 2>/dev/null; then
    fail "could not read plugin.json at $BASE_REF although it exists there — the version gate cannot compare and must not pass silently"
  fi
  BASE_VER="0.0.0"
else
  BASE_VER=$(printf '%s' "$BASE_JSON" | jq -r '.version // empty' 2>/dev/null | tr -d '\r')
  [ -n "$BASE_VER" ] || fail "plugin.json at $BASE_REF has no .version — cannot compare"
fi

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
if ! printf '%s' "$CUR_VER" | grep -qE "$SEMVER_RE"; then
  fail "plugin.json version '$CUR_VER' is not a clean x.y.z semver — cannot enforce the bump"
fi
if ! printf '%s' "$BASE_VER" | grep -qE "$SEMVER_RE"; then
  echo "SKIP: base version '$BASE_VER' at $BASE_REF is not clean x.y.z — cannot compare"
  exit 0
fi

# strictly-greater dotted-numeric compare (no `sort -V`: BSD/macOS sort lacks it)
ver_gt() { # ver_gt A B  -> success iff A > B
  a1=${1%%.*}; ar=${1#*.}; a2=${ar%%.*}; a3=${ar#*.}
  b1=${2%%.*}; br=${2#*.}; b2=${br%%.*}; b3=${br#*.}
  [ "$a1" -ne "$b1" ] && { [ "$a1" -gt "$b1" ]; return; }
  [ "$a2" -ne "$b2" ] && { [ "$a2" -gt "$b2" ]; return; }
  [ "$a3" -gt "$b3" ]
}

if ver_gt "$CUR_VER" "$BASE_VER"; then
  echo "PASS: shipped source changed and version bumped $BASE_VER -> $CUR_VER (vs $BASE_REF)"
  echo "      (changed: $(printf '%s\n' "$CHANGED" | grep -c .) file(s))"
  exit 0
fi

# The #79 failure mode: code shipped, version unchanged (or downgraded).
echo "----- shipped files changed vs $BASE_REF without a version bump -----"
printf '%s\n' "$CHANGED" | sed 's/^/    /'
fail "version is '$CUR_VER' but base ($BASE_REF) is already '$BASE_VER' — bump .claude-plugin/plugin.json + marketplace.json before shipping. No bump = incomplete release."
