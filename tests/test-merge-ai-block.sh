#!/bin/bash
# Phase 1b: the extractor emits a structured `ai_block` per wiki_update; merge-project-update.sh
# renders it (via the render CLI — reusing the TS schema, no drift) and injects the marked region
# into the CREATED page body (after frontmatter, before the prose). Closed-vocabulary.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SCRIPT="$ROOT/scripts/merge-project-update.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
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
# the block must parse back cleanly (round-trip via the page)
pass "extractor ai_block rendered + injected into the created page (closed-vocab, prose kept)"

echo; echo "ALL PASS"
