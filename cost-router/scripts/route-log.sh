#!/bin/bash
# cost-router/scripts/route-log.sh
# Contract B: routing events log (cross-plugin file-format contract).
#
# Events path: ${COST_ROUTER_EVENTS:-${SB_BRAIN_DIR:-$HOME/.second-brain}/cost-router-events.jsonl}
#
# Each call appends ONE compact JSON line:
# {"ts":<ISO8601>,"task":..,"tier":..,"models":[...],"units":<int>,"escalated":<bool>,"outcome":..,"committed":<bool>}
#
# Shell function:
#   rl_emit <task> <tier> <models-csv> <units> <escalated> <outcome> <committed>
#
# CLI:
#   route-log.sh emit <task> <tier> <models-csv> <units> <escalated> <outcome> <committed>
#
# Best-effort: never exits nonzero / never breaks callers even on write errors.
#
# Bash 3.2 / BSD-safe: no date -d, no GNU-only extensions, no assoc arrays.

set -u

# ── helpers ─────────────────────────────────────────────────────────────────

rl_path() {
  printf '%s' "${COST_ROUTER_EVENTS:-${SB_BRAIN_DIR:-$HOME/.second-brain}/cost-router-events.jsonl}"
}

# rl_emit <task> <tier> <models-csv> <units> <escalated> <outcome> <committed>
rl_emit() {
  local task="$1"
  local tier="$2"
  local models_csv="$3"
  local units="$4"
  local escalated_raw="$5"
  local outcome="$6"
  local committed_raw="$7"

  local path ts dir

  # Normalise booleans (accept true/false/0/1)
  local escalated committed
  if [ "$escalated_raw" = "true" ] || [ "$escalated_raw" = "1" ]; then
    escalated="true"
  else
    escalated="false"
  fi
  if [ "$committed_raw" = "true" ] || [ "$committed_raw" = "1" ]; then
    committed="true"
  else
    committed="false"
  fi

  ts=$(date -u +%FT%TZ)
  path=$(rl_path)
  dir=$(dirname "$path")

  # Create parent dir (best-effort, no error on failure)
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || true

  # Split models CSV into a JSON array via jq.
  # An EMPTY csv must short-circuit to [] — `printf '' | jq -R`
  # exits 0 with NO output, so the `||` fallback never fired, `--argjson` got ""
  # and the whole emit was silently dropped (100% of classifier events lost).
  local models_json
  if [ -z "$models_csv" ]; then
    models_json='[]'
  else
    models_json=$(printf '%s' "$models_csv" \
      | jq -Rc 'split(",")' 2>/dev/null) || models_json='[]'
    [ -n "$models_json" ] || models_json='[]'
  fi

  # Bounded growth (deep-review): the always-log classifier appends one line per
  # prompt; the only consumer reads tail -n 500. Rotate past 512KB, keep 1000.
  if [ -f "$path" ] && [ "$(wc -c < "$path" 2>/dev/null | tr -d ' ')" -gt 524288 ]; then
    tail -n 1000 "$path" > "${path}.tmp.$$" 2>/dev/null \
      && mv "${path}.tmp.$$" "$path" 2>/dev/null || rm -f "${path}.tmp.$$" 2>/dev/null
  fi

  # Build the JSON line and append atomically
  jq -cn \
    --arg ts "$ts" \
    --arg task "$task" \
    --arg tier "$tier" \
    --argjson models "$models_json" \
    --argjson units "$units" \
    --argjson escalated "$escalated" \
    --arg outcome "$outcome" \
    --argjson committed "$committed" \
    '{ts:$ts,task:$task,tier:$tier,models:$models,units:$units,escalated:$escalated,outcome:$outcome,committed:$committed}' \
    >> "$path" 2>/dev/null || true
}

# ── CLI entrypoint ───────────────────────────────────────────────────────────

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-}" in
    emit)
      if [ "${#}" -lt 8 ]; then
        echo "usage: route-log.sh emit <task> <tier> <models-csv> <units> <escalated> <outcome> <committed>" >&2
        exit 0
      fi
      rl_emit "$2" "$3" "$4" "$5" "$6" "$7" "$8"
      ;;
    path)
      rl_path
      printf '\n'
      ;;
    *)
      echo "usage: route-log.sh emit <task> <tier> <models-csv> <units> <escalated> <outcome> <committed>" >&2
      exit 0
      ;;
  esac
fi
