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

# Scan ALL dreams (consistent with dream-snapshot.sh's one-at-a-time guard).
#   running → a runner is active; do nothing.
#   pending → staged but not started; emit recovery banner.
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
      t=$(stat -c %Y "$anchor" 2>/dev/null || stat -f %m "$anchor" 2>/dev/null || echo 0)  # GNU || BSD/macOS
      if [ "$t" -gt "$WATERMARK_TIME" ]; then
        WATERMARK_TIME="$t"; WATERMARK="$anchor"
      fi
      ;;
  esac
done

# A runner is active → never stack a second dream.
[ -n "$RUNNING" ] && exit 0

# A dream is staged but unstarted → emit recovery banner, stage nothing.
if [ -n "$PENDING_ID" ]; then
  emit_pending_banner "$PENDING_ID"
  exit 0
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
