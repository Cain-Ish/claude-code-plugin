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

# --- G18 (R3, 2026-10-07): the wiki of a custom KNOWLEDGE_DIR --------------------------------
# The wiki lives at KNOWLEDGE_DIR (plugin option > KNOWLEDGE_DIR env > ~/knowledge, as lib.sh's
# sb_knowledge_dir). A page under a custom one with no "knowledge" segment matched none of the
# */knowledge/wiki/* arms: frontmatter enforcement was off for it. Both resolver inputs, a
# case-varied spelling, a '-' first character (the fast path stands down: the full logic's arm),
# and the index, which stays excluded there too.
# The directory is spelled as the CLI spells it: a Windows form where there is one (MSYS hands jq.exe
# the payload's /tmp/… path as C:/…/Temp/…; a /tmp spelling of the variable would be a mount alias
# of it, which the lexical match does not resolve).
KD="$TMP/Notes Vault"; mkdir -p "$KD/wiki/concepts"
KDV="$KD"; command -v cygpath >/dev/null 2>&1 && KDV=$(cygpath -m "$KD")
g18() {  # g18 <file_path> <content> [VAR=val…] -> out
  local p="$1" c="$2"; shift 2
  out=$(jq -nc --arg p "$p" --arg c "$c" '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}' \
    | env CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR= KNOWLEDGE_DIR= "$@" bash "$SCRIPT")
}
g18 "$KD/wiki/concepts/custom.md" "no frontmatter" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KDV"
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "G18: a bare page under a custom CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR wiki must be denied (got: $out)"
g18 "$KD/Wiki/Concepts/Custom.md" "no frontmatter" KNOWLEDGE_DIR="$KDV"
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "G18: a case-varied bare page under a custom KNOWLEDGE_DIR wiki must be denied (got: $out)"
g18 "$KD/wiki/concepts/dash.md" "-not a fence" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KDV"
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "G18: the full logic must deny a bare page under a custom KNOWLEDGE_DIR wiki too (got: $out)"
g18 "$KD/wiki/index.md" "# index" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KDV"
[ -z "$out" ] || fail "G18: the custom wiki's index.md stays excluded (got: $out)"
g18 "$KD/notes/plain.md" "no frontmatter" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KDV"
[ -z "$out" ] || fail "G18: a non-wiki file under the custom KNOWLEDGE_DIR stays silent (got: $out)"
pass "G18: a custom KNOWLEDGE_DIR's wiki gets frontmatter enforcement (fast path and full logic)"
# GC6 (R3B): bash 5.2's patsub_replacement turned the '&' of a HOME such as "R&D" into the matched
# '~' when ~/kb was expanded, so the custom wiki was not recognized and a bare page went unchecked.
GC6H="$TMP/R&D home"; mkdir -p "$GC6H/kb/wiki/concepts"
GC6HV="$GC6H"; command -v cygpath >/dev/null 2>&1 && GC6HV=$(cygpath -m "$GC6H")
g18 "$GC6H/kb/wiki/concepts/amp.md" "no frontmatter" HOME="$GC6HV" KNOWLEDGE_DIR='~/kb'
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "GC6: a bare page under ~/kb with '&' in HOME must be denied (got: $out)"
pass "GC6: '&' in HOME keeps a ~-relative KNOWLEDGE_DIR's wiki recognized"
# GS8 (R3B): a relative KNOWLEDGE_DIR ("kb") was compared as is, so no absolute page path matched
# it and frontmatter enforcement was off for that wiki. It is resolved against HOME (where the default
# ~/knowledge lives), both by the plugin option and by the env variable.
GS8H="$TMP/gs8 home"; mkdir -p "$GS8H/kb/wiki/concepts"
GS8HV="$GS8H"; command -v cygpath >/dev/null 2>&1 && GS8HV=$(cygpath -m "$GS8H")
g18 "$GS8H/kb/wiki/concepts/rel.md" "no frontmatter" HOME="$GS8HV" KNOWLEDGE_DIR=kb
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "GS8: a bare page under a relative KNOWLEDGE_DIR (kb = ~/kb) must be denied (got: $out)"
g18 "$GS8H/kb/wiki/concepts/rel2.md" "-no fence" HOME="$GS8HV" CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR=./kb
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  || fail "GS8: the full logic must deny a bare page under a relative plugin-option KNOWLEDGE_DIR (./kb) too (got: $out)"
pass "GS8: a relative KNOWLEDGE_DIR resolves against HOME (fast path and full logic)"

# G18: the full logic read a Write's content with one jq and exited 0 when it read nothing — a jq
# that failed (killed, out of memory) let a bare page through unchecked (Edit/MultiEdit already
# failed closed). A failing jq now asks, and says so in error-log.jsonl. The stand-in fails only
# the content read; a '-' first character keeps the fast path out of it.
G18B="$TMP/g18b"; mkdir -p "$G18B"
G18_JQ=$(command -v jq)
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in *tool_input.content*) exit 5 ;; esac; done\nexec "%s" "$@"\n' "$G18_JQ" > "$G18B/jq"; chmod +x "$G18B/jq"
: > "$TMP/brain/error-log.jsonl"
out=$(jq -nc --arg p "$TMP/knowledge/wiki/state/g18-jqfail.md" --arg c "-x" '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}' \
  | PATH="$G18B:$PATH" bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null \
  || fail "G18: a jq that fails reading a wiki Write's content must ask, not pass it (got: '$out')"
grep -q 'wiki-write-guard.sh' "$TMP/brain/error-log.jsonl" \
  || fail "G18: the failed content read must be logged (error-log: $(cat "$TMP/brain/error-log.jsonl"))"
pass "G18: a failed jq content read asks and logs (fail closed, like Edit/MultiEdit)"

# --- B7: decided before any dependency (a late PreToolUse answer is cancelled and the Write runs) ---
# Fixture: a plugin root whose lib.sh sleeps, plus PATH stand-ins that sleep for each external the
# full logic uses. The deny must still arrive within B7_BOUND seconds (whole-second SECONDS; no
# GNU timeout on macOS). Generous bounds: a passing run never sleeps, a stalled one sleeps B7_SLEEP.
# Item 17: on bash < 4.3 (the macOS lane's /bin/bash 3.2) the guards' builtin payload reader steps
# aside and jq decides every call, as on main — a stalled jq can then hold the verdict, so these
# stalled-dependency cases cannot hold there by design and are skipped (loudly) on such a bash.
FP_OFF=0
bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }' && FP_OFF=1
B7_SLEEP=20; B7_BOUND=10
B7="$TMP/b7"; mkdir -p "$B7/root/scripts" "$B7/bin" "$B7/brain"
[ -d "$B7/brain" ] || fail "B7 precondition: $B7/brain must exist before the stand-ins are installed"
printf 'sleep %s\n' "$B7_SLEEP" > "$B7/root/scripts/lib.sh"
for t in jq cat tr grep sed awk head tail cut wc realpath greadlink readlink cygpath dirname basename mkdir mv uname git; do
  printf '#!/bin/sh\nsleep %s\nexit 127\n' "$B7_SLEEP" > "$B7/bin/$t"; chmod +x "$B7/bin/$t"
done
b7_deny() {  # b7_deny <label> <needle> <payload-file>
  if [ "$FP_OFF" = 1 ]; then echo "SKIP: B7 $1 — the fast path is off on bash < 4.3 (item 17: jq decides, as on main)"; return 0; fi
  local s out
  s=$SECONDS
  out=$(CLAUDE_PLUGIN_ROOT="$B7/root" BRAIN_DIR="$B7/brain" PATH="$B7/bin:$PATH" bash "$SCRIPT" < "$3")
  s=$(( SECONDS - s ))
  [ "$s" -le "$B7_BOUND" ] || fail "B7 $1: took ${s}s with every dependency slow (bound ${B7_BOUND}s)"
  [ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
    || fail "B7 $1: expected deny, got: '$out'"
  echo "$out" | grep -q "$2" || fail "B7 $1: deny reason should mention '$2' (got: $out)"
  pass "B7 $1: deny in ${s}s with every dependency slow"
}
mkdir -p "$TMP/knowledge/wiki/issues"
printf '# no frontmatter\nbody\n' > "$TMP/knowledge/wiki/issues/b7-bare.md"
jq -nc --arg p "$TMP/.Second-Brain/Wiki/learnings/Misrouted.md" --arg c $'---\ntitle: x\n---\n' \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}' > "$B7/p1.json"
jq -nc --arg p "$TMP/knowledge/wiki/issues/b7-new.md" --arg c $'# heading\nno frontmatter' \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}' > "$B7/p2.json"
jq -nc --arg p "$TMP/knowledge/wiki/issues/b7-bare.md" \
  '{tool_name:"Edit", tool_input:{file_path:$p, old_string:"body", new_string:"new body"}}' > "$B7/p3.json"
cat > "$B7/p4.json" <<'JSON'
{"tool_name":"MultiEdit","tool_input":{"file_path":"C:\\Users\\me\\.second-brain\\wiki\\state\\x.md","edits":[{"old_string":"a","new_string":"b"}]}}
JSON
b7_deny "legacy tree (case-varied)" 'knowledge/wiki/learnings/misrouted.md' "$B7/p1.json"
b7_deny "new page without frontmatter" 'frontmatter' "$B7/p2.json"
b7_deny "Edit keeps a bare page bare" 'frontmatter' "$B7/p3.json"
b7_deny "Windows-form legacy MultiEdit" 'knowledge/wiki/state/x.md' "$B7/p4.json"
# G18: a custom KNOWLEDGE_DIR's wiki is decided on the fast path too.
mkdir -p "$TMP/Notes Vault B7/wiki/concepts"
jq -nc --arg p "$TMP/Notes Vault B7/wiki/concepts/b7-kd.md" --arg c 'no frontmatter' \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}' > "$B7/p5.json"
KDV7="$TMP/Notes Vault B7"; command -v cygpath >/dev/null 2>&1 && KDV7=$(cygpath -m "$KDV7")
CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KDV7" b7_deny "custom KNOWLEDGE_DIR wiki page" 'frontmatter' "$B7/p5.json"

# No false positives: content that merely NAMES a legacy wiki path stays silent on a non-wiki Write.
PAYLOAD=$(jq -nc --arg p "$NON_WIKI_FILE" --arg c 'see "file_path":"/x/.second-brain/wiki/y.md"' '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
[ -z "$out" ] || fail "B7: content naming a legacy wiki path must not deny a non-wiki Write (got: $out)"
pass "B7: no false positive from content text"

# T8: the fast path stands down for a Write that re-creates a FORGOTTEN page, even a bare one it
# could deny on sight — the full logic's auto-restore redirect must win over the frontmatter deny.
printf -- '---\ntitle: "Gone2"\ntype: concepts\n---\n# Gone2\noriginal.\n' > "$TMP/brain/wiki-archive/concepts/gone2.md"
printf '%s\n' '{"event":"archived","slug":"gone2","category":"concepts","date":"2026-05-26T03:00:00Z"}' >> "$TMP/brain/wiki-archive-log.jsonl"
GONE2="$TMP/knowledge/wiki/concepts/gone2.md"
PAYLOAD=$(jq -nc --arg p "$GONE2" --arg c '# bare' '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
[ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
  && echo "$out" | grep -q 'Auto-restored' \
  || fail "T8: a bare Write re-creating an archived slug must get the restore redirect, not the frontmatter deny (got: $out)"
[ -f "$GONE2" ] || fail "T8: the archived original should be restored"
pass "T8: a bare re-create of a forgotten page gets the auto-restore redirect (fast path stands down)"

# --- Payload size: every verdict must arrive before the 5 s hook timeout ---------------------
# bounded LABEL LIMIT PAYLOAD-FILE: run the guard in the background, stdout to a file, a watchdog
# killing it past LIMIT seconds — a hung guard must FAIL the test, not hang it. BD_OUT; BD_MS =
# elapsed ms (EPOCHREALTIME on bash 5; whole seconds from `date` on older bash, the macOS lane);
# BD_EL = whole seconds. The guard must exit 0. LIMIT is only the kill; every run must also
# answer within HOOK_BOUND_MS.
# Runs use a UTF-8 locale when there is one (DA #3: the multibyte payloads exist to hit bash's
# wide-character slow paths, which the C locale a bare CI shell starts in never takes).
UTF8_LOC=""
for l in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
  [ "$( (LC_ALL=$l; s=$'\303\251'; printf %s "${#s}") 2>/dev/null)" = 1 ] && { UTF8_LOC=$l; break; }
done
[ -n "$UTF8_LOC" ] || echo "SKIP: no UTF-8 locale — the size cases below run in the C locale, off the wide-character paths"
now_ms() { local n="${EPOCHREALTIME:-}"; n="${n//[!0-9]/}"; if [ -n "$n" ]; then echo $((10#$n / 1000)); else echo $(( $(date +%s) * 1000 )); fi; }
bounded() {
  local label="$1" lim="$2" pf="$3" pid wd rc t0
  t0=$(now_ms)
  env ${UTF8_LOC:+LC_ALL=$UTF8_LOC} bash "$SCRIPT" < "$pf" > "$TMP/bounded.out" 2> "$TMP/bounded.err" & pid=$!
  # TERM, then KILL 2 s later: a guard blocked writing a pipe on MSYS ignores TERM, and `wait` on it
  # never returned — the test hung until run-all's timeout with no message (final review, 0.54.1).
  ( sleep "$lim"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 & wd=$!
  wait "$pid"; rc=$?
  BD_MS=$(( $(now_ms) - t0 )); BD_EL=$((BD_MS / 1000))
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  [ "$BD_MS" -lt $((lim * 1000)) ] || fail "$label: still running after ${lim}s (killed)"
  [ "$rc" = 0 ] || fail "$label: the guard exited $rc ($(head -c 300 "$TMP/bounded.err"))"
  # Every size case must answer inside the hook budget (item F8/DA #6: the old 10 s lock let a
  # 9 s answer pass while production cancelled it at 5 s).
  [ "$BD_MS" -le "$HOOK_BOUND_MS" ] || fail "$label: answered in ${BD_MS} ms, bound $HOOK_BOUND_MS ms — past it the hook is cancelled and the tool RUNS"
  BD_OUT=$(cat "$TMP/bounded.out")
}
# within LABEL MS: the last bounded run answered inside MS milliseconds.
within() { [ "$BD_MS" -le "$2" ] || fail "$1: answered in ${BD_MS} ms, bound $2 ms — past it the hook is cancelled and the Write RUNS"; }
# The hook timeout is 5 s; hook-timer.sh, bash's start and the spawn under a loaded box take the
# rest: a case that must answer in time is bound at 4 s. BIG_BOUND stays the kill limit.
HOOK_BOUND_MS=4000
# big_body N: an 'é' (bash then matches in wide characters, the slow case) and N bytes of lines.
big_body() { printf '\303\251'; printf '%*s' "$1" '' | tr ' ' x | fold -w 80 | awk '{printf "%s\\n", $0}'; }
BIG_BOUND=10
BODY=$(big_body 524288)
# P-H1: 512 KB Writes. A file_path after the content reaches only the full logic (165 s before).
printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"%s"}}' "$NON_WIKI_FILE" "$BODY" > "$TMP/big1.json"
bounded "P-H1 512 KB non-wiki Write" "$BIG_BOUND" "$TMP/big1.json"
[ -z "$BD_OUT" ] || fail "P-H1: a 512 KB non-wiki Write must stay silent (got: $BD_OUT)"
pass "P-H1: 512 KB non-wiki Write answered in ${BD_EL}s"
printf '{"tool_name":"Write","tool_input":{"content":"# bare\\n%s","file_path":"%s"}}' "$BODY" "$TMP/knowledge/wiki/concepts/big-page.md" > "$TMP/big2.json"
bounded "P-H1 512 KB bare wiki page, file_path last" "$BIG_BOUND" "$TMP/big2.json"
echo "$BD_OUT" | grep -q '"permissionDecision":"deny"' && echo "$BD_OUT" | grep -q frontmatter \
  || fail "P-H1: a 512 KB bare wiki page (file_path last) must be denied (got: $BD_OUT)"
pass "P-H1: 512 KB bare wiki page (file_path last) denied in ${BD_EL}s"

# SEC-C1: a 65,600-byte payload whose file_path needs jq (\u escape): the fallback's here-string
# hung on MSYS for good.
C1_PRE="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/knowledge/wiki/concepts/\\u0062ig-c1.md\",\"content\":\"# bare"
{ printf '%s' "$C1_PRE"; printf '%*s' $(( 65600 - ${#C1_PRE} - 3 )) '' | tr ' ' x; printf '"}}'; } > "$TMP/c1.json"
[ "$(wc -c < "$TMP/c1.json" | tr -d ' ')" = 65600 ] || fail "SEC-C1 fixture: payload is not 65,600 bytes"
bounded "SEC-C1 65,600-byte payload (jq fallback)" 20 "$TMP/c1.json"
echo "$BD_OUT" | grep -q '"permissionDecision":"deny"' || fail "SEC-C1: the 65,600-byte bare wiki Write must be denied (got: $BD_OUT)"
pass "SEC-C1: a 65,600-byte payload through the jq fallback answers in ${BD_EL}s"

# RR-CR1: a file_path ending in 50,000 CONSECUTIVE trailing newlines. The full logic's _fp_clean
# used to strip them one at a time (`${v%"$_fp_nl"}` in a loop): O(N x length) for N trailing
# newlines, 40 s here past the 5 s hook timeout (a fail-open DoS). Verdict must be unchanged: a
# bare wiki page write still denies on frontmatter.
TRAIL50K=$(i=0; while [ $i -lt 50000 ]; do printf '\\n'; i=$((i + 1)); done)
printf '{"tool_name":"Write","tool_input":{"content":"# bare","file_path":"%s%s"}}' "$TMP/knowledge/wiki/concepts/cr1.md" "$TRAIL50K" > "$TMP/cr1.json"
bounded "RR-CR1 50,000 consecutive trailing newlines, bare wiki page" "$BIG_BOUND" "$TMP/cr1.json"
echo "$BD_OUT" | grep -q '"permissionDecision":"deny"' && echo "$BD_OUT" | grep -q frontmatter \
  || fail "RR-CR1: 50,000 trailing newlines must still deny the bare wiki page on frontmatter (got: $BD_OUT)"
within "RR-CR1 50,000 trailing newlines" "$HOOK_BOUND_MS"
pass "RR-CR1: 50,000 consecutive trailing newlines answered in ${BD_MS} ms (bare page still denies)"

# F8 item 18: the file_path itself carries the 50,000 newlines, text after them. Every file_path goes
# through _fp_lower (case-insensitive scope match), whose per-character loop was O(n^2): this payload
# never answered on MSYS (rc=124 past 60 s, before and after the trim fix) — a fail-open.
printf '{"tool_name":"Write","tool_input":{"content":"# bare","file_path":"%s/knowledge/wiki/concepts/CR1%s.md"}}' "$TMP" "$TRAIL50K" > "$TMP/cr1p.json"
bounded "item 18: 50,000 newlines inside a wiki file_path" "$BIG_BOUND" "$TMP/cr1p.json"
echo "$BD_OUT" | grep -q '"permissionDecision":"deny"' && echo "$BD_OUT" | grep -q frontmatter \
  || fail "item 18: a bare page whose file_path holds 50,000 newlines must still deny on frontmatter (got: $BD_OUT)"
T50K_MS=$BD_MS
pass "item 18: 50,000 newlines inside a wiki file_path answered in ${BD_MS} ms (bare page still denies)"

# Final review (0.54.1): one size could not tell linear from quadratic — the tombstone lookup's
# ${FILE_PATH##*/} costs basename x length and took 6-8 s at 150,000 newlines. Three times the size,
# same bound: the tombstone block now skips a path it cannot be about (newline or over 4096 chars).
TRAIL150K=$(printf '%150000s' '' | sed 's/ /\\n/g')
printf '{"tool_name":"Write","tool_input":{"content":"# bare","file_path":"%s/knowledge/wiki/concepts/CR3%s.md"}}' "$TMP" "$TRAIL150K" > "$TMP/cr3p.json"
bounded "150,000 newlines inside a wiki file_path" "$BIG_BOUND" "$TMP/cr3p.json"
echo "$BD_OUT" | grep -q '"permissionDecision":"deny"' && echo "$BD_OUT" | grep -q frontmatter \
  || fail "150k: a bare page whose file_path holds 150,000 newlines must still deny on frontmatter (got: ${BD_OUT:0:200})"
# Linearity, not a wall-clock bound: the same shape at 3x the size must cost at most ~4x (a
# quadratic step costs ~9x), which holds on any runner speed; BIG_BOUND above still catches a hang.
# The ratio needs sub-second timing: without EPOCHREALTIME (bash < 5, the macOS/bash-3.2 lane) now_ms
# is whole seconds, so a sub-second 50k baseline reads 0 ms and the 150k run reads 1000 ms — an
# unmeasurable, always-failing ratio. Assert it only where the clock can see it; the deny above and
# the BIG_BOUND hang guard still run everywhere.
if [ -n "${EPOCHREALTIME:-}" ]; then
  [ "$BD_MS" -le $(( T50K_MS * 4 + 500 )) ] || fail "150k: 3x the newlines cost ${BD_MS} ms vs ${T50K_MS} ms at 50k (over 4x: super-linear)"
fi
pass "150,000 newlines inside a wiki file_path answered in ${BD_MS} ms (bare page still denies)"

# F8 #1: 50,000 REAL newlines inside the payload itself — JSON whitespace between two keys, text
# after them — so the whole-payload trim (_fp_raw_all) sees a run followed by other text. The
# `($_fp_nl+)$` regex it used was O(run^2) on glibc for that shape.
{ printf '{"tool_name":"Write",'; printf '%50000s' '' | tr ' ' '\n'
  printf '"tool_input":{"content":"# bare","file_path":"%s"}}' "$TMP/knowledge/wiki/concepts/cr1ws.md"; } > "$TMP/cr1ws.json"
bounded "F8 50,000 newlines of JSON whitespace, bare wiki page" "$BIG_BOUND" "$TMP/cr1ws.json"
echo "$BD_OUT" | grep -q '"permissionDecision":"deny"' && echo "$BD_OUT" | grep -q frontmatter \
  || fail "F8: 50,000 newlines of JSON whitespace must still deny the bare wiki page on frontmatter (got: $BD_OUT)"
within "F8 50,000 newlines of JSON whitespace" "$HOOK_BOUND_MS"
pass "F8: 50,000 real newlines between two payload keys answered in ${BD_MS} ms (bare page still denies)"

echo
echo "ALL PASS"
