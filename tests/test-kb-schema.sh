#!/bin/bash
# Guard: the KB single source of truth. kb-schema.json is valid; the bash loader (kb-schema.sh)
# exports SB_* lists that match it; and NO script/skill hardcodes a divergent category list — every
# consumer derives from the manifest. (The TS side is covered by mcp/src/constants/kb-schema.test.ts.)
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
M="$ROOT/kb-schema.json"
fail(){ echo "FAIL: $1"; printf '%s\n' "${2:-}" | sed 's/^/    /'; exit 1; }; pass(){ echo "PASS: $1"; }

[ -f "$M" ] || fail "kb-schema.json missing"
jq -e . "$M" >/dev/null 2>&1 || fail "kb-schema.json is not valid JSON"
pass "kb-schema.json present + valid"

# bash loader exports match the manifest exactly
SB_KB_SCHEMA="$M"; source "$ROOT/scripts/kb-schema.sh"
[ "$SB_STRUCTURED_TYPES" = "$(jq -r '.structured_types|join(" ")' "$M")" ] || fail "SB_STRUCTURED_TYPES != manifest"
[ "$SB_CONTENT_CATEGORIES" = "$(jq -r '(.structured_types+.unstructured_types)|join(" ")' "$M")" ] || fail "SB_CONTENT_CATEGORIES != manifest"
[ "$SB_ALL_CATEGORIES" = "$(jq -r '(.structured_types+.unstructured_types+.generated_dirs)|join(" ")' "$M")" ] || fail "SB_ALL_CATEGORIES != manifest"
[ "$SB_FORGET_PROTECTED" = "$(jq -r '.forget_protection.protected|join(" ")' "$M")" ] || fail "SB_FORGET_PROTECTED != manifest"
[ "$SB_EDGE_TYPES" = "$(jq -r '.edge_types|join(" ")' "$M")" ] || fail "SB_EDGE_TYPES != manifest"
pass "bash loader (kb-schema.sh) exports match the manifest"

# the six structured types are exactly as expected (anchor against accidental edit)
[ "$SB_STRUCTURED_TYPES" = "learnings decisions entities issues concepts security" ] \
  || fail "structured_types unexpected: $SB_STRUCTURED_TYPES"
pass "structured_types = the canonical six"

# DRIFT GUARD: no script/skill may hardcode the six-type loop — it must use \$SB_STRUCTURED_TYPES.
H=$(grep -rnE 'for [a-z]+ in learnings decisions entities issues concepts security' "$ROOT/scripts" "$ROOT/skills" 2>/dev/null \
      | grep -vF 'SB_STRUCTURED_TYPES' || true)
[ -z "$H" ] && pass "no hardcoded six-type loop (all use \$SB_STRUCTURED_TYPES)" \
  || fail "hardcoded six-type loop found (source kb-schema.sh + use \$SB_STRUCTURED_TYPES):" "$H"

echo; echo "ALL PASS"
