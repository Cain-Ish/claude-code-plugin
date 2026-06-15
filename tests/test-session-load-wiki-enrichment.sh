#!/bin/bash
# 0.29.4: session-load.sh harvests PROJ_KW keywords from the active PROJECT.md and, when
# non-empty, calls the knowledge-search CLI to enrich the SessionStart context with the
# project's wiki notes. The harvest used awk RANGE expressions (/^## X$/,/^## /) whose
# START line also matches the END pattern, collapsing every range to its header → PROJ_KW
# was ALWAYS empty → the enrichment NEVER ran (every session silently missing wiki recall),
# and NO test covered it. ORACLE: stub `node` so the search CLI emits a sentinel ONLY when
# invoked with a non-empty query; the sentinel in the real session-load output proves the
# harvest produced keywords. With the range-collapse bug the gate is never taken, node is
# never called, and the sentinel is absent — so this test is discriminating.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SL="$ROOT/scripts/session-load.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
. "$ROOT/scripts/lib.sh" >/dev/null 2>&1

# The real search-CLI bundle must exist for session-load's `[ -f "$SEARCH_CLI" ]` gate;
# we don't run it — `node` is stubbed to stand in for it.
SEARCH_CLI="$ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"
[ -f "$SEARCH_CLI" ] || { echo "SKIP: search CLI bundle not built"; echo; echo "ALL PASS"; exit 0; }

STUB=$(mktemp -d)
printf '#!/bin/bash\nexit 0\n' > "$STUB/claude"; chmod +x "$STUB/claude"
# node stub: emit the sentinel ONLY for the knowledge-search CLI call AND only when the
# query (last arg) is non-empty — i.e. only when PROJ_KW actually harvested something.
cat > "$STUB/node" <<'NODE'
#!/bin/bash
case "$*" in
  *knowledge-search-cli*)
    q="${!#}"
    [ -n "${q// /}" ] && printf 'demo-note :: WIKIENRICH_SENTINEL'
    ;;
esac
exit 0
NODE
chmod +x "$STUB/node"

B=$(mktemp -d); PROJDIR=$(mktemp -d)
SLUG=$(sb_slug_from_dir "$PROJDIR")
mkdir -p "$B/projects/$SLUG" "$B/transcripts" "$B/knowledge/wiki"

# A realistically-populated PROJECT.md: every harvested section filled with words that
# survive the stopword filter (backbone, failover, BM25, escalation slugs).
cat > "$B/projects/$SLUG/PROJECT.md" <<'EOF'
# PROJECT: demo
## Goal
Build the Pi automation backbone with local-LLM failover.
## State
Router shipping; knowledge base self-healing.
## Recent decisions
- chose BM25 over pure vector for recall accuracy
## Open blockers
- vector dependencies offline on a fresh install
## Cross-references
See [[cost-router-patterns]] and [[crlf-frontmatter]].
EOF
printf '{"slug":"%s","path":"%s","plan_done":0,"plan_total":0}\n' "$SLUG" "$PROJDIR" > "$B/projects.jsonl"

OUT=$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$PROJDIR" \
  | env PATH="$STUB:$PATH" CLAUDE_PROJECT_DIR="$PROJDIR" BRAIN_DIR="$B" \
        KNOWLEDGE_DIR="$B/knowledge" ANTHROPIC_API_KEY="" bash "$SL" 2>/dev/null)

printf '%s' "$OUT" | grep -q 'WIKIENRICH_SENTINEL' \
  || fail "wiki-enrichment did not fire — PROJ_KW harvest is empty (awk range-collapse?); session starts without project wiki recall"
pass "PROJECT.md harvest is non-empty → wiki-enrichment invokes the search CLI (sentinel present)"

# 0.30.0 cross-OS: a CRLF PROJECT.md (Windows / imported) must NOT defeat the harvest. Every
# `/^## Section$/` awk reader fails on `## Section\r`, so without the CR-normalization the harvest
# is empty and the enrichment never fires — even though the same content works in LF above.
sed 's/$/\r/' "$B/projects/$SLUG/PROJECT.md" > "$B/projects/$SLUG/PROJECT.md.crlf" && mv "$B/projects/$SLUG/PROJECT.md.crlf" "$B/projects/$SLUG/PROJECT.md"
grep -q $'\r' "$B/projects/$SLUG/PROJECT.md" || fail "test setup: PROJECT.md is not actually CRLF"
OUT_CRLF=$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$PROJDIR" \
  | env PATH="$STUB:$PATH" CLAUDE_PROJECT_DIR="$PROJDIR" BRAIN_DIR="$B" \
        KNOWLEDGE_DIR="$B/knowledge" ANTHROPIC_API_KEY="" bash "$SL" 2>/dev/null)
printf '%s' "$OUT_CRLF" | grep -q 'WIKIENRICH_SENTINEL' \
  || fail "CRLF PROJECT.md defeated the harvest — session-load did not CR-normalize before the awk readers"
pass "CRLF PROJECT.md still harvests (session-load normalizes \\r before the awk readers)"

rm -rf "$B" "$PROJDIR" "$STUB"; echo; echo "ALL PASS"
