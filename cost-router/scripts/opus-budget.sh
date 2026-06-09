#!/bin/bash
# cost-router/scripts/opus-budget.sh
# Contract A: shared Opus-budget ledger (cross-plugin file-format contract).
#
# Ledger path: ${COST_ROUTER_LEDGER:-${SB_BRAIN_DIR:-$HOME/.second-brain}/opus-budget.json}
# Schema: {"date":"YYYY-MM-DD","opus_cost_usd":<float>,"opus_calls":<int>,"cap_usd":<float>}
#
# Daily reset: if stored "date" != today (UTC), treat spent as 0 and reset file.
# Cap: from COST_ROUTER_OPUS_CAP_USD, default 5.0.
#
# Shell functions:
#   ob_path        — print the ledger path
#   ob_today_spent — echo the float spent today (0 if no ledger / stale date)
#   ob_record <cost_usd> — add to today's total + increment opus_calls
#   ob_over_budget — exit 0 if spent >= cap, else exit 1
#
# CLI: opus-budget.sh spent | record <cost_usd> | over
#
# Bash 3.2 / BSD-safe: no date -d, no GNU-only regex, no assoc arrays.
# Float math via awk. Atomic writes via temp+mv.

set -u

# ── helpers ─────────────────────────────────────────────────────────────────

ob_path() {
  printf '%s' "${COST_ROUTER_LEDGER:-${SB_BRAIN_DIR:-$HOME/.second-brain}/opus-budget.json}"
}

ob_today_spent() {
  local path today stored_date stored_cost
  path=$(ob_path)
  today=$(date -u +%F)

  if [ ! -f "$path" ]; then
    printf '0'
    return
  fi

  stored_date=$(jq -r '.date // ""' "$path" 2>/dev/null || true)
  if [ "$stored_date" != "$today" ]; then
    # Stale — reset the file and return 0
    _ob_reset "$path"
    printf '0'
    return
  fi

  stored_cost=$(jq -r '.opus_cost_usd // 0' "$path" 2>/dev/null || true)
  printf '%s' "${stored_cost:-0}"
}

ob_record() {
  local cost_usd="$1"
  local path today current_cost current_calls cap new_cost new_calls stored_date tmp

  path=$(ob_path)
  today=$(date -u +%F)
  cap="${COST_ROUTER_OPUS_CAP_USD:-5.0}"

  # Ensure parent dir exists
  local dir
  dir=$(dirname "$path")
  [ -d "$dir" ] || mkdir -p "$dir"

  if [ -f "$path" ]; then
    stored_date=$(jq -r '.date // ""' "$path" 2>/dev/null || true)
    if [ "$stored_date" != "$today" ]; then
      # Stale: start fresh
      current_cost=0
      current_calls=0
    else
      current_cost=$(jq -r '.opus_cost_usd // 0' "$path" 2>/dev/null || true)
      current_calls=$(jq -r '.opus_calls // 0' "$path" 2>/dev/null || true)
    fi
  else
    current_cost=0
    current_calls=0
  fi

  new_cost=$(awk -v c="$current_cost" -v add="$cost_usd" 'BEGIN { printf "%.6f", c + add }')
  new_calls=$(awk -v n="$current_calls" 'BEGIN { printf "%d", n + 1 }')

  tmp="${path}.tmp.$$"
  jq -cn \
    --arg date "$today" \
    --argjson cost "$new_cost" \
    --argjson calls "$new_calls" \
    --argjson cap "$cap" \
    '{"date":$date,"opus_cost_usd":$cost,"opus_calls":$calls,"cap_usd":$cap}' \
    > "$tmp" && mv "$tmp" "$path"
}

ob_over_budget() {
  local spent cap result
  spent=$(ob_today_spent)
  cap="${COST_ROUTER_OPUS_CAP_USD:-5.0}"
  result=$(awk -v s="$spent" -v c="$cap" 'BEGIN { print (s + 0 >= c + 0) ? "1" : "0" }')
  [ "$result" = "1" ]
}

# ── internal: reset ledger to today with zero spend ─────────────────────────

_ob_reset() {
  local path="$1"
  local today cap dir tmp
  today=$(date -u +%F)
  cap="${COST_ROUTER_OPUS_CAP_USD:-5.0}"
  dir=$(dirname "$path")
  [ -d "$dir" ] || mkdir -p "$dir"
  tmp="${path}.tmp.$$"
  jq -cn \
    --arg date "$today" \
    --argjson cap "$cap" \
    '{"date":$date,"opus_cost_usd":0,"opus_calls":0,"cap_usd":$cap}' \
    > "$tmp" && mv "$tmp" "$path"
}

# ── CLI entrypoint ───────────────────────────────────────────────────────────

# Only run as CLI when executed directly (not sourced)
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-}" in
    spent)
      ob_today_spent
      printf '\n'
      ;;
    record)
      if [ -z "${2:-}" ]; then
        echo "usage: opus-budget.sh record <cost_usd>" >&2
        exit 1
      fi
      ob_record "$2"
      ;;
    over)
      ob_over_budget
      ;;
    *)
      echo "usage: opus-budget.sh spent | record <cost_usd> | over" >&2
      exit 1
      ;;
  esac
fi
