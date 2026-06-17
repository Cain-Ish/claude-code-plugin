#!/bin/bash
# dream-autostage.sh — SessionStart hook. When >= SB_DREAM_NEW_THRESHOLD new
# transcripts have landed since the last completed dream, emit a banner
# suggesting the user run `/second-brain:dream`. Never auto-stages and never
# instructs subagent spawning — explicit invocation only.
#
# Doctrinal alignment: Anthropic's Dreaming runs "between sessions, never
# during an active session" (Managed Agents docs). Counter-triggered subagent
# dispatch has no documented Anthropic pattern. See
# wiki/decisions/2026-05-28-plugin-architecture-rethink.md (C5-A).
#
# Recovery path: if a previous dream was staged but its runner never started
# (e.g. hook timeout or interruption), the banner names the pending id so the
# user can resume via `/second-brain:dream`.
#
# Kill switch: SB_DREAM_AUTOSTAGE=off   Threshold: SB_DREAM_NEW_THRESHOLD (default 10)
# Always fails open — any error → exit 0, no banner.
set -u
# Nested-spawn circuit breaker (R1.1): inside a plugin-spawned headless session, capture/context hooks no-op.
[ "${SB_NESTED_SPAWN:-0}" = "1" ] && exit 0
source "$(dirname "$0")/lib.sh"

[ "${SB_DREAM_AUTOSTAGE:-on}" = "off" ] && exit 0

THRESHOLD="${SB_DREAM_NEW_THRESHOLD:-10}"
# A non-numeric threshold (env typo) must not silently disable the feature.
case "$THRESHOLD" in
  ''|*[!0-9]*) THRESHOLD=10 ;;
esac

DREAMS_DIR="$BRAIN_DIR/dreams"
TX_DIR="$BRAIN_DIR/transcripts"
[ -d "$TX_DIR" ] || exit 0

emit_threshold_banner() {  # $1 = new-transcript count
  local n="$1"
  # shellcheck disable=SC2016  # single quotes intentional: literal backticks + printf %s placeholder
  printf '## ⓘ second-brain — dream consolidation ready\n%s new transcripts have accumulated since the last dream. Run `/second-brain:dream` to consolidate the wiki — acceptance of the staged diff stays manual.\n\n' "$n"
}

emit_pending_banner() {  # $1 = pending dream id
  local did="$1"
  # shellcheck disable=SC2016  # single quotes intentional: literal backticks + printf %s placeholder
  printf '## ⓘ second-brain — pending dream\nDream %s is staged but no runner started (likely a previous hook timeout or interruption). Run `/second-brain:dream` to resume — acceptance of the staged diff stays manual.\n\n' "$did"
}

emit_failed_banner() {  # $1 = id, $2 = error tail (R4, SCRIPTS-02/04 visibility)
  # shellcheck disable=SC2016
  printf '## ⚠ second-brain — dream failed\nDream %s failed: %s\nRetry via `/second-brain:maintain` (explicit run) or stage a fresh dream with `/second-brain:dream`.\n\n' "$1" "$2"
}

emit_quarantine_banner() {  # $1 = quarantine line (R4, SCRIPTS-03 visibility)
  # shellcheck disable=SC2016
  printf '## ⚠ second-brain — auto_maintain quarantined\n%s\nIf the error names bwrap/namespaces, redeploy the drainer unit: `bash $CLAUDE_PLUGIN_ROOT/scripts/install-extract-timer.sh --apply --oauth`. The quarantine self-clears on the next drain cycle once the cause is fixed (or delete `~/.second-brain/.llm-maintain-quarantine`).\n\n' "$1"
}

# Anchor the new-transcripts watermark on a TERMINAL dream (R4: failed/canceled
# count as terminal too). The transcripts/ subdir is populated once at create
# and never touched afterwards — a stable create-time mark.
WATERMARK=""
WATERMARK_TIME=0
update_watermark() {  # $1 = dream dir (trailing slash), $2 = status file
  local anchor="${1}transcripts"
  [ -d "$anchor" ] || anchor="$2"
  local t
  t=$(stat -c %Y "$anchor" 2>/dev/null || stat -f %m "$anchor" 2>/dev/null || echo 0)  # GNU || BSD/macOS
  if [ "$t" -gt "$WATERMARK_TIME" ]; then
    WATERMARK_TIME="$t"; WATERMARK="$anchor"
  fi
}

# Scan ALL dreams (consistent with dream-snapshot.sh's one-at-a-time guard).
#   running → a runner SHOULD be active; reclaim if stale (crashed mid-run),
#             else block (one active dream at a time).
#   pending → staged but not started; reclaim if stale, else recovery banner.
#   failed  → terminal; surface once (R4) + counts for the watermark.
#   else    → terminal (completed/archived); newest one is the watermark.
# Staleness is the SINGLE shared policy sb_dream_is_stale (lib.sh): status.json
# mtime older than SB_DREAM_RUN_TIMEOUT (6h). The runner re-stamps status.json
# between phases, so a healthy run is never wrongly reclaimed.
# Orphan dirs (no status.json, e.g. a half-created dream) are skipped so they
# can neither hijack the watermark nor force a spurious "count everything".
RUNNING_ID=""; RUNNING_SF=""
PENDING_ID=""; PENDING_SF=""
FAILED_ID=""; FAILED_ERR=""
for d in "$DREAMS_DIR"/drm_*/; do
  [ -d "$d" ] || continue
  sf="${d}status.json"
  [ -f "$sf" ] || continue
  st=$(jq -r '.status // ""' "$sf" 2>/dev/null | tr -d '\r')
  case "$st" in
    running)
      RUNNING_ID=$(jq -r '.id // ""' "$sf" 2>/dev/null | tr -d '\r')
      RUNNING_SF="$sf"
      ;;
    pending)
      PENDING_ID=$(jq -r '.id // ""' "$sf" 2>/dev/null | tr -d '\r')
      PENDING_SF="$sf"
      ;;
    failed|canceled)
      if [ "$st" = "failed" ]; then
        FAILED_ID=$(jq -r '.id // ""' "$sf" 2>/dev/null | tr -d '\r')
        FAILED_ERR=$(jq -r '.error // "unknown error"' "$sf" 2>/dev/null | head -c 160 | tr -d '\r')
      fi
      # Anchor ONLY on the stable create-time transcripts/ dir. Once the prune
      # strips it, status.json's mtime is the FAILURE time — anchoring there
      # would jump the watermark forward and silently un-count transcripts the
      # failed dream never consolidated (deep-review).
      [ -d "${d}transcripts" ] && update_watermark "$d" "$sf"
      ;;
    *) update_watermark "$d" "$sf" ;;
  esac
done

# reclaim_dream STATUS_FILE EXPECTED_STATUS ERROR — flip a stale pending|running
# dream to terminal failed so it stops blocking new dreams and the failure
# becomes visible instead of a forever-stuck mystery. The if/else keeps the
# document intact if a runner flipped the status in the scan-to-write window
# (deep-review: a bare `select` emits an EMPTY doc and clobbers status.json).
reclaim_dream() {  # $1=status file, $2=expected status (pending|running), $3=error
  jq --arg s "$2" --arg e "$(date -u +%FT%TZ)" --arg err "$3" \
    'if .status == $s then .status = "failed" | .ended_at = $e | .error = $err else . end' \
    "$1" > "$1.tmp.$$" 2>/dev/null \
    && mv "$1.tmp.$$" "$1" 2>/dev/null || rm -f "$1.tmp.$$" 2>/dev/null
}

# A runner SHOULD be active → block, UNLESS it is stale (crashed mid-run). A
# stale running dream would otherwise DEADLOCK every future dream forever
# (deep-review / R4). Reclaim it to failed (same policy as dream-snapshot.sh's
# deadlock-break) and fall through to the failed-banner surface; a fresh runner
# still blocks. Staleness = sb_dream_is_stale (status.json mtime > 6h).
if [ -n "$RUNNING_ID" ]; then
  if sb_dream_is_stale "$RUNNING_SF"; then
    RECLAIM_ERR="stale running run reclaimed by autostage (no status.json progress within SB_DREAM_RUN_TIMEOUT)"
    reclaim_dream "$RUNNING_SF" running "$RECLAIM_ERR"
    FAILED_ID="$RUNNING_ID"; FAILED_ERR="$RECLAIM_ERR"
  else
    exit 0
  fi
fi

# Stale pending (R4, SCRIPTS-02): the runner never started (hook timeout, or a
# pre-0.24.41 structural failure). Reclaim to failed so it stops blocking new
# dreams and the failure becomes visible instead of a forever-pending mystery.
if [ -n "$PENDING_ID" ] && sb_dream_is_stale "$PENDING_SF"; then
  RECLAIM_ERR="runner never started — stale pending reclaimed by autostage"
  reclaim_dream "$PENDING_SF" pending "$RECLAIM_ERR"
  FAILED_ID="$PENDING_ID"; FAILED_ERR="$RECLAIM_ERR"
  PENDING_ID=""
fi

# A dream is staged but unstarted (and fresh) → emit recovery banner, stage nothing.
if [ -n "$PENDING_ID" ]; then
  emit_pending_banner "$PENDING_ID"
  exit 0
fi

# Surface failures, then CONTINUE to the threshold logic (failed is terminal).
[ -n "$FAILED_ID" ] && emit_failed_banner "$FAILED_ID" "$FAILED_ERR"
if [ -f "$BRAIN_DIR/.llm-maintain-quarantine" ]; then
  emit_quarantine_banner "$(head -1 "$BRAIN_DIR/.llm-maintain-quarantine" 2>/dev/null)"
fi

# Count transcripts newer than the watermark (or all, if no terminal dream yet).
if [ -n "$WATERMARK" ]; then
  NEW=$(find "$TX_DIR" -maxdepth 1 -name '*.txt' -newer "$WATERMARK" 2>/dev/null | wc -l | tr -d ' ')
else
  NEW=$(find "$TX_DIR" -maxdepth 1 -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')
fi

[ "${NEW:-0}" -ge "$THRESHOLD" ] || exit 0

# Threshold tripped → suggest, do not stage. The user explicitly invokes
# /second-brain:dream when ready; that path runs dream-snapshot.sh + spawns
# the runner under direct user intent.
emit_threshold_banner "$NEW"
exit 0
