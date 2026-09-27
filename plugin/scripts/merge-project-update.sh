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
#     "plan":             ["<text>", ...],   # forward checklist -- see ## Plan grammar below. Gated
#                                             # through gate_untrusted_items() (SEC-M4): the extractor
#                                             # can echo transcript content (a prior compaction
#                                             # summary) verbatim into its own emission.
#     "compact_pending":  ["<text>", ...],   # PostCompact Pending-Tasks bullets, add-only. Cut,
#                                             # sanitized and injection-scanned RIGHT HERE by the shared
#                                             # gate_untrusted_items() trust boundary (SF-H1/SEC-M3) --
#                                             # the caller (pre-compact.sh post) only extracts the
#                                             # Pending Tasks section and passes the raw text through.
#                                             # Landed as "- [ ] [untrusted:compact TODAY] <text>". Cap 5 used,
#                                             # refused once non-pinned unfinished lines would reach 15.
#     "wiki_updates":     [{"category","slug","action","title","description","content"}, ...]
#   }
#
# --session <sid>  (optional flag, not a JSON key): sanitized to [A-Za-z0-9_-]{1,64}. Stamps
#   ## Handoff's "written: t=... session=... branch=... head=..." line from
#   $BRAIN_DIR/.injected/<sid>.prov (sb_session_prov_write, lib.sh) when that file exists.
#
# ## Plan grammar (the contract every emitter/reader codes against):
#   - [pinned] <text>                                           human north star -- never touched here
#   - [ ] <text>                                                current unfinished item (extractor/human)
#   - [x] <text>                                                done; retired by the next emission that omits it
#   - [x] <text> (dropped: <why>)                               retired without doing it
#   - [ ] [untrusted:compact YYYY-MM-DD] <text>                 added by compact_pending (source mark, sticky)
#   - [ ] [carried YYYY-MM-DD] <text>                           omitted by an emission; kept by the guard
#   - [ ] [untrusted:compact YYYY-MM-DD] [carried YYYY-MM-DD] <text>   both (source first)
#   - [stale] [ ] [carried YYYY-MM-DD] <text>                   aged by mark_stale
#   Bounds: 15 non-pinned unfinished lines (emitted+carried+compact), 5 stale (oldest dropped, logged).
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
# carried/compact-sourced/emitted rendering of the SAME item always dedups to the SAME key.
# Kept as ONE awk library string (apostrophe-free -- the single-quoted-program trap) prefixed
# onto both callers' `awk` invocations, per the "single awk, no per-item spawn" rule.
# ASCII-only tolower (mawk/BSD awk are not locale-aware): a non-ASCII key may differ across
# platforms, which only ever affects dedup — documented cross-platform trap (§8), not a bug.
# Steps mirror the spec exactly: 1) lowercase  2) strip a leading bullet  3) repeatedly strip
# LEADING marker tokens ([ ]/[x]/[pinned]/(pinned)/[stale]/[untrusted:compact D]/[carried D])
# 4) repeatedly strip TRAILING age/provenance parentheticals  5) collapse whitespace + trim +
# drop trailing punctuation. A meaningful trailing "(Windows only)" is not one of step 4's
# patterns, so it survives.
PLAN_NORM_AWK='
function plan_norm(raw,  s,t) {
  s = tolower(raw)
  sub(/^[ ]*[-*+][ ]+/, "", s)
  # Every marker token may appear wrapped in EITHER [..] (the stored PROJECT.md form) or (..)
  # (the card-rendered form -- sb_card_trunc turns [ into ( for display, Set 2). A dedup key
  # must match a compact_pending item whether the text was copied from the raw file or from
  # a rendered card, so both wrappings are stripped for every token type. No apostrophes in
  # this comment block: it lives inside a single-quoted bash string (PLAN_NORM_AWK) and one
  # would close that quote early -- exactly the jq/awk apostrophe trap this repo has hit before.
  while (1) {
    t = s
    sub(/^\[ \][ ]*/, "", s); sub(/^\( \)[ ]*/, "", s)
    sub(/^\[x\][ ]*/, "", s); sub(/^\(x\)[ ]*/, "", s)
    sub(/^\[pinned\][ ]*/, "", s); sub(/^\(pinned\)[ ]*/, "", s)
    sub(/^\[stale\][ ]*/, "", s); sub(/^\(stale\)[ ]*/, "", s)
    sub(/^\[untrusted:compact[ 0-9-]*\][ ]*/, "", s); sub(/^\(untrusted:compact[ 0-9-]*\)[ ]*/, "", s)
    sub(/^\[carried[ 0-9-]*\][ ]*/, "", s); sub(/^\(carried[ 0-9-]*\)[ ]*/, "", s)
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
# CR-M4: session-load.sh renders a Plan line into the startup card cut at a display cap,
# appending an ellipsis when it truncates -- a re-fed compaction Pending Task built from
# that rendered card echoes back a TRUNCATED prefix of a real item, ending in an ellipsis.
# An exact-key dedup misses it (the keys differ: full text vs a cut prefix), so the same
# item would duplicate every compaction cycle. ends_ellipsis/ellipsis_prefix let callers
# prefix-match a key ending in one of these markers against the other key instead of
# requiring exact equality. Byte-literal match (mawk has no multibyte awareness) is fine
# here -- both the UTF-8 bytes of the real ellipsis char and the ASCII three-dot form are
# matched as literal byte sequences, never as a character class.
function ends_ellipsis(s) {
  return (s ~ /(\.\.\.|…)$/)
}
function ellipsis_prefix(s,  t) {
  t = s
  sub(/\.\.\.$/, "", t)
  sub(/…$/, "", t)
  return t
}
function dupmatch(a, b,   pa, pb) {
  if (a == b) return 1
  if (ends_ellipsis(a)) { pa = ellipsis_prefix(a); if (length(pa) > 0 && index(b, pa) == 1) return 1 }
  if (ends_ellipsis(b)) { pb = ellipsis_prefix(b); if (length(pb) > 0 && index(a, pb) == 1) return 1 }
  return 0
}
'

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
PLAN=$(flatten_field "$RAW" plan)
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

CHANGED=0

TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT
# tr -d '\r' (not cp): normalize CRLF at ingest so every downstream awk/grep reader sees LF.
# A CRLF PROJECT.md (Windows/imported) otherwise silently no-ops the ENTIRE merge — section
# headers like `## Recent decisions` never match `/^## .../`, so decisions/blockers/plan are
# never written and dedup never fires. The merge writes TMP_OUT back, so this also LF-normalizes.
tr -d '\r' < "$PROJECT_MD" > "$TMP_OUT"

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

  local lower_new
  # Strip date prefix and common markers for dedup comparison
  lower_new=$(printf '%s' "$bullet_text" | sed 's/^\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\] //' | sed 's/^\[active\] //;s/^\[resolved\] //;s/^\[stale\] //;s/^\[decision\] //;s/^\[pinned\] //' | tr '[:upper:]' '[:lower:]')
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
  if echo "$existing_lower" | grep -qF -- "$lower_new"; then
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

# SF-H1 + SF-H2 + SEC-M1(capture side) + SEC-M3 + SEC-M4: the ONE trust boundary for text
# this script did not itself author -- PostCompact Pending-Tasks bullets AND the
# extractor's own plan[] emission (which can echo a prior compaction summary or other
# transcript content verbatim). Runs the WHOLE batch through, never a per-item spawn:
#   1) codepoint-safe cut to 120 chars/item (CR-H1: jq .[:120], not the byte-based `cut`)
#   2) sanitize via the canonical sanitize-cli (strips the Tags-block/ZWSP/WJ/BOM channel)
#   3) a gate-local case-insensitive check for evasions the shared scanner pattern set
#      (tool-return-scanner.sh, case-sensitive after the first letter) misses -- an
#      ALL-CAPS "IGNORE ALL PREVIOUS INSTRUCTIONS", a <system-reminder> tag, a bare
#      "SYSTEM:" line -- plus any \p{Cc}/\p{Cf} control/format character (ESC, BEL, NEL,
#      RLO/LRI, ...). This check lives HERE, not in tool-return-scanner.sh: it must stay
#      stricter than that shared/global pattern set without changing it for every caller.
#   4) the real injection scanner (tool-return-scanner.sh), fed on STDIN via `jq -Rs`
#      (never `--arg` with the full text -- that blows argv limits on a large blob) as a
#      synthetic Read return so it reuses the maintained pattern library.
# Fails CLOSED: any failure at any step rejects the ENTIRE batch (echoes nothing) and logs
# a specific ec1 reason. Residual (documented, not fixed here): tool-return-scanner.sh
# itself always exits 0 and prints nothing on both "clean" and several silent-degrade
# paths (SEC-M3) -- it is out of this file's ownership, so "clean" is approximated here as
# "the file existed, bash's own exit code was 0, and stdout was empty"; a scanner-owned
# opt-in clean-sentinel would close that residual gap precisely.
gate_untrusted_items() {
  local raw="$1" caller="$2"
  [ -z "$raw" ] && { printf ''; return 0; }

  local capped
  capped=$(printf '%s' "$raw" | jq -Rrs '
    split("\n") | map(select(length>0)) | map(.[0:120]) | join("\n")
  ' 2>/dev/null)
  if [ -z "$capped" ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=cut-failed" 1
    printf ''; return 1
  fi

  local sani_cli; sani_cli="$(sb_plugin_root)/mcp/dist/tools/sanitize-cli.bundle.js"
  if ! command -v node >/dev/null 2>&1 || [ ! -f "$sani_cli" ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=sanitize-unavailable" 1
    printf ''; return 1
  fi
  local sani_out sani_ec
  sani_out=$(printf '%s' "$capped" | node "$sani_cli" 2>/dev/null); sani_ec=$?
  if [ "$sani_ec" -ne 0 ] || { [ -n "$capped" ] && [ -z "$sani_out" ]; }; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=sanitize-failed" 1
    printf ''; return 1
  fi
  # Conservative-by-design: sanitize-cli's OWN removal list (ZWSP/WJ/BOM/Tags-block) is a
  # SMUGGLING signal for this untrusted-capture path even though sanitize.ts's normal job
  # (dream-snapshot staging) is to launder those chars silently -- fail closed here instead
  # of passing the laundered text through. Byte length via `wc -c` (locale-independent, so
  # LC_ALL is irrelevant to it) rather than bash `${#var}` (character count, and this repo has
  # hit real multi-byte-UTF-8 miscounts across platforms under some locales -- see MSYS non-
  # BMP UTF-8 notes) or `wc -m` (same locale sensitivity).
  local cap_len sani_len
  cap_len=$(printf '%s' "$capped" | LC_ALL=C wc -c | tr -d ' ')
  sani_len=$(printf '%s' "$sani_out" | LC_ALL=C wc -c | tr -d ' ')
  if [ "$cap_len" != "$sani_len" ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=invisible-chars" 1
    printf ''; return 1
  fi

  # The joined blob carries OUR OWN "\n" between items (and callers may carry a "\t" from
  # upstream normalization) -- both are themselves \p{Cc}, so the control-char test runs
  # against a copy with those two "normalized whitespace" separators flattened out first;
  # the phrase tests still run against the untouched text (the "(^|\n)system:" check needs
  # the real line breaks).
  if printf '%s' "$sani_out" | jq -Rse '
      def bad:
        (gsub("[\n\t]"; " ")) as $flat |
        ($flat | test("[\\p{Cc}\\p{Cf}]")) or
        test("ignore\\s+all\\s+previous\\s+instructions";"i") or
        test("disregard\\s+(all\\s+)?(prior|previous)\\s+instructions";"i") or
        test("<\\s*system-reminder";"i") or
        test("(^|\\n)\\s*system\\s*:";"i");
      bad
    ' >/dev/null 2>&1; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=gate-flagged" 1
    printf ''; return 1
  fi

  local scanner_path; scanner_path="$(dirname "$0")/tool-return-scanner.sh"
  if [ ! -f "$scanner_path" ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=scanner-failed src=missing" 1
    printf ''; return 1
  fi
  local scan_payload scan_out scan_ec
  scan_payload=$(printf '%s' "$sani_out" | jq -Rs --arg s "gate:$caller" '
    {tool_name:"Read", session_id:$s, tool_input:{file_path:("gate:untrusted-items:"+$s)}, tool_response:.}
  ' 2>/dev/null)
  if [ -z "$scan_payload" ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=scanner-failed src=payload-build" 1
    printf ''; return 1
  fi
  scan_out=$(printf '%s' "$scan_payload" | SB_INJECTION_SCAN=on SB_HOOK_PROFILE= bash "$scanner_path" 2>/dev/null)
  scan_ec=$?
  if [ "$scan_ec" -ne 0 ] || [ -n "$scan_out" ]; then
    sb_log_error "merge-project-update.sh" "gate=untrusted-items caller=$caller reason=scanner-failed" 1
    printf ''; return 1
  fi

  printf '%s' "$sani_out"
  return 0
}

# Reconcile the ## Plan checklist with the freshly-extracted items. The Plan is
# FORWARD state (what's next) — distinct from the backward-looking Recent decisions.
# Strategy: the extractor emits the full current checklist each session; we replace
# the non-[pinned] lines with it (capped), preserving [pinned] lines verbatim on top
# (human-authored north stars the LLM must never rewrite or rotate). A degraded/empty
# emission is a NO-OP — we never wipe the plan on a session that produced nothing.
# NOTE: [pinned] is the shared human-protection marker — insert_bullet() honours it the
# same way for ## Recent decisions / ## Open blockers (oldest NON-pinned bullet drops).
merge_plan() {
  local items="$1" cap="${2:-7}"
  [ -z "$items" ] && return 0
  # Only act when a ## Plan section exists (new projects scaffold it; the upgrade
  # migration backfills older PROJECT.md files). No section → nothing to reconcile.
  grep -q '^## Plan$' "$TMP_OUT" || return 0

  # SEC-M4: gate the extractor's OWN plan[] emission through the same trust boundary as
  # compact_pending -- it can echo transcript content (a prior compaction summary, tool
  # output) verbatim, reaching the startup card unsanitized/unscanned before this fix. A
  # rejected batch degrades exactly like an empty emission: no-op, Plan left untouched.
  local gated_items
  gated_items=$(gate_untrusted_items "$items" "plan")
  if [ -z "$gated_items" ]; then
    sb_log_error "merge-project-update.sh" "gate=plan-dropped reason=gate-rejected" 0
    return 0
  fi
  items="$gated_items"

  local pinned_lines pinned_bare
  pinned_lines=$(awk '/^## Plan$/{f=1;next} /^## /{f=0} f && /^- / && /\[pinned\]/' "$TMP_OUT")
  # Bare pinned text, lowercased, stripped ONCE outside any loop (was previously re-derived
  # inside a per-item bash loop -- F3/perf: 3 sed+cut spawns per emitted item, measured as a
  # real contributor to hook latency on MSYS's spawn-tax platforms).
  pinned_bare=$(printf '%s\n' "$pinned_lines" | sed -E 's/^- \[pinned\][[:space:]]*//' | tr '[:upper:]' '[:lower:]')

  local new_tmp; new_tmp=$(mktemp)
  local dropfile; dropfile=$(mktemp)
  # F3: every per-item transform (leading-bullet-strip, checkbox default, D7 [pinned]
  # neutralization, merge-owned-marker strip, pinned-duplicate exclusion) now runs INSIDE this
  # ONE awk invocation's BEGIN block, over the RAW gated item list -- zero bash subprocess
  # spawns per item (previously up to 5 sed/grep spawns x cap items).
  EMIT_RAW="$items" PINNED_BARE="$pinned_bare" CAP="$cap" TODAY="$TODAY" awk "$PLAN_NORM_AWK"'
    function findmarker(line) {
      if (match(line, /\[untrusted:compact 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/)) return substr(line, RSTART, RLENGTH)
      return ""
    }
    BEGIN {
      today = ENVIRON["TODAY"]
      cap = ENVIRON["CAP"] + 0
      pbn = split(ENVIRON["PINNED_BARE"], pbare, "\n")
      rawn = split(ENVIRON["EMIT_RAW"], rawitem, "\n")
      en = 0
      for (i = 1; i <= rawn; i++) {
        if (rawitem[i] == "") continue
        if (en >= cap) break
        t = rawitem[i]
        sub(/^[ ]*[-*+][ ]+/, "", t)                                  # strip a leading -, * or + bullet
        if (t !~ /^\[ \]/ && t !~ /^\[x\]/ && t !~ /^\[X\]/) t = "[ ] " t   # default to an open box
        # D7: a forged "[pinned]" in extractor-emitted text must never become an immortal
        # line -- neutralize the literal token so it renders as plain text, not the
        # human-pinned marker. Merge-owned markers ([carried D], [stale]) are never the
        # extractor own to write; strip them defensively so an echoed one cannot fake
        # sticky carry/stale state on a brand-new emission.
        gsub(/\[pinned\]/, "(pinned)", t)
        gsub(/\[carried[ 0-9-]*\][ ]*/, "", t)
        gsub(/\[stale\][ ]*/, "", t)
        gsub(/  +/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t)
        # never duplicate a [pinned] line -- compare BARE text (drop checkbox), exact match,
        # case-insensitive (matches the old grep -qiFx semantics).
        bare = t
        sub(/^\[[ xX]\][ ]*/, "", bare)
        barelow = tolower(bare)
        dup = 0
        for (j = 1; j <= pbn; j++) { if (pbare[j] != "" && pbare[j] == barelow) { dup=1; break } }
        if (dup) continue
        en++
        eraw[en] = t
        ecb[en] = (eraw[en] ~ /^\[[xX]\]/) ? "x" : " "
        edisp[en] = eraw[en]
        sub(/^\[[ xX]\][ ]*/, "", edisp[en])
        while (1) {
          tt = edisp[en]
          sub(/^\[untrusted:compact[ 0-9-]*\][ ]*/, "", edisp[en])
          sub(/^\[carried[ 0-9-]*\][ ]*/, "", edisp[en])
          sub(/^\[stale\][ ]*/, "", edisp[en])
          if (edisp[en] == tt) break
        }
        ekey[en] = plan_norm(eraw[en])
      }
    }
    /^## Plan$/ { print; print ""; inplan=1; pn=0; ln=0; sn=0; un=0; next }
    inplan && (/^## / || /^<!--/) { render(); print; inplan=0; next }
    inplan {
      if ($0 == "") next
      # SF-M2: pinned-ness is a property of an EXISTING line carrying the token ANYWHERE
      # (D7 forging-neutralization to (pinned) is emitted-items-only) -- checking only
      # ^- \[pinned\] missed "- [x] [pinned] X" (silently deleted, matched the checkbox
      # bucket below then never re-printed) and "- [ ] [pinned] X" (demoted to an ordinary
      # carried/rotatable item, its pin silently lost). Must run BEFORE the checkbox test.
      if ($0 ~ /\[pinned\]/) { pn++; pline[pn]=$0; next }
      if ($0 ~ /^- \[stale\]/) { sn++; sline[sn]=$0; skey[sn]=plan_norm($0); next }
      if ($0 ~ /^- \[[ xX]\]/) { ln++; lline[ln]=$0; lkey[ln]=plan_norm($0); next }
      # Invariant 14: an unrecognised bullet (no checkbox, e.g. a hand-written "- note" or
      # a */+ bullet) must never silently vanish -- carry it through verbatim and log once
      # per line (tagged UNPARSED on the shared stderr channel below) rather than dropping it.
      if ($0 ~ /^[-*+][ \t]/) { un++; uline[un]=$0; next }
      next
    }
    { print }
    END { if (inplan) render() }
    function render(   i,j,k,p,kv,kd,m,marker,carrdate,line,txt,t2,carn,staln,drop,dtxt,overflow,moved,eopen,
                        carrdate_arr,sord,victim,newcarline,newcarn) {
      for (i = 1; i <= en; i++) {
        # SEC-M2: seed from the EMITTED line itself first -- if the extractor rewords an
        # item prose but the raw sticky-source token survives in its own output (a
        # partial echo), that token is authoritative and must not be lost to a failed
        # key-match below. Marks are ADDED, never REMOVED: an existing-line match can only
        # ever set marker when it is non-empty, never blank one this seed already found.
        marker = findmarker(eraw[i])
        for (j = 1; j <= ln; j++) {
          if (!lused[j] && lkey[j] == ekey[i]) { lused[j]=1; m=findmarker(lline[j]); if (m!="") marker=m }
        }
        for (j = 1; j <= sn; j++) {
          if (!sused[j] && skey[j] == ekey[i]) { sused[j]=1; m=findmarker(sline[j]); if (m!="") marker=m }
        }
        emarker[i] = marker
      }
      eopen = 0
      for (i = 1; i <= en; i++) {
        line = "- [" ecb[i] "]"
        if (emarker[i] != "") line = line " " emarker[i]
        line = line " " edisp[i]
        outline[i] = line
        if (ecb[i] == " ") eopen++
      }
      carn = 0
      for (j = 1; j <= ln; j++) {
        if (lused[j]) continue
        if (lline[j] !~ /^- \[ \]/) continue
        carrdate = ""
        if (match(lline[j], /\[carried 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/)) carrdate = substr(lline[j], RSTART+9, 10)
        # CR-M2/CR-M3 symmetry: an item that is [untrusted:compact D] but has never yet
        # been carried (added this run by merge_compact_pending, no extraction cycle since)
        # ages from ITS OWN date, not from "today" -- otherwise it looks newest-of-all
        # forever and is never chosen as an overflow/stale victim.
        else if (match(lline[j], /\[untrusted:compact 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/))
          carrdate = substr(lline[j], RSTART+length("[untrusted:compact "), 10)
        if (carrdate == "") carrdate = today
        m = findmarker(lline[j])
        txt = lline[j]
        sub(/^- \[ \][ ]*/, "", txt)
        while (1) {
          t2 = txt
          sub(/^\[untrusted:compact[ 0-9-]*\][ ]*/, "", txt)
          sub(/^\[carried[ 0-9-]*\][ ]*/, "", txt)
          if (txt == t2) break
        }
        line = "- [ ]"
        if (m != "") line = line " " m
        line = line " [carried " carrdate "] " txt
        carn++; carline[carn] = line; carrdate_arr[carn] = carrdate
      }
      moved = 0
      if (eopen + carn > 15) {
        overflow = eopen + carn - 15
        if (overflow > carn) overflow = carn
        moved = overflow
      }
      # CR-M3: choose overflow victims by AGE (oldest carried/compact date first), not by
      # their position in carline[] (document-scan order, which is unrelated to age and
      # let a 26-day-old carried item survive while a today-added one got staled). Stable
      # ascending insertion sort by carrdate_arr; ties keep original document order
      # (tiebreak only, per spec) since the shift only happens on a STRICT ">".
      for (k = 1; k <= carn; k++) sord[k] = k
      for (k = 2; k <= carn; k++) {
        kv = sord[k]; kd = carrdate_arr[kv]
        p = k - 1
        while (p >= 1 && carrdate_arr[sord[p]] > kd) { sord[p+1] = sord[p]; p-- }
        sord[p+1] = kv
      }
      for (k = 1; k <= moved; k++) victim[sord[k]] = 1
      staln = 0
      for (j = 1; j <= sn; j++) {
        if (sused[j]) continue
        staln++; staleline[staln] = sline[j]
      }
      newcarn = 0
      for (i = 1; i <= carn; i++) {
        if (victim[i]) continue
        newcarn++; newcarline[newcarn] = carline[i]
      }
      for (i = 1; i <= carn; i++) {
        if (!victim[i]) continue
        line = carline[i]
        sub(/^- \[ \]/, "- [stale] [ ]", line)
        staln++; staleline[staln] = line
      }
      carn = newcarn
      for (i = 1; i <= carn; i++) carline[i] = newcarline[i]
      if (staln > 5) {
        drop = staln - 5
        for (i = 1; i <= drop; i++) {
          dtxt = staleline[i]
          sub(/^- \[stale\][ ]*\[[ xX]\][ ]*/, "", dtxt)
          sub(/^\[untrusted:compact[ 0-9-]*\][ ]*/, "", dtxt)
          sub(/^\[carried[ 0-9-]*\][ ]*/, "", dtxt)
          if (length(dtxt) > 80) dtxt = substr(dtxt, 1, 80)
          print "DROP\t" dtxt > "/dev/stderr"
        }
        for (i = drop+1; i <= staln; i++) staleline[i-drop] = staleline[i]
        staln -= drop
      }
      for (i = 1; i <= un; i++) {
        dtxt = uline[i]
        if (length(dtxt) > 120) dtxt = substr(dtxt, 1, 120)
        print "UNPARSED\t" dtxt > "/dev/stderr"
      }
      for (i = 1; i <= pn; i++) print pline[i]
      for (i = 1; i <= un; i++) print uline[i]
      for (i = 1; i <= en; i++) print outline[i]
      for (i = 1; i <= carn; i++) print carline[i]
      for (i = 1; i <= staln; i++) print staleline[i]
      print ""
    }
  ' "$TMP_OUT" > "$new_tmp" 2>"$dropfile"
  MP_AWK_EC=$?
  MP_BAD_STDERR=0
  while IFS=$'\t' read -r mp_tag mp_text; do
    [ -z "$mp_tag" ] && continue
    case "$mp_tag" in
      DROP)     sb_log_error "merge-project-update.sh" "gate=plan-dropped stale text=$mp_text" 0 ;;
      UNPARSED) sb_log_error "merge-project-update.sh" "gate=plan-dropped reason=unparsed text=$mp_text" 1 ;;
      # SF-C1: the ONLY expected stderr shapes from this awk are the two tags above --
      # anything else (a raw awk runtime-error message, garbage) means the awk did not
      # run to completion cleanly even if its exit code happens to read 0 on this
      # platform. Treat it the same as a nonzero exit: fail closed, leave Plan unchanged.
      *) MP_BAD_STDERR=1 ;;
    esac
  done < "$dropfile"
  if [ "$MP_AWK_EC" -ne 0 ] || [ "$MP_BAD_STDERR" -eq 1 ]; then
    sb_log_error "merge-project-update.sh" "gate=merge-plan-failed reason=awk-error ec=$MP_AWK_EC stderr=$(tr '\n' ' ' < "$dropfile" | head -c 200)" 1
    rm -f "$new_tmp" "$dropfile"
    return 1
  fi
  rm -f "$dropfile"
  # Preserve the module's no-op contract: only rewrite + mark dirty when the plan
  # actually changed. The extractor re-emits the full list every session, so an
  # unchanged plan must NOT churn last_updated.
  if cmp -s "$new_tmp" "$TMP_OUT"; then
    rm -f "$new_tmp"
  else
    mv "$new_tmp" "$TMP_OUT"
    CHANGED=1
  fi
}

# PostCompact Pending-Tasks -> ## Plan, add-only (C2/C3). gate_untrusted_items() (the shared
# trust boundary above) sanitizes + injection-scans the WHOLE batch before any of it reaches
# here. This function then applies the Plan grammar: forging defence (any [ / ] neutralized
# to ( / ) so a compaction bullet can never fake a merge-owned or human marker, in ONE sed
# pass over the gated blob -- no per-item spawn), dedup against every existing Plan line by
# normalized key (CR-M4: including a prefix match when either side ends in an ellipsis, so a
# card-truncated echo of a real item never duplicates it), and the 15-unfinished bound
# (refuse, never evict an existing item to make room). ONE awk over the Plan section plus
# ENVIRON["EMIT"].
merge_compact_pending() {
  local raw="$1"
  local items
  items=$(flatten_field "$raw" compact_pending)
  [ -z "$items" ] && return 0
  items=$(printf '%s\n' "$items" | head -n 5)

  local gated
  gated=$(gate_untrusted_items "$items" "compact_pending")
  if [ -z "$gated" ]; then
    sb_log_error "merge-project-update.sh" "gate=compact-pending added=0 dedup=0 refused=0 reason=gate-rejected" 0
    return 0
  fi
  # Forging defence + leading-#-strip in ONE sed pass (sed is line-oriented by default, so
  # `^` anchors to the START OF EACH LINE here, not just the start of the whole blob -- this
  # was already effectively batched semantics; the old per-item while-loop just spawned sed/
  # cut N times to get it).
  local emit2
  emit2=$(printf '%s\n' "$gated" | sed 's/\[/(/g; s/\]/)/g' | sed -E 's/^#+[[:space:]]*//')
  [ -z "$emit2" ] && return 0

  local new_tmp; new_tmp=$(mktemp)
  local countfile; countfile=$(mktemp)
  EMIT="$emit2" TODAY="$TODAY" awk "$PLAN_NORM_AWK"'
    function flush_plan(   ek,existing_open,found_stale,insert_at,last_nonblank,b,k,c,dup,newline) {
      ek = 0
      existing_open = 0
      for (b = 1; b <= bn; b++) {
        if (buf[b] ~ /^- \[ \]/) existing_open++
        if (buf[b] ~ /^- /) { ek++; ekey[ek]=plan_norm(buf[b]) }
      }
      found_stale = 0; insert_at = bn + 1
      for (b = 1; b <= bn; b++) { if (buf[b] ~ /^- \[stale\]/) { insert_at=b; found_stale=1; break } }
      if (!found_stale) {
        last_nonblank = 0
        for (b = 1; b <= bn; b++) if (buf[b] != "") last_nonblank = b
        insert_at = last_nonblank + 1
      }
      for (c = 1; c <= cn; c++) {
        dup = 0
        for (k = 1; k <= ek; k++) { if (dupmatch(ekey[k], ckey[c])) { dup=1; break } }
        if (dup) { dedup++; continue }
        if (existing_open >= 15) { refused++; continue }
        newline = "- [ ] [untrusted:compact " today "] " cand[c]
        for (b = bn; b >= insert_at; b--) buf[b+1] = buf[b]
        buf[insert_at] = newline
        bn++; insert_at++; added++; existing_open++
        ek++; ekey[ek] = ckey[c]
      }
      for (b = 1; b <= bn; b++) print buf[b]
      print "COUNTS\t" (added " " dedup " " refused) > "/dev/stderr"
    }
    BEGIN {
      today = ENVIRON["TODAY"]
      n = split(ENVIRON["EMIT"], tmp, "\n")
      cn = 0
      for (i = 1; i <= n; i++) { if (tmp[i] != "") { cn++; cand[cn]=tmp[i]; ckey[cn]=plan_norm(tmp[i]) } }
      added=0; dedup=0; refused=0; inplan=0; sawplan=0; bn=0
    }
    /^## Plan$/ { print; inplan=1; sawplan=1; bn=0; next }
    inplan && (/^## / || /^<!--/) {
      flush_plan()
      inplan = 0
      print
      next
    }
    inplan { bn++; buf[bn]=$0; next }
    { print }
    END {
      if (inplan) flush_plan()
      if (!sawplan) {
        print ""
        print "## Plan"
        print ""
        bn = 0
        flush_plan()
      }
    }
  ' "$TMP_OUT" > "$new_tmp" 2>"$countfile"
  MCP_AWK_EC=$?

  # SF-C1: the ONLY expected stderr line is the single tagged COUNTS row from flush_plan();
  # anything else (or a nonzero awk exit) means the pass did not run to completion cleanly.
  # Fail closed -- leave the Plan section (TMP_OUT) exactly as it was.
  local counts added dedup refused mcp_bad=0 mcp_line mcp_tag mcp_rest mcp_lines=0
  while IFS=$'\t' read -r mcp_tag mcp_rest; do
    [ -z "$mcp_tag" ] && [ -z "$mcp_rest" ] && continue
    if [ "$mcp_tag" = "COUNTS" ]; then
      counts="$mcp_rest"; mcp_lines=$((mcp_lines + 1))
    else
      mcp_bad=1
    fi
  done < "$countfile"
  rm -f "$countfile"
  if [ "$MCP_AWK_EC" -ne 0 ] || [ "$mcp_bad" -eq 1 ] || [ "$mcp_lines" -ne 1 ]; then
    sb_log_error "merge-project-update.sh" "gate=merge-compact-pending-failed reason=awk-error ec=$MCP_AWK_EC" 1
    rm -f "$new_tmp"
    return 1
  fi
  read -r added dedup refused <<< "$counts"
  case "$added" in ''|*[!0-9]*) added=0 ;; esac
  case "$dedup" in ''|*[!0-9]*) dedup=0 ;; esac
  case "$refused" in ''|*[!0-9]*) refused=0 ;; esac
  sb_log_error "merge-project-update.sh" "gate=compact-pending added=$added dedup=$dedup refused=$refused" 0

  if [ "$added" -gt 0 ]; then
    mv "$new_tmp" "$TMP_OUT"
    CHANGED=1
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
  if grep -q '^## State$' "$TMP_OUT"; then
    NOTE="last session goal: $note" awk '
      BEGIN { note=ENVIRON["NOTE"] }
      /^## State$/ { print; print note; f=1; next }
      f && /^## / { f=0 }
      f && /^last session goal: / { next }
      { print }
    ' "$TMP_OUT" > "$new_tmp"
  else
    # Heading absent (older/hand-rolled PROJECT.md): append the section at EOF
    # rather than silently dropping the note.
    NOTE="last session goal: $note" awk '
      { print }
      END { print ""; print "## State"; print ENVIRON["NOTE"] }
    ' "$TMP_OUT" > "$new_tmp"
  fi
  # SF-C1: check the awk exit code -- on failure leave ## State exactly as it was rather
  # than risking a truncated/empty rewrite reaching TMP_OUT.
  if [ $? -ne 0 ]; then
    sb_log_error "merge-project-update.sh" "gate=merge-state-failed reason=awk-error" 1
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
    lower_verb=$(printf '%s' "$verb" | tr '[:upper:]' '[:lower:]')
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
  if grep -q '^## How-to$' "$TMP_OUT"; then
    BODY="$body" awk '
      BEGIN { body = ENVIRON["BODY"] }
      $0 == "## How-to" { print; print ""; if (length(body)) print body; print ""; f=1; next }
      f && (/^## / || /^<!--/) { f=0; print; next }
      f { next }
      { print }
    ' "$TMP_OUT" > "$new_tmp"
  else
    BODY="$body" awk '
      BEGIN { body = ENVIRON["BODY"]; done = 0 }
      /^## Recent decisions$/ && !done { print "## How-to"; print ""; print body; print ""; done=1 }
      { print }
      END { if (!done) { print ""; print "## How-to"; print ""; print body } }
    ' "$TMP_OUT" > "$new_tmp"
  fi
  if [ $? -ne 0 ]; then
    sb_log_error "merge-project-update.sh" "gate=merge-howto-failed reason=awk-error" 1
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
  local existing_body=""
  if grep -q '^## Handoff$' "$TMP_OUT"; then
    existing_body=$(awk '/^## Handoff$/{f=1;next} /^## /{f=0} f' "$TMP_OUT" | awk '$0 != "" && $0 !~ /^written: /')
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
  if grep -q '^## Handoff$' "$TMP_OUT"; then
    BODY="$body" awk '
      BEGIN { body = ENVIRON["BODY"] }
      $0 == "## Handoff" { print; print ""; if (length(body)) print body; print ""; f=1; next }
      f && (/^## / || /^<!--/) { f=0; print; next }
      f { next }
      { print }
    ' "$TMP_OUT" > "$new_tmp"
  else
    BODY="$body" awk '
      BEGIN { body = ENVIRON["BODY"]; done = 0 }
      /^## Recent decisions$/ && !done { print "## Handoff"; print ""; print body; print ""; done=1 }
      { print }
      END { if (!done) { print ""; print "## Handoff"; print ""; print body } }
    ' "$TMP_OUT" > "$new_tmp"
  fi
  if [ $? -ne 0 ]; then
    sb_log_error "merge-project-update.sh" "gate=merge-handoff-failed reason=awk-error" 1
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

# Forward-looking plan (replace-reconcile; preserves [pinned], never wipes on empty).
merge_plan "$PLAN" 7

# PostCompact Pending-Tasks -> ## Plan, add-only. Runs AFTER merge_plan (D3: the caller has
# already sanitized + injection-scanned this text) so a compact_pending item never overwrites
# an in-session emission's carry/stale decisions for the same key this run.
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
    lower_ref=$(printf '%s' "$ref" | tr '[:upper:]' '[:lower:]')
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

# --- Auto-staleness: mark decisions/blockers older than N days as [stale] ---
# N defaults to 30 (the review skill's staleness horizon); override per policy.
# Validate-or-default (same idiom as SB_DREAM_STALE_DAYS / SB_FORGET_MIN_AGE_DAYS).
STALE_DAYS="${SB_PROJECT_STALE_DAYS:-30}"
case "$STALE_DAYS" in ''|*[!0-9]*) STALE_DAYS=30 ;; esac
STALE_CUTOFF=$(date -v-"${STALE_DAYS}"d +%Y-%m-%d 2>/dev/null \
  || date -d "${STALE_DAYS} days ago" +%Y-%m-%d 2>/dev/null \
  || echo "1970-01-01")

mark_stale() {
  local section="$1"
  local new_tmp errfile
  new_tmp=$(mktemp)
  errfile=$(mktemp)
  awk -v s="$section" -v cutoff="$STALE_CUTOFF" '
    $0 == s { flag=1; print; next }
    /^## / { flag=0; print; next }
    flag && /^- \[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/ && !/\[stale\]/ && !/\[superseded\]/ {
      d = $0; sub(/^- \[/, "", d); sub(/\].*/, "", d)
      if (d < cutoff) { sub(/^- /, "- [stale] "); changed=1 }
    }
    # Plan lines carry their age in a [carried YYYY-MM-DD] token instead of a leading
    # "- [DATE]" prefix (checkbox comes first). CR-M2: a Plan item that is ONLY
    # [untrusted:compact D] (added by merge_compact_pending, never yet carried because
    # no extraction has run since) has no [carried] token at all -- fall back to the
    # compact-source date so it still ages instead of sitting "newest-looking" forever
    # and permanently occupying a slot in the 15-unfinished cap.
    flag && /^- \[ \]/ && !/\[stale\]/ {
      d = ""
      if (match($0, /\[carried 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/)) {
        d = substr($0, RSTART+9, 10)
      } else if (match($0, /\[untrusted:compact 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/)) {
        d = substr($0, RSTART+length("[untrusted:compact "), 10)
      }
      if (d != "" && d < cutoff) { sub(/^- /, "- [stale] "); changed=1 }
    }
    { print }
    END { exit (changed ? 0 : 1) }
  ' "$TMP_OUT" > "$new_tmp" 2>"$errfile"
  local awk_ec=$?
  # SF-C1: this awk's exit code is a DELIBERATE two-state signal (0=changed, 1=no-op),
  # never "success vs failure" -- a genuine crash can still legitimately exit 1 and look
  # like an ordinary no-op. It intentionally never writes to stderr, so ANY stderr output
  # is the real failure signal here; only on that (or an exit code outside {0,1}) do we
  # log loud and leave the section untouched.
  if [ -s "$errfile" ] || { [ "$awk_ec" -ne 0 ] && [ "$awk_ec" -ne 1 ]; }; then
    sb_log_error "merge-project-update.sh" "gate=mark-stale-failed section=$section reason=awk-error ec=$awk_ec stderr=$(tr '\n' ' ' < "$errfile" | head -c 200)" 1
    rm -f "$new_tmp" "$errfile"
    return 1
  fi
  rm -f "$errfile"
  if [ "$awk_ec" -eq 0 ]; then
    mv "$new_tmp" "$TMP_OUT"
    CHANGED=1
  else
    rm -f "$new_tmp"
  fi
}

mark_stale "## Recent decisions"
mark_stale "## Open blockers"
mark_stale "## Plan"

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
  if [ ! -s "$TMP_OUT" ] || ! grep -q '^# PROJECT' "$TMP_OUT" 2>/dev/null; then
    sb_log_error "merge-project-update.sh" "PROJECT.md staging buffer corrupted (empty or missing '# PROJECT' header) for $PROJECT_MD — write REFUSED, delta NOT applied" 3
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
