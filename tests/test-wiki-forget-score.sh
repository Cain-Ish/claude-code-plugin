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

# D190: a REAL protected-category learning whose slug merely CONTAINS "session" (a
# live example: learnings/session-load-emits-plain-text-banners-be.md) must keep its
# PROTECT:category flag — the old `*session*` bare substring match cleared it. Linked
# so it doesn't ALSO trip the (unrelated) PROTECT:linked fallback and mask the bug.
printf -- '---\ntitle: Session load emits plain text banners\ndescription: real learning\n---\nreal prose body content about session-load banners with plenty of descriptive text here.\n' > "$T/wiki/learnings/session-load-emits-plain-text-banners-be.md"
touch -d '90 days ago' "$T/wiki/learnings/session-load-emits-plain-text-banners-be.md"
# D190 counterpart: an ACTUAL generated session-digest recap page (the intended target
# of the exclusion) must still lose category protection — the anchor narrowed to a
# prefix, it did not stop matching its real target.
printf -- '---\ntitle: Session digest\ndescription: auto-generated recap\n---\ntiny auto-generated recap body.\n' > "$T/wiki/learnings/session-digest-2026-06-17.md"
touch -d '90 days ago' "$T/wiki/learnings/session-digest-2026-06-17.md"

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
# C1 regression: exactly one TSV row per page (6 pages), each with a numeric score.
nrows=$(printf '%s\n' "$out" | grep -c .)
[ "$nrows" -eq 6 ] && ok "6 clean TSV rows (no access-counts corruption)" || bad "expected 6 rows, got $nrows (C1 corruption?)"
printf '%s\n' "$out" | awk -F'\t' 'NF{ if($1 !~ /^[0-9.]+$/){print "bad score: "$0; e=1} } END{exit e}' && ok "all scores numeric" || bad "non-numeric score field"

# D190 assertions
echo "$out" | awk -F'\t' '$2=="session-load-emits-plain-text-banners-be"{print $5}' | grep -q "PROTECT:category" \
  && ok "D190: real learning slug containing 'session' KEEPS PROTECT:category" \
  || bad "D190: real learning slug containing 'session' lost PROTECT:category ($out)"
echo "$out" | awk -F'\t' '$2=="session-digest-2026-06-17"{print $5}' | grep -q "PROTECT:category" \
  && bad "D190: generated session-digest-* page wrongly kept PROTECT:category (exclusion no longer matches its real target)" \
  || ok "D190: generated session-digest-* page correctly loses category protection"

# D6 (audit): [[slug|alias]], [[cat/slug]] and [[slug#heading]] all link to slug, but the inbound
# count read them as the literal "slug|alias" etc., so a page linked only that way looked orphaned
# and lost PROTECT:linked (FORGET could archive it).
T6=$(mktemp -d)
mkdir -p "$T6/wiki/entities"
for s in aliased pathed anchored; do printf -- '---\ntitle: %s\n---\nbody text for %s.\n' "$s" "$s" > "$T6/wiki/entities/$s.md"; done
printf -- '---\ntitle: L\n---\nsee [[aliased|Alias Text]], [[entities/pathed]] and [[anchored#Some section]].\n' > "$T6/wiki/entities/linker6.md"
out6=$(KNOWLEDGE_DIR="$T6" BRAIN_DIR="$T6/brain" bash "$SC")
for s in aliased pathed anchored; do
  echo "$out6" | awk -F'\t' -v s="$s" '$2==s{print $4" "$5}' | grep -q 'inb=1 .*PROTECT:linked' \
    && ok "D6: the $s link form counts as inbound (PROTECT:linked)" \
    || bad "D6: $s not counted as linked ($(echo "$out6" | awk -F'\t' -v s="$s" '$2==s'))"
done
rm -rf "$T6"

# D7 (audit): pages are scored in one batch (created: dates converted once per distinct date).
# Lock the created:-first age rule and its mtime fallback: every mtime here is fresh, so only a
# parsed created: (plain or quoted ISO) can make a page old.
T7=$(mktemp -d); mkdir -p "$T7/wiki/entities"
printf -- '---\ntitle: a\ncreated: 2020-01-01\n---\nbody.\n' > "$T7/wiki/entities/old-plain.md"
printf -- '---\ntitle: b\ncreated: "2020-01-01T10:00:00Z"\n---\nbody.\n' > "$T7/wiki/entities/old-iso.md"
printf -- '---\ntitle: c\n---\nbody.\n' > "$T7/wiki/entities/no-created.md"
# Access counts are read in one jq listing: a legacy flat-number entry (it errors on .count) must
# not end the listing before the nested entries after it.
mkdir -p "$T7/brain"; printf '%s' '{"old-plain":4,"old-iso":{"count":7}}' > "$T7/brain/access-counts.json"
out7=$(KNOWLEDGE_DIR="$T7" BRAIN_DIR="$T7/brain" bash "$SC")
echo "$out7" | awk -F'\t' '$2=="old-iso"{print $4}' | grep -q 'acc=7 ' \
  && ok "D7: a flat-number access-count entry does not cut off the ones after it" \
  || bad "D7: old-iso lost its access count after a flat-number entry ($(echo "$out7" | awk -F'\t' '$2=="old-iso"'))"
for s in old-plain old-iso; do
  r=$(echo "$out7" | awk -F'\t' -v s="$s" '$2==s{print $4"|"$5}')
  a=$(printf '%s' "$r" | sed -E 's/.*age=([0-9-]+)d.*/\1/')
  case "$r" in *PROTECT:age*) bad "D7: $s aged by mtime, not created: ($r)" ;;
    *) [ "${a:-0}" -gt 2000 ] 2>/dev/null && ok "D7: $s aged from created: (${a}d)" || bad "D7: $s age wrong ($r)" ;; esac
done
echo "$out7" | awk -F'\t' '$2=="no-created"{print $5}' | grep -q 'PROTECT:age' \
  && ok "D7: a page without created: falls back to its (fresh) mtime" || bad "D7: no-created page not aged by mtime ($out7)"
# Scale guard: the old loop spent ~0.3-0.7 s per page on Windows (~950 pages overran the 600 s
# dream_accept timeout); the batch scores 300 pages in about a second there.
i=0; while [ "$i" -lt 300 ]; do i=$((i + 1)); printf -- '---\ntitle: s%s\ncreated: 2026-0%s-1%s\n---\nsee [[s%s]]\n' "$i" $((i % 9 + 1)) $((i % 10)) $((i / 2 + 1)) > "$T7/wiki/entities/s$i.md"; done
s0=$SECONDS; n7=$(KNOWLEDGE_DIR="$T7" BRAIN_DIR="$T7/brain" bash "$SC" | grep -c .); dt=$((SECONDS - s0))
[ "$n7" -eq 303 ] && [ "$dt" -lt 30 ] && ok "D7: 303 pages scored in ${dt}s" || bad "D7: 303 pages -> $n7 rows in ${dt}s (want 303 rows in < 30 s)"
rm -rf "$T7"
echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
