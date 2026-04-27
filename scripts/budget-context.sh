#!/bin/bash
# Hot/warm/cold context budget for ~/.second-brain/learnings.md.
#
# session-load.sh used to inject the entire learnings.md into the SessionStart
# context — unbounded growth, no prioritization. This script scores each
# learning by (confidence x recency_factor) and emits only the top entries
# that fit within HOT_BUDGET_CHARS (~4k tokens default).
#
# Demoted entries stay in learnings.md; /second-brain:query can retrieve them
# on demand. Legacy entries without a meta line score as raw confidence (1.0)
# so they don't get unfairly demoted before they have a chance to accumulate
# meta. Entire file is emitted unchanged when it already fits the budget.
#
# Usage: bash budget-context.sh
# Stdout: trimmed learnings.md content
# Stderr: brief budget report

# Force C locale so ${#X} and wc -c agree (bytes, not multibyte chars).
LC_ALL=C
export LC_ALL
set -u

LEARNINGS="$HOME/.second-brain/learnings.md"
HOT_BUDGET_CHARS="${SECOND_BRAIN_HOT_BUDGET:-16000}"  # ~4k tokens at ~4 bytes/token

# Defensive: nothing to do if file missing/empty.
[ -f "$LEARNINGS" ] || exit 0
[ -s "$LEARNINGS" ] || { cat "$LEARNINGS"; exit 0; }

# Tiny file -> emit as-is.
TOTAL_BYTES=$(wc -c < "$LEARNINGS" | tr -d ' ')
if [ "$TOTAL_BYTES" -le "$HOT_BUDGET_CHARS" ]; then
  cat "$LEARNINGS"
  exit 0
fi

TODAY=$(date -u +"%Y-%m-%d")

# Sentinel for embedding multi-line block bodies as a single TSV line:
#   \034 (file separator, octal escape) is POSIX-portable across gawk, mawk,
#   and BSD awk; tr '\034' '\n' restores newlines on output.
# POSIX awk only — no 3-arg match(); use match() + RSTART/RLENGTH + substr().
SCORED=$(awk -v today="$TODAY" '
function date_to_days(d,    y, m, dd) {
  if (length(d) != 10) return 0
  y = substr(d, 1, 4) + 0
  m = substr(d, 6, 2) + 0
  dd = substr(d, 9, 2) + 0
  return y * 365 + m * 30 + dd
}
function days_between(later, earlier) { return date_to_days(later) - date_to_days(earlier) }
function score(conf, last_used,    d, factor) {
  if (last_used == "") return conf
  d = days_between(today, last_used)
  if (d < 0) d = 0
  factor = 1 - d / 180
  if (factor < 0) factor = 0
  return conf * factor
}
function extract(re_str, line,    s) {
  # Pass regex as a string; awk evaluates regex constants against $0 when
  # passed as function args, returning a boolean instead of the regex.
  if (match(line, re_str)) {
    s = substr(line, RSTART, RLENGTH)
    sub(/^[^=]+=/, "", s)
    return s
  }
  return ""
}
function emit_block() {
  if (!has_header) return
  s = score(conf + 0, last_used)
  gsub(/\n/, "\034", buf)
  printf "%.4f\t%d\t%s\n", s, header_nr, buf
  buf = ""; has_header = 0; has_meta = 0; conf = 1; last_used = ""
}
BEGIN { buf = ""; has_header = 0; has_meta = 0; conf = 1; last_used = ""; head = "" }
NR == 1 && $0 ~ /^# / { head = head $0 "\n"; next }
/^$/ && head != "" && !has_header { head = head "\n"; next }
/^## \[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/ {
  emit_block()
  has_header = 1
  header_nr = NR
  buf = $0 "\n"
  next
}
/^<!-- meta: / {
  has_meta = 1
  c = extract("confidence=[0-9]+(\\.[0-9]+)?", $0)
  if (c ~ /^[0-9]+(\.[0-9]+)?$/) conf = c
  d = extract("last_used=[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]", $0)
  if (d ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) last_used = d
  buf = buf $0 "\n"
  next
}
{
  if (has_header) buf = buf $0 "\n"
  else if (head != "") head = head $0 "\n"
}
END {
  emit_block()
  gsub(/\n/, "\034", head)
  printf "__HEAD__\t-1\t%s\n", head
}
' "$LEARNINGS")

# Emit the head row first (everything before the first ## block: file title,
# blank lines, etc.).
HEAD_LINE=$(printf '%s\n' "$SCORED" | awk -F'\t' '$1 == "__HEAD__" {print $3; exit}' | tr '\034' '\n')
printf '%s' "$HEAD_LINE"

# Then iterate scored blocks in descending score, ascending original position.
USED=${#HEAD_LINE}
KEPT=0
DROPPED=0
TOTAL=0
while IFS=$'\t' read -r SCORE POS BODY; do
  [ -z "${BODY:-}" ] && continue
  [ "$SCORE" = "__HEAD__" ] && continue
  TOTAL=$((TOTAL + 1))
  RESTORED=$(printf '%s' "$BODY" | tr '\034' '\n')
  LEN=${#RESTORED}
  if [ $((USED + LEN)) -le "$HOT_BUDGET_CHARS" ]; then
    printf '%s' "$RESTORED"
    USED=$((USED + LEN))
    KEPT=$((KEPT + 1))
  else
    DROPPED=$((DROPPED + 1))
  fi
done <<< "$(printf '%s\n' "$SCORED" | awk '$1 != "__HEAD__"' | sort -t$'\t' -k1,1nr -k2,2n)"

printf 'budget-context: kept %d/%d entries within %s bytes (%d demoted to /second-brain:query).\n' \
  "$KEPT" "$TOTAL" "$HOT_BUDGET_CHARS" "$DROPPED" >&2

exit 0
