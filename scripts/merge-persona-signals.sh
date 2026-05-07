#!/bin/bash
# Merge persona signals from LLM extraction into the accumulation file.
# Input: JSON array of persona_signals on stdin
# Storage: ~/.second-brain/persona-signals.jsonl
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SIGNALS_FILE="$BRAIN_DIR/persona-signals.jsonl"
mkdir -p "$BRAIN_DIR"
touch "$SIGNALS_FILE"

PRUNE_DAYS=90
TODAY=$(date -u +%Y-%m-%d)
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"

NEW_SIGNALS=$(cat)
if ! echo "$NEW_SIGNALS" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
  exit 0
fi

# Load existing signals as JSON array
EXISTING=$(jq -sc '.' "$SIGNALS_FILE" 2>/dev/null || echo '[]')

# Merge new signals into existing using jq
MERGED=$(jq -nc \
  --argjson existing "$EXISTING" \
  --argjson new_sigs "$NEW_SIGNALS" \
  --arg today "$TODAY" \
  --arg session "$SESSION_ID" \
  '
  # For each new signal, either merge into existing or append
  reduce ($new_sigs[]) as $sig ($existing;
    ($sig.signal | ascii_downcase | .[0:40]) as $norm |
    # Find matching index
    (to_entries | map(select(
      (.value.signal | ascii_downcase | .[0:40]) == $norm
    )) | .[0].key) as $idx |
    if $idx != null then
      # Update existing: increment count, append evidence, update last_seen
      .[$idx].count += 1 |
      .[$idx].last_seen = $today |
      .[$idx].evidence += [{session: $session, date: $today, text: $sig.evidence}]
    else
      # New signal
      . + [{
        category: $sig.category,
        signal: $sig.signal,
        evidence: [{session: $session, date: $today, text: $sig.evidence}],
        confidence: $sig.confidence,
        first_seen: $today,
        last_seen: $today,
        count: 1,
        graduated: false
      }]
    end
  )
  ')

# Prune stale signals (>90 days, not graduated)
CUTOFF=$(date -u -v-${PRUNE_DAYS}d +%Y-%m-%d 2>/dev/null \
  || date -u -d "${PRUNE_DAYS} days ago" +%Y-%m-%d 2>/dev/null \
  || echo "1970-01-01")

MERGED=$(echo "$MERGED" | jq -c \
  --arg cutoff "$CUTOFF" \
  '[.[] | select(.graduated == true or .last_seen >= $cutoff)]')

# --- Auto-graduate high-confidence signals with 3+ observations ---
GRAD_CANDIDATES=$(echo "$MERGED" | jq -c '[.[] | select(.count >= 3 and .confidence == "high" and .graduated == false)]')
GRAD_COUNT=$(echo "$GRAD_CANDIDATES" | jq 'length')

if [ "$GRAD_COUNT" -gt 0 ]; then
  GRADUATED_INDICES=""
  for i in $(seq 0 $((GRAD_COUNT - 1))); do
    SIG_TEXT=$(echo "$GRAD_CANDIDATES" | jq -r ".[$i].signal")
    if sb_pin_to_user "$SIG_TEXT"; then
      GRADUATED_INDICES="$GRADUATED_INDICES $i"
    fi
  done

  if [ -n "$GRADUATED_INDICES" ]; then
    for i in $GRADUATED_INDICES; do
      SIG_NORM=$(echo "$GRAD_CANDIDATES" | jq -r ".[$i].signal | ascii_downcase | .[0:40]")
      MERGED=$(echo "$MERGED" | jq -c --arg norm "$SIG_NORM" '
        [.[] | if (.signal | ascii_downcase | .[0:40]) == $norm then .graduated = true else . end]
      ')
    done
  fi
fi

# Write back as JSONL (one JSON object per line)
echo "$MERGED" | jq -c '.[]' > "$SIGNALS_FILE"
