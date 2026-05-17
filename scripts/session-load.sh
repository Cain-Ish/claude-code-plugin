#!/bin/bash
# Hot-tier loader with byte-budget enforcement.
# Outputs USER.md + active PROJECT.md + persona signals + wiki enrichment,
# capped at BYTE_BUDGET to avoid overflowing Claude's context window.
# Priority: USER.md > PROJECT.md > persona signals > wiki enrichment.
source "$(dirname "$0")/lib.sh"

USER_FILE="$BRAIN_DIR/USER.md"
INDEX_FILE="$BRAIN_DIR/projects.jsonl"
PROJECTS_DIR="$BRAIN_DIR/projects"
BYTE_BUDGET=8000   # ~2000 tokens. Claude Code hard-caps hook output at 10K chars.

slug=$(basename "$PWD")
echo "$slug" > "$BRAIN_DIR/.active-session-slug"
project_file="$PROJECTS_DIR/$slug/PROJECT.md"

if [ ! -f "$project_file" ]; then
  mkdir -p "$(dirname "$project_file")"
  cat > "$project_file" <<TMPL
# PROJECT: $slug

## Goal
(auto-scaffolded — describe this project's goal)

## State

## Conventions

## Recent decisions

## Open blockers

## Cross-references

<!-- last_updated: $(date -u +%Y-%m-%dT%H:%M:%SZ) -->
<!-- last_queried_wiki: -->
TMPL
  if [ -f "$INDEX_FILE" ] && ! grep -q "\"slug\":\"$slug\"" "$INDEX_FILE" 2>/dev/null; then
    jq -nc --arg s "$slug" --arg n "$slug" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{slug:$s, name:$n, last_session_iso:$t, hot_byte_count:0}' >> "$INDEX_FILE"
  fi
fi

cp "$project_file" "$BRAIN_DIR/.session-baseline-$slug.md"

# --- Collect components with byte tracking ---
OUTPUT_FILE=$(mktemp)
USED=0

sb_append() {
  local text="$1" label="$2" max="${3:-0}"
  local size=${#text}
  [ "$size" -eq 0 ] && return 0
  if [ "$max" -gt 0 ] && [ "$size" -gt "$max" ]; then
    text=$(printf '%s' "$text" | head -c "$max")
    size=$max
  fi
  local projected=$((USED + size))
  if [ "$projected" -gt "$BYTE_BUDGET" ]; then
    sb_log_error "session-load.sh" "gate=byte-budget $label skipped (${size}B would exceed ${BYTE_BUDGET}B cap, used=${USED}B)" 0
    return 1
  fi
  printf '%s' "$text" >> "$OUTPUT_FILE"
  USED=$projected
  return 0
}

# Bump per-project session counter (used by cadence banner below).
sb_increment_session_count "$slug"

# 0a. Cadence + maintenance banners — surface SB system events that would
# otherwise require the user to remember to run /second-brain:dream or
# /second-brain:improve. Threshold-gated to avoid banner fatigue.
SESSION_COUNT=$(sb_get_session_count "$slug")
DREAM_THRESHOLD="${SB_DREAM_CADENCE:-15}"
if [ "$SESSION_COUNT" -ge "$DREAM_THRESHOLD" ]; then
  sb_append "$(printf '## ⓘ second-brain — dream consolidation suggested\n%s sessions since last dream (threshold: %s).\nRun: `/second-brain:dream --background` — mines transcripts for missed learnings, stages changes for review.\n\n' \
    "$SESSION_COUNT" "$DREAM_THRESHOLD")" "dream-cadence-banner" 300
fi
if sb_get_maintainer_needed "$slug"; then
  sb_append "$(printf '## ⓘ second-brain — knowledge-maintainer recommended\nWiki writes happened recently. Run the maintainer agent to rebuild cross-links, dedupe, and reindex.\nRun: `Use the second-brain:knowledge-maintainer agent to consolidate the latest wiki writes.`\n\n')" "maintainer-banner" 250
  sb_clear_maintainer_needed "$slug"
fi
PIN_COUNT=$(sb_count_pin_candidates "$slug")
if [ "$PIN_COUNT" -gt 0 ]; then
  sb_append "$(printf '## ⓘ second-brain — %s pin candidate(s) pending\nExtracted persona signals waiting in `~/.second-brain/projects/%s/.pin-candidates.jsonl`.\nRun: `Review pin candidates in second-brain and decide which to pin to USER.md.`\n\n' \
    "$PIN_COUNT" "$slug")" "pin-candidates-banner" 250
fi

# 0. Extractor health banner — surfaces silent LLM-extraction failures.
# Without this banner, broken `claude` CLI auth caused 113 consecutive stop-
# hook subprocess failures with zero user-visible signal — wiki/learnings
# stayed empty for days. Banner is HIGH priority so it lands first.
if [ -f "$SB_HEALTH_FILE" ] && command -v jq >/dev/null 2>&1; then
  H_STATUS=$(jq -r '.status // "unknown"' "$SB_HEALTH_FILE" 2>/dev/null)
  if [ "$H_STATUS" = "fail" ]; then
    H_BACKEND=$(jq -r '.backend // "unknown"' "$SB_HEALTH_FILE" 2>/dev/null)
    H_REASON=$(jq  -r '.reason  // ""'        "$SB_HEALTH_FILE" 2>/dev/null)
    H_AT=$(jq      -r '.checked_at // ""'     "$SB_HEALTH_FILE" 2>/dev/null)
    H_FAILS=$(sb_count_recent_extraction_failures)
    # Hint differs by failure mode. If user has neither API key nor OAuth,
    # full fix instructions; if they have OAuth but the `--bare` flag is
    # blocking auth, that's now auto-handled by lib.sh:sb_call_extractor.
    H_HINT="fix: run \`claude /login\` (OAuth) or \`export ANTHROPIC_API_KEY=sk-ant-...\` (API key); lib.sh picks the right backend automatically."
    HEALTH_BANNER=$(printf '## ⚠ second-brain extractor: FAILED\nbackend=%s checked=%s recent_failures=%s\nreason: %s\nimpact: Stop/PreCompact hooks not writing wiki learnings — session insights are lost on exit.\n%s\n\n' \
      "$H_BACKEND" "$H_AT" "$H_FAILS" "$H_REASON" "$H_HINT")
    sb_append "$HEALTH_BANNER" "extractor-health-banner" 600
  fi
fi

# 1. USER.md — always included
if [ -f "$USER_FILE" ]; then
  USER_CONTENT=$(cat "$USER_FILE")
  sb_append "$USER_CONTENT" "USER.md" 0
fi

# 2. Persona signals — capped at 600 bytes
PERSONA_FILE="$BRAIN_DIR/persona-signals.jsonl"
if [ -f "$PERSONA_FILE" ] && [ -s "$PERSONA_FILE" ] && command -v jq >/dev/null 2>&1; then
  THIRTY_DAYS_AGO=$(date -u -v-30d +%Y-%m-%d 2>/dev/null \
    || date -u -d "30 days ago" +%Y-%m-%d 2>/dev/null \
    || echo "1970-01-01")

  SIGNALS=$(jq -rs --arg cutoff "$THIRTY_DAYS_AGO" '
    [.[] | select(
      .last_seen >= $cutoff and
      .graduated == false and
      .count >= 2
    )]
    | sort_by(-.count)
    | .[0:5]
    | .[] | "- [\(.category)] \(.signal) (seen \(.count)x)"
  ' "$PERSONA_FILE" 2>/dev/null)

  if [ -n "$SIGNALS" ]; then
    PERSONA_BLOCK=$(printf '\n## Observed patterns (from session history, not yet graduated to USER.md)\n%s\n' "$SIGNALS")
    sb_append "$PERSONA_BLOCK" "persona-signals" 600
  fi
fi

# 3. PROJECT.md — always included
if [ -f "$project_file" ]; then
  PROJ_CONTENT=$(printf '\n%s' "$(cat "$project_file")")
  sb_append "$PROJ_CONTENT" "PROJECT.md" 0
fi

# 4. Index line — tiny, always fits
if [ -f "$INDEX_FILE" ]; then
  IDX_LINE=$(printf '\n%s' "$(jq --arg s "$slug" -r 'select(.slug == $s)' "$INDEX_FILE" 2>/dev/null | head -1)")
  sb_append "$IDX_LINE" "index-line" 200
fi

# 5. Wiki enrichment — fills remaining budget, capped at 1500 bytes
KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SEARCH_CLI="$PLUGIN_ROOT/mcp/dist/tools/knowledge-search-cli.bundle.js"

if [ -f "$project_file" ] && [ -f "$SEARCH_CLI" ] && command -v node >/dev/null 2>&1; then
  STOP_RE='(the|a|an|is|are|was|were|will|be|have|has|had|do|does|did|can|could|should|would|to|of|in|for|on|at|by|with|from|and|but|or|not|no|this|that|auto|scaffolded|describe|active|resolved|stale|decision|pinned|project|goal|state|open|recent|cross|references|conventions)'

  PROJ_KW=$(awk '
    /^## (Goal|State|Conventions)$/,/^## / { if (!/^##/ && !/^\(auto-scaffolded/ && NF>0) print }
    /^## Recent decisions$/,/^## / { if (/^- /) print }
    /^## Open blockers$/,/^## / { if (/^- /) print }
    /^## Cross-references$/,/^## / { if (/\[\[/) { gsub(/[\[\]]/, ""); print } }
  ' "$project_file" 2>/dev/null | \
    tr -cs '[:alpha:]' '\n' | \
    grep -vxiE "$STOP_RE" | \
    sort -u | head -10 | tr '\n' ' ')

  if [ -n "${PROJ_KW// /}" ]; then
    WIKI_HITS=$(KNOWLEDGE_DIR="$KNOWLEDGE_DIR" node "$SEARCH_CLI" "$PROJ_KW" 2>/dev/null || true)
    if [ -n "$WIKI_HITS" ]; then
      sb_append "$(printf '\n%s' "$WIKI_HITS")" "wiki-enrichment" 1500
    fi
  fi
fi

# 6. Dream completion nudge
DREAMS_DIR="$BRAIN_DIR/dreams"
if [ -d "$DREAMS_DIR" ] && command -v jq >/dev/null 2>&1; then
  for sf in "$DREAMS_DIR"/drm_*/status.json; do
    [ -f "$sf" ] || continue
    DSTATUS=$(jq -r '.status' "$sf" 2>/dev/null)
    if [ "$DSTATUS" = "completed" ]; then
      DID=$(jq -r '.id' "$sf" 2>/dev/null)
      DA=$(jq -r '.outputs.pages_added // 0' "$sf" 2>/dev/null)
      DM=$(jq -r '.outputs.pages_modified // 0' "$sf" 2>/dev/null)
      sb_append "$(printf '\n[Dream %s completed: +%s added, ~%s modified — run /second-brain:dream to review and accept/discard]' "$DID" "$DA" "$DM")" "dream-nudge" 250
      break
    fi
  done
fi

# --- Emit collected output ---
cat "$OUTPUT_FILE"
rm -f "$OUTPUT_FILE"

# --- Bookkeeping (no output) ---
if [ "$USED" -gt "$BYTE_BUDGET" ]; then
  sb_log_error "session-load.sh" "hot-tier exceeded byte budget: $USED > $BYTE_BUDGET" 0
fi

if [ -f "$INDEX_FILE" ] && command -v jq >/dev/null 2>&1; then
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  TMP_IDX=$(mktemp)
  jq --arg s "$slug" --arg t "$TS" '
    if .slug == $s then .last_session_iso = $t else . end
  ' "$INDEX_FILE" > "$TMP_IDX" 2>/dev/null && mv "$TMP_IDX" "$INDEX_FILE" || rm -f "$TMP_IDX"
fi

# --- Stale wiki/index.md auto-reindex (background, no output) ---
# Decoupled from extraction success: when LLM extraction is broken for days,
# manual /pin or /archive writes still happen but reindex never fires. This
# closes that gap by triggering reindex if the index is >24h old.
WIKI_INDEX="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}/wiki/index.md"
WIKI_INDEX="${WIKI_INDEX/#\~/$HOME}"
if [ -f "$WIKI_INDEX" ]; then
  INDEX_MTIME=$(stat -c %Y "$WIKI_INDEX" 2>/dev/null || stat -f %m "$WIKI_INDEX" 2>/dev/null || echo 0)
  NOW_S=$(date +%s)
  INDEX_AGE_S=$((NOW_S - INDEX_MTIME))
  if [ "$INDEX_AGE_S" -gt 86400 ]; then
    (
      sb_reindex_wiki "${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}" >/dev/null 2>&1 || true
    ) &
    disown 2>/dev/null || true
  fi
fi

exit 0
