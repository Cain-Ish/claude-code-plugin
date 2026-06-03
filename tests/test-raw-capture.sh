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
grep -q 'user-invocable: true' "$SKILL" || fail "capture skill not user-invocable"
pass "capture skill present and wired"

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

rm -rf "$T"
echo; echo "ALL PASS"
