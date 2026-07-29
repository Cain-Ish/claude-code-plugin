#!/bin/bash
# Create a dream: snapshot wiki into staging, select and symlink transcripts,
# write status.json. Exits non-zero on failure with error on stderr.
#
# Usage: dream-snapshot.sh [--instructions "..."] [--slug <project>] [--since <date>] [--max-count N] [--model <id>]
# Outputs: the dream_id on stdout
set -u
source "$(dirname "$0")/lib.sh"

INSTRUCTIONS=""
FILTER_SLUGS=""
FILTER_SINCE=""
MAX_COUNT=50
# Tier intent, not a literal — recorded into status.json and overridable via --model.
MODEL="tier:mid"

while [ $# -gt 0 ]; do
  case "$1" in
    --instructions) INSTRUCTIONS="$2"; shift 2 ;;
    --slug)         FILTER_SLUGS="${FILTER_SLUGS:+$FILTER_SLUGS }$2"; shift 2 ;;
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

PROJECT_SLUG_RECORD="${FILTER_SLUGS:-all}"

KNOWLEDGE_DIR="$(sb_knowledge_dir)"
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
  s=$(jq -r '.status' "$sf" 2>/dev/null | tr -d '\r')
  if [ "$s" = "pending" ] || [ "$s" = "running" ]; then
    did=$(jq -r '.id' "$sf" 2>/dev/null | tr -d '\r')
    # SP-C: a crash mid-run would otherwise stick at pending/running forever and DEADLOCK
    # every future dream (this guard refuses while one is active). sb_dream_is_stale (lib.sh)
    # is the SINGLE shared policy: a pending/running dream whose status.json mtime has not
    # advanced within SB_DREAM_RUN_TIMEOUT (6h default) is treated as crashed. The liveness
    # signal is the mtime — the dream-runner re-stamps status.json between phases — so a
    # healthy run is never wrongly reclaimed; a genuine crash blocks only until the timeout
    # before auto-recovery. On stale: mark failed (staging kept for SP-D to prune) and
    # proceed; otherwise refuse (one active dream at a time).
    if sb_dream_is_stale "$sf"; then
      jq --arg e "stale $s run reclaimed (no status.json progress within SB_DREAM_RUN_TIMEOUT)" --arg t "$(date -u +%FT%TZ)" \
        '.status="failed" | .error=$e | .ended_at=$t' "$sf" > "$sf.tmp.$$" 2>/dev/null && mv "$sf.tmp.$$" "$sf" 2>/dev/null || rm -f "$sf.tmp.$$" 2>/dev/null
      echo "warning: reclaimed stale $s dream $did — proceeding" >&2
    else
      echo "error: dream $did is already $s" >&2
      exit 1
    fi
  fi
done

# Unreviewed-completed cap (state hygiene): a completed dream that is never accepted
# or discarded holds its ~1MB staging payload forever AND gives no signal it needs
# review. Refuse to create a NEW dream once >= 3 completed dreams remain unreviewed
# (archived_at unset) — the operator must dream_accept or dream_discard some first.
# NEVER deletes anything; the backlog is preserved for review. Loud (sb_log_error +
# stderr) so the refusal surfaces at the next SessionStart banner and to the caller.
UNREVIEWED=0
for csf in "$DREAMS_DIR"/drm_*/status.json; do
  [ -f "$csf" ] || continue
  cst=$(jq -r '.status // ""' "$csf" 2>/dev/null | tr -d '\r')
  car=$(jq -r '.archived_at // ""' "$csf" 2>/dev/null | tr -d '\r')
  if [ "$cst" = "completed" ] && { [ -z "$car" ] || [ "$car" = "null" ]; }; then
    UNREVIEWED=$((UNREVIEWED + 1))
  fi
done
if [ "$UNREVIEWED" -ge 3 ]; then
  sb_log_error "dream-snapshot.sh" "refused: $UNREVIEWED completed dreams await review — run dream_accept or dream_discard before creating another" 1
  echo "error: $UNREVIEWED completed dreams are unreviewed — run dream_accept or dream_discard on some before creating a new dream" >&2
  exit 1
fi

# Prune old dream dirs to retention.dream_keep_count (default 5), oldest-first
# (drm_<ts> names sort chronologically). Archived dreams are deleted whole;
# FAILED/CANCELED dreams lose their staging/transcripts payload
# (~1MB each — worth reclaiming) but KEEP status.json for forensics.
# A pending/running/completed-but-unreviewed dream is NEVER touched.
DREAM_KEEP="${SB_DREAM_KEEP_COUNT:-$(sb_config_get .retention.dream_keep_count 5)}"
case "$DREAM_KEEP" in ''|*[!0-9]*) DREAM_KEEP=5 ;; esac
DREAM_COUNT=$(find "$DREAMS_DIR" -maxdepth 1 -type d -name 'drm_*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$DREAM_COUNT" -ge "$DREAM_KEEP" ]; then
  find "$DREAMS_DIR" -maxdepth 1 -type d -name 'drm_*' 2>/dev/null | sort | while read -r old; do
    [ "$DREAM_COUNT" -lt "$DREAM_KEEP" ] && break
    old_archived=$(jq -r '.archived_at // ""' "$old/status.json" 2>/dev/null | tr -d '\r')
    old_st=$(jq -r '.status // ""' "$old/status.json" 2>/dev/null | tr -d '\r')
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
# Family-slug alternation for transcript matching, computed ONCE (not per-transcript):
# a transcript matches if its name contains _<slug>_ for ANY requested family member.
ALT=$(printf '%s' "$FILTER_SLUGS" | tr ' ' '|')

if [ -d "$TRANSCRIPT_DIR" ]; then
  for tf in $(ls -1 "$TRANSCRIPT_DIR"/*.txt 2>/dev/null | sort -r); do
    [ "$SELECTED" -ge "$MAX_COUNT" ] && break

    if [ -n "$FILTER_SLUGS" ]; then
      # a transcript matches if its name contains _<slug>_ for ANY family member (ALT hoisted above).
      fname=$(basename "$tf")
      echo "$fname" | grep -qE "_(${ALT})_" || continue
    fi

    if [ -n "$FILTER_SINCE" ]; then
      fdate=$(basename "$tf" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1)
      [ -n "$fdate" ] && [ "$fdate" \< "$FILTER_SINCE" ] && continue
    fi

    # Stage a SANITIZED copy (P6b): strip invisible/Tags-block smuggling chars before the
    # dream-runner agent reads the transcript. Always a real copy (never a symlink) — the sanitizer
    # must not write through to the original. mtime is preserved (the autostage watermark property);
    # the source transcript is left untouched, and the staging dir is pruned wholesale either way.
    _dst="$DREAM_DIR/transcripts/$(basename "$tf")"
    sb_strip_invisible_copy "$tf" "$_dst"
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
  --arg pslug "$PROJECT_SLUG_RECORD" \
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
      wiki_snapshot_bytes: $wsb,
      project_slug: $pslug
    },
    outputs: {
      pages_added: 0,
      pages_modified: 0,
      pages_removed: 0
    },
    error: null
  }' > "$DREAM_DIR/status.json"

echo "$DREAM_ID"
