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

# Prompt instructs refresh on update (so the extractor actually emits a block for update actions).
grep -qiE 'ai_block.*(update|refresh)|(update|refresh).*ai.?block|refresh.*in place' "$ROOT/scripts/extract-prompt.txt" \
  || fail "extract-prompt.txt does not instruct emitting/refreshing ai_block on update"
pass "extract-prompt instructs ai_block refresh on update"

echo; echo "ALL PASS"
