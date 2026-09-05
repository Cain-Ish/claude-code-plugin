#!/bin/bash
# pins: SB_CODEMAP_ORIENT — kill-switch test: asserts =off suppresses the orientation banner
# Tests that session-load.sh injects the active project's code-map "architectural
# spine" (top-ranked SOURCE files from BRAIN_DIR/projects/<slug>/codemap/map.md) into
# the hot tier, strips symbols to bare paths (spaced paths survive), honors the
# SB_CODEMAP_ORIENT kill switch, no-ops on an absent/empty store, and — the placement
# lock — still fires BEFORE the forced USER.md in a near-cap populated project (the
# live 8.3KB-PROJECT.md starvation this section's priority placement fixed).
# P0.1 orient-rung wiring, hardened by the 0.33.35 review findings.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Hermetic harness (review findings 3+10): HOME sandboxed so the developer's real
# ~/knowledge (graph conflicts, wiki) can't leak banners into the byte budget;
# CLAUDE_PROJECT_DIR pinned so an ambient export can't win slug resolution over the
# cd'd workdir; claude CLI stubbed; API key cleared for a deterministic auth banner.
BRAIN="$TMP/.second-brain"
WORKDIR="$TMP/demo"
STUB="$TMP/stub"; mkdir -p "$STUB" "$WORKDIR" "$BRAIN/projects/demo/codemap"
printf '#!/bin/bash\nexit 0\n' > "$STUB/claude"; chmod +x "$STUB/claude"

cat > "$BRAIN/projects/demo/PROJECT.md" <<'EOF'
# PROJECT: demo

## Goal
codemap orientation demo

## State

## Conventions

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: 2026-07-08T00:00:00Z -->
<!-- last_queried_wiki: -->
EOF

# A code map shaped exactly like serialize.ts emits: 'path — sym1, sym2' ranked lines
# + a '(+N more files omitted)' footer. One path carries a SPACE (legal in a repo) —
# the extraction must keep it whole, not inject a truncated 'src/my' fragment.
write_map() {
  cat > "$BRAIN/projects/demo/codemap/map.md" <<'EOF'
src/core/router.ts — route, dispatch, RouterError
src/my utils/helper.ts — assist, cleanup
src/core/store.ts — load, save, migrate
(+7 more files omitted)
EOF
}
write_map

run() {
  (cd "$WORKDIR" && echo '{"hook_event_name":"SessionStart","source":"startup"}' \
    | env PATH="$STUB:$PATH" HOME="$TMP" CLAUDE_PROJECT_DIR="$WORKDIR" \
          BRAIN_DIR="$BRAIN" ANTHROPIC_API_KEY="" \
          bash "$ROOT/scripts/session-load.sh" 2>/dev/null)
}

# --- Test 1: spine injected when the store exists; paths whole, symbols stripped ---
OUT=$(run)
echo "$OUT" | grep -q 'architectural spine' || fail "code-map orientation header not injected"
echo "$OUT" | grep -q 'src/core/router.ts' || fail "top-ranked spine file not injected"
echo "$OUT" | grep -q 'src/my utils/helper.ts' || fail "spaced path not kept whole"
echo "$OUT" | grep -q '^src/my$' && fail "spaced path truncated to a bogus 'src/my' fragment"
echo "$OUT" | grep -q 'code_neighbors' || fail "code_neighbors pointer missing"
# Paths only — the ' — symbols' tail must be stripped for the compact pointer.
echo "$OUT" | grep -q 'RouterError' && fail "symbols leaked into the pointer (expected paths only)"
# The '(+N more…)' footer must not leak as a bogus path.
echo "$OUT" | grep -q '(+7 more' && fail "omission footer leaked into the spine"
pass "session-load injects the code-map spine (whole paths only) + tool pointer"

# --- Test 2: kill switch suppresses it even when the store exists ---
OUT2=$(SB_CODEMAP_ORIENT=off run)
echo "$OUT2" | grep -q 'architectural spine' && fail "SB_CODEMAP_ORIENT=off did not suppress the block"
pass "SB_CODEMAP_ORIENT=off suppresses the code-map block"

# --- Test 3: absent store → clean no-op, exit 0 (back-compat / fallback branch) ---
rm -rf "$BRAIN/projects/demo/codemap"
OUT3=$(run); RC=$?
[ "$RC" -eq 0 ] || fail "session-load returned non-zero without a code-map store"
echo "$OUT3" | grep -q 'architectural spine' && fail "code-map block emitted with no store"
pass "no code-map store → clean no-op (back-compat)"

# --- Test 4: empty map.md → no-op (fallback branch: store present but empty) ---
mkdir -p "$BRAIN/projects/demo/codemap"; : > "$BRAIN/projects/demo/codemap/map.md"
OUT4=$(run); RC4=$?
[ "$RC4" -eq 0 ] || fail "session-load non-zero on empty map.md"
echo "$OUT4" | grep -q 'architectural spine' && fail "code-map block emitted for an empty map.md"
pass "empty map.md → clean no-op"

# --- Test 5: PLACEMENT LOCK (review finding 9) — near-cap forced sections must not
# starve the spine, and the spine must precede the forced USER.md. Reproduces the
# live regression: with §0d placed after the forced sections, a populated PROJECT.md
# consumed the banner room and the block never fired. A refactor that moves §0d back
# below USER/PROJECT goes red here. ---
write_map
{ printf -- '---\ntitle: u\n---\nUSER_HEAD_MARKER\n'; for i in $(seq 1 76); do printf 'decision bullet %s with extra descriptive filler bytes for realistic size.\n' "$i"; done; } > "$BRAIN/USER.md"
touch -t 202001010000 "$BRAIN/USER.md"
{ printf '# PROJECT: demo\n\n## Goal\nbig project\n\n## State\n'; for i in $(seq 1 44); do printf -- '- populated state line %s with some descriptive bytes here too.\n' "$i"; done; } > "$BRAIN/projects/demo/PROJECT.md"
OUT5=$(run)
LEN5=${#OUT5}
echo "  near-cap fixtures: USER=$(wc -c <"$BRAIN/USER.md")B PROJECT=$(wc -c <"$BRAIN/projects/demo/PROJECT.md")B → output=${LEN5} chars"
[ "$LEN5" -le 10000 ] || fail "output ${LEN5} > 10000 ceiling with spine + near-cap forced sections"
echo "$OUT5" | grep -q 'architectural spine' || fail "populated project budget-starved the spine (placement regression)"
POS_SPINE=$(printf '%s\n' "$OUT5" | grep -n 'architectural spine' | head -1 | cut -d: -f1)
POS_USER=$(printf '%s\n' "$OUT5" | grep -n 'USER_HEAD_MARKER' | head -1 | cut -d: -f1)
[ -n "$POS_USER" ] || fail "forced USER.md section missing from output"
[ "$POS_SPINE" -lt "$POS_USER" ] || fail "spine (line $POS_SPINE) not before forced USER.md (line $POS_USER)"
pass "near-cap project: spine lands, precedes '# USER', total ≤ 10000 (placement locked)"

echo; echo "ALL PASS"
