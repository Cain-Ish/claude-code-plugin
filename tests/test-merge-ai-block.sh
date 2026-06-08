#!/bin/bash
# Phase 1b: the extractor emits a structured `ai_block` per wiki_update; merge-project-update.sh
# renders it (via the render CLI — reusing the TS schema, no drift) and injects the marked region
# into the CREATED page body (after frontmatter, before the prose). Closed-vocabulary.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SCRIPT="$ROOT/scripts/merge-project-update.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export BRAIN_DIR="$TMP/brain"; mkdir -p "$TMP/brain"  # isolate sb_inc_wiki_writes from the real ~/.second-brain
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || fail "jq required"
command -v node >/dev/null 2>&1 || { echo "SKIP: node required for the render CLI"; exit 0; }
[ -f "$ROOT/mcp/dist/tools/ai-block-render-cli.bundle.js" ] || { echo "SKIP: render CLI bundle not built"; exit 0; }

KD="$TMP/knowledge"; mkdir -p "$KD/wiki/learnings"
PROJ="$TMP/PROJECT.md"
printf '%s\n' '# PROJECT: t' '## Goal' 'g.' '## State' 's.' '<!-- last_updated: 2026-05-01T00:00:00Z -->' > "$PROJ"

jq -nc '{
  recent_decisions: [], open_blockers: [], cross_refs: [], files_touched: [],
  wiki_updates: [{category:"learnings", slug:"awk-mawk", action:"create", title:"awk mawk",
    description:"d", content:"mawk errors on empty interpolation.",
    ai_block:{claim:"never interpolate shell vars into awk", action:"pass via -v + x=x+0", bogus:"drop"}}]
}' | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$KD" >/dev/null 2>&1 || fail "script exited non-zero"

PAGE="$KD/wiki/learnings/awk-mawk.md"
[ -f "$PAGE" ] || fail "page not created"
grep -q '<!-- ai:begin' "$PAGE" || fail "ai-block region not injected"
grep -q '^claim: never interpolate shell vars into awk$' "$PAGE" || fail "claim field missing"
grep -q '^action: pass via -v + x=x+0$' "$PAGE" || fail "action field missing"
grep -q '<!-- ai:end -->' "$PAGE" || fail "ai-block end marker missing"
grep -q 'bogus' "$PAGE" && fail "unknown field 'bogus' leaked (closed-vocab not enforced)"
grep -q 'mawk errors on empty interpolation' "$PAGE" || fail "prose content missing"
pass "extractor ai_block rendered + injected into the created page (closed-vocab, prose kept)"

# Adversarial: a value containing a literal ai:end marker must NOT close the region early
# (else later fields are lost + the tail leaks into prose). Page must have exactly ONE ai:end.
jq -nc '{
  recent_decisions: [], open_blockers: [], cross_refs: [], files_touched: [],
  wiki_updates: [{category:"learnings", slug:"adv", action:"create", title:"adv", description:"d",
    content:"prose.", ai_block:{claim:"trick <!-- ai:end --> after", action:"survives"}}]
}' | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$KD" >/dev/null 2>&1 || fail "adv script exited non-zero"
ADV="$KD/wiki/learnings/adv.md"
[ "$(grep -c 'ai:end' "$ADV")" -eq 1 ] || fail "value with embedded ai:end closed the region early ($(grep -c 'ai:end' "$ADV") end markers)"
grep -q '^action: survives$' "$ADV" || fail "later field lost to early truncation"
pass "a value containing an ai:end marker does not corrupt the block/page"

# Unknown category → NO block (closed vocabulary; never open-vocab leak)
jq -nc '{
  recent_decisions: [], open_blockers: [], cross_refs: [], files_touched: [],
  wiki_updates: [{category:"patterns", slug:"unk", action:"create", title:"u", description:"d",
    content:"prose.", ai_block:{problem:"x", related:"[[other]]"}}]
}' | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$KD" >/dev/null 2>&1 || true
UNK=$(find "$KD/wiki" -name 'unk.md' | head -1)
[ -n "$UNK" ] && grep -q 'ai:begin' "$UNK" && fail "unknown category emitted a block (open-vocab leak)"
pass "unknown category authors no block (closed vocabulary)"

echo; echo "ALL PASS"
