#!/usr/bin/env bash
# The recall-probe guard must PROTECT a page that is the unique answer to its topic
# and allow archiving a redundant one. Uses BM25-only search via wiki-recall-check.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC="$ROOT/scripts/wiki-forget-candidates.sh"
[ -x "$SC" ] || chmod +x "$SC" 2>/dev/null
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export KNOWLEDGE_DIR="$T" BRAIN_DIR="$T/brain"
mkdir -p "$T/wiki/entities" "$T/brain"; echo '{}' > "$T/brain/access-counts.json"
# unique-answer old orphan stub -> score-candidate but recall-PROTECTED
printf -- '---\ntitle: Zorblax protocol\ndescription: the unique zorblax handshake\nkeywords: zorblax handshake\n---\nThe zorblax protocol handshake is unique and documented only here in this note.\n' > "$T/wiki/entities/zorblax.md"
# redundant pair: each is covered by the other -> archivable
printf -- '---\ntitle: Foobar note A\ndescription: foobar caching duplicate\nkeywords: foobar caching\n---\nFoobar caching duplicate note A content about foobar caching behavior.\n' > "$T/wiki/entities/foobar-a.md"
printf -- '---\ntitle: Foobar note B\ndescription: foobar caching duplicate\nkeywords: foobar caching\n---\nFoobar caching duplicate note B content about foobar caching behavior.\n' > "$T/wiki/entities/foobar-b.md"
touch -d '120 days ago' "$T/wiki/entities/zorblax.md" "$T/wiki/entities/foobar-a.md" "$T/wiki/entities/foobar-b.md"

P=0;F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
out=$(SB_FORGET_FLOOR=0.99 bash "$SC"); rc=$?
echo "--- candidates output ---"; echo "$out"; echo "--- (rc=$rc) ---"
if echo "$out" | grep -q "zorblax"; then bad "zorblax (unique answer) must be PROTECTED"; else ok "unique-answer page protected by recall probe"; fi
if echo "$out" | grep -qE "foobar-(a|b)"; then ok "redundant duplicate is archivable"; else bad "redundant page should be archivable"; fi
echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
