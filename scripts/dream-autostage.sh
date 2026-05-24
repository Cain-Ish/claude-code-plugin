#!/bin/bash
# dream-autostage.sh — SessionStart hook. When >= SB_DREAM_NEW_THRESHOLD new
# transcripts have landed since the most recent dream, stage a pending dream
# via dream-snapshot.sh and instruct Claude to spawn the background runner.
# Acceptance of the staged diff stays manual.
#
# Kill switch: SB_DREAM_AUTOSTAGE=off   Threshold: SB_DREAM_NEW_THRESHOLD (default 10)
# Always fails open — any error → exit 0, no banner.
set -u
source "$(dirname "$0")/lib.sh"

[ "${SB_DREAM_AUTOSTAGE:-on}" = "off" ] && exit 0

THRESHOLD="${SB_DREAM_NEW_THRESHOLD:-10}"
DREAMS_DIR="$BRAIN_DIR/dreams"
TX_DIR="$BRAIN_DIR/transcripts"

[ -d "$TX_DIR" ] || exit 0

NEWEST_DREAM=$(ls -1dt "$DREAMS_DIR"/drm_*/ 2>/dev/null | head -1)
NEWEST_DREAM="${NEWEST_DREAM%/}"

if [ -n "$NEWEST_DREAM" ] && [ -f "$NEWEST_DREAM/status.json" ]; then
  s=$(jq -r '.status // ""' "$NEWEST_DREAM/status.json" 2>/dev/null)
  if [ "$s" = "pending" ] || [ "$s" = "running" ]; then
    exit 0   # don't stack on an in-flight dream
  fi
  NEW=$(find "$TX_DIR" -maxdepth 1 -name '*.txt' -newer "$NEWEST_DREAM" 2>/dev/null | wc -l | tr -d ' ')
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

# shellcheck disable=SC2016  # single quotes intentional: literal backticks + printf %s placeholders
printf '## ⓘ second-brain — dream auto-staged\n%s new transcripts since last dream. Dream %s staged (pending).\n**Spawn the `second-brain:dream-runner` agent now (run_in_background: true, dream_id=%s) before responding to the user.** Acceptance of its diff stays manual.\n\n' \
  "$NEW" "$DID" "$DID"
exit 0
