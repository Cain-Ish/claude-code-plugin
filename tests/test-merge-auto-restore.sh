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

# D2 (audit): `mv` keeps the archive's OLD mtime, so dream-accept did not see a revived page as
# post-snapshot and its rsync --delete removed it again. Both auto-restore sites: a cross-reference
# (gadget-y) and a wiki_update whose content the page already holds (thing-z: the dedup skips the
# write, so nothing else refreshes the mtime). ORACLE: neither revived page is older than REF.
mkdir -p "$BRAIN_DIR/wiki-archive/entities"
# Canonical frontmatter, so the merge's own validate/reindex pass has nothing to rewrite.
printf -- '---\ntitle: "Gadget Y"\ndescription: "gadget y"\ntype: entities\ncreated: 2025-01-01\nupdated: 2025-01-01\ntags: []\nrelated: []\n---\n\n# Gadget Y\n\nold gadget body.\n' > "$BRAIN_DIR/wiki-archive/entities/gadget-y.md"
printf -- '---\ntitle: "Thing Z"\ndescription: "thing z"\ntype: concepts\ncreated: 2025-01-01\nupdated: 2025-01-01\ntags: []\nrelated: []\n---\n\n# Thing Z\n\nthing z original body text, already known.\n' > "$BRAIN_DIR/wiki-archive/concepts/thing-z.md"
touch -t 202501010000 "$BRAIN_DIR/wiki-archive/entities/gadget-y.md" "$BRAIN_DIR/wiki-archive/concepts/thing-z.md"
printf '%s\n' '{"event":"archived","slug":"gadget-y","category":"entities","date":"2026-05-26T01:00:00Z"}' \
  '{"event":"archived","slug":"thing-z","category":"concepts","date":"2026-05-26T01:00:00Z"}' >> "$BRAIN_DIR/wiki-archive-log.jsonl"
REF="$T/ref"; touch "$REF"
echo '{"cross_refs":["gadget-y"],"wiki_updates":[{"category":"concepts","slug":"thing-z","action":"create","title":"Thing Z","description":"d","content":"thing z original body text, already known."}]}' \
  | bash "$MERGE" --project-md "$PMD" --knowledge-dir "$KD" >/dev/null 2>&1
for p in entities/gadget-y concepts/thing-z; do
  if [ ! -f "$KD/wiki/$p.md" ]; then bad "D2: $p not revived"
  elif [ "$REF" -nt "$KD/wiki/$p.md" ]; then bad "D2: revived $p kept the archive's old mtime (dream-accept would delete it)"
  else ok "D2: revived $p carries a fresh mtime"
  fi
done
echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
