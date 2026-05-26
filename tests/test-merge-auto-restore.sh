#!/usr/bin/env bash
# Extraction must REVIVE an archived page (not create a duplicate) when a delta
# would re-create its slug.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MERGE="$ROOT/scripts/merge-project-update.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export BRAIN_DIR="$T/brain"; KD="$T/knowledge"
mkdir -p "$BRAIN_DIR/wiki-archive/concepts" "$KD/wiki/concepts"
PMD="$T/PROJECT.md"; printf '# proj\n\n## Recent decisions\n\n## Cross-references\n' > "$PMD"
# archived page 'widget-x' (lives in the archive, NOT in the live wiki) + log
printf -- '---\ntitle: "Widget X"\ntype: concepts\ndescription: "original widget x"\ntags: [widget]\n---\n# Widget X\noriginal body.\n' > "$BRAIN_DIR/wiki-archive/concepts/widget-x.md"
printf '%s\n' '{"event":"archived","slug":"widget-x","category":"concepts","date":"2026-05-26T01:00:00Z"}' > "$BRAIN_DIR/wiki-archive-log.jsonl"

P=0;F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
# delta tries to (re)create widget-x with new content
echo '{"wiki_updates":[{"category":"concepts","slug":"widget-x","action":"create","title":"Widget X","description":"d","content":"fresh info about widget x that resurged in a new session."}]}' \
  | bash "$MERGE" --project-md "$PMD" --knowledge-dir "$KD" >/dev/null 2>&1

[ -f "$KD/wiki/concepts/widget-x.md" ] && ok "page revived into live wiki" || bad "page not revived"
[ ! -f "$BRAIN_DIR/wiki-archive/concepts/widget-x.md" ] && ok "archive copy moved out (no duplicate)" || bad "archive copy still present"
grep -q '"event":"restored"' "$BRAIN_DIR/wiki-archive-log.jsonl" && grep -q 'widget-x' "$BRAIN_DIR/wiki-archive-log.jsonl" && ok "restored event logged" || bad "no restored event"
n=$(find "$KD/wiki" -name 'widget-x.md' | wc -l); [ "$n" -eq 1 ] && ok "exactly one live copy" || bad "got $n copies"
echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
