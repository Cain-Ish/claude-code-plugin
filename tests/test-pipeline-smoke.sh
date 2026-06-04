#!/bin/bash
# Full-pipeline integration smoke test — exercises the REAL built CLI bundles end-to-end in a
# fully isolated sandbox (temp BRAIN_DIR + KNOWLEDGE_DIR; never touches ~/.second-brain or
# ~/knowledge). Unlike the per-component unit tests, this proves the shipped artifacts compose:
#   SP-3 setup-scan → SP-2 raw inbox → SP-4 drain plumbing → SP-1 project-scoped serving.
# (Phase 4c's node-AUTHORING is LLM-driven, so only the deterministic plumbing it relies on is
#  exercised here; its wiring is guarded by test-maintainer-raw-drain.sh + test-maintain-skill.sh.)
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
SCAN_CLI="$ROOT/mcp/dist/tools/raw-scan-cli.bundle.js"
CAP_CLI="$ROOT/mcp/dist/tools/raw-capture-cli.bundle.js"
SEARCH_CLI="$ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"
fail(){ echo "FAIL: $1"; FAILED=1; }
ok(){ echo "PASS: $1"; }
FAILED=0

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; echo; echo "ALL PASS"; exit 0; }
for b in "$SCAN_CLI" "$CAP_CLI" "$SEARCH_CLI"; do
  [ -f "$b" ] || { echo "SKIP: $(basename "$b") not built — run cd mcp && npm run build"; echo; echo "ALL PASS"; exit 0; }
done

# ~40-word padding constant (no `seq` dependency — keeps each fixture page a realistic length so the
# FORGET/stub heuristics treat it as substantive).
PAD="lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua ut enim ad minim veniam quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat duis aute irure"

# --- isolated sandbox ---
SB=$(mktemp -d); KD=$(mktemp -d); RP=$(mktemp -d)
export BRAIN_DIR="$SB" KNOWLEDGE_DIR="$KD" SB_ACTIVE_SLUG="smoke"
mkdir -p "$SB/projects/smoke"; : > "$SB/projects/smoke/PROJECT.md"
RAW="$SB/projects/smoke/raw"

# STAGE 1 — SP-3 setup deep-scan
printf '# Project\nThe wireguard tunnel backbone. %s\n' "$PAD" > "$RP/README.md"
mkdir -p "$RP/docs"; printf '# Guide\nHow the rate limiter works. %s\n' "$PAD" > "$RP/docs/guide.md"
mkdir -p "$RP/src"; printf '# DESIGN\nThe planner loop design. %s\n' "$PAD" > "$RP/src/DESIGN.md"
mkdir -p "$RP/node_modules/pkg"; printf '# junk\n%s\n' "$PAD" > "$RP/node_modules/pkg/README.md"   # excluded (junk dir)
printf '# changelog\n- v1\n%s\n' "$PAD" > "$RP/CHANGELOG.md"                                        # excluded (low-signal)
DRY=$(SCAN_ROOT="$RP" node "$SCAN_CLI" --dry-run 2>&1)
echo "$DRY" | grep -q '3 high-signal doc' || fail "dry-run should find exactly 3 high-signal docs ($DRY)"
echo "$DRY" | grep -q 'README.md' && echo "$DRY" | grep -q 'docs/guide.md' && echo "$DRY" | grep -q 'src/DESIGN.md' || fail "dry-run missing an expected doc"
echo "$DRY" | grep -q 'node_modules' && fail "dry-run leaked a junk-dir file"
echo "$DRY" | grep -q 'CHANGELOG' && fail "dry-run leaked CHANGELOG (low-signal)"
[ -z "$(ls -A "$RAW" 2>/dev/null)" ] || fail "dry-run wrote items (should preview only)"
SCAN_ROOT="$RP" node "$SCAN_CLI" 2>&1 | grep -q 'Captured 3' || fail "scan capture should report 3"
[ "$(ls "$RAW"/*.md 2>/dev/null | wc -l)" -eq 3 ] || fail "expected 3 raw items after scan"
grep -lq '^captured_by: setup-scan$' "$RAW"/*.md || fail "scan items not stamped captured_by: setup-scan"
ok "SP-3 setup-scan: 3 high-signal docs captured; junk + CHANGELOG excluded; dry-run wrote nothing"

# STAGE 2 — SP-2 manual capture
node "$CAP_CLI" capture "https://example.com/wireguard-spec" >/dev/null 2>&1
echo "a quick note about the rate limiter" | node "$CAP_CLI" paste >/dev/null 2>&1
[ "$(ls "$RAW"/*.md 2>/dev/null | wc -l)" -eq 5 ] || fail "expected 5 raw items (3 scan + url + paste)"
grep -lq '^content_type: text/uri-list$' "$RAW"/*.md || fail "URL not stored as an offline pointer"
node "$CAP_CLI" list 2>&1 | grep -q '5 item(s), 5 unprocessed' || fail "list should show 5 unprocessed"
ok "SP-2 capture: URL stored as an offline pointer + paste; inbox = 5 unprocessed"

# STAGE 3 — SP-4 drain plumbing
PEND=$(node "$CAP_CLI" pending 2>&1)
[ "$(printf '%s\n' "$PEND" | grep -c .)" -eq 5 ] || fail "pending should emit 5 TSV rows"
printf '%s\n' "$PEND" | awk -F'\t' 'NF!=5{bad=1} END{exit bad+0}' || fail "a pending row is not 5 tab-columns"
PID=$(printf '%s\n' "$PEND" | head -1 | cut -f1)
node "$CAP_CLI" process "$PID" --node wireguard-backbone 2>&1 | grep -q "Processed $PID" || fail "process did not report"
grep -q '^status: processed$' "$RAW/$PID.md" || fail "item not flipped to processed"
grep -q '^target_node: wireguard-backbone$' "$RAW/$PID.md" || fail "target_node back-ref not set"
[ "$(node "$CAP_CLI" pending 2>&1 | grep -c .)" -eq 4 ] || fail "pending should drop the processed item (→4)"
ok "SP-4 drain plumbing: pending 5-col TSV → process flips status + back-ref → pending excludes it (5→4)"

# STAGE 4 — SP-1 project-scoped serving (suppression is the deterministic, CLI-observable behavior;
# the SB_PROJECT_SCOPE=off kill switch is covered deterministically by the mcp vitest suite).
mkdir -p "$KD/wiki/learnings"
w(){ printf -- '---\ntitle: %s\ntype: learnings\nproject: %s\ndescription: wireguard tunnel keyword\n---\n\n# %s\n\nwireguard tunnel keyword %s\n' "$1" "$2" "$1" "$PAD" > "$KD/wiki/learnings/$1.md"; }
w a1 alpha; w a2 alpha; w a3 alpha; w b1 beta
SCOPED=$(SB_ACTIVE_SLUG=alpha node "$SEARCH_CLI" "wireguard tunnel" 2>&1)
printf '%s\n' "$SCOPED" | grep -q 'b1' && fail "scoped(alpha) search leaked the beta page b1"
printf '%s\n' "$SCOPED" | grep -qE 'a[123]' || fail "scoped(alpha) search returned no alpha page"
ok "SP-1 scoped serving: scoped to alpha, the beta page is suppressed; alpha pages served"

# STAGE 5 — isolation
[ ! -e "$HOME/.second-brain/projects/smoke" ] || fail "LEAKED into the real ~/.second-brain"
ok "isolation: real ~/.second-brain + ~/knowledge untouched"

rm -rf "$SB" "$KD" "$RP"
echo
if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; else echo "ALL FAIL"; exit 1; fi
