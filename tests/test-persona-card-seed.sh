#!/bin/bash
# Guard: the persona-card seed templates (auto-seed in persona-context.sh + the setup-skill
# scaffold) must be GENERIC — no plugin-author-specific content, no asserted identity. Caught
# 2026-06-03: setup shipped "skill bodies under ~500 lines; extract templates to siblings" as
# the default persona, leaking the author's conventions to every fresh install, and defaulted
# the identity to "senior engineer" (false on an empty KB). Both seeds must stay neutral.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SETUP="$ROOT/skills/setup/SKILL.md"; PCTX="$ROOT/scripts/persona-context.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
for f in "$SETUP" "$PCTX"; do
  b=$(basename "$f")
  [ -f "$f" ] || fail "$b not found"
  grep -qiE 'skill bodies under|extract templates to siblings' "$f" \
    && fail "$b: persona seed leaks a plugin-author convention (skill bodies / extract templates)"
  grep -qE '\$\{ROLE:-senior engineer\}' "$f" \
    && fail "$b: persona seed defaults identity to 'senior engineer' (asserts a false identity on an empty KB)"
  pass "$b: persona seed is generic (no author leftover, no asserted identity)"
done
# Both seeds carry the same neutral role-placeholder default (consistency, not divergence).
for f in "$SETUP" "$PCTX"; do
  grep -qF '${ROLE:-(set your role' "$f" || fail "$(basename "$f"): missing the neutral \${ROLE:-(set your role…)} default"
done
pass "both seeds use the same neutral role placeholder (no divergence)"
echo; echo "ALL PASS"
