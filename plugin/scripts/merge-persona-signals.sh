#!/bin/bash
# Merge persona signals from LLM extraction into the accumulation file.
# Input on stdin: either the legacy bare JSON array of persona_signals, or an
# object {persona_signals: [...], rule_candidates: [...]} — the object form
# lets the Stop-hook route both extractor outputs through this one consumer.
# Storage: ~/.second-brain/persona-signals.jsonl (signals),
#          ~/.second-brain/persona-rules.pending.json (rule candidates),
#          ~/.second-brain/persona-rules.json .learned[] (auto-armed warn rules)
set -u
source "$(dirname "$0")/lib.sh"

SIGNALS_FILE="$BRAIN_DIR/persona-signals.jsonl"
mkdir -p "$BRAIN_DIR"
touch "$SIGNALS_FILE"

PRUNE_DAYS=90
TODAY=$(date -u +%Y-%m-%d)
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"

RAW_INPUT=$(cat)
if printf '%s' "$RAW_INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  NEW_SIGNALS=$(printf '%s' "$RAW_INPUT" | jq -c '.persona_signals // []')
  NEW_CANDIDATES=$(printf '%s' "$RAW_INPUT" | jq -c '.rule_candidates // []')
else
  NEW_SIGNALS="$RAW_INPUT"
  NEW_CANDIDATES='[]'
fi
if ! echo "$NEW_SIGNALS" | jq -e 'type == "array"' >/dev/null 2>&1; then
  NEW_SIGNALS='[]'
fi
if ! echo "$NEW_CANDIDATES" | jq -e 'type == "array"' >/dev/null 2>&1; then
  NEW_CANDIDATES='[]'
fi
if echo "$NEW_SIGNALS" | jq -e 'length == 0' >/dev/null 2>&1 \
  && echo "$NEW_CANDIDATES" | jq -e 'length == 0' >/dev/null 2>&1; then
  exit 0
fi

# Load existing signals as JSON array. D139: `jq -s '.'` aborts the WHOLE slurp on
# one unparseable line (a partial append, a crash mid-write, a concurrent-write
# tear — see D120) and the `|| echo '[]'` then treats every accumulated signal as
# absent, so the merge below rebuilds the file from ONLY the new signals — months
# of graduation counts silently wiped. `-R … fromjson?` skips just the bad line;
# a torn line is logged once (not per row) via sb_log_error, never per skipped row.
TORN_SIGNALS=$(sb_count_torn_lines "$SIGNALS_FILE")
[ "${TORN_SIGNALS:-0}" -gt 0 ] && sb_log_error "merge-persona-signals.sh" "persona-signals.jsonl: skipped $TORN_SIGNALS torn line(s)" 0
EXISTING=$(jq -Rnc '[inputs | fromjson? | select(type=="object")]' "$SIGNALS_FILE" 2>/dev/null)
[ -n "$EXISTING" ] || EXISTING='[]'

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

# --- Numeric confidence (score) + code-enforced weekly decay ---
# score is DERIVED fresh every run from count + last_seen, so repeated runs
# are idempotent (no compounding): occurrence base (1-2 obs -> 0.3, 3-5 ->
# 0.5, 6-10 -> 0.7, 11+ -> 0.85) minus 0.02 per FULL week since last_seen,
# clamped to a 0.1 floor, rounded to 2 decimals. The string `confidence`
# field stays untouched — graduation below and the Stop-hook pin-candidate
# routing still read it. Date math is pure jq (fromdateiso8601 + now), so no
# GNU/BSD `date -d`/-v divergence; an unparseable last_seen decays as zero
# weeks rather than nuking the record. Ungraduated signals decayed below 0.2
# are PRUNED (logged loud below); graduated ones are kept — their record is
# the dedup ledger that stops a paraphrase from re-graduating into a
# duplicate USER.md pin.
SCORED=$(echo "$MERGED" | jq -c '
  map(. + {score:
    # The WHOLE value expression is parenthesized: an object value that is a bare
    # pipeline (`{k: a | b / c}`) parses on newer jq but is a SYNTAX ERROR on the
    # older jq CI ships — the object-value grammar there needs one enclosing group.
    (((if .count >= 11 then 0.85
      elif .count >= 6 then 0.7
      elif .count >= 3 then 0.5
      else 0.3 end)
     - 0.02 * ((((now - ((((.last_seen // "") + "T00:00:00Z") | fromdateiso8601?) // now)) / 604800) | floor)
               | if . < 0 then 0 else . end))
    | (if . < 0.1 then 0.1 else . end)
    | ((. * 100 | round) / 100))
  })
  | {keep:   map(select(.graduated == true or .score >= 0.2)),
     pruned: map(select(.graduated != true and .score < 0.2) | .signal)}
')
PRUNED_N=$(echo "$SCORED" | jq -r '.pruned | length' | tr -d '\r')
case "$PRUNED_N" in ''|*[!0-9]*) PRUNED_N=0 ;; esac
if [ "$PRUNED_N" -gt 0 ]; then
  PRUNED_LIST=$(echo "$SCORED" | jq -r '.pruned | join("; ")' | tr -d '\r' | head -c 400)
  sb_log_error "merge-persona-signals.sh" "decay-pruned n=$PRUNED_N signals=$PRUNED_LIST" 0
fi
MERGED=$(echo "$SCORED" | jq -c '.keep')

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
    SIG_TEXT=$(echo "$GRAD_CANDIDATES" | jq -r ".[$i].signal" | tr -d '\r')
    if sb_pin_to_user "$SIG_TEXT"; then
      GRADUATED_INDICES="$GRADUATED_INDICES $i"
    fi
  done

  if [ -n "$GRADUATED_INDICES" ]; then
    for i in $GRADUATED_INDICES; do
      SIG_TEXT_LOWER=$(echo "$GRAD_CANDIDATES" | jq -r ".[$i].signal" | tr -d '\r')
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

# Write back as JSONL (one JSON object per line). Guard against jq-internal
# failures emptying $MERGED — without this, a malformed evidence string in
# NEW_SIGNALS that breaks the reduce above would silently truncate
# SIGNALS_FILE to zero bytes and wipe every accumulated persona signal.
# Atomic via tempfile so a partial write never replaces a valid file.
if [ -n "$MERGED" ] && echo "$MERGED" | jq -e 'type == "array"' >/dev/null 2>&1; then
  TMP_SIG="$SIGNALS_FILE.tmp.$$"
  if echo "$MERGED" | jq -c '.[]' > "$TMP_SIG" 2>/dev/null; then
    mv "$TMP_SIG" "$SIGNALS_FILE"
  else
    rm -f "$TMP_SIG" 2>/dev/null
  fi
fi

# --- Rule-candidate accumulation → auto-arm as learned WARN rules ---
# Candidates come from the extractor only when the transcript showed an
# explicit user correction, a revert of an assistant edit, or the same
# mistake twice. Each is accumulated in persona-rules.pending.json keyed by
# a stable cksum of event+pattern; at 3 sightings it auto-arms into the USER
# persona-rules.json under .learned[] with action "warn" — advisory-only, so
# unattended arming can never block or prompt. deny/rewrite arming stays a
# human decision, and the shipped default rules file is never written.
if echo "$NEW_CANDIDATES" | jq -e 'length > 0' >/dev/null 2>&1; then
  PENDING_FILE="$BRAIN_DIR/persona-rules.pending.json"
  [ -s "$PENDING_FILE" ] || echo '{}' > "$PENDING_FILE"
  USER_RULES="$BRAIN_DIR/persona-rules.json"
  DEFAULT_RULES="$(dirname "$0")/persona-rules.default.json"

  # Pending entries share the signals' PRUNE_DAYS retention: a candidate not
  # re-sighted inside the window is stale evidence — without this the file
  # grows without bound and an ancient count=2 could arm off one fresh sighting.
  # One jq pass computes keep + pruned count; write-back is atomic tmp+mv.
  PEND_SPLIT=$(jq -c --arg cutoff "$CUTOFF" '
    {keep: with_entries(select((.value.last_seen // "1970-01-01") >= $cutoff)),
     pruned_n: ([.[] | select((.last_seen // "1970-01-01") < $cutoff)] | length)}
  ' "$PENDING_FILE" 2>/dev/null || echo '')
  if [ -n "$PEND_SPLIT" ]; then
    PEND_PRUNED=$(printf '%s' "$PEND_SPLIT" | jq -r '.pruned_n' | tr -d '\r')
    case "$PEND_PRUNED" in ''|*[!0-9]*) PEND_PRUNED=0 ;; esac
    if [ "$PEND_PRUNED" -gt 0 ]; then
      TMP_PEND="$PENDING_FILE.tmp.$$"
      if printf '%s' "$PEND_SPLIT" | jq -c '.keep' > "$TMP_PEND" 2>/dev/null; then
        mv "$TMP_PEND" "$PENDING_FILE"
        sb_log_error "merge-persona-signals.sh" "pending-pruned n=$PEND_PRUNED last_seen older than ${PRUNE_DAYS}d" 0
      else
        rm -f "$TMP_PEND" 2>/dev/null
        sb_log_error "merge-persona-signals.sh" "pending-prune-write-failed" 0
      fi
    fi
  fi

  # In-batch dedup (unique_by): three copies inside ONE extraction must count
  # once, or a single chatty session could arm a rule by itself. Shape gate:
  # only bash|file events (the only frames the guard evaluates — anything else
  # would accumulate permanently-inert entries), non-empty pattern + message,
  # action warn.
  # Candidates are TRANSCRIPT-DERIVED (untrusted): the message is truncated to
  # 200 chars (it becomes advisory context on every matching tool call — an
  # unbounded message is a stored-injection channel), and the pattern is
  # rejected when overly long (>120 — a regex is not safely truncatable) or
  # overly broad (nothing but regex metacharacters — ".*" would fire on every
  # call and turn one rule into a permanent high-frequency channel).
  CAND_LIST=$(echo "$NEW_CANDIDATES" | jq -c '
    map(select((type == "object")
      and ((.event // "") | IN("bash", "file"))
      and ((.pattern // "") != "")
      and ((.pattern | length) <= 120)
      and ((.pattern | test("^[.*+?^$()\\[\\]{}|\\\\ ]*$")) | not)
      and ((.message // "") != ""))
      | .message |= .[0:200])
    | unique_by((.event // "") + " " + (.pattern // ""))
    | .[]')

  while IFS= read -r cand; do
    [ -z "$cand" ] && continue
    ev=$(printf '%s' "$cand" | jq -r '.event' | tr -d '\r')
    pat=$(printf '%s' "$cand" | jq -r '.pattern' | tr -d '\r')
    msg=$(printf '%s' "$cand" | jq -r '.message' | tr -d '\r')
    # cksum (POSIX, present on MSYS/BSD/Linux) gives a stable content key that
    # is safe as a JSON object key regardless of what regex chars pattern holds.
    key="$ev-$(printf '%s\n%s\n' "$ev" "$pat" | cksum | tr -s ' \t' '-')"

    TMP_PEND="$PENDING_FILE.tmp.$$"
    if jq -c --arg k "$key" --arg ev "$ev" --arg pat "$pat" --arg msg "$msg" --arg today "$TODAY" '
      .[$k] = (if .[$k] then
          .[$k] | .count += 1 | .last_seen = $today | .message = $msg
        else
          {event: $ev, pattern: $pat, action: "warn", message: $msg,
           count: 1, first_seen: $today, last_seen: $today}
        end)
    ' "$PENDING_FILE" > "$TMP_PEND" 2>/dev/null; then
      mv "$TMP_PEND" "$PENDING_FILE"
    else
      rm -f "$TMP_PEND" 2>/dev/null
      sb_log_error "merge-persona-signals.sh" "pending-candidate-update-failed key=$key" 0
      continue
    fi

    CNT=$(jq -r --arg k "$key" '.[$k].count // 0' "$PENDING_FILE" | tr -d '\r')
    case "$CNT" in ''|*[!0-9]*) CNT=0 ;; esac
    if [ "$CNT" -ge 3 ]; then
      # Seed the USER rules file from the shipped defaults if absent FIRST:
      # the guard prefers the user file whenever it exists, so writing a
      # learned-only file would silently shadow every default rule. Seed via
      # tmp+mv — the guard reads this file mid-session and must never see a
      # half-copied one.
      if [ ! -s "$USER_RULES" ]; then
        TMP_SEED="$USER_RULES.tmp.$$"
        if [ -s "$DEFAULT_RULES" ]; then
          cp "$DEFAULT_RULES" "$TMP_SEED" && mv "$TMP_SEED" "$USER_RULES"
        else
          echo '{"rules":[]}' > "$TMP_SEED" && mv "$TMP_SEED" "$USER_RULES"
        fi
      fi
      # Idempotent: an already-armed event+pattern is never re-added.
      ALREADY=$(jq -r --arg ev "$ev" --arg pat "$pat" \
        '[.learned // [] | .[] | select(.event == $ev and .pattern == $pat)] | length' \
        "$USER_RULES" | tr -d '\r')
      case "$ALREADY" in ''|*[!0-9]*) ALREADY=0 ;; esac
      if [ "$ALREADY" -eq 0 ]; then
        TMP_RULES="$USER_RULES.tmp.$$"
        # .learned[] is capped at 50 (evict oldest): the guard walks the whole
        # array on EVERY tool call, so unbounded growth is a hot-path tax.
        if jq --arg ev "$ev" --arg pat "$pat" --arg msg "$msg" '
          .learned = ((.learned // []) + [{event: $ev, pattern: $pat, action: "warn", message: $msg}])
          | .learned |= (if length > 50 then .[length-50:] else . end)
        ' "$USER_RULES" > "$TMP_RULES" 2>/dev/null; then
          mv "$TMP_RULES" "$USER_RULES"
          sb_log_audit "merge-persona-signals.sh" "arm" "learned-warn-rule" "$ev:$pat" "$msg" "$SESSION_ID"
        else
          rm -f "$TMP_RULES" 2>/dev/null
          sb_log_error "merge-persona-signals.sh" "learned-rule-arm-failed event=$ev pattern=$pat" 0
        fi
      fi
    fi
  done <<< "$CAND_LIST"
fi

exit 0
