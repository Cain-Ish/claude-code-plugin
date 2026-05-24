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
# Reject mktemp/temp-style slugs. A session started from /tmp/tmp.xK3p9q or
# any short random-looking dir creates a ghost project that's never used and
# never cleaned up — observed 33 such directories accumulated before this
# guard was added. We replace the slug with "scratch" so the project is shared
# rather than per-tempdir. The user can still rename it later if they want.
case "$slug" in
  tmp.*|tmp|.tmp.*|tmpfs|"")
    slug="scratch"
    ;;
esac
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
# Legacy session-count nag: only when auto-stage is disabled. When autostage is
# on (default), dream-autostage.sh owns the nudge — suppress here to avoid a
# double banner. See docs/specs/2026-05-24-dream-auto-stage-design.md §7.
if [ "${SB_DREAM_AUTOSTAGE:-on}" = "off" ] && [ "$SESSION_COUNT" -ge "$DREAM_THRESHOLD" ]; then
  sb_append "$(printf '## ⓘ second-brain — dream consolidation suggested\n%s sessions since last dream (threshold: %s).\nRun: `/second-brain:dream --background` — mines transcripts for missed learnings, stages changes for review.\n\n' \
    "$SESSION_COUNT" "$DREAM_THRESHOLD")" "dream-cadence-banner" 300
fi
# --- v2.8.0 maintainer auto-dispatch: reconcile previous + threshold -----
KD_RESOLVED="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
N=${SB_MAINTAINER_THRESHOLD:-3}
AUTO=${SB_MAINTAINER_AUTO:-on}
PROJ_DIR="$BRAIN_DIR/projects/$slug"
DISP_FILE="$PROJ_DIR/.maintainer-dispatched"
ACK_FILE="$PROJ_DIR/.maintainer-needed-last"
DISABLED_FILE="$PROJ_DIR/.maintainer-auto-disabled"

# [reconcile] If previous dispatch finished, reset state on success or bump fail-count on failure.
N_MAX_FAILS=${SB_MAINTAINER_MAX_FAILS:-3}
if [ -f "$DISP_FILE" ] && [ -f "$ACK_FILE" ]; then
  # Success.
  sb_reset_wiki_writes "$slug"
  sb_reset_maintainer_fails "$slug"
  rm -f "$DISP_FILE" "$ACK_FILE"
elif [ -f "$DISP_FILE" ] && [ ! -f "$ACK_FILE" ]; then
  # Failure: parent Claude didn't write the ack file.
  COUNT_AFTER=$(( N - 1 < 0 ? 0 : N - 1 ))
  sb_set_wiki_writes "$slug" "$COUNT_AFTER"
  sb_inc_maintainer_fails "$slug"
  rm -f "$DISP_FILE"
  sb_log_error "session-load.sh" "maintainer-auto-dispatch-failed slug=$slug" 0
  sb_append "$(printf '## ⚠ maintainer auto-dispatch failed last session — see error-log\n\n')" \
    "maintainer-fail-banner" 200
  if [ "$(sb_get_maintainer_fails "$slug")" -ge "$N_MAX_FAILS" ]; then
    touch "$DISABLED_FILE"
    sb_log_error "session-load.sh" "maintainer-auto-disabled slug=$slug fails=$N_MAX_FAILS" 0
    sb_reset_maintainer_fails "$slug"
  fi
fi

# [dispatch] Decide whether to emit the BLOCKING REQUIREMENT banner.
if [ "$AUTO" != "off" ] && [ ! -f "$DISABLED_FILE" ]; then
  COUNT=$(sb_get_wiki_writes "$slug")
  if [ "$COUNT" -ge "$N" ]; then
    BANNER=$(printf '## ⚙ BLOCKING REQUIREMENT — knowledge-maintainer auto-dispatch\n\nProject `%s` has accumulated %s wiki writes since the last\nconsolidation cycle. Before responding to the user'"'"'s prompt, you MUST:\n\n1. Dispatch the `second-brain:knowledge-maintainer` subagent via the\n   Agent tool. Brief it with: "Auto-dispatched after %s wiki writes.\n   Run full 6-phase consolidation. Knowledge dir: %s.\n   Brain dir: ~/.second-brain. Project slug: %s."\n\n2. When the subagent returns, write this acknowledgment file to mark\n   the run complete (counter reset depends on it):\n\n       echo ok > ~/.second-brain/projects/%s/.maintainer-needed-last\n\n3. Print ONE LINE to the user in this exact format, derived from the\n   subagent'"'"'s report:\n\n       ✓ second-brain maintainer: R relations, D descriptions, B broken-links, O orphans\n\n   Where R/D/B/O are integers parsed from the subagent'"'"'s phase 3/4/1 totals.\n   If the subagent reports zero changes in all phases, print:\n       ✓ second-brain maintainer: nothing to consolidate\n\n4. THEN respond to the user'"'"'s actual prompt. Do not surface the full\n   subagent report unless the user asks.\n\nOverride: set `SB_MAINTAINER_AUTO=off` in shell rc to disable this entirely.\n\n' \
      "$slug" "$COUNT" "$COUNT" "$KD_RESOLVED" "$slug" "$slug")
    sb_append "$BANNER" "maintainer-auto-banner" 1400
    touch "$DISP_FILE"
    sb_log_error "session-load.sh" "maintainer-auto-dispatched slug=$slug count=$COUNT" 0
  fi
fi
PIN_COUNT=$(sb_count_pin_candidates "$slug")
if [ "$PIN_COUNT" -gt 0 ]; then
  sb_append "$(printf '## ⓘ second-brain — %s pin candidate(s) pending\nExtracted persona signals waiting in `~/.second-brain/projects/%s/.pin-candidates.jsonl`.\nRun: `Review pin candidates in second-brain and decide which to pin to USER.md.`\n\n' \
    "$PIN_COUNT" "$slug")" "pin-candidates-banner" 250
fi

# USER.md Never/Always rules vs persona-rules.default.json enforcement gap.
# USER.md text is advisory (injected as ambient context); only rules in
# persona-rules.default.json are HARD-ENFORCED at PreToolUse. If the user
# edits USER.md without updating the rules JSON, those edits never become
# blocking guards. Banner fires when USER.md is newer than the rules file,
# nudging the user to keep them in sync manually.
# Kill switch: SB_RULES_GAP_BANNER=off.
if [ "${SB_RULES_GAP_BANNER:-on}" != "off" ] && [ -f "$USER_FILE" ]; then
  RULES_FILE_RUNTIME="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}/scripts/persona-rules.default.json"
  if [ -f "$RULES_FILE_RUNTIME" ]; then
    UM_MT=$(stat -c %Y "$USER_FILE" 2>/dev/null || stat -f %m "$USER_FILE" 2>/dev/null || echo 0)
    PR_MT=$(stat -c %Y "$RULES_FILE_RUNTIME" 2>/dev/null || stat -f %m "$RULES_FILE_RUNTIME" 2>/dev/null || echo 0)
    if [ "$UM_MT" -gt "$PR_MT" ]; then
      # awk range `/start/,/end/` matches the header line on both ends — so
      # `/^## Never/,/^## /` collapses to just the Never header itself and
      # never reaches the bullets. Use an explicit in-section flag instead.
      NEVER_COUNT=$(awk '
        /^## Never/ { in_s=1; next }
        /^## / && in_s { in_s=0 }
        in_s && /^- / { c++ }
        END { print c+0 }
      ' "$USER_FILE" 2>/dev/null)
      ALWAYS_COUNT=$(awk '
        /^## Always/ { in_s=1; next }
        /^## / && in_s { in_s=0 }
        in_s && /^- / { c++ }
        END { print c+0 }
      ' "$USER_FILE" 2>/dev/null)
      sb_append "$(printf '## ⓘ second-brain — USER.md rules are advisory, not enforced\nUSER.md has %s Never + %s Always bullet(s) but was modified after persona-rules.default.json. Tool-time blocking only happens for rules wired into `scripts/persona-rules.default.json` (the rules array). USER.md text reaches the model as context but does not block tool calls.\nTo make a Never rule hard-enforced, add it to the rules JSON. Suppress this banner: `SB_RULES_GAP_BANNER=off`.\n\n' \
        "$NEVER_COUNT" "$ALWAYS_COUNT")" "rules-gap-banner" 500
    fi
  fi
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
    # Mode-aware hint. Previous single-template was telling users to "run
    # claude /login" on every failure — but the actual cause varies:
    #   - "auth:..." prefix (or "unauthorized"/"not logged in") → real auth fail
    #   - "non-json:..." → the LLM editorialized instead of returning JSON
    #   - "empty after pty-retry..." / ec=124 timeouts → claude CLI hanging,
    #     usually recursive-claude conflict; fix is ANTHROPIC_API_KEY backstop
    #   - "api:..." → ANTHROPIC_API_KEY call failed (rate limit / billing)
    case "$H_REASON" in
      auth:*|*unauthorized*|*"not logged in"*|*"please run /login"*|*"invalid api key"*)
        H_HINT="fix: run \`claude /login\` (OAuth) or \`export ANTHROPIC_API_KEY=sk-ant-...\` (API key)."
        ;;
      non-json:*|pty-retry-non-json:*)
        H_HINT="cause: extractor LLM returned prose instead of JSON. fix: re-run with a fresh session; persistent failures usually mean the system prompt was truncated — check scripts/extract-prompt.txt."
        ;;
      empty*|*timeout*|*ec=124*)
        H_HINT="cause: \`claude\` CLI hung past the timeout (recursive-claude / OAuth conflict). fix: \`export ANTHROPIC_API_KEY=sk-ant-...\` so lib.sh uses the direct-API backstop instead of the recursive CLI path."
        ;;
      api:*)
        H_HINT="cause: ANTHROPIC_API_KEY call failed (rate limit / billing / model name). fix: check \`echo \$ANTHROPIC_API_KEY | head -c 10\` and Anthropic console quotas."
        ;;
      *)
        H_HINT="fix: run \`claude /login\` (OAuth) or \`export ANTHROPIC_API_KEY=sk-ant-...\`; tail \`~/.second-brain/error-log.jsonl\` for the underlying diag line."
        ;;
    esac
    HEALTH_BANNER=$(printf '## ⚠ second-brain extractor: FAILED\nbackend=%s checked=%s recent_failures=%s\nreason: %s\nimpact: Stop/PreCompact hooks not writing wiki learnings — session insights are lost on exit.\n%s\n\n' \
      "$H_BACKEND" "$H_AT" "$H_FAILS" "$H_REASON" "$H_HINT")
    sb_append "$HEALTH_BANNER" "extractor-health-banner" 800
  fi
fi

# 0a-bis. Auth-mode line — one quiet line so the user always knows which
# credential path the extractor will use this session. Critical for the dual-
# auth UX (Claude subscription vs Anthropic API key): without this banner,
# new machines silently default to OAuth-only and the user only discovers the
# in-session limitation when they notice extractor failures days later.
# Suppress: SB_AUTH_LINE=off
if [ "${SB_AUTH_LINE:-on}" = "on" ]; then
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    AUTH_PREFIX="${ANTHROPIC_API_KEY:0:10}"
    sb_append "$(printf '## ⓘ second-brain auth\nmode: api-key (key: %s…, len=%s) — direct anthropic-api, works in all contexts.\n\n' \
      "$AUTH_PREFIX" "${#ANTHROPIC_API_KEY}")" "auth-mode-line" 220
  elif command -v claude >/dev/null 2>&1; then
    sb_append "$(printf '## ⓘ second-brain auth\nmode: subscription (OAuth) — in-session Stop/PreCompact extraction will queue (recursive-claude lock).\nfix to enable in-session extraction: `export ANTHROPIC_API_KEY=sk-ant-...` or run `sb auth doctor`.\n\n')" "auth-mode-line" 350
  else
    sb_append "$(printf '## ⚠ second-brain auth\nmode: none — neither ANTHROPIC_API_KEY nor `claude` CLI is available. Run `sb auth doctor`.\n\n')" "auth-mode-line" 220
  fi
fi

# 0b. Episodic embeddings banner — surfaces missing native deps that prevent
# vector search over transcripts. Production bug 2026-05-22: 976/981 exchanges
# had embedding:[] because @huggingface/transformers was --external in the
# bundle but never installed under the plugin cache. Banner fires only when
# pending count is non-trivial AND a transcript has been indexed (otherwise
# we'd spam new installs).
SB_EPI_INDEX="${BRAIN_DIR:-$HOME/.second-brain}/episodic-index.json"
if [ -f "$SB_EPI_INDEX" ] && command -v jq >/dev/null 2>&1; then
  EPI_PENDING=$(jq -r '[.exchanges[]? | select((.embedding|length)==0)] | length' "$SB_EPI_INDEX" 2>/dev/null || echo 0)
  EPI_TOTAL=$(jq -r   '.exchanges | length'                                       "$SB_EPI_INDEX" 2>/dev/null || echo 0)
  if [ "${EPI_PENDING:-0}" -gt 10 ] && [ "${EPI_TOTAL:-0}" -gt 0 ]; then
    EPI_BANNER=$(printf '## ⓘ second-brain — episodic vector search degraded\n%s of %s exchanges have no embedding (text search works; vector / mode=both will miss them).\ncause: `@huggingface/transformers` runtime dep missing from the plugin cache.\nfix: `bash $CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh` (one-time, downloads ~70MB native deps), then `rm %s` to let the next indexer run repair entries.\nSuppress: `SB_EMBED_PENDING_BANNER=off`.\n\n' \
      "$EPI_PENDING" "$EPI_TOTAL" "$SB_EPI_INDEX")
    [ "${SB_EMBED_PENDING_BANNER:-on}" = "on" ] && sb_append "$EPI_BANNER" "episodic-embed-pending-banner" 700
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
