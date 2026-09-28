#!/bin/bash
# Idempotent merge of a JSON delta into PROJECT.md + wiki pages. Used by
# the Stop-hook auto-archival flow (scripts/stop-extract.sh).
#
# Usage:
#   bash merge-project-update.sh --project-md <path> --knowledge-dir <dir> [--json-file <path>]
#   # or pipe JSON on stdin
#
# JSON schema (all keys optional, default to []):
#   {
#     "recent_decisions": ["<text>", ...],   # cap 3 bullets in PROJECT.md
#     "open_blockers":    ["<text>", ...],   # cap 15
#     "cross_refs":       ["<slug>", ...],   # cap 3, scaffolds ~/knowledge/wiki/entities/<slug>.md if missing
#     "files_touched":    ["<path>", ...],   # informational
#     "plan":             ["<text>", ...],   # forward checklist -- see ## Plan grammar below. Each
#                                             # item passes a LIGHT per-item gate (gate_plan_items: one
#                                             # jq pass, SEC-M4/R2-SF4) -- the extractor can echo
#                                             # transcript content verbatim. A flagged item is dropped
#                                             # on its own (logged once), the rest reconcile normally.
#                                             # No length cut, no scanner spawn.
#     "compact_pending":  ["<text>", ...],   # PostCompact Pending-Tasks bullets, add-only. Capped to 5,
#                                             # deduped, cut to 120 codepoints, THEN sanitized and
#                                             # injection-scanned by gate_untrusted_items() (SF-H1/
#                                             # SEC-M3/N5: exactly what is stored is what is scanned) --
#                                             # the caller (pre-compact.sh post) only extracts the
#                                             # Pending Tasks section and passes the raw text through.
#                                             # Landed as "- [ ] [untrusted:compact TODAY] <text>".
#                                             # Refused once non-pinned unfinished lines (counted AFTER
#                                             # this merge aged the Plan) would reach 15.
#     "wiki_updates":     [{"category","slug","action","title","description","content"}, ...]
#   }
#
# --session <sid>  (optional flag, not a JSON key): sanitized to [A-Za-z0-9_-]{1,64}. Stamps
#   ## Handoff's "written: t=... session=... branch=... head=..." line from
#   $BRAIN_DIR/.injected/<sid>.prov (sb_session_prov_write, lib.sh) when that file exists.
#
# ## Plan grammar (the contract every emitter/reader codes against):
#   - [pinned] <text>                                           human north star -- never touched here
#   - [ ] [pinned] <text> / - [x] [pinned] <text>               also pinned (the token must LEAD the text)
#   - [ ] <text>                                                current unfinished item (extractor/human)
#   - [x] <text>                                                done; retired by the next emission that omits it
#   - [x] <text> (dropped: <why>)                               retired without doing it
#   - [ ] [untrusted:compact YYYY-MM-DD] <text>                 added by compact_pending (source mark, sticky)
#   - [ ] [carried YYYY-MM-DD] <text>                           omitted by an emission; kept by the guard
#   - [ ] [untrusted:compact YYYY-MM-DD] [carried YYYY-MM-DD] <text>   both (source first)
#   - [stale] [ ] [carried YYYY-MM-DD] <text>                   aged by mark_stale
#   Bounds: 15 non-pinned unfinished lines (emitted+carried+compact), 5 stale (oldest DATE dropped
#   first, logged; enforced on every merge by mark_stale).
#   Ownership: the reconcile owns ONLY checklist lines ("- [ ]", "- [x]", "- [stale]"). Every other
#   line in the section -- prose, ### headings, tables, code fences, indented or numbered items,
#   plain bullets, pinned lines -- stays verbatim in its original position (one gate=plan-unparsed
#   trace row counts the non-pinned ones). Only the FIRST "## Plan" / "## Plan <suffix>" header is
#   the Plan; a later "## Plan ..." header is an ordinary section and is never reconciled.
#   Aging: a new line carried by an omitting emission gets [carried TODAY]; the [untrusted:compact D]
#   date only ages a line when this merge had no plan emission (the OAuth/no-drainer case), and a
#   mark echoed by the extractor never supplies an old date (a NEW marked item gets TODAY).
#
# Behavior:
#   - Empty deltas → no-op (PROJECT.md unchanged, no timestamp bump).
#   - Decisions/blockers de-duped by case-insensitive substring match
#     against existing bullets in the same section.
#   - Cross-refs de-duped case-insensitively against existing [[refs]].
#   - When ANY section actually changed, last_updated footer is bumped.
#   - Missing cross-ref pages get a proper frontmatter stub in wiki/entities/.
#   - Atomic write: stage to a tempfile, mv into place.
#   - Invalid JSON on stdin → exit non-zero with PROJECT.md untouched.
set -u
source "$(dirname "$0")/lib.sh"

# F4 (0.54.0 round 2): EVERY awk and tr in this script runs in byte mode. Apple awk exits 2 on any
# regex test of an invalid-UTF-8 line under a UTF-8 locale (a torn goal line from the old byte cut
# failed merge_plan, merge_state, mark_stale and the timestamp step on every merge). Functions
# shadow the commands for this script and everything it calls in-process (lib.sh helpers
# included); `command` keeps PATH lookup, and a leading VAR=value on a call still reaches the
# child (bash 3.2 and 5.x).
awk() { LC_ALL=C command awk "$@"; }
tr() { LC_ALL=C command tr "$@"; }
# F2: ONE case-folding rule on BOTH sides of every text dedup -- the same awk tolower() that folds
# the stored lines. tr (ASCII-only) and awk tolower() never agree on non-ASCII text: gawk under a
# UTF-8 locale folds Unicode letters, and MSYS gawk even under LC_ALL=C folds the Latin-1 byte
# range (it rewrites UTF-8 lead bytes). Mixing the two re-inserted a "Łódź ..." decision (or a
# pinned Plan echo) on every merge. What tolower() does with those bytes does not matter as long as
# BOTH keys come from it; keys are compared, never written.
lc() { awk '{ print tolower($0) }'; }

PROJECT_MD=""
JSON_FILE=""
KNOWLEDGE_DIR=""
SESSION_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project-md)    PROJECT_MD="$2";    shift 2 ;;
    --knowledge-dir) KNOWLEDGE_DIR="$2"; shift 2 ;;
    --json-file)     JSON_FILE="$2";     shift 2 ;;
    --session)       SESSION_ARG="$2";   shift 2 ;;
    *) echo "merge-project-update: unknown arg: $1" >&2; exit 2 ;;
  esac
done
# --session is provenance, not a security boundary -- an invalid value just degrades to "no
# session" rather than ever reaching the Handoff stamp or a filesystem path unsanitized (C4,
# lib.sh sb_session_prov_write writes the .prov file this reads by the SAME sid, so the
# charset already matches on the write side). SF-L6: lib.sh (and BRAIN_DIR) ARE already
# sourced by this point -- log the drop at ec0 (trace, not a real failure: a bad --session is
# an upstream caller bug, not this script's) instead of the old, truly silent no-op.
case "$SESSION_ARG" in
  *[!A-Za-z0-9_-]*)
    sb_log_error "merge-project-update.sh" "gate=session-arg-invalid dropped --session (bad charset)" 0
    SESSION_ARG=""
    ;;
esac
SESSION_ARG="${SESSION_ARG:0:64}"

[ -n "$PROJECT_MD" ] || { echo "merge-project-update: --project-md is required" >&2; exit 2; }
[ -z "$KNOWLEDGE_DIR" ] && KNOWLEDGE_DIR="$(sb_knowledge_dir)"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"   # re-expand: a --knowledge-dir arg may carry a literal ~
KNOWLEDGE_WIKI="$KNOWLEDGE_DIR/wiki"
# The render CLI turns a structured ai_block into the marked region deterministically
# (reuses the TS schema → no bash/TS drift). Resolved relative to this script (plugin root).
RENDER_CLI="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")"/.. && pwd)}/mcp/dist/tools/ai-block-render-cli.bundle.js"
[ -f "$PROJECT_MD" ] || { echo "merge-project-update: project file not found: $PROJECT_MD" >&2; exit 2; }
# Originating project slug = the PROJECT.md parent dir. Stamped as the project: facet on
# pages this run creates, and the key for the wiki-writes counter + session-count reset.
# Validated, NOT sb_sanitize_slug'd: the facet must equal the registry slug EXACTLY for
# scoped search (sub-project slugs like mono__api carry underscores sanitize would eat).
# Charset mirrors validateSlug (path-guard.ts): dots ALLOWED (real project dirs like
# my.app must keep their counters + facet), leading dot / "/" / empty rejected. A
# rejected name blanks the slug (no bogus facet) and is logged — blanking also disables
# the two state sinks above, which must never happen silently.
PROJECT_SLUG=$(basename "$(dirname "$PROJECT_MD")")
case "$PROJECT_SLUG" in
  ''|/|.*|*[!a-zA-Z0-9._-]*)
    if [ -n "$PROJECT_SLUG" ] && [ "$PROJECT_SLUG" != "." ] && [ "$PROJECT_SLUG" != "/" ]; then
      sb_log_error "merge-project-update.sh" "project slug '$PROJECT_SLUG' fails the facet charset — project: stamp, wiki-writes counter, and session-count reset skipped this run" 0
    fi
    PROJECT_SLUG=""
    ;;
esac

if [ -n "$JSON_FILE" ]; then
  RAW=$(cat "$JSON_FILE")
else
  RAW=$(cat)
fi

if ! echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "merge-project-update: input is not a JSON object" >&2
  exit 1
fi

WIKI_WRITES=0

# Strip CR from every line — Windows / Git-Bash jq pipelines can leak \r
# into values, which silently breaks all our string comparisons below.
strip_cr() { tr -d '\r'; }

# ## Plan normalization key (Slice 1 §2), shared by merge_plan and merge_compact_pending so a
# carried/compact-sourced/emitted/card-rendered form of the SAME item always keys the SAME way.
# Kept as ONE awk library string (apostrophe-free -- the single-quoted-program trap) prefixed
# onto the callers' `awk` invocations, per the "single awk, no per-item spawn" rule. Every
# caller runs it under LC_ALL=C (R2-SF3): keys are byte-oriented by design (both sides of every
# compare come from this same function, see lc() above), and a UTF-8 locale made gawk warn on
# any non-UTF-8 byte in PROJECT.md -- a warning the strict stderr checks below used to read as a
# failure, freezing the Plan on every merge.
# Steps: 1) lowercase  2) fold every [ ] to ( ) (NEW-M3b: the card renders brackets as parens,
# compact_pending and the plan[] gate neutralize them the same way, so bracketed text only
# round-trips when the key ignores the difference)  3) strip a leading bullet  4) repeatedly
# strip LEADING marker tokens (checkbox/pinned/stale/untrusted:compact D/carried D)
# 5) repeatedly strip TRAILING age/provenance parentheticals  6) collapse whitespace + trim +
# drop trailing punctuation. A meaningful trailing "(Windows only)" is not one of step 5's
# patterns, so it survives.
PLAN_NORM_AWK='
function plan_norm(raw,  s,t) {
  s = tolower(raw)
  gsub(/\[/, "(", s)
  gsub(/\]/, ")", s)
  gsub(/\t/, " ", s)
  sub(/^[ ]*[-*+][ ]+/, "", s)
  while (1) {
    t = s
    sub(/^\( \)[ ]*/, "", s)
    sub(/^\(x\)[ ]*/, "", s)
    sub(/^\(pinned\)[ ]*/, "", s)
    sub(/^\(stale\)[ ]*/, "", s)
    sub(/^\(untrusted:compact[ 0-9-]*\)[ ]*/, "", s)
    sub(/^\(carried[ 0-9-]*\)[ ]*/, "", s)
    if (s == t) break
  }
  while (1) {
    t = s
    sub(/[ ]*\(<1h\)[ ]*$/, "", s)
    sub(/[ ]*\([0-9]+[mhd]\)[ ]*$/, "", s)
    sub(/[ ]*\([0-9]+[mhd] ago\)[ ]*$/, "", s)
    sub(/[ ]*\(carried[^)]*\)[ ]*$/, "", s)
    sub(/[ ]*\(dropped:[^)]*\)[ ]*$/, "", s)
    sub(/[ ]*\(stale[^)]*\)[ ]*$/, "", s)
    if (s == t) break
  }
  gsub(/[ ]+/, " ", s)
  sub(/^ /, "", s)
  sub(/ $/, "", s)
  sub(/[.:;,!]+$/, "", s)
  return s
}
# CR-M4 / NEW-M3c: session-load.sh renders a Plan line into a card cut at a display cap and
# appends an ellipsis when it truncates, so a re-fed echo of that card is a TRUNCATED prefix of
# a real item. plan_key() therefore looks for a trailing ellipsis (the real one or ASCII "...")
# on the RAW text, BEFORE plan_norm strips trailing dots (which made the ASCII branch dead), and
# reports it in the global KELL so keymatch() can prefix-match that side. Byte-literal matching
# is fine under LC_ALL=C: both forms are fixed byte sequences, never a character class.
function plan_key(raw,   s) {
  s = raw
  sub(/[ \t]+$/, "", s)
  KELL = 0
  if (s ~ /\.\.\.$/) { KELL = 1; sub(/\.\.\.$/, "", s) }
  else if (s ~ /…$/) { KELL = 1; sub(/…$/, "", s) }
  return plan_norm(s)
}
function keymatch(ka, ea, kb, eb) {
  if (ka == kb) return 1
  if (ea && length(ka) > 0 && index(kb, ka) == 1) return 1
  if (eb && length(kb) > 0 && index(ka, kb) == 1) return 1
  return 0
}
'
# Plan LINE helpers (merge_plan + mark_stale): the pinned rule, the two dated tokens, and the
# display text of a stored checklist line. Pinned is ANCHORED (N1): only "- [pinned] X",
# "- [ ] [pinned] X" and "- [x] [pinned] X" -- a "[pinned]" anywhere else in a line is plain text,
# so no emitted or compacted text can ever grow into an immortal line.
PLAN_LINE_AWK='
function is_pinned(line) { return (line ~ /^- (\[[ xX]\] )?\[pinned\]/) }
function findmarker(line) {
  if (match(line, /\[untrusted:compact 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/)) return substr(line, RSTART, RLENGTH)
  return ""
}
function carried_date(line) {
  if (match(line, /\[carried 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/)) return substr(line, RSTART + 9, 10)
  return ""
}
function compact_date(line) {
  if (match(line, /\[untrusted:compact 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/)) return substr(line, RSTART + 19, 10)
  return ""
}
function owned_text(line,   t, t2) {
  t = line
  sub(/^- /, "", t)
  sub(/^\[stale\][ ]*/, "", t)
  sub(/^\[[ xX]\][ ]*/, "", t)
  while (1) {
    t2 = t
    sub(/^\[untrusted:compact[ 0-9-]*\][ ]*/, "", t)
    sub(/^\[carried[ 0-9-]*\][ ]*/, "", t)
    if (t == t2) break
  }
  return t
}
'

# One gate verdict per untrusted item (plan[] and compact_pending share it). Classes, in this
# precedence: control = any \p{Cc} (items are single-line by the time they get here, so no
# character is exempt); format = invisible/format characters (\p{Cf} incl. the Tags block,
# line/paragraph separators, variation selectors incl. the E0100 supplement, Hangul fillers,
# U+034F); phrase = every tool-return-scanner.sh pattern, case-INSENSITIVE (that scanner is
# case-sensitive after the first letter), plus the evasions it misses: "ignore the above
# instructions", "disregard", a system: marker or a <system>/<system-reminder> tag ANYWHERE in
# the text (not only at line start -- a leading "[ ] " used to defeat the anchor). jq/Oniguruma,
# 1.7.1-safe; apostrophe-free (it lives inside single quotes).
GATE_CLASS_JQ='
  def bad_class:
    if test("\\p{Cc}") then "control"
    elif test("[\\p{Cf}\\p{Zl}\\p{Zp}\\x{FE00}-\\x{FE0F}\\x{E0100}-\\x{E01EF}\\x{115F}\\x{1160}\\x{3164}\\x{FFA0}\\x{034F}]") then "format"
    elif test("ignore\\s+(all\\s+)?(the\\s+)?(previous|prior|above)\\s+(instructions?|context|messages?|directions?|prompts?)|\\bdisregard\\b|\\bsystem\\s*:|<\\s*/?\\s*system([\\s>/-]|$)|</?(human|assistant)[\\s>]|(begin|end)\\s+(prompt|system\\s+prompt|instructions?)|do\\s+not\\s+(tell|inform|notify|mention)\\s+(the\\s+)?user|execute\\s+the\\s+following\\s+(command|code|instructions?|prompt)|new\\s+(instructions?|system\\s+prompt|directive)\\s*:"; "i") then "phrase"
    else "" end;
  def gate_row($v):
    [ $v[] | select(.c != "") ] as $bad
    | "GATE \($bad | length) \(if ($bad | length) == 0 then "-" else ([ $bad[] | .i | tostring ] | join(",")) end) \(if ($bad | length) == 0 then "-" else ([ $bad[] | .c ] | join(",")) end)";
'

# Failure-row helper (R2-SF8): the flattened, bounded head of a captured stderr text. Only ever
# called on a failure path, so its spawns never touch the happy path.
err_head() { [ -n "${1:-}" ] && printf '%s' "$1" | tr '\r\n\t' '   ' | head -c 200; }

# D142: guard these four array fields the same way merge_handoff (below) already
# guards handoff's fields — `jq -r '.[]?'` alone pretty-prints a non-string
# element across several physical lines and expands any embedded \n in a
# string, so ONE malformed/multi-line element became SEVERAL independently
# dated, independently 5/15/3/7-capped bullets (brace/key fragments, injected
# headings), rotating real decisions off the cap. flatten_field keeps only
# string elements (dropping anything else, logged once) and collapses embedded
# CR/LF to a space so exactly one source element becomes exactly one line.
flatten_field() {
  local raw="$1" key="$2" out dropped
  out=$(printf '%s' "$raw" | jq -r --arg k "$key" '
    (.[$k] // []) | (if type == "array" then . else [] end)
    | map(select(type == "string" and . != ""))
    | .[]
    | gsub("[\r\n]+"; " ")
  ' 2>/dev/null | strip_cr)
  dropped=$(printf '%s' "$raw" | jq -r --arg k "$key" '
    (.[$k] // []) | (if type == "array" then . else [] end) | map(select(type != "string")) | length
  ' 2>/dev/null)
  if [ -n "${dropped:-}" ] && [ "$dropped" -gt 0 ] 2>/dev/null; then
    sb_log_error "merge-project-update.sh" "$key: dropped $dropped non-string element(s)" 0
  fi
  printf '%s' "$out"
}
DECISIONS=$(flatten_field "$RAW" recent_decisions)
BLOCKERS=$(flatten_field "$RAW" open_blockers)
REFS=$(flatten_field "$RAW" cross_refs)
# plan[] is NOT flattened here: gate_plan_items (below, one jq pass) flattens AND gates it.
PLAN=""
# One line only, bounded, leading markdown-header chars stripped (a '#'-prefixed
# emission would fork the section structure).
# Codepoint-safe cut (CR-H1 class): `head -c 240` is BYTE-based and can tear a multi-byte
# UTF-8 character mid-codepoint; jq's `.[0:240]` slices by codepoint. Folded into ONE jq call.
SESSION_GOAL=$(echo "$RAW" | jq -r '
  (.session_goal // "")
  | gsub("\r"; "")
  | split("\n")[0]
  | sub("^#*[ \t]*"; "")
  | .[0:240]
' 2>/dev/null)
# jq on Windows writes CRLF; a single-line capture keeps a trailing CR on some hosts (R2-SF1 class).
SESSION_GOAL="${SESSION_GOAL//$'\r'/}"

CHANGED=0

TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT
# tr -d '\r' (not cp): normalize CRLF at ingest so every downstream awk/grep reader sees LF.
# A CRLF PROJECT.md (Windows/imported) otherwise silently no-ops the ENTIRE merge — section
# headers like `## Recent decisions` never match `/^## .../`, so decisions/blockers/plan are
# never written and dedup never fires. The merge writes TMP_OUT back, so this also LF-normalizes.
tr -d '\r' < "$PROJECT_MD" > "$TMP_OUT"
# R2-SF7: the final guard below compares the staged buffer against THIS file's own first
# heading (whatever the human named it), never a hardcoded "# PROJECT" -- a hand-renamed
# heading used to make every later merge refuse to write, with a misleading message.
ORIG_HEAD=$(LC_ALL=C grep -m1 -E '^#+ ' "$TMP_OUT")

# Archive a dropped decision bullet to the wiki decisions log — PER PROJECT, with a
# project: facet, so rotated decisions stay reachable by project-scoped search instead
# of piling into one cross-project global file (invisible to tiering).
archive_dropped_decision() {
  local text="$1"
  text=$(echo "$text" | sed 's/^- //')
  [ -z "$text" ] && return 0
  local archive_file
  if [ -n "$PROJECT_SLUG" ]; then
    archive_file="$KNOWLEDGE_WIKI/decisions/${PROJECT_SLUG}-decisions-log.md"
  else
    archive_file="$KNOWLEDGE_WIKI/decisions/project-decisions-log.md"
  fi
  mkdir -p "$(dirname "$archive_file")"
  if [ ! -f "$archive_file" ]; then
    local ts_now
    ts_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    {
      printf '%s\n' "---"
      printf 'title: "Archived Project Decisions%s"\n' "${PROJECT_SLUG:+ — $PROJECT_SLUG}"
      printf 'type: decisions\n'
      printf 'description: "Auto-archived decisions rotated out of PROJECT.md hot tier"\n'
      printf 'created: %s\n' "$ts_now"
      printf 'updated: %s\n' "$ts_now"
      [ -n "$PROJECT_SLUG" ] && printf 'project: %s\n' "$PROJECT_SLUG"
      printf '%s\n\n' "---"
      printf '# Archived Project Decisions%s\n\n' "${PROJECT_SLUG:+ — $PROJECT_SLUG}"
    } > "$archive_file"
  fi
  printf '%s\n' "- $text" >> "$archive_file"
  WIKI_WRITES=1
}

# Insert a bullet under "## <section>", dedupe case-insensitively, cap N.
# Drops the oldest (top-most) bullet when cap is reached. For decisions,
# dropped bullets are archived to wiki instead of discarded.
insert_bullet() {
  local section="$1" bullet_text="$2" cap="$3"
  [ -z "$bullet_text" ] && return 0

  local lower_new ln_ec
  # Strip date prefix and common markers for dedup comparison
  lower_new=$(printf '%s' "$bullet_text" | sed 's/^\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\] //' | sed 's/^\[active\] //;s/^\[resolved\] //;s/^\[stale\] //;s/^\[decision\] //;s/^\[pinned\] //' | lc); ln_ec=$?
  # F7: an EMPTY key is never a duplicate -- `grep -qF -- ""` matches every line, so a failed
  # normalization (a fork failure under load) used to drop the bullet silently as a "dup".
  # Fail loud and insert it undeduped instead: a possible duplicate beats a lost decision.
  local skip_dedup=0
  if [ -z "$lower_new" ]; then
    sb_log_error "merge-project-update.sh" "gate=insert-bullet-normalize-failed section=$section ec=$ln_ec — dedup skipped, bullet inserted" 1
    skip_dedup=1
  fi
  local existing_lower
  # [superseded]/[stale] bullets are NOT part of the dedup corpus: grep -qF below is a
  # SUBSTRING match, so a superseded line containing the original text would silently
  # block a legitimate flip-flop re-pin AND count as a dedup hit — inflating the
  # gate=decision-capture pinned counter with matches that are not evidence of
  # in-session pinning. Mirrors the TS pin-to-project dedup semantics (0.48.0).
  existing_lower=$(awk -v s="$section" '
    $0 == s { flag=1; next }
    /^## / { flag=0 }
    flag && /^- \[superseded\] / { next }
    flag && /^- \[stale\] / { next }
    flag && /^- / { gsub(/^- (\[[0-9]{4}-[0-9]{2}-[0-9]{2}\] )?(\[(active|resolved|stale|decision|pinned)\] )?/, "- "); print tolower($0) }
  ' "$TMP_OUT")
  if [ "$skip_dedup" -eq 0 ] && echo "$existing_lower" | grep -qF -- "$lower_new"; then
    LAST_INSERT_DUP=1
    return 0
  fi

  local count
  count=$(awk -v s="$section" '
    $0 == s { flag=1; next }
    /^## / { flag=0 }
    flag && /^- / { c++ }
    END { print c+0 }
  ' "$TMP_OUT")

  local new_tmp
  new_tmp=$(mktemp)
  if [ "$count" -ge "$cap" ]; then
    # Capture the oldest bullet before dropping it
    if [ "$section" = "## Recent decisions" ]; then
      local oldest
      oldest=$(awk -v s="$section" '
        $0 == s { flag=1; next }
        /^## / { flag=0 }
        flag && /^- / && !/\[pinned\]/ { print; exit }
      ' "$TMP_OUT")
      [ -n "$oldest" ] && archive_dropped_decision "$oldest"
    fi
    BULLET="- $bullet_text" awk -v s="$section" '
      BEGIN { flag=0; dropped=0; appended=0; new=ENVIRON["BULLET"] }
      $0 == s { print; flag=1; next }
      flag && /^## / {
        if (!appended) { print new; appended=1 }
        flag=0; print; next
      }
      flag && !appended && !/^- / && !/^$/ {
        print new; appended=1; flag=0; print; next
      }
      flag && /^- / && !/\[pinned\]/ && !dropped { dropped=1; next }
      { print }
      END {
        if (flag && !appended) { print new }
      }
    ' "$TMP_OUT" > "$new_tmp"
  else
    BULLET="- $bullet_text" awk -v s="$section" '
      BEGIN { flag=0; appended=0; new=ENVIRON["BULLET"] }
      $0 == s { print; flag=1; next }
      flag && /^## / {
        if (!appended) { print new; appended=1 }
        flag=0; print; next
      }
      flag && !appended && !/^- / && !/^$/ {
        print new; appended=1; flag=0; print; next
      }
      { print }
      END {
        if (flag && !appended) { print new }
      }
    ' "$TMP_OUT" > "$new_tmp"
  fi
  mv "$new_tmp" "$TMP_OUT"
  CHANGED=1
}

# The compact_pending trust boundary (SF-H1 + SF-H2 + SEC-M1 capture side + SEC-M3). Text this
# script did not author -- PostCompact Pending-Tasks bullets -- passes the WHOLE gate before any
# of it is stored. The caller (merge_compact_pending) has already capped the batch to 5, deduped
# it against the Plan and cut every survivor to 120 codepoints, so what is checked here is
# EXACTLY what gets stored (N5: no filler can push a stored item past a scan window, and an item
# the dedup drops can no longer veto the rest). Steps, all whole-batch, all fail-CLOSED:
#   1) sanitize via the canonical sanitize-cli -- ANY change it would make (ZWSP/WJ/BOM/Tags,
#      a torn UTF-8 byte) is itself the smuggling signal: reject, never launder
#   2) the real injection scanner (tool-return-scanner.sh), fed on STDIN via `jq -Rs` (never
#      --arg: argv limits) as a synthetic Read return, reusing the maintained pattern library
#   3) the per-item class check shared with plan[] (GATE_CLASS_JQ: control/format/phrase,
#      case-insensitive -- catches what the case-sensitive scanner misses).
# A hit or a failure echoes nothing and logs one specific ec1 reason with its exit code and
# stderr head (R2-SF8); a scanner HIT (scanner-flagged) and a scanner CRASH (scanner-failed) are
# different events and stay apart. Every node/jq output is CR-stripped (R2-SF1: Windows jq
# writes CRLF). Residual, scanner-owned: tool-return-scanner.sh exits 0 and prints nothing both
# when clean and on several silent-degrade paths, so "clean" here means "the file existed, it
# exited 0 and printed nothing"; an opt-in clean sentinel in the scanner would close that gap.
gate_untrusted_items() {
  local items="$1" caller="$2"
  [ -z "$items" ] && return 0

  local sani_cli; sani_cli="$(sb_plugin_root)/mcp/dist/tools/sanitize-cli.bundle.js"
  if ! command -v node >/dev/null 2>&1 || [ ! -f "$sani_cli" ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=sanitize-unavailable" 1
    return 1
  fi
  # N12: ONE private stderr file for every step below, and no predictable fallback path -- when
  # mktemp itself fails nothing gets scanned, so nothing gets stored.
  local gerr=""
  gerr=$(mktemp "${TMPDIR:-/tmp}/sb-scan-err.XXXXXX" 2>/dev/null) || gerr=""
  if [ -z "$gerr" ] || [ ! -f "$gerr" ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=scanner-failed src=mktemp" 1
    return 1
  fi

  local sani_out sani_ec
  sani_out=$(printf '%s' "$items" | node "$sani_cli" 2>"$gerr"); sani_ec=$?
  sani_out="${sani_out//$'\r'/}"
  if [ "$sani_ec" -ne 0 ] || [ -z "$sani_out" ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=sanitize-failed ec=$sani_ec err=$(err_head "$(cat "$gerr")")" 1
    rm -f "$gerr"; return 1
  fi
  # Byte-exact compare (bash `!=` is a plain strcmp, locale-independent): anything the sanitizer
  # removed or replaced was in the batch.
  if [ "$sani_out" != "$items" ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=invisible-chars" 1
    rm -f "$gerr"; return 1
  fi

  local scanner_path; scanner_path="$(dirname "$0")/tool-return-scanner.sh"
  if [ ! -f "$scanner_path" ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=scanner-failed src=missing" 1
    rm -f "$gerr"; return 1
  fi
  local scan_payload scan_out scan_ec
  scan_payload=$(printf '%s' "$sani_out" | jq -Rs --arg s "gate:$caller" '
    {tool_name:"Read", session_id:$s, tool_input:{file_path:("gate:untrusted-items:"+$s)}, tool_response:.}
  ' 2>"$gerr")
  if [ -z "$scan_payload" ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=scanner-failed src=payload-build err=$(err_head "$(cat "$gerr")")" 1
    rm -f "$gerr"; return 1
  fi
  scan_out=$(printf '%s' "$scan_payload" | SB_INJECTION_SCAN=on SB_HOOK_PROFILE= bash "$scanner_path" 2>"$gerr")
  scan_ec=$?
  scan_out="${scan_out//$'\r'/}"
  if [ "$scan_ec" -ne 0 ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=scanner-failed ec=$scan_ec err=$(err_head "$(cat "$gerr")")" 1
    rm -f "$gerr"; return 1
  fi
  if [ -n "$scan_out" ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=scanner-flagged" 1
    rm -f "$gerr"; return 1
  fi

  # The case-insensitive class check runs AFTER the scanner: the accept set is the same either way
  # (every step must pass), and this order keeps a phrase the maintained scanner already knows
  # logged as scanner-flagged, so only what the scanner MISSES (other casings, control/format
  # characters) reads as gate-flagged. R2-SF6: no `jq -e` exit-code test -- the verdict is a
  # positive "GATE <n> ..." row, so a jq crash (ec 2/3/5, no row) fails closed, never "clean".
  local verdict v_ec v_tag v_n v_idx v_cls
  verdict=$(printf '%s' "$sani_out" | jq -Rrs "$GATE_CLASS_JQ"'
      split("\n") | map(select(length > 0))
      | [ to_entries[] | {i: .key, c: (.value | bad_class)} ] as $v
      | gate_row($v)
    ' 2>"$gerr"); v_ec=$?
  verdict="${verdict//$'\r'/}"
  read -r v_tag v_n v_idx v_cls <<< "$verdict"
  case "$v_n" in ''|*[!0-9]*) v_tag="" ;; esac
  if [ "$v_ec" -ne 0 ] || [ "$v_tag" != "GATE" ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=gate-error ec=$v_ec err=$(err_head "$(cat "$gerr")")" 1
    rm -f "$gerr"; return 1
  fi
  rm -f "$gerr"
  if [ "$v_n" -gt 0 ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=gate-flagged items=$v_n idx=$v_idx class=$v_cls" 1
    return 1
  fi

  printf '%s' "$sani_out"
  return 0
}

# SEC-M4 / R2-SF4 / N5: the extractor's OWN plan[] emission can echo transcript content (a prior
# compaction summary, tool output) verbatim, so it is gated as well -- but LIGHTLY and PER ITEM,
# in ONE jq pass over the raw delta: each string element is flattened (CR/LF -> space) and
# classed with the shared GATE_CLASS_JQ, and ONLY the flagged items are dropped, logged once
# (count, 0-based plan[] indexes, classes). One benign false positive (a ZWJ emoji, "Strip the
# <system-reminder> tags") no longer freezes the whole Plan session after session, and no filler
# can push an item past a scan window because every item is classed. Deliberately NO length cut
# (NEW-H2: the old 120 cut tore the "(dropped: why)" suffix and the marker prefix off real items,
# so they never matched and never retired) and no node/scanner spawn. A jq failure (or a
# malformed verdict row) fails CLOSED: the whole emission is dropped, reason=gate-error.
# Sets the global PLAN: the kept items, one per line, CR-stripped.
gate_plan_items() {
  local raw="$1" prog out ec hdr tag n idx cls nonstr
  PLAN=""
  prog="$GATE_CLASS_JQ"'
    (.plan // []) | (if type == "array" then . else [] end)
    | ([ .[] | select(type != "string") ] | length) as $nonstr
    | [ to_entries[] | select((.value | type) == "string" and .value != "")
        | {i: .key, t: (.value | gsub("[\r\n]+"; " "))} | .c = (.t | bad_class) ] as $v
    | (gate_row($v) + " \($nonstr)"), ($v[] | select(.c == "") | .t)
  '
  out=$(printf '%s' "$raw" | jq -r "$prog" 2>/dev/null); ec=$?
  out="${out//$'\r'/}"
  hdr="${out%%$'\n'*}"
  read -r tag n idx cls nonstr <<< "$hdr"
  case "$n" in ''|*[!0-9]*) tag="" ;; esac
  case "$nonstr" in ''|*[!0-9]*) tag="" ;; esac
  if [ "$ec" -ne 0 ] || [ "$tag" != "GATE" ]; then
    # Failure path only: re-run once to capture the stderr head for the row (R2-SF8).
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=plan reason=gate-error ec=$ec err=$(err_head "$(printf '%s' "$raw" | jq -r "$prog" 2>&1 >/dev/null)")" 1
    return 1
  fi
  if [ "$nonstr" -gt 0 ]; then
    sb_log_error "merge-project-update.sh" "plan: dropped $nonstr non-string element(s)" 0
  fi
  if [ "$n" -gt 0 ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=plan dropped=$n idx=$idx class=$cls" 1
  fi
  case "$out" in *$'\n'*) PLAN="${out#*$'\n'}" ;; esac
  return 0
}

# R2-SF10: a PROJECT.md with no Plan section still receives Plan items (plan[] and compact_pending
# alike) -- a fresh "## Plan" header is spliced in BEFORE the trailing footer comments (the first
# last_updated/last_queried_wiki line), or at EOF when the file has none. Writes to $2, never to
# TMP_OUT itself, so a caller whose own pass then fails leaves TMP_OUT exactly as it was.
scaffold_plan_section() {
  local src="$1" dst="$2" sc_out sc_ec line sc_done=0 sc_bad=0
  sc_out=$(LC_ALL=C awk '
    !done && /^<!-- (last_updated|last_queried_wiki):/ {
      if (NR > 1 && prev != "") print ""
      print "## Plan"
      print ""
      done = 1
    }
    { print; prev = $0 }
    END {
      if (!done) { if (NR > 0 && prev != "") print ""; print "## Plan"; print "" }
      print "DONE" > "/dev/stderr"
    }
  ' "$src" 2>&1 >"$dst"); sc_ec=$?
  while IFS= read -r line; do
    case "$line" in ''|*warning:*) ;; DONE) sc_done=1 ;; *) sc_bad=1 ;; esac
  done <<< "$sc_out"
  if [ "$sc_ec" -ne 0 ] || [ "$sc_done" -ne 1 ] || [ "$sc_bad" -eq 1 ]; then
    sb_log_error "merge-project-update.sh" "gate=plan-scaffold-failed reason=awk-error ec=$sc_ec stderr=$(err_head "$sc_out")" 1
    return 1
  fi
  return 0
}

# Reconcile the ## Plan checklist with the freshly-extracted items. The Plan is FORWARD state
# (what is next) -- distinct from the backward-looking Recent decisions. The extractor emits the
# full current checklist each session; the reconcile rewrites ONLY the checklist lines it owns
# ("- [ ]", "- [x]"/"- [X]", "- [stale]"), IN PLACE:
#   - an existing line an emitted item matches (same key; or, for a card-truncated echo ending in
#     an ellipsis, a key prefix -- then the stored full text is kept) is rewritten in its own slot;
#     duplicates of it collapse into that one slot
#   - an omitted open line is carried in its slot ([carried D] sticky, else [carried TODAY]);
#     an omitted done line retires; an omitted stale line stays for mark_stale to cap
#   - brand-new emitted items land after the last checklist line (else before the first stale
#     line, else after the last text line of the section)
# Every other line -- prose, ### headings, tables, code fences, indented/numbered items, plain
# bullets, pinned lines -- is printed verbatim where it stood (design 4: nothing human-written is
# ever deleted or moved), and the non-pinned ones are counted in ONE gate=plan-unparsed row.
# [pinned] lines are human north stars the LLM never rewrites: an emitted item equal to one is
# skipped. A degraded/empty emission is a NO-OP -- the plan is never wiped by a session that
# produced nothing. Only the FIRST "## Plan" header is the section (R2-SF2/N4).
merge_plan() {
  local items="$1" cap="${2:-7}"
  [ -z "$items" ] && return 0

  local src="$TMP_OUT" scaff=""
  if ! LC_ALL=C grep -qE '^## Plan( |$)' "$TMP_OUT"; then
    scaff=$(mktemp) || { sb_log_error "merge-project-update.sh" "gate=merge-plan-failed reason=mktemp" 1; return 1; }
    if ! scaffold_plan_section "$TMP_OUT" "$scaff"; then
      rm -f "$scaff"
      return 1
    fi
    src="$scaff"
  fi
  local new_tmp
  new_tmp=$(mktemp) || {
    [ -n "$scaff" ] && rm -f "$scaff"
    sb_log_error "merge-project-update.sh" "gate=merge-plan-failed reason=mktemp" 1
    return 1
  }

  # ONE awk (no per-item spawn), LC_ALL=C (R2-SF3). Emitted items are parsed in BEGIN: a leading
  # checkbox and a leading well-formed [untrusted:compact D] (or its card form) are recognized
  # and taken off, merge-owned [carried D]/[stale] tokens are dropped, and then EVERY remaining
  # [ / ] becomes ( / ) (N1): "[pinne[stale]d]" and friends can never reassemble into a live
  # token, and pinned-ness is anchored anyway (is_pinned). Marks: an existing line mark wins
  # (its date is never overridden); an emitted mark with no existing one is re-dated TODAY, so
  # a forged old date cannot age a new item (NEW-M1). A mark is added, never removed.
  local mp_out mp_ec
  # The items reach awk on STDIN (read in BEGIN), not through the environment: plan[] has no
  # length cut, and one environment string is capped near 128 KB on Linux (E2BIG kills the exec).
  mp_out=$(printf '%s\n' "$items" | CAP="$cap" TODAY="$TODAY" LC_ALL=C awk "$PLAN_NORM_AWK$PLAN_LINE_AWK"'
    function put_new(   i) { for (i = 1; i <= en; i++) if (!anchor[i]) print outline[i] }
    function render(   k, L, i, j, c, m, dup, pbn, lastc, firsts, lastnb, insafter, eopen, carn, over, p, kv, kd, line, d, sd, nnew) {
      pbn = 0; lastc = 0; firsts = 0; lastnb = 0; un = 0
      for (k = 1; k <= secn; k++) {
        L = sec[k]; typ[k] = "o"
        if (L ~ /^[ \t]*$/) { typ[k] = "b"; continue }
        lastnb = k
        if (is_pinned(L)) { typ[k] = "p"; pbn++; pkey[pbn] = plan_key(L); pell[pbn] = KELL; continue }
        if (L ~ /^- \[stale\]/) { typ[k] = "s"; key[k] = plan_key(L); kell[k] = KELL; if (!firsts) firsts = k; continue }
        if (L ~ /^- \[[ xX]\]/) { typ[k] = "c"; key[k] = plan_key(L); kell[k] = KELL; lastc = k; continue }
        un++
      }
      # Emitted list: skip pinned duplicates (NEW-L5: "- [ ] [pinned] X" counts too) and repeats
      # within the emission itself, then cap.
      en = 0
      for (c = 1; c <= cn && en < cap; c++) {
        dup = 0
        for (j = 1; j <= pbn && !dup; j++) if (keymatch(pkey[j], pell[j], ckey[c], cell[c])) dup = 1
        for (i = 1; i <= en && !dup; i++) if (ckey[eidx[i]] == ckey[c]) dup = 1
        if (dup) continue
        en++; eidx[en] = c
      }
      for (k = 1; k <= secn; k++) mby[k] = 0
      for (i = 1; i <= en; i++) {
        c = eidx[i]; anchor[i] = 0; emk[i] = ""; edisp[i] = ctxt[c]
        for (k = 1; k <= secn; k++) {
          if ((typ[k] != "c" && typ[k] != "s") || mby[k]) continue
          if (key[k] != ckey[c]) continue
          mby[k] = i
          if (!anchor[i]) anchor[i] = k
          m = findmarker(sec[k]); if (m != "" && emk[i] == "") emk[i] = m
        }
        if (anchor[i]) continue
        # No exact key: at most ONE ellipsis-prefix match, so a short echo never swallows
        # several distinct items that happen to share its prefix.
        for (k = 1; k <= secn; k++) {
          if ((typ[k] != "c" && typ[k] != "s") || mby[k]) continue
          if (!keymatch(key[k], kell[k], ckey[c], cell[c])) continue
          mby[k] = i; anchor[i] = k
          emk[i] = findmarker(sec[k])
          if (cell[c]) edisp[i] = owned_text(sec[k])
          break
        }
      }
      eopen = 0
      for (i = 1; i <= en; i++) {
        c = eidx[i]; m = emk[i]
        if (m == "" && cem[c]) m = "[untrusted:compact " today "]"
        line = "- [" ccb[c] "]"
        if (m != "") line = line " " m
        outline[i] = line " " edisp[i]
        if (ccb[c] == " ") eopen++
      }
      carn = 0
      for (k = 1; k <= secn; k++) {
        newl[k] = sec[k]; dead[k] = 0
        if (typ[k] != "c" && typ[k] != "s") continue
        if (mby[k]) {
          if (anchor[mby[k]] == k) newl[k] = outline[mby[k]]
          else dead[k] = 1
          continue
        }
        if (typ[k] == "s") continue
        if (sec[k] !~ /^- \[ \]/) { dead[k] = 1; continue }
        # NEW-M1: a line carried for the first time is carried as of TODAY -- it was live (in
        # the file, unstaled) until this emission omitted it. Its compact date still ranks it
        # for overflow (CR-M3), it just never back-dates the carry.
        d = carried_date(sec[k]); sd = d
        if (sd == "") sd = compact_date(sec[k])
        if (sd == "") sd = today
        if (d == "") d = today
        m = findmarker(sec[k])
        line = "- [ ]"
        if (m != "") line = line " " m
        newl[k] = line " [carried " d "] " owned_text(sec[k])
        carn++; cidx[carn] = k; cdate[carn] = sd
      }
      # Bound: 15 open. Overflow victims are the OLDEST carried lines (stable insertion sort by
      # date, document order breaks ties), aged to [stale] in place -- never dropped here.
      if (eopen + carn > 15) {
        over = eopen + carn - 15
        if (over > carn) over = carn
        for (j = 1; j <= carn; j++) ord[j] = j
        for (j = 2; j <= carn; j++) {
          kv = ord[j]; kd = cdate[kv]; p = j - 1
          while (p >= 1 && cdate[ord[p]] > kd) { ord[p + 1] = ord[p]; p-- }
          ord[p + 1] = kv
        }
        for (j = 1; j <= over; j++) { k = cidx[ord[j]]; sub(/^- \[ \]/, "- [stale] [ ]", newl[k]) }
      }
      nnew = 0
      for (i = 1; i <= en; i++) if (!anchor[i]) nnew++
      if (lastnb == 0) {
        # A section with no text at all (fresh scaffold, or blanks only): render it canonically.
        if (nnew == 0) { for (k = 1; k <= secn; k++) print sec[k]; return }
        print ""
        put_new()
        print ""
        return
      }
      insafter = lastc
      if (!insafter && firsts) insafter = firsts - 1
      if (!insafter && !firsts) insafter = lastnb
      if (insafter == 0) put_new()
      for (k = 1; k <= secn; k++) {
        if (!dead[k]) print newl[k]
        if (k == insafter) put_new()
      }
    }
    BEGIN {
      today = ENVIRON["TODAY"]
      cap = ENVIRON["CAP"] + 0
      cn = 0
      while ((getline t < "/dev/stdin") > 0) {
        sub(/^[ \t]*[-*+][ \t]+/, "", t)
        cb = " "
        if (t ~ /^\[[xX]\]/) { cb = "x"; t = substr(t, 4) }
        else if (t ~ /^\[ \]/) t = substr(t, 4)
        em = 0
        while (1) {
          sub(/^[ \t]+/, "", t)
          if (t ~ /^\[untrusted:compact 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/) { em = 1; t = substr(t, 31); continue }
          if (t ~ /^\(untrusted:compact[ 0-9-]*\)/) { em = 1; sub(/^\(untrusted:compact[ 0-9-]*\)/, "", t); continue }
          if (t ~ /^(\[|\()carried[ 0-9-]*(\]|\))/) { sub(/^(\[|\()carried[ 0-9-]*(\]|\))/, "", t); continue }
          if (t ~ /^(\[|\()stale(\]|\))/) { sub(/^(\[|\()stale(\]|\))/, "", t); continue }
          break
        }
        gsub(/\[/, "(", t)
        gsub(/\]/, ")", t)
        gsub(/[ \t]+/, " ", t)
        sub(/ $/, "", t)
        if (t == "") continue
        cn++; ccb[cn] = cb; cem[cn] = em; ctxt[cn] = t
        ckey[cn] = plan_key(t); cell[cn] = KELL
      }
    }
    !seen && /^## Plan( |$)/ { seen = 1; inplan = 1; print; next }
    inplan && (/^## / || /^<!--/) { render(); inplan = 0; print; next }
    inplan { secn++; sec[secn] = $0; next }
    { print }
    END {
      if (inplan) render()
      if (un > 0) print "UNPARSEDCOUNT\t" un > "/dev/stderr"
      print "DONE" > "/dev/stderr"
    }
  ' "$src" 2>&1 >"$new_tmp"); mp_ec=$?

  # SF-C1: the ONLY expected stderr lines are the UNPARSEDCOUNT trace and the DONE sentinel (a
  # gawk "warning:" line is tolerated -- R2-SF3). Anything else, a missing DONE, or a nonzero exit
  # means the pass did not complete: fail closed, TMP_OUT (and so the Plan) left exactly as it was.
  local line mp_unparsed="" mp_done=0 mp_bad=0
  while IFS= read -r line; do
    case "$line" in
      '') ;;
      DONE) mp_done=1 ;;
      UNPARSEDCOUNT$'\t'*) mp_unparsed="${line#*$'\t'}" ;;
      *warning:*) ;;
      *) mp_bad=1 ;;
    esac
  done <<< "$mp_out"
  case "$mp_unparsed" in *[!0-9]*) mp_bad=1 ;; esac
  if [ "$mp_ec" -ne 0 ] || [ "$mp_bad" -eq 1 ] || [ "$mp_done" -ne 1 ]; then
    sb_log_error "merge-project-update.sh" "gate=merge-plan-failed reason=awk-error ec=$mp_ec stderr=$(err_head "$mp_out")" 1
    rm -f "$new_tmp"
    [ -n "$scaff" ] && rm -f "$scaff"
    return 1
  fi
  [ -n "$scaff" ] && rm -f "$scaff"
  PLAN_RECONCILED=1
  # A kept (never dropped) human line: ONE ec0 trace row per merge carrying the count.
  if [ -n "$mp_unparsed" ]; then
    sb_log_error "merge-project-update.sh" "gate=plan-unparsed kept=$mp_unparsed" 0
  fi
  # No-op contract: only rewrite + mark dirty when the plan actually changed -- the extractor
  # re-emits the full list every session, so an unchanged plan must NOT churn last_updated.
  if cmp -s "$new_tmp" "$TMP_OUT"; then
    rm -f "$new_tmp"
  else
    mv "$new_tmp" "$TMP_OUT"
    CHANGED=1
  fi
  if [ -n "$scaff" ]; then
    sb_log_error "merge-project-update.sh" "gate=plan-scaffolded caller=plan" 0
  fi
}

# PostCompact Pending-Tasks -> ## Plan, add-only (C2/C3). Order is the point (N5, TA2-5):
#   cap 5 -> normalize (CR/LF/TAB flattened, every [ / ] -> ( / ) forging defence, leading #
#   stripped) -> dedup against the FIRST Plan section on the UNCUT text -> cut survivors to 120
#   codepoints -> gate EXACTLY those survivors -> insert.
# Deduping the uncut candidate is what lets a startup-card echo (cap 160: a long item plus its
# 31-char marker prefix, no ellipsis) and a lean-card echo (cap 120: an ellipsis the 120 cut
# would chop off) find the real item; the cut form is checked TOO, so a long task re-sent by a
# later compaction still matches the 120-codepoint text an earlier one stored. Bound: refuse --
# never evict -- once non-pinned unfinished lines would reach 15, counted AFTER this merge aged
# the Plan (mark_stale runs first). ONE jq + one awk to decide, the gate, one awk to insert.
merge_compact_pending() {
  local raw="$1"
  local prep prep_ec hdr ns body
  prep=$(printf '%s' "$raw" | jq -r '
      (.compact_pending // []) | (if type == "array" then . else [] end)
      | ([ .[] | select(type != "string") ] | length) as $ns
      | "N \($ns)",
        ( map(select(type == "string" and . != "")) | .[0:5] | .[]
          | gsub("[\r\n\t]+"; " ") | gsub("\\["; "(") | gsub("\\]"; ")")
          | sub("^\\s*#+"; "") | sub("^\\s+"; "") | sub("\\s+$"; "")
          | select(length > 0)
          | ., (.[0:120] | sub("\\s+$"; "")) )
    ' 2>/dev/null); prep_ec=$?
  prep="${prep//$'\r'/}"
  hdr="${prep%%$'\n'*}"
  local prep_ok=1
  [ "$prep_ec" -eq 0 ] || prep_ok=0
  case "$hdr" in 'N '*) ns="${hdr#N }" ;; *) ns="" ;; esac
  case "$ns" in ''|*[!0-9]*) prep_ok=0 ;; esac
  if [ "$prep_ok" -ne 1 ]; then
    sb_log_error "merge-project-update.sh" "gate=merge-compact-pending-failed reason=prepare-error ec=$prep_ec" 1
    return 1
  fi
  if [ "$ns" -gt 0 ]; then
    sb_log_error "merge-project-update.sh" "compact_pending: dropped $ns non-string element(s)" 0
  fi
  body=""
  case "$prep" in *$'\n'*) body="${prep#*$'\n'}" ;; esac
  [ -z "$body" ] && return 0

  # Decide: dedup + refusal over the FIRST Plan section. One tagged stream (stdout+stderr): the
  # survivors as ADD lines, one COUNTS row, the DONE sentinel -- any other line is a failure.
  local dd_out dd_ec
  dd_out=$(PAIRS="$body" LC_ALL=C awk "$PLAN_NORM_AWK$PLAN_LINE_AWK"'
    BEGIN {
      n = split(ENVIRON["PAIRS"], pr, "\n"); cn = 0
      for (i = 1; i + 1 <= n; i += 2) {
        cn++; full[cn] = pr[i]; cut[cn] = pr[i + 1]
        fkey[cn] = plan_key(full[cn]); fell[cn] = KELL
        ckey[cn] = plan_key(cut[cn])
      }
    }
    !seen && /^## Plan( |$)/ { seen = 1; inplan = 1; next }
    inplan && (/^## / || /^<!--/) { inplan = 0; next }
    inplan && /^- / {
      ek++; ekey[ek] = plan_key($0); eell[ek] = KELL
      if ($0 ~ /^- \[ \]/ && !is_pinned($0)) open++
    }
    END {
      for (c = 1; c <= cn; c++) {
        dup = 0
        for (k = 1; k <= ek && !dup; k++) if (keymatch(ekey[k], eell[k], fkey[c], fell[c]) || ekey[k] == ckey[c]) dup = 1
        if (dup) { dedup++; continue }
        if (open >= 15) { refused++; continue }
        print "ADD\t" cut[c]
        open++
        ek++; ekey[ek] = fkey[c]; eell[ek] = fell[c]
        ek++; ekey[ek] = ckey[c]; eell[ek] = 0
      }
      print "COUNTS\t" (dedup + 0) " " (refused + 0)
      print "DONE"
    }
  ' "$TMP_OUT" 2>&1); dd_ec=$?
  dd_out="${dd_out//$'\r'/}"

  local line surv="" counts="" nc=0 dd_done=0 dd_bad=0
  while IFS= read -r line; do
    case "$line" in
      '') ;;
      ADD$'\t'*) surv="${surv}${surv:+$'\n'}${line#*$'\t'}" ;;
      COUNTS$'\t'*) counts="${line#*$'\t'}"; nc=$((nc + 1)) ;;
      DONE) dd_done=1 ;;
      *warning:*) ;;
      *) dd_bad=1 ;;
    esac
  done <<< "$dd_out"
  local dedup="" refused=""
  read -r dedup refused <<< "$counts"
  case "$dedup" in ''|*[!0-9]*) dd_bad=1 ;; esac
  case "$refused" in ''|*[!0-9]*) dd_bad=1 ;; esac
  if [ "$dd_ec" -ne 0 ] || [ "$dd_bad" -eq 1 ] || [ "$dd_done" -ne 1 ] || [ "$nc" -ne 1 ]; then
    sb_log_error "merge-project-update.sh" "gate=merge-compact-pending-failed reason=awk-error ec=$dd_ec stderr=$(err_head "$dd_out")" 1
    return 1
  fi
  if [ -z "$surv" ]; then
    sb_log_error "merge-project-update.sh" "gate=compact-pending added=0 dedup=$dedup refused=$refused" 0
    return 0
  fi

  local gated
  gated=$(gate_untrusted_items "$surv" "compact_pending")
  if [ -z "$gated" ]; then
    sb_log_error "merge-project-update.sh" "gate=compact-pending added=0 dedup=$dedup refused=$refused reason=gate-rejected" 0
    return 0
  fi

  local src="$TMP_OUT" scaff=""
  if ! LC_ALL=C grep -qE '^## Plan( |$)' "$TMP_OUT"; then
    scaff=$(mktemp) || { sb_log_error "merge-project-update.sh" "gate=merge-compact-pending-failed reason=mktemp" 1; return 1; }
    if ! scaffold_plan_section "$TMP_OUT" "$scaff"; then
      rm -f "$scaff"
      return 1
    fi
    src="$scaff"
  fi
  local new_tmp
  new_tmp=$(mktemp) || {
    [ -n "$scaff" ] && rm -f "$scaff"
    sb_log_error "merge-project-update.sh" "gate=merge-compact-pending-failed reason=mktemp" 1
    return 1
  }
  # Insert: after the last checklist line (else before the first stale line, else after the
  # section text); every existing line stays exactly where it was.
  local ins_out ins_ec
  ins_out=$(ADD="$gated" TODAY="$TODAY" LC_ALL=C awk "$PLAN_LINE_AWK"'
    function put_new(   i) { for (i = 1; i <= an; i++) print "- [ ] [untrusted:compact " today "] " add[i] }
    function flush(   k, lastc, firsts, lastnb, insafter) {
      lastc = 0; firsts = 0; lastnb = 0
      for (k = 1; k <= bn; k++) {
        if (buf[k] ~ /^[ \t]*$/) continue
        lastnb = k
        if (buf[k] ~ /^- \[stale\]/) { if (!firsts) firsts = k; continue }
        if (buf[k] ~ /^- \[[ xX]\]/ && !is_pinned(buf[k])) lastc = k
      }
      placed = an
      if (lastnb == 0) { print ""; put_new(); print ""; return }
      insafter = lastc
      if (!insafter && firsts) insafter = firsts - 1
      if (!insafter && !firsts) insafter = lastnb
      if (insafter == 0) put_new()
      for (k = 1; k <= bn; k++) { print buf[k]; if (k == insafter) put_new() }
    }
    BEGIN {
      today = ENVIRON["TODAY"]
      n = split(ENVIRON["ADD"], tmp, "\n"); an = 0
      for (i = 1; i <= n; i++) if (tmp[i] != "") { an++; add[an] = tmp[i] }
    }
    !seen && /^## Plan( |$)/ { seen = 1; inplan = 1; print; next }
    inplan && (/^## / || /^<!--/) { flush(); inplan = 0; print; next }
    inplan { bn++; buf[bn] = $0; next }
    { print }
    END {
      if (inplan) flush()
      print "ADDED\t" (placed + 0) > "/dev/stderr"
      print "DONE" > "/dev/stderr"
    }
  ' "$src" 2>&1 >"$new_tmp"); ins_ec=$?
  local added="" ins_done=0 ins_bad=0
  while IFS= read -r line; do
    case "$line" in
      '') ;;
      ADDED$'\t'*) added="${line#*$'\t'}" ;;
      DONE) ins_done=1 ;;
      *warning:*) ;;
      *) ins_bad=1 ;;
    esac
  done <<< "$ins_out"
  case "$added" in ''|*[!0-9]*) ins_bad=1 ;; esac
  if [ "$ins_ec" -ne 0 ] || [ "$ins_bad" -eq 1 ] || [ "$ins_done" -ne 1 ]; then
    sb_log_error "merge-project-update.sh" "gate=merge-compact-pending-failed reason=awk-error ec=$ins_ec stderr=$(err_head "$ins_out")" 1
    rm -f "$new_tmp"
    [ -n "$scaff" ] && rm -f "$scaff"
    return 1
  fi
  [ -n "$scaff" ] && rm -f "$scaff"
  sb_log_error "merge-project-update.sh" "gate=compact-pending added=$added dedup=$dedup refused=$refused" 0
  if [ "$added" -gt 0 ]; then
    mv "$new_tmp" "$TMP_OUT"
    CHANGED=1
    if [ -n "$scaff" ]; then
      sb_log_error "merge-project-update.sh" "gate=plan-scaffolded caller=compact_pending" 0
    fi
  else
    rm -f "$new_tmp"
  fi
}

# One-line resumable WHY under ## State: "last session goal: … (reached: <phase>)".
# Replace-style like merge_plan: the previous note line is dropped, every other line
# in the section (human notes) is preserved, and an empty emission is a no-op — the
# note is never wiped by a session that produced nothing.
merge_state() {
  local note="$1"
  [ -z "$note" ] && return 0
  local new_tmp; new_tmp=$(mktemp)
  # stderr is captured (not a temp file: no extra spawn on the happy path) so a failure row can
  # carry the exit code AND what awk said (R2-SF8).
  local st_err st_ec
  if grep -q '^## State$' "$TMP_OUT"; then
    st_err=$(NOTE="last session goal: $note" awk '
      BEGIN { note=ENVIRON["NOTE"] }
      /^## State$/ { print; print note; f=1; next }
      f && /^## / { f=0 }
      f && /^last session goal: / { next }
      { print }
    ' "$TMP_OUT" 2>&1 >"$new_tmp"); st_ec=$?
  else
    # Heading absent (older/hand-rolled PROJECT.md): append the section at EOF
    # rather than silently dropping the note.
    st_err=$(NOTE="last session goal: $note" awk '
      { print }
      END { print ""; print "## State"; print ENVIRON["NOTE"] }
    ' "$TMP_OUT" 2>&1 >"$new_tmp"); st_ec=$?
  fi
  # SF-C1: check the awk exit code -- on failure leave ## State exactly as it was rather
  # than risking a truncated/empty rewrite reaching TMP_OUT.
  if [ "$st_ec" -ne 0 ]; then
    sb_log_error "merge-project-update.sh" "gate=merge-state-failed reason=awk-error ec=$st_ec stderr=$(err_head "$st_err")" 1
    rm -f "$new_tmp"
    return 1
  fi
  # No-op contract: only rewrite + mark dirty when the note actually changed, so an
  # unchanged goal never churns last_updated.
  if cmp -s "$new_tmp" "$TMP_OUT"; then
    rm -f "$new_tmp"
  else
    mv "$new_tmp" "$TMP_OUT"
    CHANGED=1
  fi
}

# P0 rec 2 (capture widening): procedural runbooks — "how X is done here".
# Renders extractor-emitted procedures[] into a compact ## How-to section: one
# line per runbook `- <verb>: <commands> (needs: …) — avoids: …`, deduped by
# task_verb case-insensitively (newest wins), capped at 5 entries (oldest
# dropped). The section is created BEFORE ## Recent decisions when absent:
# PROJECT.md rides the SessionStart hot tier under a 3000B head-keeping cap,
# so anything appended after the footer would be the first truncation
# casualty. Empty/absent procedures → byte-identical no-op.
merge_howto() {
  local raw="$1" cap="${2:-5}"
  local new_entries
  # Backticks/CR/LF stripped inside jq: a stray backtick in exact_commands
  # would fracture downstream markdown rendering of the line.
  new_entries=$(printf '%s' "$raw" | jq -r '
    .procedures // [] | .[0:2] | .[]
    | select(type == "object")
    | select(((.task_verb // "") | tostring) != "" and ((.exact_commands // "") | tostring) != "")
    | "- " + (.task_verb | tostring | gsub("[`\r\n:]"; " ") | gsub("(^ +| +$)"; "") | .[0:40])
      + ": " + (.exact_commands | tostring | gsub("[`\r\n]"; " ") | .[0:200])
      + (if ((.preconditions // "") | tostring) != "" then " (needs: " + (.preconditions | tostring | gsub("[`\r\n]"; " ") | .[0:80]) + ")" else "" end)
      + (if ((.gotcha_avoided // "") | tostring) != "" then " — avoids: " + (.gotcha_avoided | tostring | gsub("[`\r\n]"; " ") | .[0:100]) else "" end)
  ' 2>/dev/null | strip_cr)
  [ -z "$new_entries" ] && return 0

  local body entry verb lower_verb
  body=$(awk '/^## How-to$/{f=1;next} /^## /{f=0} f && /^- /' "$TMP_OUT")
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    verb=$(printf '%s' "$entry" | sed 's/^- //; s/:.*//')
    lower_verb=$(printf '%s' "$verb" | lc)
    # Same-verb dedup: drop any existing line whose "- <verb>:" prefix matches
    # case-insensitively (ENVIRON + tolower — portable, no awk -v backslash trap).
    body=$(printf '%s\n' "$body" | HOWTO_V="- $lower_verb:" awk '
      BEGIN { v = ENVIRON["HOWTO_V"] }
      { if (index(tolower($0), v) == 1) next; print }')
    body="${body}${body:+
}$entry"
  done <<< "$new_entries"
  # Cap: newest entries live at the BOTTOM; keep the last $cap lines.
  body=$(printf '%s\n' "$body" | grep -v '^$' | tail -n "$cap")
  [ -z "$body" ] && return 0

  local new_tmp; new_tmp=$(mktemp)
  local ht_err ht_ec
  if grep -q '^## How-to$' "$TMP_OUT"; then
    ht_err=$(BODY="$body" awk '
      BEGIN { body = ENVIRON["BODY"] }
      $0 == "## How-to" { print; print ""; if (length(body)) print body; print ""; f=1; next }
      f && (/^## / || /^<!--/) { f=0; print; next }
      f { next }
      { print }
    ' "$TMP_OUT" 2>&1 >"$new_tmp"); ht_ec=$?
  else
    ht_err=$(BODY="$body" awk '
      BEGIN { body = ENVIRON["BODY"]; done = 0 }
      /^## Recent decisions$/ && !done { print "## How-to"; print ""; print body; print ""; done=1 }
      { print }
      END { if (!done) { print ""; print "## How-to"; print ""; print body } }
    ' "$TMP_OUT" 2>&1 >"$new_tmp"); ht_ec=$?
  fi
  if [ "$ht_ec" -ne 0 ]; then
    sb_log_error "merge-project-update.sh" "gate=merge-howto-failed reason=awk-error ec=$ht_ec stderr=$(err_head "$ht_err")" 1
    rm -f "$new_tmp"
    return 1
  fi
  # No-op contract: only rewrite + mark dirty on a real change (idempotent re-emissions
  # of the same runbooks must not churn last_updated).
  if cmp -s "$new_tmp" "$TMP_OUT"; then
    rm -f "$new_tmp"
  else
    mv "$new_tmp" "$TMP_OUT"
    CHANGED=1
  fi
}

# Decision-ritual (0.48.0): session handoff — in-flight state, failed approaches,
# file:line pointers. Replace-style like merge_state: the previous handoff is dropped,
# the new one written; an empty/absent emission is a NO-OP so a degraded session never
# wipes a real handoff. Nothing accumulates — next session's handoff replaces this one.
# Hard 600B cap truncated at LINE boundaries (merge_howto discipline): the section
# rides the SessionStart 3000B hot-tier cap and must never dominate it. Created
# BEFORE ## Recent decisions when absent (head-keeping, see merge_howto note above).
merge_handoff() {
  local raw="$1"
  local body
  # Type-guard every field: one wrong-typed field (handoff as a string, a scalar
  # failed_approaches) must degrade to "that field is empty", NOT abort the whole jq
  # expression — an atomic [..] with 2>/dev/null would silently discard VALID sibling
  # fields and be indistinguishable from "no handoff this session".
  local jq_err
  jq_err=$(mktemp)
  body=$(printf '%s' "$raw" | jq -r '
    (.handoff // {}) | (if type == "object" then . else {} end) | [
      (if ((.in_flight // "") | tostring) != "" then
        "in-flight: " + ((.in_flight | tostring) | gsub("[`\r\n]"; " ") | .[0:160])
       else empty end),
      ((.failed_approaches // []) | (if type == "array" then . else [] end)
        | .[:3][] | select(type == "string" and . != "")
        | "- failed: " + (gsub("[`\r\n]"; " ") | .[0:120])),
      ((.pointers // []) | (if type == "array" then . else [] end)
        | .[:5][] | select(type == "string" and . != "")
        | "- see: " + (gsub("[`\r\n]"; " ") | .[0:120]))
    ] | join("\n")
  ' 2>"$jq_err" | strip_cr)
  if [ -s "$jq_err" ]; then
    sb_log_error "merge-project-update.sh" "handoff jq parse failed — handoff dropped this merge: $(head -c 200 "$jq_err" | tr '\n' ' ')" 0
  fi
  rm -f "$jq_err"
  [ -z "$body" ] && return 0
  # C4 (fixed cut before compare): 600 total budget minus the WIDEST possible stamp line
  # (MAX_STAMP_BYTES=112: "written: t=<11 digits> session=<8> branch=<40> head=<12>" plus
  # separators), cut FIRST on line boundaries, THEN compare against the existing section
  # body with its own stamp line stripped -- so a long handoff re-emitted under a DIFFERENT
  # --session (different epoch/branch/head) still counts as unchanged when its 3 content
  # lines are unchanged, and the OLD stamp survives (its age reflects the content's age, not
  # merge time). Validation of the read side lives in session-load.sh (Set 2); this side never
  # re-validates what it just wrote.
  local MAX_STAMP_BYTES=112
  local body_cap=$((600 - MAX_STAMP_BYTES))
  body=$(printf '%s\n' "$body" | awk -v cap="$body_cap" '{ n += length($0) + 1; if (n > cap) exit; print }')
  [ -z "$body" ] && return 0

  # The rendered section is "<blank> <written: line> <content lines> <blank>" -- strip the
  # written: line AND the framing blanks (never part of the content jq built) so this compares
  # like-for-like against $body, which is content lines only, no stamp, no blanks.
  # CR-L1: the reader stops where the WRITER stops -- at the next "## " heading OR the first
  # "<!--" footer line. Stopping only at "## " swept the footer comments into existing_body
  # whenever ## Handoff was the last section, so an identical re-emission never compared equal
  # and re-stamped (and bumped last_updated) on every single merge.
  local existing_body=""
  if grep -q '^## Handoff$' "$TMP_OUT"; then
    existing_body=$(awk '/^## Handoff$/{f=1;next} /^## / || /^<!--/{f=0} f' "$TMP_OUT" | awk '$0 != "" && $0 !~ /^written: /')
  fi
  [ "$existing_body" = "$body" ] && return 0   # unchanged content: keep the OLD stamp, no rewrite

  local stamp_t stamp_sid8="" stamp_branch="" stamp_head="" stamp
  # SF-M3: gate=handoff-stamp -- diagnoses WHY a stamp fell back to merge-time-only. src=prov
  # is the good case (a real .prov epoch was read); no-prov means no --session was passed or
  # its .prov file does not exist yet (a plain race: pre-compact.sh writes .prov before
  # calling merge, but a Stop/drainer caller may run with no upstream prov-write at all);
  # bad-prov means the file existed but its first field failed to parse as an epoch (a
  # corrupt/torn write) -- distinct from no-prov because it points at a DIFFERENT bug class.
  local prov_src="no-prov"
  stamp_t=$(date +%s)
  if [ -n "$SESSION_ARG" ]; then
    stamp_sid8="${SESSION_ARG:0:8}"
    local prov_f="$BRAIN_DIR/.injected/$SESSION_ARG.prov"
    if [ -f "$prov_f" ]; then
      local prov_line prov_epoch prov_sha prov_branch
      prov_line=$(head -1 "$prov_f" 2>/dev/null | tr -d '\r')
      IFS=$'\t' read -r prov_epoch prov_sha prov_branch <<< "$prov_line"
      case "$prov_epoch" in
        ''|*[!0-9]*) prov_src="bad-prov" ;;
        *) stamp_t="$prov_epoch"; prov_src="prov" ;;
      esac
      [ -n "$prov_sha" ] && stamp_head="$prov_sha"
      [ -n "$prov_branch" ] && stamp_branch="$prov_branch"
    fi
  fi
  sb_log_error "merge-project-update.sh" "gate=handoff-stamp src=$prov_src session=${stamp_sid8:-none}" 0
  stamp="written: t=$stamp_t"
  [ -n "$stamp_sid8" ] && stamp="$stamp session=$stamp_sid8"
  [ -n "$stamp_branch" ] && stamp="$stamp branch=$stamp_branch"
  [ -n "$stamp_head" ] && stamp="$stamp head=$stamp_head"
  body="$stamp"$'\n'"$body"

  local new_tmp; new_tmp=$(mktemp)
  local ho_err ho_ec
  if grep -q '^## Handoff$' "$TMP_OUT"; then
    ho_err=$(BODY="$body" awk '
      BEGIN { body = ENVIRON["BODY"] }
      $0 == "## Handoff" { print; print ""; if (length(body)) print body; print ""; f=1; next }
      f && (/^## / || /^<!--/) { f=0; print; next }
      f { next }
      { print }
    ' "$TMP_OUT" 2>&1 >"$new_tmp"); ho_ec=$?
  else
    ho_err=$(BODY="$body" awk '
      BEGIN { body = ENVIRON["BODY"]; done = 0 }
      /^## Recent decisions$/ && !done { print "## Handoff"; print ""; print body; print ""; done=1 }
      { print }
      END { if (!done) { print ""; print "## Handoff"; print ""; print body } }
    ' "$TMP_OUT" 2>&1 >"$new_tmp"); ho_ec=$?
  fi
  if [ "$ho_ec" -ne 0 ]; then
    sb_log_error "merge-project-update.sh" "gate=merge-handoff-failed reason=awk-error ec=$ho_ec stderr=$(err_head "$ho_err")" 1
    rm -f "$new_tmp"
    return 1
  fi
  # No-op contract: an identical re-emission must not churn last_updated.
  if cmp -s "$new_tmp" "$TMP_OUT"; then
    rm -f "$new_tmp"
  else
    mv "$new_tmp" "$TMP_OUT"
    CHANGED=1
  fi
}

# Detect if a new decision contradicts an existing one. Marks old as [superseded].
# Requires: negation words in new + >50% word overlap with existing.
detect_supersede() {
  [ "${SB_SKIP_SUPERSEDE:-0}" = "1" ] && return 1
  local new_text="$1"
  local new_lower
  new_lower=$(printf '%s' "$new_text" | tr '[:upper:]' '[:lower:]')

  # Must contain negation or explicit override language
  if ! echo "$new_lower" | grep -qE "(don't|dont|do not|not |never |removed |dropped |disabled |stopped |supersedes |replaces |instead of |no longer )"; then
    return 1
  fi

  local new_words new_count
  new_words=$(printf '%s' "$new_lower" | sed 's/\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\] //' | tr -cs '[:alpha:]' '\n' | grep -vxE '(the|a|an|is|are|was|were|to|of|in|for|on|at|by|with|not|no|dont|never|don|do|instead|supersedes|replaces)' | sort -u)
  new_count=$(echo "$new_words" | grep -c . 2>/dev/null || true)
  [ "$new_count" -lt 3 ] && return 1

  local existing
  existing=$(awk '
    /^## Recent decisions$/ { flag=1; next }
    /^## / { flag=0 }
    flag && /^- / && !/\[superseded\]/ && !/\[stale\]/ { print }
  ' "$TMP_OUT")

  [ -z "$existing" ] && return 1

  while IFS= read -r old_line; do
    [ -z "$old_line" ] && continue
    local old_lower old_words old_count overlap pct
    old_lower=$(printf '%s' "$old_line" | tr '[:upper:]' '[:lower:]')
    old_words=$(printf '%s' "$old_lower" | sed 's/^- //' | sed 's/\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\] //' | tr -cs '[:alpha:]' '\n' | grep -vxE '(the|a|an|is|are|was|were|to|of|in|for|on|at|by|with|not|no|dont|never|don|do)' | sort -u)
    old_count=$(echo "$old_words" | grep -c . 2>/dev/null || true)
    [ "$old_count" -eq 0 ] && continue
    overlap=$(comm -12 <(echo "$new_words") <(echo "$old_words") | grep -c . 2>/dev/null || true)
    pct=$((overlap * 100 / old_count))
    if [ "$pct" -ge 50 ]; then
      local new_tmp
      new_tmp=$(mktemp)
      OLD_LINE="$old_line" awk '
        BEGIN { target = ENVIRON["OLD_LINE"]; done = 0 }
        !done && $0 == target { sub(/^- /, "- [superseded] "); done = 1 }
        { print }
      ' "$TMP_OUT" > "$new_tmp"
      mv "$new_tmp" "$TMP_OUT"
      CHANGED=1
      return 0
    fi
  done <<< "$existing"
  return 1
}

TODAY=$(date +%Y-%m-%d)
# Capture-latency metric (decision-ritual 0.48.0): a dedup-hit means the decision was
# already in PROJECT.md when Stop-extraction found it in the transcript — i.e. it was
# pinned in-session via pin_to_project (or carried from a prior session, an accepted
# over-count); a fresh insert means it was captured only at Stop. TRACE row, never a
# blocker: the ratio pinned/(pinned+stop_only) rising across sessions is the measured
# contract for the in-session capture instruction in persona-context.sh.
DEC_PINNED=0; DEC_STOP_ONLY=0; LAST_INSERT_DUP=0
if [ -n "$DECISIONS" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Skip "files this session" fallback lines — they're not decisions
    echo "$line" | grep -q '^files this session:' && continue
    # Prefix with date if not already dated
    dated_line="$line"
    if ! echo "$line" | grep -qE '^\[20[0-9]{2}-[0-9]{2}-[0-9]{2}\]'; then
      dated_line="[$TODAY] $line"
    fi
    detect_supersede "$dated_line" || true
    LAST_INSERT_DUP=0
    insert_bullet "## Recent decisions" "$dated_line" 5
    if [ "$LAST_INSERT_DUP" = "1" ]; then DEC_PINNED=$((DEC_PINNED + 1)); else DEC_STOP_ONLY=$((DEC_STOP_ONLY + 1)); fi
  done <<< "$DECISIONS"
  # ec=0 gate= trace -> audit-log (same channel as gate=value-loop); one row per merge.
  sb_log_error "merge-project-update.sh" "gate=decision-capture pinned=$DEC_PINNED stop_only=$DEC_STOP_ONLY" 0
fi

if [ -n "$BLOCKERS" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    insert_bullet "## Open blockers" "$line" 15
  done <<< "$BLOCKERS"
fi

# --- Auto-staleness: mark decisions/blockers/Plan items older than N days as [stale] ---
# N defaults to 30 (the review skill's staleness horizon); override per policy.
# Validate-or-default (same idiom as SB_DREAM_STALE_DAYS / SB_FORGET_MIN_AGE_DAYS).
STALE_DAYS="${SB_PROJECT_STALE_DAYS:-30}"
case "$STALE_DAYS" in ''|*[!0-9]*) STALE_DAYS=30 ;; esac
STALE_CUTOFF=$(date -v-"${STALE_DAYS}"d +%Y-%m-%d 2>/dev/null \
  || date -d "${STALE_DAYS} days ago" +%Y-%m-%d 2>/dev/null \
  || echo "1970-01-01")

# Set by merge_plan once a plan[] emission actually reconciled this merge.
PLAN_RECONCILED=0

mark_stale() {
  local section="$1" fallback=1
  # NEW-M1: the [untrusted:compact D] date ages a Plan line ONLY when this merge had no plan
  # emission. After a reconcile every open line the emission omitted carries a [carried D]
  # token, so the lines still without one are exactly the ones just EMITTED -- live by
  # definition, never aged by the date their source mark happens to carry.
  [ "${PLAN_RECONCILED:-0}" = "1" ] && fallback=0
  local new_tmp
  new_tmp=$(mktemp) || { sb_log_error "merge-project-update.sh" "gate=mark-stale-failed section=$section reason=mktemp" 1; return 1; }
  local ms_out awk_ec
  ms_out=$(LC_ALL=C awk -v s="$section" -v cutoff="$STALE_CUTOFF" -v fallback="$fallback" "$PLAN_LINE_AWK"'
    function stale_date(line,   d) { d = carried_date(line); if (d == "") d = compact_date(line); return d }
    # Stale cap 5 on EVERY merge (not only when a plan emission ran): drop the OLDEST dated
    # stale lines first (an undated one counts as oldest; document order breaks ties, NEW-L1),
    # each logged by text; every other line of the section prints exactly as buffered.
    function plan_flush(   b, n, k, p, kv, kd, drop, t) {
      n = 0
      for (b = 1; b <= bn; b++) if (buf[b] ~ /^- \[stale\]/) { n++; sidx[n] = b; sd[n] = stale_date(buf[b]) }
      if (n > 5) {
        for (k = 1; k <= n; k++) ord[k] = k
        for (k = 2; k <= n; k++) {
          kv = ord[k]; kd = sd[kv]; p = k - 1
          while (p >= 1 && sd[ord[p]] > kd) { ord[p + 1] = ord[p]; p-- }
          ord[p + 1] = kv
        }
        drop = n - 5
        for (k = 1; k <= drop; k++) {
          b = sidx[ord[k]]; dead[b] = 1
          t = buf[b]; sub(/^- \[stale\][ ]*/, "", t)
          print "DROP\t" owned_text("- " t) > "/dev/stderr"
        }
        changed = 1
      }
      for (b = 1; b <= bn; b++) if (!dead[b]) print buf[b]
    }
    BEGIN { isplan = (s == "## Plan") }
    # The Plan is the FIRST "## Plan" / "## Plan <suffix>" header only (R2-SF2); every other
    # section matches its header EXACTLY (NEW-L3: a "## Open blockers (archived)" section is
    # history, never aged).
    isplan && !seen && /^## Plan( |$)/ { seen = 1; flag = 1; print; next }
    !isplan && $0 == s { flag = 1; print; next }
    flag && isplan && (/^## / || /^<!--/) { plan_flush(); flag = 0; print; next }
    /^## / { flag = 0; print; next }
    # Plan lines carry their age in a [carried D] token (checkbox first). CR-M2: an item that is
    # ONLY [untrusted:compact D] ages by that date when nothing reconciled the Plan this merge
    # (the OAuth/no-drainer case), instead of sitting newest-looking forever in the 15 cap.
    # Pinned lines never age.
    flag && isplan {
      line = $0
      if (line ~ /^- \[ \]/ && !is_pinned(line)) {
        d = carried_date(line)
        if (d == "" && fallback) d = compact_date(line)
        if (d != "" && d < cutoff) { sub(/^- /, "- [stale] ", line); changed = 1 }
      }
      bn++; buf[bn] = line
      next
    }
    flag && /^- \[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/ && !/\[stale\]/ && !/\[superseded\]/ {
      d = $0; sub(/^- \[/, "", d); sub(/\].*/, "", d)
      if (d < cutoff) { sub(/^- /, "- [stale] "); changed = 1 }
    }
    { print }
    END {
      if (flag && isplan) plan_flush()
      print "DONE" > "/dev/stderr"
      exit (changed ? 0 : 1)
    }
  ' "$TMP_OUT" 2>&1 >"$new_tmp"); awk_ec=$?
  # SF-C1: the exit code is a DELIBERATE two-state signal (0 = changed, 1 = no-op), never
  # "success vs failure" -- so success ALSO needs the DONE sentinel (a crash never reaches END)
  # and nothing on stderr but DROP rows and tolerated gawk "warning:" lines (R2-SF3). Anything
  # else: log loud, leave the section untouched.
  local line ms_done=0 ms_bad=0 ms_drops=""
  while IFS= read -r line; do
    case "$line" in
      '') ;;
      DONE) ms_done=1 ;;
      DROP$'\t'*) ms_drops="${ms_drops}${ms_drops:+$'\n'}${line#*$'\t'}" ;;
      *warning:*) ;;
      *) ms_bad=1 ;;
    esac
  done <<< "$ms_out"
  if [ "$ms_bad" -eq 1 ] || [ "$ms_done" -ne 1 ] || { [ "$awk_ec" -ne 0 ] && [ "$awk_ec" -ne 1 ]; }; then
    sb_log_error "merge-project-update.sh" "gate=mark-stale-failed section=$section reason=awk-error ec=$awk_ec stderr=$(err_head "$ms_out")" 1
    rm -f "$new_tmp"
    return 1
  fi
  if [ -n "$ms_drops" ]; then
    while IFS= read -r line; do
      sb_log_error "merge-project-update.sh" "gate=plan-dropped stale text=${line:0:80}" 0
    done <<< "$ms_drops"
  fi
  if [ "$awk_ec" -eq 0 ]; then
    mv "$new_tmp" "$TMP_OUT"
    CHANGED=1
  else
    rm -f "$new_tmp"
  fi
}

# Forward-looking plan: gate (per item), reconcile in place (never wipes on empty, never
# touches a human line), then age + cap it, all BEFORE compact_pending -- so the compact
# refusal bound counts open items AFTER this merge aged them, and a compact item added below
# (dated TODAY) is never in scope of this aging pass.
gate_plan_items "$RAW"
merge_plan "$PLAN" 7
mark_stale "## Plan"

# PostCompact Pending-Tasks -> ## Plan, add-only, gated inside (full trust boundary).
merge_compact_pending "$RAW"

# Resumable session WHY (replace-style one-liner; never wipes on empty).
merge_state "$SESSION_GOAL"

# Procedural runbooks → ## How-to (replace-by-verb, cap 5, no-op on empty).
merge_howto "$RAW" 5

# Session handoff → ## Handoff (replace-style, 600B cap, no-op on empty).
merge_handoff "$RAW"

if [ -n "$REFS" ]; then
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    lower_ref=$(printf '%s' "$ref" | lc)
    existing=$(awk '
      /^## Cross-references$/ { flag=1; next }
      /^## / { flag=0 }
      flag && /^- \[\[/ { print tolower($0) }
    ' "$TMP_OUT")
    if ! echo "$existing" | grep -qF -- "[[$lower_ref]]"; then
      insert_bullet "## Cross-references" "[[$ref]]" 3
    fi
    safe_ref=$(sb_sanitize_slug "$ref") || continue
    # Skip if page already exists anywhere in the wiki
    if ! find "$KNOWLEDGE_WIKI" -name "$safe_ref.md" -type f ! -name 'index.md' 2>/dev/null | grep -q .; then
      # Auto-restore: if this slug was forgotten, revive the original instead of
      # stubbing. Log only after a successful mv (no phantom "restored" events); if
      # the mv fails (archive file vanished), fall through to creating the stub.
      arch=$(BRAIN_DIR="$BRAIN_DIR" "$(dirname "$0")/wiki-archived-slugs.sh" --path "$safe_ref" 2>/dev/null) || arch=""
      restored=0
      if [ -n "$arch" ]; then
        acat=$(basename "$(dirname "$arch")"); mkdir -p "$KNOWLEDGE_WIKI/$acat"
        if mv "$arch" "$KNOWLEDGE_WIKI/$acat/$safe_ref.md" 2>/dev/null; then
          printf '{"event":"restored","slug":"%s","category":"%s","date":"%s"}\n' \
            "$safe_ref" "$acat" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$BRAIN_DIR/wiki-archive-log.jsonl" 2>/dev/null || true
          WIKI_WRITES=1; CHANGED=1; restored=1
        fi
      fi
      if [ "$restored" -eq 0 ]; then
        mkdir -p "$KNOWLEDGE_WIKI/entities"
        ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        {
          printf '%s\n' "---"
          printf 'title: "%s"\n' "$ref"
          printf 'type: entities\n'
          printf 'description: "Auto-created stub — needs expansion."\n'
          printf 'created: %s\n' "$ts"
          printf 'updated: %s\n' "$ts"
          printf 'related: []\n'
          printf 'tags: []\n'
          printf '%s\n\n' "---"
          printf '# %s\n\n' "$ref"
          printf 'TODO: expand.\n'
        } > "$KNOWLEDGE_WIKI/entities/$safe_ref.md"
        WIKI_WRITES=1
        CHANGED=1
      fi
    fi
  done <<< "$REFS"
fi

# Decisions/blockers age at the end, after every writer (the Plan already aged, above).
mark_stale "## Recent decisions"
mark_stale "## Open blockers"

WIKI_UPDATES_COUNT=$(echo "$RAW" | jq '.wiki_updates // [] | length' 2>/dev/null || echo 0)
if [ "$WIKI_UPDATES_COUNT" -gt 0 ]; then
  mkdir -p "$KNOWLEDGE_WIKI"
  while IFS= read -r update; do
    raw_category=$(echo "$update" | jq -r '.category // "concepts"' | tr -d '\r')
    raw_slug=$(echo "$update" | jq -r '.slug // empty' | tr -d '\r')
    action=$(echo "$update" | jq -r '.action // "create"' | tr -d '\r')
    title=$(echo "$update" | jq -r '.title // ""' | tr -d '\r')
    description=$(echo "$update" | jq -r '.description // ""' | tr -d '\r')
    content=$(echo "$update" | jq -r '.content // ""' | tr -d '\r')

    category=$(sb_sanitize_slug "$raw_category") || continue
    slug=$(sb_sanitize_slug "$raw_slug") || continue
    [ -z "$content" ] && continue

    # project: facet for a page created this run. Default = the originating project
    # (write-time linkage). The extractor may override per update: an explicit
    # "project" key of "" marks the page deliberately GLOBAL (cross-project learning).
    if echo "$update" | jq -e 'has("project")' >/dev/null 2>&1; then
      page_project=$(echo "$update" | jq -r '.project // ""' | tr -d '\r')
    else
      page_project="$PROJECT_SLUG"
    fi
    # Same exact-match rule as PROJECT_SLUG: validate charset, never rewrite.
    case "$page_project" in /|.*|*[!a-zA-Z0-9._-]*) page_project="" ;; esac

    # Render the extractor's structured ai_block into the marked region (closed-vocab,
    # schema-ordered). Fail-safe: no block / no node / no CLI ⇒ "" (inject nothing).
    ai_region=""
    aiblk=$(echo "$update" | jq -c '.ai_block // empty' 2>/dev/null)
    if [ -n "$aiblk" ] && [ "$aiblk" != "null" ] && command -v node >/dev/null 2>&1 && [ -f "$RENDER_CLI" ]; then
      ai_region=$(jq -nc --arg t "$category" --argjson b "$aiblk" '{type:$t,block:$b}' 2>/dev/null | node "$RENDER_CLI" 2>/dev/null)
    fi

    # Gate: reject MR/session-style slugs
    if echo "$slug" | grep -qE '^mr[0-9]+-|^mr-[0-9]+|-mr[0-9]+$|-session$'; then
      continue
    fi
    # Gate: reject session-narrative content
    if echo "$content" | grep -qiE '(files (changed|touched)|review approach|in this session|friction signals:)'; then
      continue
    fi

    target_dir="$KNOWLEDGE_WIKI/$category"
    mkdir -p "$target_dir"
    target_file="$target_dir/$slug.md"
    ts_now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Check for existing page with same slug in any category (avoid duplicates)
    existing=$(find "$KNOWLEDGE_WIKI" -name "$slug.md" -type f ! -name 'index.md' 2>/dev/null | head -1)
    if [ -z "$existing" ]; then
      # Auto-restore: re-creating a forgotten slug revives the original (then the
      # new content lands as an update below) rather than spawning a duplicate.
      arch=$(BRAIN_DIR="$BRAIN_DIR" "$(dirname "$0")/wiki-archived-slugs.sh" --path "$slug" 2>/dev/null) || arch=""
      if [ -n "$arch" ]; then
        acat=$(basename "$(dirname "$arch")"); mkdir -p "$KNOWLEDGE_WIKI/$acat"
        if mv "$arch" "$KNOWLEDGE_WIKI/$acat/$slug.md" 2>/dev/null; then
          printf '{"event":"restored","slug":"%s","category":"%s","date":"%s"}\n' \
            "$slug" "$acat" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$BRAIN_DIR/wiki-archive-log.jsonl" 2>/dev/null || true
          existing="$KNOWLEDGE_WIKI/$acat/$slug.md"; target_file="$existing"; action="update"
        fi
      fi
    fi
    if [ -n "$existing" ] && [ "$existing" != "$target_file" ]; then
      target_file="$existing"
      action="update"
    fi

    if [ "$action" = "update" ] && [ -f "$target_file" ]; then
      # Refresh the authored ai-block FIRST -- before the prose-dedup early-continue --
      # so a sharpened block is applied even when the prose is a duplicate ("a stale block is
      # worse than none"). Replace a COMPLETE region in place (FIRST ai:begin only, via a
      # `replaced` latch + a `drop` that never re-arms -- so a stray ai:begin in prose can't
      # duplicate the region or run away to EOF); inject after a real frontmatter fence if absent;
      # leave a malformed begin-without-end page untouched (never eat the body). mawk-safe: ENVIRON.
      if [ -n "$ai_region" ]; then
        if grep -qE '<!--[[:space:]]*ai:begin' "$target_file" 2>/dev/null; then
          if grep -qE '<!--[[:space:]]*ai:end[[:space:]]*-->' "$target_file" 2>/dev/null; then
            AI_REGION="$ai_region" awk '
              BEGIN { reg = ENVIRON["AI_REGION"] }
              /<!--[[:space:]]*ai:begin/ && !replaced { print reg; drop=1; replaced=1; next }
              drop && /<!--[[:space:]]*ai:end[[:space:]]*-->/ { drop=0; next }
              drop { next }
              { print }
            ' "$target_file" > "$target_file.tmp" && mv "$target_file.tmp" "$target_file"
          fi
          # else: malformed (begin without end) -> no-op (safe)
        else
          AI_REGION="$ai_region" awk '
            BEGIN { reg = ENVIRON["AI_REGION"]; fm=0; done=0 }
            NR==1 && !/^---[[:space:]]*$/ { print; noinject=1; next }
            noinject { print; next }
            /^---[[:space:]]*$/ && fm<2 { print; fm++; if (fm==2 && !done) { print ""; print reg; print ""; done=1 } next }
            { print }
          ' "$target_file" > "$target_file.tmp" && mv "$target_file.tmp" "$target_file"
        fi
      fi
      # Content-aware dedup: skip only if the new content's 60-byte prefix
      # already appears (verbatim, in order) in the page.
      # D143: grep -F treats an embedded newline as separating MULTIPLE alternate
      # patterns ("a list of fixed strings, separated by newlines"), so the old
      # `grep -qF "$content_check" "$target_file"` let ANY ONE line of a
      # multi-line prefix (a recurring "Symptom: .../"Fix:", or even a blank
      # line matching everything) mark the WHOLE update a duplicate — dropping
      # genuinely new later lines that were never actually in the page. Flatten
      # embedded newlines to spaces on BOTH the pattern and the page it
      # searches, so the compare is exactly ONE literal pattern against ONE
      # flattened haystack, never a newline-delimited pattern list.
      # Copilot (PR #103): trim leading whitespace BEFORE taking the prefix, and require a
      # non-space byte — an update that starts with blank lines would otherwise yield a
      # spaces-only pattern that matches every page and silently skips the real update.
      content_check=$(printf '%s' "$content" | tr '\n' ' ' | sed 's/^[[:space:]]*//' | head -c 60)
      case "$content_check" in *[![:space:]]*) ;; *) content_check="" ;; esac
      if [ -n "$content_check" ] && tr '\n' ' ' < "$target_file" 2>/dev/null | grep -qF "$content_check"; then
        continue
      fi
      # Append under History/Updates section with timestamp
      if grep -q '^## History' "$target_file" 2>/dev/null; then
        CONTENT="$content" awk -v ts="$(date +%Y-%m-%d)" '
          /^## History/ { print; printed=1; next }
          printed && !inserted { print "- [" ts "] " ENVIRON["CONTENT"]; inserted=1 }
          { print }
        ' "$target_file" > "$target_file.tmp" && mv "$target_file.tmp" "$target_file"
      else
        printf '\n## Updates\n\n%s\n' "$content" >> "$target_file"
      fi
      if grep -q '^updated:' "$target_file" 2>/dev/null; then
        awk -v ts="$ts_now" '{ if (/^updated:/) print "updated: " ts; else print }' \
          "$target_file" > "$target_file.tmp" && mv "$target_file.tmp" "$target_file"
      fi
    else
      {
        printf '%s\n' "---"
        printf 'title: "%s"\n' "${title:-$slug}"
        printf 'type: %s\n' "$category"
        [ -n "$description" ] && printf 'description: "%s"\n' "$description"
        printf 'created: %s\n' "$ts_now"
        printf 'updated: %s\n' "$ts_now"
        [ -n "$page_project" ] && printf 'project: %s\n' "$page_project"
        printf '%s\n\n' "---"
        [ -n "$ai_region" ] && printf '%s\n\n' "$ai_region"   # authored ai-block (shared intermediate)
        printf '# %s\n\n' "${title:-$slug}"
        printf '%s\n' "$content"
      } > "$target_file"
    fi
    WIKI_WRITES=1
  done < <(echo "$RAW" | jq -c '.wiki_updates // [] | .[]' 2>/dev/null)
fi

if [ "$CHANGED" -eq 1 ]; then
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  new_tmp=$(mktemp)
  awk -v ts="$ts" '
    /^<!-- last_updated:/ { print "<!-- last_updated: " ts " -->"; next }
    { print }
  ' "$TMP_OUT" > "$new_tmp"
  if [ $? -eq 0 ] && [ -s "$new_tmp" ]; then
    mv "$new_tmp" "$TMP_OUT"
  else
    sb_log_error "merge-project-update.sh" "gate=merge-timestamp-failed reason=awk-error — last_updated NOT bumped, prior TMP_OUT kept" 1
    rm -f "$new_tmp"
  fi
  # SF-C1 final guard: whatever ran above (any merge_*/mark_stale/insert_bullet/
  # detect_supersede awk, all rewriting the SAME TMP_OUT staging buffer), TMP_OUT must
  # still look like a real PROJECT.md before it is ever allowed to replace the real one.
  # This is the LAST line of defense against every awk call in this script -- a truncated/
  # emptied TMP_OUT from any of them must never overwrite a good PROJECT.md.
  # R2-SF7: "still looks real" = non-empty AND still carrying the ORIGINAL file's own first
  # heading line (ORIG_HEAD, captured at ingest) -- no merge writer ever rewrites a heading.
  if [ ! -s "$TMP_OUT" ] || { [ -n "$ORIG_HEAD" ] && ! LC_ALL=C grep -qxF -- "$ORIG_HEAD" "$TMP_OUT"; }; then
    sb_log_error "merge-project-update.sh" "PROJECT.md staging buffer corrupted (empty or missing its original first heading '${ORIG_HEAD:0:80}') for $PROJECT_MD — write REFUSED, delta NOT applied" 3
    rm -f "$TMP_OUT" 2>/dev/null
    trap - EXIT
    exit 3
  fi
  # EXIT 3 ON A FAILED WRITE. This `mv` was unchecked and the script ended `exit 0` regardless,
  # so an unwritable PROJECT.md (permissions, full disk, a path that stopped existing) returned
  # success to the drainer, which recorded the transcript `outcome:ok` — and the archive cap
  # then evicted it FIRST as "already extracted". Knowledge destroyed, health file still `ok`,
  # no log row. Sandbox-reproduced 2026-08-23 (ledger EC-13). A non-zero here becomes `retry`
  # in the drainer (error after SB_DRAIN_MAX_FAILS) and the transcript is retained.
  if ! mv "$TMP_OUT" "$PROJECT_MD"; then
    sb_log_error "merge-project-update.sh" "PROJECT.md write FAILED for $PROJECT_MD — delta NOT applied; transcript must be retried, not marked extracted" 3
    rm -f "$TMP_OUT" 2>/dev/null
    trap - EXIT
    exit 3
  fi
  trap - EXIT
fi

if [ "$WIKI_WRITES" -eq 1 ]; then
  # Centralized reindex helper (lib.sh) — handles ESM dynamic-import correctly
  # and derives plugin root when CLAUDE_PLUGIN_ROOT is unset.
  sb_reindex_wiki "$KNOWLEDGE_DIR"
  # Increment the wiki-writes counter. session-load.sh consumes this at the
  # SB_MAINTAINER_THRESHOLD and auto-dispatches the maintainer subagent.
  # PROJECT_SLUG derived once near the top (single source).
  [ -n "$PROJECT_SLUG" ] && sb_inc_wiki_writes "$PROJECT_SLUG"
fi

# Reset session counter after a dream cycle. We detect "dream just accepted"
# by the presence of a freshly-archived dream dir touched within last 5 min.
# Cheap heuristic, no MCP roundtrip needed.
RECENT_DREAM=$(find "$BRAIN_DIR/dreams/" -maxdepth 2 -name 'status.json' -mmin -5 2>/dev/null \
  | xargs -I{} jq -r 'select(.status == "completed" or .status == "archived") | .id' {} 2>/dev/null | head -1)
if [ -n "$RECENT_DREAM" ]; then
  # PROJECT_SLUG from the guarded top-level derivation — never recompute it raw here
  # (an unguarded basename would reach the .session-count path sink unvalidated).
  [ -n "$PROJECT_SLUG" ] && sb_reset_session_count "$PROJECT_SLUG"
fi

exit 0
