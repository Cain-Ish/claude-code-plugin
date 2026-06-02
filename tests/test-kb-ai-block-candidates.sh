#!/bin/bash
# kb-ai-block-candidates.sh: deterministic, read-only enumeration of blockless structured
# pages with substantive prose. One TSV row per candidate: <type>\t<slug>\t<path>.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SC="$ROOT/scripts/kb-ai-block-candidates.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
[ -f "$SC" ] || fail "script missing"
W="$TMP/knowledge/wiki"; mkdir -p "$W"/{learnings,state,projects}
# candidate: structured, no block, long prose
printf '%s\n' '---' 'title: A' 'type: learnings' '---' '# A' "$(printf 'real prose detail. %.0s' $(seq 1 20))" > "$W/learnings/cand.md"
# NOT: has a block
printf '%s\n' '---' 'title: B' 'type: learnings' '---' '<!-- ai:begin -->' 'claim: c' '<!-- ai:end -->' '# B' "$(printf 'prose. %.0s' $(seq 1 20))" > "$W/learnings/hasblock.md"
# NOT: stub (short)
printf '%s\n' '---' 'title: C' 'type: learnings' '---' '# C' 'tiny.' > "$W/learnings/stub.md"
# NOT: non-structured type
printf '%s\n' '---' 'title: D' 'type: state' '---' '# D' "$(printf 'long state prose. %.0s' $(seq 1 20))" > "$W/state/st.md"
# NOT: generated MOC dir
printf '%s\n' '---' 'title: P' 'type: projects' '---' '# P' "$(printf 'long moc prose. %.0s' $(seq 1 20))" > "$W/projects/p.md"

OUT=$(bash "$SC" --knowledge-dir "$TMP/knowledge")
printf '%s\n' "$OUT" | grep -q $'^learnings\tcand\t' || fail "candidate not listed"
printf '%s\n' "$OUT" | grep -q 'hasblock' && fail "page WITH a block listed"
printf '%s\n' "$OUT" | grep -q 'stub' && fail "stub listed"
printf '%s\n' "$OUT" | grep -q $'^state\t' && fail "non-structured type listed"
printf '%s\n' "$OUT" | grep -q 'projects' && fail "generated MOC listed"
[ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 1 ] || fail "expected exactly 1 candidate, got $(printf '%s\n' "$OUT" | grep -c .)"
pass "enumerates only blockless, substantive, structured pages"

# idempotent / read-only: running twice yields identical output, mutates nothing
H1=$(md5sum "$W/learnings/cand.md"); OUT2=$(bash "$SC" --knowledge-dir "$TMP/knowledge"); H2=$(md5sum "$W/learnings/cand.md")
[ "$H1" = "$H2" ] || fail "script mutated a page (must be read-only)"
[ "$OUT" = "$OUT2" ] || fail "non-deterministic output across runs"
pass "read-only + deterministic"
echo; echo "ALL PASS"
