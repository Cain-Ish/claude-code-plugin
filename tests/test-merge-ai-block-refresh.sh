#!/bin/bash
# Phase 3: merge-project-update.sh refreshes the authored ai-block on UPDATE (not just create).
# Replace-in-place when a complete region exists; inject when absent; never corrupt a malformed page.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SCRIPT="$ROOT/scripts/merge-project-update.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || fail "jq required"
command -v node >/dev/null 2>&1 || { echo "SKIP: node required"; exit 0; }
[ -f "$ROOT/mcp/dist/tools/ai-block-render-cli.bundle.js" ] || { echo "SKIP: render CLI not built"; exit 0; }

KD="$TMP/knowledge"; mkdir -p "$KD/wiki/learnings"
PROJ="$TMP/PROJECT.md"
printf '%s\n' '# PROJECT: t' '## Goal' 'g.' '## State' 's.' '<!-- last_updated: 2026-05-01T00:00:00Z -->' > "$PROJ"
run(){ jq -nc "$1" | "$SCRIPT" --project-md "$PROJ" --knowledge-dir "$KD" >/dev/null 2>&1; }

# 1) create page WITH a block, then UPDATE with a fresh block -> block REPLACED in place, one region.
run '{recent_decisions:[],open_blockers:[],cross_refs:[],files_touched:[],
  wiki_updates:[{category:"learnings",slug:"refr",action:"create",title:"R",description:"d",
    content:"original prose body line.",ai_block:{claim:"old claim",action:"old action"}}]}' || fail "create exited nonzero"
run '{recent_decisions:[],open_blockers:[],cross_refs:[],files_touched:[],
  wiki_updates:[{category:"learnings",slug:"refr",action:"update",title:"R",description:"d",
    content:"a brand new distinct second observation.",ai_block:{claim:"new claim",action:"new action"}}]}' || fail "update exited nonzero"
P="$KD/wiki/learnings/refr.md"
[ "$(grep -c '<!-- ai:begin' "$P")" -eq 1 ] || fail "expected exactly one ai:begin after refresh, got $(grep -c '<!-- ai:begin' "$P")"
grep -q '^claim: new claim$' "$P" || fail "block not refreshed (claim still old)"
grep -q 'old claim' "$P" && fail "stale block field 'old claim' survived the refresh"
grep -q 'original prose body line' "$P" || fail "original prose lost during refresh"
grep -q 'brand new distinct second observation' "$P" || fail "appended update content lost"
pass "UPDATE replaces an existing ai-block in place, preserving prose"

# 2) page with NO block gets one INJECTED on update (after frontmatter, before H1).
printf '%s\n' '---' 'title: Inj' 'type: learnings' 'created: 2026-05-01T00:00:00Z' 'updated: 2026-05-01T00:00:00Z' '---' '' '# Inj' '' 'long standing prose.' > "$KD/wiki/learnings/inj.md"
run '{recent_decisions:[],open_blockers:[],cross_refs:[],files_touched:[],
  wiki_updates:[{category:"learnings",slug:"inj",action:"update",title:"Inj",description:"d",
    content:"some genuinely new appended detail here.",ai_block:{claim:"injected claim",action:"do"}}]}' || fail "inject-update nonzero"
I="$KD/wiki/learnings/inj.md"
grep -q '<!-- ai:begin' "$I" || fail "block not injected into a previously-blockless page on update"
grep -q '^claim: injected claim$' "$I" || fail "injected block missing claim"
awk 'BEGIN{fm=0} /^---[[:space:]]*$/{fm++} fm>=2 && /<!-- ai:begin/{ok=1} /^# Inj/{ if(!ok) exit 1; exit 0 } END{exit (ok?0:1)}' "$I" || fail "injected block not between frontmatter and H1"
pass "UPDATE injects a block into a previously-blockless page (after frontmatter, before H1)"

# 3) malformed page (ai:begin without ai:end) is left UNTOUCHED -- never eat the body.
printf '%s\n' '---' 'title: Bad' 'type: learnings' 'updated: 2026-05-01T00:00:00Z' '---' '<!-- ai:begin -->' 'claim: dangling' '' '# Bad' 'irreplaceable prose tail.' > "$KD/wiki/learnings/bad.md"
run '{recent_decisions:[],open_blockers:[],cross_refs:[],files_touched:[],
  wiki_updates:[{category:"learnings",slug:"bad",action:"update",title:"Bad",description:"d",
    content:"new line for the malformed page.",ai_block:{claim:"replacement",action:"do"}}]}' || true
grep -q 'irreplaceable prose tail' "$KD/wiki/learnings/bad.md" || fail "malformed page body was eaten by the refresh"
[ "$(grep -c 'ai:begin' "$KD/wiki/learnings/bad.md")" -eq 1 ] || fail "refresh added a second begin marker to a malformed page"
pass "malformed (begin-without-end) page is not corrupted by refresh"

# 4) a real COMPLETE block at top + an inline <!-- ai:begin --> in PROSE: refresh must replace ONLY
#    the first (real) block and must NOT re-arm drop on the prose mention (else it eats to EOF --
#    the FORGET-bug class, realistic on this repo's own ai-block-documenting pages).
{
  printf '%s\n' '---' 'title: Inline' 'type: learnings' 'updated: 2026-05-01T00:00:00Z' '---'
  printf '%s\n' '<!-- ai:begin (authored) -->' 'claim: orig claim' 'action: orig' '<!-- ai:end -->'
  printf '%s\n' '' '# Inline' '' 'Prose before the mention.' \
    'Docs note: a page may contain <!-- ai:begin --> in its prose.' \
    'stray inline line' 'FINAL TAIL must survive.'
} > "$KD/wiki/learnings/inline.md"
run '{recent_decisions:[],open_blockers:[],cross_refs:[],files_touched:[],
  wiki_updates:[{category:"learnings",slug:"inline",action:"update",title:"Inline",description:"d",
    content:"a fresh distinct observation for the inline page.",ai_block:{claim:"fresh claim",action:"do"}}]}' || fail "inline-update nonzero"
N="$KD/wiki/learnings/inline.md"
grep -q 'FINAL TAIL must survive' "$N" || fail "prose tail after an inline ai:begin was eaten (FORGET-bug re-introduced)"
grep -q '^claim: fresh claim$' "$N" || fail "real block not refreshed"
grep -q 'orig claim' "$N" && fail "stale real-block field survived"
grep -q 'Docs note: a page may contain' "$N" || fail "inline prose mention was lost"
pass "a stray ai:begin in prose cannot re-arm the drop or eat the body"

# 5) dedup-skip must STILL refresh the block (refresh runs before the prose-dedup early-continue).
run '{recent_decisions:[],open_blockers:[],cross_refs:[],files_touched:[],
  wiki_updates:[{category:"learnings",slug:"dedup",action:"create",title:"Dedup",description:"d",
    content:"IDENTICAL DEDUP SENTINEL CONTENT for the dedup page.",ai_block:{claim:"v1 claim",action:"a"}}]}' || fail "dedup-create nonzero"
run '{recent_decisions:[],open_blockers:[],cross_refs:[],files_touched:[],
  wiki_updates:[{category:"learnings",slug:"dedup",action:"update",title:"Dedup",description:"d",
    content:"IDENTICAL DEDUP SENTINEL CONTENT for the dedup page.",ai_block:{claim:"v2 claim",action:"a"}}]}' || fail "dedup-update nonzero"
D="$KD/wiki/learnings/dedup.md"
grep -q '^claim: v2 claim$' "$D" || fail "block NOT refreshed when prose was a duplicate (refresh must precede the dedup continue)"
grep -q 'v1 claim' "$D" && fail "stale block survived the dedup-skipped refresh"
pass "block refresh runs even when the prose content is a duplicate"

# Prompt instructs refresh on update (so the extractor actually emits a block for update actions).
grep -qiE 'ai_block.*(update|refresh)|(update|refresh).*ai.?block|refresh.*in place' "$ROOT/scripts/extract-prompt.txt" \
  || fail "extract-prompt.txt does not instruct emitting/refreshing ai_block on update"
pass "extract-prompt instructs ai_block refresh on update"

echo; echo "ALL PASS"
