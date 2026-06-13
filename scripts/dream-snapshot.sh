#!/bin/bash
# Create a dream: snapshot wiki into staging, select and symlink transcripts,
# write status.json. Exits non-zero on failure with error on stderr.
#
# Usage: dream-snapshot.sh [--instructions "..."] [--slug <project>] [--since <date>] [--max-count N] [--model <id>]
# Outputs: the dream_id on stdout
set -u
source "$(dirname "$0")/lib.sh"

INSTRUCTIONS=""
FILTER_SLUG=""
FILTER_SINCE=""
MAX_COUNT=50
MODEL="claude-sonnet-4-6"

while [ $# -gt 0 ]; do
  case "$1" in
    --instructions) INSTRUCTIONS="$2"; shift 2 ;;
    --slug)         FILTER_SLUG="$2"; shift 2 ;;
    --since)
      if echo "$2" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
        FILTER_SINCE="$2"
      else
        echo "error: --since must be YYYY-MM-DD, got: $2" >&2; exit 1
      fi
      shift 2 ;;
    --max-count)    MAX_COUNT="$2"; shift 2 ;;
    --model)        MODEL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"
WIKI_DIR="$KNOWLEDGE_DIR/wiki"

if [ ! -d "$WIKI_DIR" ]; then
  echo "error: wiki directory missing at $WIKI_DIR" >&2
  exit 1
fi

# Guard: only one pending/running dream at a time
DREAMS_DIR="$BRAIN_DIR/dreams"
mkdir -p "$DREAMS_DIR"

for sf in "$DREAMS_DIR"/drm_*/status.json; do
  [ -f "$sf" ] || continue
  s=$(jq -r '.status' "$sf" 2>/dev/null)
  if [ "$s" = "pending" ] || [ "$s" = "running" ]; then
    did=$(jq -r '.id' "$sf" 2>/dev/null)
    # SP-C: a crash mid-run would otherwise stick at pending/running forever and DEADLOCK
    # every future dream (this guard refuses while one is active). Treat a pending/running
    # dream whose status.json hasn't advanced in SB_DREAM_RUN_TIMEOUT as crashed: mark it
    # failed (recoverable — its staging is kept for SP-D to prune) and proceed.
    # The liveness signal is the status.json mtime; the dream-runner heartbeats it between
    # phases (re-stamps status=running), so a healthy run keeps it fresh. The default is a
    # DELIBERATELY GENEROUS 6h — safely beyond any realistic 50-transcript consolidation
    # even if a heartbeat is missed — so a still-running dream is never wrongly reclaimed;
    # the cost is only that a genuine crash blocks for up to 6h before auto-recovery.
    smt=$(stat -c %Y "$sf" 2>/dev/null || stat -f %m "$sf" 2>/dev/null || echo 0)
    run_to="${SB_DREAM_RUN_TIMEOUT:-21600}"; case "$run_to" in ''|*[!0-9]*) run_to=21600 ;; esac
    if [ "$(( $(date +%s) - ${smt:-0} ))" -gt "$run_to" ]; then
      tmp=$(mktemp) && jq --arg e "stale $s run reclaimed after ${run_to}s with no progress" \
        '.status="failed" | .error=$e' "$sf" > "$tmp" 2>/dev/null && mv "$tmp" "$sf" || rm -f "$tmp"
      echo "warning: reclaimed stale $s dream $did (no progress in ${run_to}s) — proceeding" >&2
    else
      echo "error: dream $did is already $s" >&2
      exit 1
    fi
  fi
done

# Prune old dream dirs to retention.dream_keep_count (default 5), oldest-first
# (drm_<ts> names sort chronologically). Archived dreams are deleted whole;
# FAILED/CANCELED dreams (R4, SCRIPTS-04) lose their staging/transcripts payload
# (~1MB each, previously never reclaimed) but KEEP status.json for forensics.
# A pending/running/completed-but-unreviewed dream is NEVER touched.
DREAM_KEEP="${SB_DREAM_KEEP_COUNT:-$(sb_config_get .retention.dream_keep_count 5)}"
case "$DREAM_KEEP" in ''|*[!0-9]*) DREAM_KEEP=5 ;; esac
DREAM_COUNT=$(find "$DREAMS_DIR" -maxdepth 1 -type d -name 'drm_*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$DREAM_COUNT" -ge "$DREAM_KEEP" ]; then
  find "$DREAMS_DIR" -maxdepth 1 -type d -name 'drm_*' 2>/dev/null | sort | while read -r old; do
    [ "$DREAM_COUNT" -lt "$DREAM_KEEP" ] && break
    old_archived=$(jq -r '.archived_at // ""' "$old/status.json" 2>/dev/null)
    old_st=$(jq -r '.status // ""' "$old/status.json" 2>/dev/null)
    if [ -n "$old_archived" ] && [ "$old_archived" != "null" ]; then
      rm -rf "$old"
      DREAM_COUNT=$((DREAM_COUNT - 1))
    elif [ "$old_st" = "failed" ] || [ "$old_st" = "canceled" ]; then
      # Only strip failures older than a day (deep-review): a JUST-failed
      # dream's staged partial work may still be wanted for debugging.
      if [ -n "$(find "$old/status.json" -mtime +1 2>/dev/null)" ]; then
        rm -rf "$old/staging" "$old/transcripts" 2>/dev/null || true
      fi
    fi
  done
fi

DREAM_ID=$(sb_generate_dream_id)
DREAM_DIR="$DREAMS_DIR/$DREAM_ID"
mkdir -p "$DREAM_DIR/staging" "$DREAM_DIR/transcripts"

# Snapshot wiki. -p PRESERVES mtimes (P4): FORGET scores age from mtime, and
# dream-accept's rsync -a writes staged mtimes onto live — a plain `cp -r` reset
# every page to "now", re-arming the FORGET age-gate corpus-wide so nothing
# could ever age into a candidate (silently neutering the recency fix). `cp -rp`
# keeps each unchanged page's real mtime; only pages the dream actually edits
# get a fresh mtime (correct — they WERE modified).
cp -rp "$WIKI_DIR" "$DREAM_DIR/staging/wiki"
SNAPSHOT_BYTES=$(find "$DREAM_DIR/staging/wiki" -type f -name '*.md' -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
WIKI_PAGE_COUNT=$(find "$DREAM_DIR/staging/wiki" -type f -name '*.md' ! -name 'index.md' 2>/dev/null | wc -l | tr -d ' ')

# Select and symlink transcripts
TRANSCRIPT_DIR="$BRAIN_DIR/transcripts"
SELECTED=0

if [ -d "$TRANSCRIPT_DIR" ]; then
  for tf in $(ls -1 "$TRANSCRIPT_DIR"/*.txt 2>/dev/null | sort -r); do
    [ "$SELECTED" -ge "$MAX_COUNT" ] && break

    if [ -n "$FILTER_SLUG" ]; then
      fname=$(basename "$tf")
      echo "$fname" | grep -q "_${FILTER_SLUG}_" || continue
    fi

    if [ -n "$FILTER_SINCE" ]; then
      fdate=$(basename "$tf" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1)
      [ -n "$fdate" ] && [ "$fdate" \< "$FILTER_SINCE" ] && continue
    fi

    ln -sf "$tf" "$DREAM_DIR/transcripts/$(basename "$tf")"
    SELECTED=$((SELECTED + 1))
  done
fi

# Write status.json
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -nc \
  --arg id "$DREAM_ID" \
  --arg now "$NOW" \
  --arg model "$MODEL" \
  --arg instr "$INSTRUCTIONS" \
  --argjson tc "$SELECTED" \
  --argjson wpc "$WIKI_PAGE_COUNT" \
  --argjson wsb "$SNAPSHOT_BYTES" \
  '{
    id: $id,
    status: "pending",
    created_at: $now,
    started_at: null,
    ended_at: null,
    archived_at: null,
    model: $model,
    instructions: $instr,
    inputs: {
      transcript_count: $tc,
      wiki_page_count: $wpc,
      wiki_snapshot_bytes: $wsb
    },
    outputs: {
      pages_added: 0,
      pages_modified: 0,
      pages_removed: 0
    },
    error: null
  }' > "$DREAM_DIR/status.json"

echo "$DREAM_ID"
