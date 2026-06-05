#!/bin/bash
# SP-C: the dream nudge surfaces only dreams AWAITING REVIEW (completed + archived_at unset),
# escalates a genuinely-stale one, surfaces a count for several, and goes SILENT once a dream
# is archived (accept/discard stamp archived_at while leaving status "completed").
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"; SL="$ROOT/scripts/session-load.sh"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }

B=$(mktemp -d); : > "$B/USER.md"; mkdir -p "$B/dreams"
# $1 id $2 status $3 archived_at("" → null) $4 added $5 modified $6 touch-stamp("" → now)
mkdrm(){ local d="$B/dreams/$1"; mkdir -p "$d"; local arch="null"; [ -n "$3" ] && arch="\"$3\""
  printf '{"id":"%s","status":"%s","archived_at":%s,"ended_at":"2026-05-17T15:37:23Z","outputs":{"pages_added":%s,"pages_modified":%s}}\n' \
    "$1" "$2" "$arch" "$4" "$5" > "$d/status.json"
  [ -n "$6" ] && touch -t "$6" "$d/status.json"; }
emit(){ printf '{"hook_event_name":"SessionStart","cwd":"/tmp"}' | env BRAIN_DIR="$B" bash "$SL" 2>/dev/null; }
ago(){ date -d "$1" +%Y%m%d%H%M 2>/dev/null || date -v-"$2" +%Y%m%d%H%M; }   # GNU || BSD

# 1. ARCHIVED completed dream → SILENT (the reported bug: was re-nagging forever)
mkdrm drm_a completed 2026-05-17T16:22:56Z 4 21 ""
out=$(emit)
echo "$out" | grep -qiE 'Dream drm_a|review and accept|UNREVIEWED' && fail "nagged about an ARCHIVED (terminal) dream" || pass "archived dream → silent (bug fixed)"

# 2. FRESH completed-unarchived → normal nudge (not escalated)
rm -rf "$B/dreams"/*; mkdrm drm_b completed "" 3 5 ""
out=$(emit)
echo "$out" | grep -q 'Dream drm_b completed' || fail "no nudge for a fresh completed dream"
echo "$out" | grep -q 'UNREVIEWED' && fail "fresh dream wrongly escalated" || pass "fresh completed → normal nudge"

# 3. STALE completed-unarchived (mtime ~30d old) → escalated banner
rm -rf "$B/dreams"/*; mkdrm drm_c completed "" 4 21 "$(ago '30 days ago' 30d)"
out=$(emit)
{ echo "$out" | grep -q 'UNREVIEWED' && echo "$out" | grep -q 'NOT in your wiki'; } || fail "stale dream not escalated"
pass "stale completed → escalated 'UNREVIEWED / not in your wiki' banner"

# 4. iterate-all: two unaccepted → a count is surfaced (no silent drop of the 2nd)
rm -rf "$B/dreams"/*; mkdrm drm_d completed "" 1 1 ""; mkdrm drm_e completed "" 2 2 ""
out=$(emit)
echo "$out" | grep -qE '\+1 more' && pass "multiple awaiting → count surfaced (no silent drop)" || fail "second unaccepted dream silently dropped"

# 5. running/pending dreams are NOT nudged (only completed-unarchived)
rm -rf "$B/dreams"/*; mkdrm drm_f running "" 0 0 ""
out=$(emit)
echo "$out" | grep -qiE 'Dream drm_f|review' && fail "nudged about a running dream" || pass "running dream → no nudge"

rm -rf "$B"; echo; echo "ALL PASS"
