#!/bin/bash
# Tests for scripts/wiki-write-guard.sh — denies wiki writes without frontmatter.
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/wiki-write-guard.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# Simulate a wiki tree.
mkdir -p "$TMP/knowledge/wiki/state"
WIKI_FILE="$TMP/knowledge/wiki/state/new-page.md"
INDEX_FILE="$TMP/knowledge/wiki/index.md"
NON_WIKI_FILE="$TMP/scratch/note.md"
mkdir -p "$(dirname "$NON_WIKI_FILE")"

# --- Write tool ---

# Test 1: Write to wiki page without frontmatter → deny.
PAYLOAD=$(jq -nc --arg p "$WIKI_FILE" --arg c "# Just a heading\n\nContent." \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "Write without frontmatter should deny (got: $out)"
pass "Write without frontmatter denied"

# Test 2: Write to wiki page WITH frontmatter → silent (allowed).
PAYLOAD=$(jq -nc --arg p "$WIKI_FILE" --arg c $'---\ntitle: "x"\ntype: state\n---\n\n# x\n' \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
[ -z "$out" ] || fail "Write with frontmatter should be silent (got: $out)"
pass "Write with frontmatter allowed"

# Test 3: Write to index.md → silent (excluded).
PAYLOAD=$(jq -nc --arg p "$INDEX_FILE" --arg c "# Wiki index\n" \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
[ -z "$out" ] || fail "Write to index.md should be silent (got: $out)"
pass "index.md excluded"

# Test 4: Write to non-wiki path → silent.
PAYLOAD=$(jq -nc --arg p "$NON_WIKI_FILE" --arg c "no frontmatter here\n" \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
[ -z "$out" ] || fail "Non-wiki Write should be silent (got: $out)"
pass "non-wiki write silent"

# --- Edit tool ---

# Test 5: Edit on existing wiki file that already has frontmatter → silent.
printf -- '---\ntitle: x\n---\n\n# x\nbody\n' > "$WIKI_FILE"
PAYLOAD=$(jq -nc --arg p "$WIKI_FILE" \
  '{tool_name:"Edit", tool_input:{file_path:$p, old_string:"body", new_string:"updated body"}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
[ -z "$out" ] || fail "Edit on FM-present file should be silent (got: $out)"
pass "Edit on FM-present file allowed"

# Test 6: Edit on existing wiki file WITHOUT frontmatter, new_string doesn't add it → deny.
printf -- '# heading\nbody\n' > "$WIKI_FILE"
PAYLOAD=$(jq -nc --arg p "$WIKI_FILE" \
  '{tool_name:"Edit", tool_input:{file_path:$p, old_string:"body", new_string:"updated body"}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "Edit on FM-missing file without remedy should deny (got: $out)"
pass "Edit on FM-missing file denied"

# Test 7: Edit on FM-missing file whose new_string introduces frontmatter → allow.
printf -- '# heading\nbody\n' > "$WIKI_FILE"
NEW_STR=$'---\ntitle: x\n---\n# heading'
PAYLOAD=$(jq -nc --arg p "$WIKI_FILE" --arg n "$NEW_STR" \
  '{tool_name:"Edit", tool_input:{file_path:$p, old_string:"# heading", new_string:$n}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
[ -z "$out" ] || fail "Edit that adds FM should be silent (got: $out)"
pass "Edit that adds frontmatter allowed"

# --- Kill switch ---

# Test 8: SB_PERSONA_GATE=off → never blocks, even on bad input.
PAYLOAD=$(jq -nc --arg p "$WIKI_FILE" --arg c "no frontmatter\n" \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
out=$(SB_PERSONA_GATE=off printf '%s' "$PAYLOAD" | SB_PERSONA_GATE=off bash "$SCRIPT")
[ -z "$out" ] || fail "Kill switch should suppress all output (got: $out)"
pass "kill switch honored"

# --- Unrelated tool ---

# Test 9: Bash tool → silent (we don't filter Bash).
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' | bash "$SCRIPT")
[ -z "$out" ] || fail "Bash tool should be silent (got: $out)"
pass "Bash tool silent"

echo
echo "ALL PASS"
