#!/bin/bash
# End-to-end: the capture CLI (which the skill drives) ingests material into a project's
# raw inbox, is idempotent, lists items (flagging malformed), and discards.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
CLI="$ROOT/mcp/dist/tools/raw-capture-cli.bundle.js"
SKILL="$ROOT/skills/capture/SKILL.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

[ -f "$SKILL" ] || fail "skills/capture/SKILL.md missing"
grep -q 'raw-capture-cli.bundle.js' "$SKILL" || fail "capture skill does not invoke the raw-capture CLI"
# 0.29.0 surface-collapse: capture is hook/automation-driven, NOT a user slash command.
# It must be user-invocable: false (drained by /maintain + the hook capture path), while
# still wired to the CLI so model-invocation keeps working. Assert the intended state.
grep -q 'user-invocable: false' "$SKILL" || fail "capture skill should be user-invocable: false (surface-collapse) — hook/automation-driven"
pass "capture skill present, CLI-wired, and hidden from the user surface"

command -v node >/dev/null 2>&1 || { echo "SKIP: node"; echo; echo "ALL PASS"; exit 0; }
[ -f "$CLI" ] || { echo "SKIP: CLI bundle not built"; echo; echo "ALL PASS"; exit 0; }

T=$(mktemp -d); export BRAIN_DIR="$T" SB_ACTIVE_SLUG=demo
mkdir -p "$T/projects/demo"; : > "$T/projects/demo/PROJECT.md"
run(){ node "$CLI" "$@"; }

out=$(run capture "rate limit design note")
echo "$out" | grep -q 'Captured .* — 1 unprocessed' || fail "first capture not reported ($out)"
pass "capture creates an unprocessed item"

out=$(run capture "rate limit design note")
echo "$out" | grep -q 'Already captured' || fail "re-capture not idempotent ($out)"
pass "identical re-capture is idempotent"

RAW="$T/projects/demo/raw"
[ "$(ls "$RAW"/*.md | wc -l)" -eq 1 ] || fail "expected exactly 1 item after idempotent re-capture"
grep -q '^status: unprocessed$' "$RAW"/*.md || fail "item missing status: unprocessed"
grep -q '^content_type: text/markdown$' "$RAW"/*.md || fail "item missing content_type"
grep -q '^source: paste$' "$RAW"/*.md || fail "inline capture should record canonical source: paste"

printf 'not a real item\n' > "$RAW/broken.md"
run list | grep -q 'broken .*malformed' || fail "--list did not flag the malformed item"
pass "list flags malformed items"

ID=$(ls "$RAW" | grep -v broken | sed 's/\.md$//' | head -1)
run discard "$ID" | grep -q "Discarded $ID" || fail "discard did not report"
grep -q '^status: discarded$' "$RAW/$ID.md" || fail "status not flipped to discarded"
pass "discard flips status"

# --- SP-4: pending work-list + process (drain plumbing) ---
run capture "a fresh drain candidate note" >/dev/null
PID=$(run pending | cut -f1 | head -1)
[ -n "$PID" ] || fail "pending emitted no unprocessed item"
# Form-agnostic: the path column (field 2) ends with /<id>.md. bash sees $RAW in POSIX form
# (/tmp/…) but Node emits the Windows form (C:/Users/…/Temp/…) after Git-for-Windows translates
# the env-var path, so a full "$RAW/$PID.md" prefix match is wrong on Git Bash. The suffix check
# still catches a missing/misnamed path column and is correct on every OS.
run pending | cut -f2 | grep -q "/$PID\.md$" || fail "pending row missing the item path"
run pending | grep -q 'a fresh drain candidate note' || fail "pending row missing the gist"
pass "pending emits a TSV work-list (id, path, gist) of unprocessed items"

run process "$PID" --node my-node | grep -q "Processed $PID" || fail "process did not report"
grep -q '^status: processed$' "$RAW/$PID.md" || fail "status not flipped to processed"
grep -q '^target_node: my-node$' "$RAW/$PID.md" || fail "target_node back-ref not set"
[ -z "$(run pending | grep "$PID" || true)" ] || fail "processed item still appears in pending"
pass "process flips status + sets target_node; pending excludes processed"

# pending must tab-sanitize target_node (a tab would shift TSV columns)
run capture "tab node test" --node "$(printf 'a\tb')" >/dev/null
TNF=$(run pending | grep 'tab node test' | awk -F'\t' '{print NF}')
[ "$TNF" = "5" ] || fail "pending row not 5 tab-fields (tab in target_node corrupts TSV): got $TNF"
pass "pending tab-sanitizes target_node (5 TSV columns)"

# --- SP-5: --slug override (cross-project drain isolation) ---
# Set up project A (alpha) and project B (beta) inboxes in the same BRAIN_DIR.
mkdir -p "$T/projects/alpha" "$T/projects/beta"
: > "$T/projects/alpha/PROJECT.md"
: > "$T/projects/beta/PROJECT.md"

# Capture an item into project alpha's inbox directly.
ALPHA_OUT=$(BRAIN_DIR="$T" SB_ACTIVE_SLUG=alpha node "$CLI" capture "alpha-specific note")
echo "$ALPHA_OUT" | grep -q 'Captured .* — 1 unprocessed' || fail "--slug test: alpha capture failed ($ALPHA_OUT)"
ALPHA_ID=$(BRAIN_DIR="$T" SB_ACTIVE_SLUG=alpha node "$CLI" pending | cut -f1 | head -1)
[ -n "$ALPHA_ID" ] || fail "--slug test: alpha pending returned nothing"

# With active=beta, --slug alpha must list alpha's item (cross-project pending).
POUT=$(BRAIN_DIR="$T" SB_ACTIVE_SLUG=beta node "$CLI" --slug alpha pending)
echo "$POUT" | grep -q "$ALPHA_ID" || fail "--slug alpha pending (active=beta) did not list alpha's item ($POUT)"
pass "--slug alpha pending lists alpha's item when active=beta"

# Without --slug, active=beta: beta's pending is empty (alpha's item is invisible).
BETA_POUT=$(BRAIN_DIR="$T" SB_ACTIVE_SLUG=beta node "$CLI" pending)
[ -z "$(echo "$BETA_POUT" | grep "$ALPHA_ID" || true)" ] || fail "beta pending (no --slug) should NOT see alpha's item"
pass "pending without --slug (active=beta) does not see alpha's item"

# With active=beta, --slug alpha + process: should mark alpha's item processed.
PROC_OUT=$(BRAIN_DIR="$T" SB_ACTIVE_SLUG=beta node "$CLI" --slug alpha process "$ALPHA_ID" --node alpha-node)
echo "$PROC_OUT" | grep -q "Processed $ALPHA_ID" || fail "--slug alpha process (active=beta) failed ($PROC_OUT)"
grep -q '^status: processed$' "$T/projects/alpha/raw/$ALPHA_ID.md" || fail "alpha item status not flipped to processed"
grep -q '^target_node: alpha-node$' "$T/projects/alpha/raw/$ALPHA_ID.md" || fail "alpha item target_node not set"
pass "--slug alpha process (active=beta) marks alpha's item processed with target_node"

# Confirm: without --slug, active=beta, process on alpha's id returns not-found.
NFOUT=$(BRAIN_DIR="$T" SB_ACTIVE_SLUG=beta node "$CLI" process "$ALPHA_ID" --node wrongnode)
echo "$NFOUT" | grep -q 'No raw item' || fail "process without --slug (active=beta) should return not-found for alpha id ($NFOUT)"
pass "process without --slug (active=beta) returns not-found for another project's id"

rm -rf "$T"
echo; echo "ALL PASS"
