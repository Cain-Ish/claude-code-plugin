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
printf '%s' '{"keep-me":{"count":9,"last_accessed":"2026-05-26T00:00:00Z"},"dead-stub":{"count":0,"last_accessed":"2026-01-01T00:00:00Z"},"hot-orphan":{"count":50,"last_accessed":"2026-05-26T00:00:00Z"}}' > "$T/brain/access-counts.json"
# protected learning, will be linked (inbound>0)
printf -- '---\ntitle: Keep me\ndescription: important\n---\nbody body body body body body body body body body body body body body body body body body body body body.\n' > "$T/wiki/learnings/keep-me.md"
# orphan stub entity, old, tiny -> forgettable
printf -- '---\ntitle: Dead stub\ndescription: x\n---\ntiny.\n' > "$T/wiki/entities/dead-stub.md"
# a page linking to keep-me (gives keep-me inbound=1)
printf -- '---\ntitle: Linker\ndescription: links\n---\nsee [[keep-me]] for details and more context here for length.\n' > "$T/wiki/entities/linker.md"
# v4 correction lock: a FREQUENTLY-ACCESSED (count=50), old, orphan, full-prose entity must NOT
# be rescued by its access count. Under the old access-weighted score (0.30*s_acc) a count of 50
# pushed it to ~0.40 (>floor → frequency-protected); the v4 importance-only score must drop it
# below the floor — usage-frequency no longer scores (rich-get-richer hub bias removed).
printf -- '---\ntitle: Hot orphan\ndescription: x\n---\nreal prose real prose real prose real prose real prose real prose real prose real prose real prose real prose real prose real prose real prose real prose real prose.\n' > "$T/wiki/entities/hot-orphan.md"
touch -d '90 days ago' "$T/wiki/entities/dead-stub.md" "$T/wiki/entities/hot-orphan.md"

P=0;F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }
out=$(bash "$SC")
ds=$(echo "$out" | awk -F'\t' '$2=="dead-stub"{print $1}')
km=$(echo "$out" | awk -F'\t' '$2=="keep-me"{print $1}')
awk "BEGIN{exit !($ds < $km)}" && ok "dead-stub scores below keep-me" || bad "ds=$ds km=$km"
# A 90-day unaccessed orphan stub must score BELOW the candidate FLOOR — i.e. be an
# ACTUAL forget candidate, not merely ranked under keep-me. The old "ds<km" check passed
# even when FORGET was completely dead (recency decayed too slowly to ever cross the floor).
FLOOR="${SB_FORGET_FLOOR:-0.15}"
awk "BEGIN{exit !($ds < $FLOOR)}" && ok "dead-stub below FORGET floor ($ds < $FLOOR) — a real candidate" || bad "dead-stub ds=$ds NOT below floor $FLOOR — FORGET silently emits zero candidates"
echo "$out" | awk -F'\t' '$2=="keep-me"{print $5}' | grep -q "PROTECT:category" && ok "keep-me category-protected" || bad "keep-me not protected ($out)"
echo "$out" | awk -F'\t' '$2=="dead-stub"{print $5}' | grep -qv "PROTECT:age" && ok "dead-stub not age-protected" || bad "dead-stub wrongly age-protected"
# v4 correction lock: hot-orphan (access=50, 90d old, orphan, full-prose) must be a forget
# candidate — usage-frequency no longer scores, so its high access count does NOT rescue it.
ho=$(echo "$out" | awk -F'\t' '$2=="hot-orphan"{print $1}')
ho_pf=$(echo "$out" | awk -F'\t' '$2=="hot-orphan"{print $5}')
awk "BEGIN{exit !($ho < $FLOOR)}" && ok "hot-orphan below FORGET floor ($ho < $FLOOR) — access-count no longer rescues a low-importance orphan (v4)" || bad "hot-orphan ho=$ho NOT below floor $FLOOR — frequency still drives the score (v4 correction regressed)"
[ -z "$ho_pf" ] && ok "hot-orphan unprotected (no frequency/recency protection)" || bad "hot-orphan wrongly protected (protflag='$ho_pf')"
# C1 regression: exactly one TSV row per page (4 pages), each with a numeric score.
nrows=$(printf '%s\n' "$out" | grep -c .)
[ "$nrows" -eq 4 ] && ok "4 clean TSV rows (no access-counts corruption)" || bad "expected 4 rows, got $nrows (C1 corruption?)"
printf '%s\n' "$out" | awk -F'\t' 'NF{ if($1 !~ /^[0-9.]+$/){print "bad score: "$0; e=1} } END{exit e}' && ok "all scores numeric" || bad "non-numeric score field"
echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
