#!/bin/bash
# pins: SB_PERSONA_GATE — kill-switch test: asserts =off never blocks, even on bad input (Test 8)
# Tests for scripts/wiki-write-guard.sh — denies wiki writes without frontmatter.
set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/scripts/wiki-write-guard.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Hermetic brain dir so the tombstone check reads an empty archive-log (fail-open)
# for the frontmatter cases below; the tombstone cases populate it explicitly.
export BRAIN_DIR="$TMP/brain"; mkdir -p "$TMP/brain"

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
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
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
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
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

# --- Tombstone / auto-restore (cold-tier forgetting coordination) ---

# Archived page 'gone' lives in the archive (NOT the live wiki) + log says archived.
mkdir -p "$TMP/brain/wiki-archive/concepts"
printf -- '---\ntitle: "Gone"\ntype: concepts\n---\n# Gone\noriginal.\n' > "$TMP/brain/wiki-archive/concepts/gone.md"
printf '%s\n' '{"event":"archived","slug":"gone","category":"concepts","date":"2026-05-26T01:00:00Z"}' > "$TMP/brain/wiki-archive-log.jsonl"
GONE="$TMP/knowledge/wiki/concepts/gone.md"; mkdir -p "$(dirname "$GONE")"

# Test 10: Write re-creating an archived slug → restore original + deny (redirect to Edit).
PAYLOAD=$(jq -nc --arg p "$GONE" --arg c $'---\ntitle: x\n---\nnew' \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "Write to archived slug should deny (got: $out)"
echo "$out" | grep -qi "restore" || fail "deny reason should mention restore (got: $out)"
[ -f "$GONE" ] || fail "archived original should be restored to the wiki path"
grep -q '"event":"restored"' "$TMP/brain/wiki-archive-log.jsonl" || fail "restored event not logged"
pass "archived-slug Write restores original + denies"

# Test 11: Write a non-archived NEW page with frontmatter → allowed (tombstone doesn't fire).
FRESH="$TMP/knowledge/wiki/concepts/fresh-topic.md"
PAYLOAD=$(jq -nc --arg p "$FRESH" --arg c $'---\ntitle: fresh\ntype: concepts\n---\nbody' \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
[ -z "$out" ] || fail "non-archived new page should be allowed (got: $out)"
pass "non-archived new page allowed (tombstone inert)"

# Test 12 (Windows form): C:\…\knowledge\wiki\… frontmatter enforced -------
# Before the fix the backslash path never matched the '/'-separated glob, so
# frontmatter enforcement + tombstone auto-restore were both inert on Windows.
# Regression lock: drop the backslash normalization in wiki-write-guard.sh and
# this flips to a silent allow (FAIL).
cat > "$TMP/win-payload.json" <<'JSON'
{"tool_name":"Write","tool_input":{"file_path":"C:\\Users\\me\\knowledge\\wiki\\learnings\\new.md","content":"# no frontmatter here\n"}}
JSON
out=$(bash "$SCRIPT" < "$TMP/win-payload.json")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "Windows C:\\ wiki write without frontmatter should deny (was inert on Windows): $out"
pass "Windows C:\\ wiki write without frontmatter denied"

# --- Legacy-wiki misroute lock (P0.4) -------------------------------------
# The raw-drainer once wrote pages into legacy ~/.second-brain/wiki LIVE —
# invisible to knowledge_search until hand-moved. The prose pin in
# agents/raw-drainer.md can drift; this deny cannot (canonical-wiki invariant).

# Test 13: Write into a .second-brain/wiki tree → deny EVEN WITH frontmatter,
# and the reason must carry the corrected canonical path.
LEGACY="$TMP/.second-brain/wiki/learnings/misrouted.md"
PAYLOAD=$(jq -nc --arg p "$LEGACY" --arg c $'---\ntitle: x\ntype: learnings\n---\nbody' \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "legacy-wiki Write should deny even with frontmatter (got: $out)"
echo "$out" | grep -q 'knowledge/wiki/learnings/misrouted.md' \
  || fail "deny reason should carry the corrected canonical path (got: $out)"
pass "legacy .second-brain/wiki Write denied with canonical redirect"

# Test 14: Edit into the legacy tree → deny too (misroute is tool-agnostic).
PAYLOAD=$(jq -nc --arg p "$LEGACY" \
  '{tool_name:"Edit", tool_input:{file_path:$p, old_string:"a", new_string:"---\nb"}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "legacy-wiki Edit should deny (got: $out)"
pass "legacy .second-brain/wiki Edit denied"

# Test 15 (Windows form): C:\…\.second-brain\wiki\… caught after backslash
# normalization — the misroute happened on Windows in the live incident.
cat > "$TMP/win-legacy.json" <<'JSON'
{"tool_name":"Write","tool_input":{"file_path":"C:\\Users\\me\\.second-brain\\wiki\\state\\x.md","content":"---\ntitle: x\n---\nbody\n"}}
JSON
out=$(bash "$SCRIPT" < "$TMP/win-legacy.json")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "Windows legacy-wiki write should deny (got: $out)"
pass "Windows C:\\ legacy wiki write denied"

# Test 16: dream STAGING under .second-brain/dreams/<id>/staging/wiki → silent
# (the adjacent-segment match must not hit the sanctioned staging copy).
STAGING="$TMP/.second-brain/dreams/drm_x/staging/wiki/state/y.md"
PAYLOAD=$(jq -nc --arg p "$STAGING" --arg c $'---\ntitle: y\n---\nbody' \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
[ -z "$out" ] || fail "dream staging write should be silent (got: $out)"
pass "dream staging wiki copy untouched by the legacy deny"

# Test 17: kill switch — SB_PERSONA_GATE=off silences the legacy deny too.
PAYLOAD=$(jq -nc --arg p "$LEGACY" --arg c $'---\ntitle: x\n---\nbody' \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
out=$(printf '%s' "$PAYLOAD" | SB_PERSONA_GATE=off bash "$SCRIPT")
[ -z "$out" ] || fail "SB_PERSONA_GATE=off should silence the legacy deny (got: $out)"
pass "kill switch silences the legacy deny"

# --- Case-insensitivity locks (0.45.4 — the 0.45.2 persona-tool-guard class) ---
# NTFS and default APFS are case-insensitive: …/knowledge/Wiki/Page.md IS
# …/knowledge/wiki/page.md there, and before the fix every case variant hit the
# scope gate's `*) exit 0` arm — frontmatter enforcement, tombstone auto-restore
# and the legacy-misroute deny were ALL silently bypassed by a one-letter case
# change. Regression lock: drop the FP_LC lowercased-copy matching in
# wiki-write-guard.sh and tests 18-21 flip to silent allows (FAIL).

# Test 18: case-varied wiki Write without frontmatter → deny.
CASEY="$TMP/knowledge/Wiki/state/Case-Varied.md"
PAYLOAD=$(jq -nc --arg p "$CASEY" --arg c "# no frontmatter\n" \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "case-varied wiki Write without frontmatter should deny (got: $out)"
pass "case-varied wiki Write without frontmatter denied"

# Test 19: Windows backslash + case variance combined (the real-world shape).
cat > "$TMP/win-case.json" <<'JSON'
{"tool_name":"Write","tool_input":{"file_path":"C:\\Users\\me\\KNOWLEDGE\\Wiki\\learnings\\New.md","content":"# no frontmatter\n"}}
JSON
out=$(bash "$SCRIPT" < "$TMP/win-case.json")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "Windows case-varied wiki write should deny (got: $out)"
pass "Windows backslash+case-varied wiki write denied"

# Test 20: case-varied LEGACY tree → deny, reason carries the canonical path.
CLEGACY="$TMP/.Second-Brain/Wiki/learnings/Misrouted.md"
PAYLOAD=$(jq -nc --arg p "$CLEGACY" --arg c $'---\ntitle: x\ntype: learnings\n---\nbody' \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "case-varied legacy-wiki Write should deny (got: $out)"
echo "$out" | grep -q 'knowledge/wiki/learnings/misrouted.md' \
  || fail "deny reason should carry the lowercased canonical path (got: $out)"
pass "case-varied legacy wiki Write denied with canonical redirect"

# Test 21: tombstone fires on a case-varied recreate of a forgotten slug.
# Canonical slugs are lowercase (sb_sanitize_slug), so Vanished.md on NTFS/APFS
# recreates the forgotten page vanished.md — the lookup must survive the casing.
mkdir -p "$TMP/brain/wiki-archive/concepts"
printf -- '---\ntitle: "Vanished"\ntype: concepts\n---\n# Vanished\noriginal.\n' \
  > "$TMP/brain/wiki-archive/concepts/vanished.md"
printf '%s\n' '{"event":"archived","slug":"vanished","category":"concepts","date":"2026-05-26T02:00:00Z"}' \
  >> "$TMP/brain/wiki-archive-log.jsonl"
PAYLOAD=$(jq -nc --arg p "$TMP/knowledge/Wiki/concepts/Vanished.md" --arg c $'---\ntitle: x\n---\nnew' \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "case-varied Write to archived slug should deny (got: $out)"
[ -f "$TMP/knowledge/wiki/concepts/vanished.md" ] \
  || fail "archived original should be restored to the CANONICAL lowercase path"
pass "case-varied archived-slug Write restores original + denies"

# Test 22: over-blocking control — case-varied NON-wiki path stays silent.
mkdir -p "$TMP/Scratch"
PAYLOAD=$(jq -nc --arg p "$TMP/Scratch/Note.md" --arg c "no frontmatter\n" \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
[ -z "$out" ] || fail "case-varied non-wiki write should stay silent (got: $out)"
pass "case-varied non-wiki write silent (no over-blocking)"

echo
echo "ALL PASS"
