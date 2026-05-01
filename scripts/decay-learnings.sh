#!/bin/bash
# Decay sweeper for ~/.second-brain/learnings.md.
#
# Each learning carries a meta line:
#   <!-- meta: confidence=0.65 hits=3 last_used=2026-04-27 -->
#
# Drop an entry when ALL of these hold:
#   - last_used > MAX_AGE_DAYS old
#   - hits < MIN_HITS
#   - confidence < MIN_CONFIDENCE
#
# Conservative on purpose — a high-confidence learning never decays from age
# alone, and a recently-touched one is always kept. We back up before deleting
# anything so a bad sweep is recoverable.
#
# Invoked by SessionStart (low-cost: no-op on tiny files) and by
# /second-brain:improve as part of its cleanup pass.

set -u

BRAIN_DIR="$HOME/.second-brain"
LEARNINGS="$BRAIN_DIR/learnings.md"
DECAY_LOG="$BRAIN_DIR/decay-log.jsonl"

MAX_AGE_DAYS="${SECOND_BRAIN_DECAY_MAX_AGE:-60}"
MIN_HITS="${SECOND_BRAIN_DECAY_MIN_HITS:-2}"
MIN_CONFIDENCE="${SECOND_BRAIN_DECAY_MIN_CONFIDENCE:-0.5}"
BACKUPS_KEEP="${SECOND_BRAIN_DECAY_BACKUPS_KEEP:-5}"

# Hard requirement: jq. Same preflight as every other hook.
command -v jq >/dev/null 2>&1 || { echo "decay-learnings: jq missing, skipping" >&2; exit 0; }

# Bail fast if there's nothing to do.
[ -f "$LEARNINGS" ] || exit 0
[ -s "$LEARNINGS" ] || exit 0

# Compute cutoff date in YYYY-MM-DD; works on GNU and BSD date.
CUTOFF=$(date -u -d "$MAX_AGE_DAYS days ago" +"%Y-%m-%d" 2>/dev/null \
      || date -u -v-"${MAX_AGE_DAYS}"d +"%Y-%m-%d")
# Empty CUTOFF + set -u + lexicographic compare = mass-delete trap. Refuse.
[ -n "$CUTOFF" ] || { echo "decay-learnings: cannot compute cutoff date, aborting" >&2; exit 1; }
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# awk processes the file in one pass. POSIX-only: no 3-arg match() (gawk-only,
# silently fails on macOS BSD awk and mawk). Confidence is validated as numeric
# before use; malformed values default to 1 (keep-safe).
TMP=$(mktemp)
DROPPED_LIST=$(mktemp)
trap 'rm -f "$TMP" "$DROPPED_LIST"' EXIT

awk -v cutoff="$CUTOFF" \
    -v min_hits="$MIN_HITS" \
    -v min_conf="$MIN_CONFIDENCE" \
    -v dropped_file="$DROPPED_LIST" '
function extract(re_str, line,    s) {
  # POSIX match(string, dynamic_regex_string) — passing the regex as a string
  # is mandatory; awk evaluates regex constants against $0 when passed as
  # function arguments (yielding a boolean), not as the regex itself.
  if (match(line, re_str)) {
    s = substr(line, RSTART, RLENGTH)
    sub(/^[^=]*=/, "", s)
    return s
  }
  return ""
}
function is_numeric(s) { return s ~ /^[0-9]+(\.[0-9]+)?$/ }
function flush_block() {
  if (!has_header) return
  keep = 1
  if (has_meta) {
    if (last_used < cutoff && hits < min_hits && (conf + 0) < (min_conf + 0)) {
      keep = 0
    }
  }
  if (keep) {
    printf "%s", buf
  } else {
    print title >> dropped_file
  }
  buf = ""; has_header = 0; has_meta = 0; title = ""; last_used = ""; hits = 0; conf = 1
}
BEGIN { buf = ""; has_header = 0; has_meta = 0; title = ""; last_used = ""; hits = 0; conf = 1 }
/^## \[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/ {
  flush_block()
  has_header = 1
  title = $0
  buf = $0 "\n"
  next
}
/^<!-- meta: / {
  has_meta = 1
  c = extract("confidence=[0-9]+(\\.[0-9]+)?", $0)
  if (is_numeric(c)) conf = c
  h = extract("hits=[0-9]+", $0)
  if (h ~ /^[0-9]+$/) hits = h + 0
  d = extract("last_used=[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]", $0)
  if (d ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) last_used = d
  buf = buf $0 "\n"
  next
}
{
  if (has_header) buf = buf $0 "\n"
  else            print
}
END { flush_block() }
' "$LEARNINGS" > "$TMP"

# Count dropped entries.
DROPPED_COUNT=$(wc -l < "$DROPPED_LIST" 2>/dev/null | tr -d ' \t')
DROPPED_COUNT=${DROPPED_COUNT:-0}

if [ "$DROPPED_COUNT" -gt 0 ]; then
  # Lockfile to coordinate with any concurrent writers of learnings.md
  LOCKFILE="$BRAIN_DIR/.learnings.lock"
  exec 9>"$LOCKFILE"
  flock -w 5 9 2>/dev/null || true

  # Back up the original before overwriting.
  STAMP=$(date -u +"%Y%m%d%H%M%S")
  cp "$LEARNINGS" "$LEARNINGS.bak.$STAMP"
  mv "$TMP" "$LEARNINGS"

  # Cap backup retention so SessionStart-frequent decays don't fill disk.
  # ls -1t lists newest first; tail -n +N skips the first N-1.
  ls -1t "$LEARNINGS".bak.* 2>/dev/null | tail -n +"$((BACKUPS_KEEP + 1))" | while IFS= read -r OLD; do
    rm -f "$OLD"
  done

  # Log via jq -R/-s so titles are properly JSON-encoded (handles backslashes,
  # quotes, control chars). No raw printf fallback — jq is required above.
  TITLES_JSON=$(jq -R -s 'split("\n") | map(select(length>0))' "$DROPPED_LIST")
  jq -nc \
    --arg t "$NOW" \
    --argjson n "$DROPPED_COUNT" \
    --argjson titles "$TITLES_JSON" \
    '{timestamp:$t, entries_dropped:$n, dropped_titles:$titles}' \
    >> "$DECAY_LOG"
else
  rm -f "$TMP"
fi

exit 0
