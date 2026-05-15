#!/bin/bash
# Merge persona signals from LLM extraction into the accumulation file.
# Input: JSON array of persona_signals on stdin
# Storage: ~/.second-brain/persona-signals.jsonl
set -u
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
  # For each new signal, either merge into existing or append.
  # Word-overlap dedup uses set-min as the denominator (intersection over the
  # smaller set size, gated by a 3-word floor on both sides). Set-max was too
  # strict: long detailed signals (~20+ unique content words) rarely re-occurred
  # at 60 percent overlap, so identical underlying behaviors stayed as separate
  # count=1 entries forever. Set-min asks whether most of the smaller side
  # words are shared with the larger side — better at catching paraphrases of
  # the same pattern, while the min-word-count guard prevents trivial 1-2 word
  # matches from collapsing distinct signals.
  # NOTE: this block is inside a bash single-quoted jq program. Apostrophes in
  # comments will close the quote — keep this prose apostrophe-free.
  def content_words: ascii_downcase | [scan("[a-z]{3,}")] | unique;
  def word_overlap($a; $b):
    ($a | length) as $la | ($b | length) as $lb |
    if ($la < 3) or ($lb < 3) then 0
    else
      ([$la, $lb] | min) as $denom |
      ([$a[] | select(. as $w | $b | index($w))] | length) * 100 / $denom
    end;

  reduce ($new_sigs[]) as $sig ($existing;
    ($sig.signal | content_words) as $new_words |
    (to_entries | map(
      (.value.signal | content_words) as $old_words |
      {key: .key, pct: word_overlap($new_words; $old_words)}
    ) | map(select(.pct >= 50)) | sort_by(-.pct) | .[0].key) as $idx |
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

# --- Auto-graduate high-confidence signals with 2+ observations ---
# Threshold was count>=3, but field data showed cross-session paraphrase
# divergence + the old strict dedup kept nearly everything at count=1. After
# loosening the dedup above, count>=2 is the natural floor: a behavior seen
# in two distinct sessions with high LLM confidence is genuine signal.
GRAD_CANDIDATES=$(echo "$MERGED" | jq -c '[.[] | select(.count >= 2 and .confidence == "high" and .graduated == false)]')
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
      SIG_TEXT_LOWER=$(echo "$GRAD_CANDIDATES" | jq -r ".[$i].signal")
      MERGED=$(echo "$MERGED" | jq -c --arg sig "$SIG_TEXT_LOWER" '
        # Mirror the merge-step dedup: set-min denominator, 50% threshold,
        # 3-word floor on both sides. Without this mirror, a graduated signal
        # could leave its near-duplicates ungraduated and they would re-fire.
        def content_words: ascii_downcase | [scan("[a-z]{3,}")] | unique;
        ($sig | content_words) as $target |
        [.[] | (.signal | content_words) as $w |
          if (($target | length) < 3) or (($w | length) < 3) then .
          else
            ([($target | length), ($w | length)] | min) as $denom |
            if (([$target[] | select(. as $t | $w | index($t))] | length) * 100 / $denom) >= 50
            then .graduated = true else . end
          end
        ]
      ')
    done
  fi
fi

# Cap at 100 entries (keep highest-count signals) and trim evidence arrays
MERGED=$(echo "$MERGED" | jq -c '
  [.[] | .evidence = (.evidence | if length > 5 then .[-5:] else . end)]
  | sort_by(-.count)
  | .[0:100]
')

# Write back as JSONL (one JSON object per line)
echo "$MERGED" | jq -c '.[]' > "$SIGNALS_FILE"
