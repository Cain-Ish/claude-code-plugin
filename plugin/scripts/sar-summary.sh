#!/bin/bash
# sar-summary.sh — Stop hook (HarnessAudit SAR channel).
#
# Aggregates audit-log.jsonl entries for the current session_id, computes
# a Safety Adherence Rate (SAR), and emits a one-line banner via the
# Stop hook's universal `systemMessage` field. Read-only over the audit
# log — never modifies or rotates it.
#
# SAR (HarnessAudit-style) = 1 - (ask + deny) / total_verdicts
#   - allow / rewrite count as "agent stayed in lane"
#   - ask / deny count as hard boundary violations
#   - flag is a warning, not a violation (does not pull SAR down)
#
# Output: stdout JSON with `systemMessage` only when audit entries for
# this session exist. Otherwise silent. Always exit 0 (fail-soft).
#
# Kill switch: SB_SAR_SUMMARY=off
set -u
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0

# Read stdin ONCE, builtins only (no `cat` spawn) — mirrors buddy-statusline.sh's own hot-path
# read, and matters here too: F5 (portability review), see below.
RAW=""
[ -t 0 ] || IFS= read -r -t 2 -d '' RAW || true
RAW="${RAW//$'\r'/}"

# --- Thinking-animation busy marker (0.54.0): clear here, BEFORE this hook's own kill switches
# and the SAR-specific early exits below — Stop fires on every session Stop with no matcher on
# this hook, so this is the one guaranteed clear point for what persona-context.sh stamped at the
# start of the turn. rm -f is a no-op when nothing was ever written (a muted / sprite-off /
# SB_BUDDY=off session never creates the marker); it never blocks or fails this hook.
# F5 (portability review): this must stay FORK-FREE — the old `cat`+`jq`+`tr` pipeline spawned all
# three on EVERY Stop, even when SB_SAR_SUMMARY=off or SB_BUDDY=off (this hook's OWN kill switches,
# unrelated to whether the marker gets cleared). Session-id-by-regex, builtins only — the exact
# technique buddy-statusline.sh already uses for the same reason on its own hot path.
# SEC-L2/SF-L7: this regex doubles as the sanitizer — only [A-Za-z0-9_-]{1,64} can ever land in
# BASH_REMATCH, so a session_id carrying path separators (e.g. "../../x") simply fails to match and
# this hook deletes nothing. Full-match-or-reject, not strip: the same rule persona-context.sh's
# write side applies to this identical marker path, so a marker this hook can find is exactly a
# marker persona-context.sh could have written, and vice versa.
SID=""
[[ "$RAW" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]{1,64})\" ]] && SID="${BASH_REMATCH[1]}"
BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
[ -n "$SID" ] && rm -f "$BRAIN_DIR/.buddy/$SID.busy" 2>/dev/null

[ "${SB_HOOK_PROFILE:-}" = "minimal" ] && : "${SB_SAR_SUMMARY:=off}" # hook-profile shim: this check runs before lib.sh's mapping (or lib-less)
[ "${SB_SAR_SUMMARY:-on}" = "off" ] && exit 0

[ -z "$RAW" ] && exit 0

# Bail if stdin isn't a JSON object (fail-soft on malformed input).
echo "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

SESSION_ID=$(printf '%s' "$RAW" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r')
[ -z "$SESSION_ID" ] && exit 0

AUDIT="$BRAIN_DIR/audit-log.jsonl"
[ -f "$AUDIT" ] || exit 0

# Rotate the audit log here. lib.sh defines sb_rotate_audit_log
# (5000 lines / 5 MiB cap, drops oldest 50%) but has no call site of its
# own — without this call the file grows unbounded. Stop is the cheapest
# place: it fires once per session, we already touch the audit file, and
# the rotation is a no-op when caps are not exceeded.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
if source "$PLUGIN_ROOT/scripts/lib.sh" 2>/dev/null; then
  sb_rotate_audit_log 2>/dev/null || true
fi

# D159: `jq -r 'select(...)' "$AUDIT"` parses the file as a whitespace-separated
# JSON STREAM — one torn/partial line anywhere (a concurrent-append tear, see D120)
# aborts the WHOLE pass, and every verdict past that point is silently lost. `-R`
# reads each line as a raw string and `fromjson?` skips only the bad one, so good
# rows on both sides of a tear are still counted (never re-widen the abort surface).
counts=$(jq -Rr --arg sid "$SESSION_ID" '
  fromjson? | select(type == "object" and .session_id == $sid) | .verdict // empty
' "$AUDIT" 2>/dev/null | sort | uniq -c | awk '{print $2 "=" $1}')

# Log a torn line ONCE per read (not once per skipped row) so a corrupt audit-log
# is visible in error-log.jsonl instead of silently degrading every SAR banner.
if command -v sb_count_torn_lines >/dev/null 2>&1; then
  AUDIT_TORN=$(sb_count_torn_lines "$AUDIT")
  [ "${AUDIT_TORN:-0}" -gt 0 ] && sb_log_error "sar-summary.sh" "audit-log: skipped $AUDIT_TORN torn line(s) for session=$SESSION_ID" 0
fi

[ -z "$counts" ] && exit 0

allow=0; ask=0; deny=0; flag=0; rewrite=0
while IFS='=' read -r v n; do
  [ -z "$v" ] && continue
  case "$v" in
    allow)   allow=$n ;;
    ask)     ask=$n ;;
    deny)    deny=$n ;;
    flag)    flag=$n ;;
    rewrite) rewrite=$n ;;
  esac
done <<<"$counts"

total=$((allow + ask + deny + flag + rewrite))
[ "$total" -eq 0 ] && exit 0

# SAR: hard violations pull the score down; flags are warnings only.
hard=$((ask + deny))
sar=$(awk -v t="$total" -v v="$hard" 'BEGIN { printf "%.2f", 1 - v/t }')

# Top 3 most-tripped rules for this session (informational tail). D159: same
# torn-line-tolerant `-R … fromjson?` form as the counts pass above.
top=$(jq -Rr --arg sid "$SESSION_ID" '
  fromjson? | select(type == "object" and .session_id == $sid) | .rule // "anonymous"
' "$AUDIT" 2>/dev/null | sort | uniq -c | sort -rn | head -3 \
  | awk '{ count=$1; $1=""; sub(/^ /,""); printf "  - %s x%s\n", $0, count }')

SID_SHORT="${SESSION_ID:0:8}"
BANNER=$(printf '[second-brain SAR] session=%s\n  verdicts: allow=%d ask=%d deny=%d flag=%d rewrite=%d (total %d)\n  sar=%s  (1.00 = clean, 0.00 = every-call-blocked)\n%s  Detail: jq '\''select(.session_id=="%s")'\'' %s' \
  "$SID_SHORT" \
  "$allow" "$ask" "$deny" "$flag" "$rewrite" "$total" \
  "$sar" \
  "${top:+$top$'\n'}" \
  "$SESSION_ID" "$AUDIT")

jq -nc --arg m "$BANNER" '{ systemMessage: $m }' 2>/dev/null || true

exit 0
