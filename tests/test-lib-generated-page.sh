#!/bin/bash
# tests/test-lib-generated-page.sh — R5.1 generated-page contract:
# sb_write_generated_page writes born-valid frontmatter (title/description/
# type: state/generated: true) + a do-not-hand-edit marker + the stdin body,
# atomically, preserving created: across regenerations.
set -u
REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"; export BRAIN_DIR="$SANDBOX/brain"; mkdir -p "$BRAIN_DIR"
fail() { echo "FAIL: $1"; exit 1; }

OUT="$SANDBOX/wiki/state/gen-page.md"
( source "$REPO_ROOT/scripts/lib.sh"
  printf '# Body\n\ncontent line\n' | sb_write_generated_page "$OUT" "Gen Page" "A generated test page" ) \
  || fail "helper returned nonzero"
[ -f "$OUT" ] || fail "page not written"
head -1 "$OUT" | grep -qx -- '---' || fail "missing frontmatter fence"
grep -q '^title: "Gen Page"' "$OUT" || fail "missing/wrong title"
grep -q '^type: state' "$OUT" || fail "missing type: state"
grep -q '^generated: true' "$OUT" || fail "missing generated: true"
grep -q 'do not hand-edit' "$OUT" || fail "missing generated marker"
grep -q 'content line' "$OUT" || fail "stdin body missing"

# INDEPENDENT ORACLE: "born-valid" means valid by the REAL validator, not a handpicked
# subset. Derive the canonical required-field set straight from knowledge-validate.ts's
# REQUIRED_FM_FIELDS so this test cannot drift from the validator (add an 8th required
# field there and this fails until the generator emits it). Pre-fix tags+related were
# absent and the page was born INCOMPLETE while these checks stayed green — the exact
# "test re-asserts a weaker notion than the oracle" gap.
VALIDATE_TS="$REPO_ROOT/mcp/src/tools/knowledge-validate.ts"
REQUIRED=$(grep -m1 'REQUIRED_FM_FIELDS *=' "$VALIDATE_TS" | grep -oE "'[a-z]+'" | tr -d "'")
[ -n "$REQUIRED" ] || fail "could not parse REQUIRED_FM_FIELDS from $VALIDATE_TS"
for k in $REQUIRED; do
  grep -qE "^${k}:" "$OUT" || fail "generated page NOT born-valid: missing required field '$k:' (validator flags incomplete_frontmatter)"
done
echo "PASS: born-valid against validator REQUIRED_FM_FIELDS — [$(echo "$REQUIRED" | tr '\n' ' ' | sed 's/ $//')]"

# created: survives regeneration; updated: refreshes.
sed -i.bak 's/^created: .*/created: 2020-01-01/' "$OUT" && rm -f "$OUT.bak"
( source "$REPO_ROOT/scripts/lib.sh"
  printf 'new body\n' | sb_write_generated_page "$OUT" "Gen Page" "A generated test page" )
grep -q '^created: 2020-01-01' "$OUT" || fail "created: not preserved across regeneration"
grep -q "^updated: $(date -u +%F)" "$OUT" || fail "updated: not refreshed"
grep -q 'new body' "$OUT" || fail "regenerated body missing"
grep -q 'content line' "$OUT" && fail "old body not replaced"

echo "PASS: sb_write_generated_page born-valid + created-preserving"
echo "ALL PASS"
