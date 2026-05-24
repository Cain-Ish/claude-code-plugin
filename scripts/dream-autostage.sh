#!/bin/bash
# dream-autostage.sh — SessionStart hook. When >= SB_DREAM_NEW_THRESHOLD new
# transcripts have landed since the last completed dream, stage a pending dream
# via dream-snapshot.sh and instruct Claude to spawn the background runner.
#
# Also re-emits the spawn instruction for a dream left 'pending' (staged but
# whose runner never started — e.g. a hook timeout or interruption), so an
# interruption can't permanently wedge autostaging. A 'running' dream means a
# runner is active, so we stay quiet. Acceptance of the staged diff stays manual.
#
# Kill switch: SB_DREAM_AUTOSTAGE=off   Threshold: SB_DREAM_NEW_THRESHOLD (default 10)
# Always fails open — any error → exit 0, no banner.
set -u
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

emit_spawn_banner() {  # $1 = dream id, $2 = new-transcript count ("" for recovery)
  local did="$1" n="$2" why
  if [ -n "$n" ]; then
    why="$n new transcripts since last dream. Dream $did staged (pending)."
  else
    why="Dream $did is staged (pending) but its runner never started — recovering."
  fi
  # shellcheck disable=SC2016  # single quotes intentional: literal backticks + printf %s placeholders
  printf '## ⓘ second-brain — dream auto-staged\n%s\n**Spawn the `second-brain:dream-runner` agent now (run_in_background: true, dream_id=%s) before responding to the user.** Acceptance of its diff stays manual.\n\n' \
    "$why" "$did"
}

# Scan ALL dreams (consistent with dream-snapshot.sh's one-at-a-time guard).
#   running → a runner is active; do nothing.
#   pending → staged but not started; (re)emit the spawn instruction.
#   else    → terminal (completed/archived); newest one is the watermark.
# Orphan dirs (no status.json, e.g. a half-created dream) are skipped so they
# can neither hijack the watermark nor force a spurious "count everything".
RUNNING=""
PENDING_ID=""
WATERMARK=""        # path whose mtime anchors "new since last dream"
WATERMARK_TIME=0
for d in "$DREAMS_DIR"/drm_*/; do
  [ -d "$d" ] || continue
  sf="${d}status.json"
  [ -f "$sf" ] || continue
  st=$(jq -r '.status // ""' "$sf" 2>/dev/null)
  case "$st" in
    running) RUNNING=1 ;;
    pending) PENDING_ID=$(jq -r '.id // ""' "$sf" 2>/dev/null) ;;
    *)
      # Anchor on the transcripts/ subdir: it is populated once at create and
      # never touched afterwards, so its mtime is a stable create-time mark.
      # (The dream dir's own mtime drifts when the runner/accept writes into it.)
      anchor="${d}transcripts"
      [ -d "$anchor" ] || anchor="$sf"
      t=$(stat -c %Y "$anchor" 2>/dev/null || echo 0)
      if [ "$t" -gt "$WATERMARK_TIME" ]; then
        WATERMARK_TIME="$t"; WATERMARK="$anchor"
      fi
      ;;
  esac
done

# A runner is active → never stack a second dream.
[ -n "$RUNNING" ] && exit 0

# A dream is staged but unstarted → (re)emit the spawn instruction, stage nothing.
if [ -n "$PENDING_ID" ]; then
  emit_spawn_banner "$PENDING_ID" ""
  exit 0
fi

# Count transcripts newer than the watermark (or all, if no terminal dream yet).
if [ -n "$WATERMARK" ]; then
  NEW=$(find "$TX_DIR" -maxdepth 1 -name '*.txt' -newer "$WATERMARK" 2>/dev/null | wc -l | tr -d ' ')
else
  NEW=$(find "$TX_DIR" -maxdepth 1 -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')
fi

[ "${NEW:-0}" -ge "$THRESHOLD" ] || exit 0

DID=$(bash "$(dirname "$0")/dream-snapshot.sh" --max-count 100 2>/dev/null)
RC=$?
if [ "$RC" -ne 0 ] || [ -z "$DID" ]; then
  sb_log_error "dream-autostage.sh" "stage failed rc=$RC new=$NEW" 0
  exit 0
fi

emit_spawn_banner "$DID" "$NEW"
exit 0
