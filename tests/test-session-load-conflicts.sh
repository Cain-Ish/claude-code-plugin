#!/bin/bash
# session-load.sh surfaces the FOLDED open graph-conflict count in a HIGH-priority
# banner — present even under a near-full byte budget (a correctness signal must not
# be the item silently dropped at the ceiling). Spec 2026-06-01 §4 + §7 test #12.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $1"; exit 1; }
pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || fail "jq required"

export BRAIN_DIR="$TMP/.second-brain"
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$TMP/knowledge"
export CLAUDE_PLUGIN_ROOT="$ROOT"
KDIR="$TMP/knowledge"
mkdir -p "$BRAIN_DIR/projects/demo" "$KDIR/graph"
WORKDIR="$TMP/demo"; mkdir -p "$WORKDIR"

# Near-full budget: USER.md + PROJECT.md ~6KB combined.
big(){ for i in $(seq 1 80); do printf 'filler line %02d aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"; done; }
{ printf '# USER\n'; big; } > "$BRAIN_DIR/USER.md"
{ printf '# PROJECT: demo\n\n## Goal\ndemo\n\n## State\n'; big; printf '\n## Conventions\n\n## Recent decisions\n\n## Open blockers\n\n## Cross-references\n'; } > "$BRAIN_DIR/projects/demo/PROJECT.md"

run(){ (cd "$WORKDIR" && bash "$ROOT/scripts/session-load.sh" 2>/dev/null); }

# --- 1: 2 open conflicts (3 identities, one resolved) → banner present, count=2, ≤8000 ---
cat > "$KDIR/graph/conflicts.jsonl" <<'EOF'
{"detected_at":"2026-06-01T10:00:00Z","from":"a","type":"requires","to":"b","kind":"reintroduce","against":{},"source":"merge-edges","status":"open"}
{"detected_at":"2026-06-01T10:00:01Z","from":"c","type":"supersedes","to":"d","kind":"opposing","against":{},"source":"merge-edges","status":"open"}
{"detected_at":"2026-06-01T10:00:02Z","from":"e","type":"requires","to":"f","kind":"reintroduce","against":{},"source":"merge-edges","status":"open"}
{"detected_at":"2026-06-01T11:00:00Z","from":"e","type":"requires","to":"f","kind":"reintroduce","against":{},"source":"merge-edges","status":"resolved"}
EOF
OUT=$(run)
printf '%s' "$OUT" | grep -q 'graph conflict' || fail "conflict banner missing under near-full budget"
printf '%s' "$OUT" | grep -q '2 graph conflict' || fail "folded open-count wrong (expected 2; resolved identity should not count)"
[ "${#OUT}" -le 8000 ] || fail "output exceeded 8000B (${#OUT})"
pass "banner present + folded count=2 + within budget (${#OUT}B)"

# --- 2: all resolved → no banner ---
cat > "$KDIR/graph/conflicts.jsonl" <<'EOF'
{"detected_at":"2026-06-01T10:00:00Z","from":"a","type":"requires","to":"b","kind":"reintroduce","against":{},"source":"merge-edges","status":"open"}
{"detected_at":"2026-06-01T11:00:00Z","from":"a","type":"requires","to":"b","kind":"reintroduce","against":{},"source":"merge-edges","status":"resolved"}
EOF
OUT=$(run)
printf '%s' "$OUT" | grep -q 'graph conflict' && fail "banner shown when 0 open conflicts" || pass "no banner when all resolved"

# --- 3: no conflicts.jsonl → no banner (back-compat) ---
rm -f "$KDIR/graph/conflicts.jsonl"
OUT=$(run)
printf '%s' "$OUT" | grep -q 'graph conflict' && fail "banner shown with no conflicts file" || pass "no banner when sidecar absent"

echo; echo "ALL PASS"
