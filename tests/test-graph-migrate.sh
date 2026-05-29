#!/bin/bash
# Tests for scripts/graph-migrate.sh — one-shot, idempotent, reversible import
# of existing related:/[[links]] into the bi-temporal edge log as untyped
# `relates` edges. Never guesses requires/affects. Reversible (delete graph/).
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCRIPT="$ROOT/scripts/graph-migrate.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }
[ -f "$SCRIPT" ] || fail "scripts/graph-migrate.sh not found"

KDIR="$TMP/knowledge"; mkdir -p "$KDIR/wiki/entities"
printf '%s\n' '---' 'title: A' 'type: entities' 'created: 2026-05-01' 'related: [[page-b]]' '---' '# A' > "$KDIR/wiki/entities/page-a.md"
printf '%s\n' '---' 'title: B' 'type: entities' 'created: 2026-05-02' 'related: []' '---' '# B' > "$KDIR/wiki/entities/page-b.md"
# page-d uses the BARE-YAML related: [x, y] form (no [[..]] anywhere) — the
# majority format on the real wiki (103/135 pages). A [[..]]-only grep misses it.
printf '%s\n' '---' 'title: D' 'type: entities' 'created: 2026-05-04' 'related: [page-a, page-b]' '---' '# D' 'no bracket links in this body' > "$KDIR/wiki/entities/page-d.md"

# --- Test 1: migration creates untyped relates edges from related: ---
KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
LOG="$KDIR/graph/edges.jsonl"
[ -f "$LOG" ] || fail "edges.jsonl not created"
grep -q '"from":"page-a"' "$LOG" || fail "related: not migrated"
grep -q '"type":"relates"' "$LOG" || fail "migrated edge not typed relates"
grep -q '"source":"migration:v1"' "$LOG" || fail "source not stamped migration:v1"
grep -q '"valid_from":"2026-05-01"' "$LOG" || fail "valid_from not seeded from created"
pass "related: links migrated as untyped relates edges with created→valid_from"

# --- Test 1b: BARE-YAML related: [a, b] (no [[..]]) is migrated (the 103/135 case) ---
grep -q '"from":"page-d".*"to":"page-a"' "$LOG" || fail "bare-YAML related: [page-a,..] not migrated (page-d->page-a missing)"
grep -q '"from":"page-d".*"to":"page-b"' "$LOG" || fail "bare-YAML related: [..,page-b] not migrated (page-d->page-b missing)"
pass "bare-YAML related: [a, b] frontmatter migrated (not just [[..]])"

# --- Test 2: idempotent — second run adds no duplicates ---
N1=$(wc -l < "$LOG")
KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
N2=$(wc -l < "$LOG")
[ "$N1" = "$N2" ] || fail "migration not idempotent ($N1 -> $N2)"
pass "migration is idempotent"

# --- Test 3: body [[wiki-links]] are also migrated ---
printf '%s\n' '---' 'title: C' 'type: entities' 'created: 2026-05-03' 'related: []' '---' '# C' '' 'See [[page-a]] for details.' > "$KDIR/wiki/entities/page-c.md"
KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
grep -q '"from":"page-c"' "$LOG" || fail "body [[link]] not migrated"
pass "body [[wiki-links]] migrated"

# --- Test 4: reversible — pages untouched (related: still present) ---
grep -q 'related: \[\[page-b\]\]' "$KDIR/wiki/entities/page-a.md" || fail "migration mutated page related: (should be read-only)"
pass "pages left untouched (reversible: delete graph/ to undo)"

# --- Test 5: does not duplicate a relates edge already present from another source ---
# Seed an extractor-sourced relates page-a->page-b, then migrate must NOT re-add it.
GDIR="$KDIR/graph"; mkdir -p "$GDIR"
: > "$GDIR/edges.jsonl"
printf '%s\n' '{"op":"assert","from":"page-a","to":"page-b","type":"relates","valid_from":"2026-05-01","valid_to":null,"recorded_at":"2026-05-10T00:00:00Z","source":"extractor"}' > "$GDIR/edges.jsonl"
KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT" --knowledge-dir "$KDIR"
AB=$(grep -c '"from":"page-a".*"to":"page-b"' "$GDIR/edges.jsonl" 2>/dev/null || echo 0)
[ "$AB" -eq 1 ] || fail "migrate duplicated a relates edge already present from another source (count=$AB)"
pass "migrate does not duplicate a relates edge from another source"

echo; echo "ALL PASS"
