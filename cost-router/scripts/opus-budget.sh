#!/bin/bash
# cost-router/scripts/opus-budget.sh
# Contract A: shared premium-spend ledger (cross-plugin file-format contract).
#
# Records spend for PREMIUM models — anything above the DO/SCOUT tiers
# (Opus today; Fable and future top-tier models tomorrow). INFORMATIONAL
# ONLY: there is no cap and no enforcement — the ledger exists
# so banners/summaries can report what premium dispatches cost today. The
# tier→model assignments change over releases, so nothing here hardcodes a
# limit against a model name.
#
# Ledger path: ${COST_ROUTER_LEDGER:-${SB_BRAIN_DIR:-$HOME/.second-brain}/opus-budget.json}
# (filename + key names are historical — kept for cross-plugin compatibility)
# Schema: {"date":"YYYY-MM-DD","opus_cost_usd":<float>,"opus_calls":<int>}
#
# Daily reset: if stored "date" != today (UTC), treat spent as 0 and reset file.
#
# Shell functions:
#   ob_path        — print the ledger path
#   ob_today_spent — echo the float spent today (0 if no ledger / stale date)
#   ob_record <cost_usd> — add to today's total + increment opus_calls
#
# CLI: opus-budget.sh spent | record <cost_usd>
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
    # Stale — report 0 WITHOUT touching the file: `spent` is called by the
    # SessionStart banner, and a read path must never mutate state. The
    # reset happens lazily inside ob_record.
    printf '0'
    return
  fi

  stored_cost=$(jq -r '.opus_cost_usd // 0' "$path" 2>/dev/null || true)
  printf '%s' "${stored_cost:-0}"
}

ob_record() {
  local cost_usd="$1"
  local path today current_cost current_calls new_cost new_calls stored_date tmp

  path=$(ob_path)
  today=$(date -u +%F)

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
    '{"date":$date,"opus_cost_usd":$cost,"opus_calls":$calls}' \
    > "$tmp" && mv "$tmp" "$path"
}

# ── internal: reset ledger to today with zero spend ─────────────────────────

_ob_reset() {
  local path="$1"
  local today dir tmp
  today=$(date -u +%F)
  dir=$(dirname "$path")
  [ -d "$dir" ] || mkdir -p "$dir"
  tmp="${path}.tmp.$$"
  jq -cn \
    --arg date "$today" \
    '{"date":$date,"opus_cost_usd":0,"opus_calls":0}' \
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
      echo "'over' was removed in 0.24.45 — the premium-spend ledger is informational, there is no cap" >&2
      exit 1
      ;;
    *)
      echo "usage: opus-budget.sh spent | record <cost_usd>" >&2
      exit 1
      ;;
  esac
fi
