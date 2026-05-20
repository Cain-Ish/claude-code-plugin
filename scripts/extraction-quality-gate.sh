#!/bin/bash
# extraction-quality-gate.sh — Layer 4 (Karpathy "compile-on-ingest with validator")
# Reads DELTA_JSON on stdin, filters low-quality entries, writes filtered JSON to stdout.
# Rejections logged to ~/.second-brain/.rejected-extractions.jsonl
#
# Modes:
#   default (rules-only, free, ~0ms)
#   SB_QUALITY_GATE_LLM=on → also run Haiku validator on borderline entries
#
# Strictness (rules-only mode):
#   SB_QUALITY_GATE_STRICTNESS=conservative (default) — reject obvious noise (~10%)
#   SB_QUALITY_GATE_STRICTNESS=aggressive — also reject low-signal generic entries (~30%)
#
# Kill switch: SB_QUALITY_GATE=off → passthrough unchanged.
set -u

# Kill switch
if [ "${SB_QUALITY_GATE:-on}" = "off" ]; then
  cat
  exit 0
fi

BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
LOG_FILE="$BRAIN_DIR/.rejected-extractions.jsonl"
STRICTNESS="${SB_QUALITY_GATE_STRICTNESS:-conservative}"
LLM_MODE="${SB_QUALITY_GATE_LLM:-off}"
HAIKU_MODEL="${SB_QUALITY_GATE_MODEL:-claude-haiku-4-5-20251001}"

mkdir -p "$BRAIN_DIR" 2>/dev/null

INPUT=$(cat 2>/dev/null || true)
if [ -z "$INPUT" ]; then exit 0; fi

# Rule predicates — return 0 if entry should be REJECTED (i.e. it's noise).
# $1 = entry text, $2 = category key (recent_decisions | open_blockers |
# cross_refs). Categories carry different shape: decisions/blockers are full
# sentences; cross_refs are wiki slugs (e.g. "router-daemon", "new-page") and
# must NOT be subjected to sentence-shaped checks (word-count, platitude
# regex) — those would silently drop every legitimate short slug, which is
# the bug that caused `[[new-page]]` to never reach PROJECT.md and broke
# tests/test-stop-extract.sh test 1.
is_noise() {
  local entry="$1"
  local key="${2:-}"
  # Empty / whitespace-only — always noise regardless of category.
  [ -z "$(printf '%s' "$entry" | tr -d '[:space:]')" ] && return 0

  if [ "$key" = "cross_refs" ]; then
    # Slug shape: lowercase letters, digits, hyphens. 2–80 chars. No spaces.
    # Reject obvious malformations (whitespace inside, leading/trailing dash,
    # double dashes) so the wiki stays clean — but ACCEPT short slugs.
    printf '%s' "$entry" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' || return 0
    local len; len=${#entry}
    [ "$len" -lt 2 ] && return 0
    [ "$len" -gt 80 ] && return 0
    return 1
  fi

  # --- Sentence-shaped categories (decisions, blockers) ---
  # Plugin-internal placeholder text the stop-extract fallback inserts
  printf '%s' "$entry" | grep -qiE '^files this session:' && return 0
  # Generic platitudes (case-insensitive)
  printf '%s' "$entry" | grep -qiE '^(good code|quality matters|tests are important|write clean code|be careful|follow best practices)\.?$' && return 0
  # Single-word entries are too vague
  local wc; wc=$(printf '%s' "$entry" | wc -w | tr -d ' ')
  [ "$wc" -lt 3 ] && return 0
  if [ "$STRICTNESS" = "aggressive" ]; then
    # Aggressive: reject entries that don't reference a specific noun/file/identifier
    printf '%s' "$entry" | grep -qiE '\b(it|this|that|they|them|we|us|stuff|things)\b' && {
      printf '%s' "$entry" | grep -qE '[A-Z][a-z]+[A-Z]|\.\w+|/|::|@' || return 0
    }
  fi
  return 1
}

# Optional Haiku gate — called only if SB_QUALITY_GATE_LLM=on AND entry survived rules.
# Returns 0 = accept, 1 = reject.
haiku_check() {
  local entry="$1"
  local kind="$2"
  local prompt="You are a noise filter for a developer's second-brain knowledge base. Given a candidate $kind, respond with ONLY 'ACCEPT' or 'REJECT'. Reject if the entry is generic platitude, restates an obvious truth, refers to a transient session detail (e.g. 'files touched this session'), or has no durable value. Accept if it's a real decision, blocker, pattern, or insight.

Strictness: $STRICTNESS

Candidate ($kind): $entry"
  local result
  # `--bare` requires ANTHROPIC_API_KEY (OAuth tokens ignored). Use only when set.
  if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ "${SB_USE_BARE:-0}" = "1" ]; then
    result=$(printf '%s' "$prompt" | timeout 5 claude -p --bare --model "$HAIKU_MODEL" 2>/dev/null | tr -d '\r' | head -1 || true)
  else
    result=$(printf '%s' "$prompt" | timeout 5 claude -p --model "$HAIKU_MODEL" 2>/dev/null | tr -d '\r' | head -1 || true)
  fi
  case "$result" in
    *ACCEPT*) return 0 ;;
    *) return 1 ;;
  esac
}

# Process an array under a given key; filter, log rejections, return new array.
filter_array() {
  local key="$1"
  local arr_json
  arr_json=$(printf '%s' "$INPUT" | jq -cr ".${key} // []")
  local len
  len=$(printf '%s' "$arr_json" | jq 'length')
  [ -z "$len" ] || [ "$len" = "0" ] && { echo '[]'; return; }

  local kept='[]'
  local idx=0
  while [ "$idx" -lt "$len" ]; do
    local entry
    entry=$(printf '%s' "$arr_json" | jq -r ".[$idx]")
    idx=$((idx + 1))
    if is_noise "$entry" "$key"; then
      jq -nc --arg k "$key" --arg e "$entry" --arg r "rules:noise" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{key:$k, entry:$e, reason:$r, at:$t}' >> "$LOG_FILE"
      continue
    fi
    if [ "$LLM_MODE" = "on" ]; then
      if ! haiku_check "$entry" "$key"; then
        jq -nc --arg k "$key" --arg e "$entry" --arg r "llm:rejected" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{key:$k, entry:$e, reason:$r, at:$t}' >> "$LOG_FILE"
        continue
      fi
    fi
    kept=$(printf '%s' "$kept" | jq -c --arg e "$entry" '. + [$e]')
  done
  printf '%s' "$kept"
}

DECISIONS=$(filter_array "recent_decisions")
BLOCKERS=$(filter_array "open_blockers")
CROSS_REFS=$(filter_array "cross_refs")

# Rebuild the JSON with filtered arrays, keep all other fields untouched.
printf '%s' "$INPUT" | jq -c \
  --argjson d "$DECISIONS" \
  --argjson b "$BLOCKERS" \
  --argjson c "$CROSS_REFS" \
  '.recent_decisions = $d | .open_blockers = $b | .cross_refs = $c'
