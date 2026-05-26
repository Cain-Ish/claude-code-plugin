#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SC="$ROOT/scripts/wiki-forget-score.sh"
[ -x "$SC" ] || chmod +x "$SC" 2>/dev/null
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export KNOWLEDGE_DIR="$T" BRAIN_DIR="$T/brain"
mkdir -p "$T/wiki/learnings" "$T/wiki/entities" "$T/brain"
# Non-empty access-counts in the REAL nested schema {slug:{count,last_accessed}} —
# guards C1: reading it as a bare value used to break awk + split TSV rows.
printf '%s' '{"keep-me":{"count":9,"last_accessed":"2026-05-26T00:00:00Z"},"dead-stub":{"count":0,"last_accessed":"2026-01-01T00:00:00Z"}}' > "$T/brain/access-counts.json"
# protected learning, will be linked (inbound>0)
printf -- '---\ntitle: Keep me\ndescription: important\n---\nbody body body body body body body body body body body body body body body body body body body body body.\n' > "$T/wiki/learnings/keep-me.md"
# orphan stub entity, old, tiny -> forgettable
printf -- '---\ntitle: Dead stub\ndescription: x\n---\ntiny.\n' > "$T/wiki/entities/dead-stub.md"
# a page linking to keep-me (gives keep-me inbound=1)
printf -- '---\ntitle: Linker\ndescription: links\n---\nsee [[keep-me]] for details and more context here for length.\n' > "$T/wiki/entities/linker.md"
touch -d '90 days ago' "$T/wiki/entities/dead-stub.md"

P=0;F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
out=$(bash "$SC")
ds=$(echo "$out" | awk -F'\t' '$2=="dead-stub"{print $1}')
km=$(echo "$out" | awk -F'\t' '$2=="keep-me"{print $1}')
awk "BEGIN{exit !($ds < $km)}" && ok "dead-stub scores below keep-me" || bad "ds=$ds km=$km"
echo "$out" | awk -F'\t' '$2=="keep-me"{print $5}' | grep -q "PROTECT:category" && ok "keep-me category-protected" || bad "keep-me not protected ($out)"
echo "$out" | awk -F'\t' '$2=="dead-stub"{print $5}' | grep -qv "PROTECT:age" && ok "dead-stub not age-protected" || bad "dead-stub wrongly age-protected"
# C1 regression: exactly one TSV row per page (3 pages), each with a numeric score.
nrows=$(printf '%s\n' "$out" | grep -c .)
[ "$nrows" -eq 3 ] && ok "3 clean TSV rows (no access-counts corruption)" || bad "expected 3 rows, got $nrows (C1 corruption?)"
printf '%s\n' "$out" | awk -F'\t' 'NF{ if($1 !~ /^[0-9.]+$/){print "bad score: "$0; e=1} } END{exit e}' && ok "all scores numeric" || bad "non-numeric score field"
echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
