#!/bin/bash
# v1.0 PreCompact entry. Same logic as run-stop-predicate.sh but with a
# different trigger label. Captures PROJECT.md state for a future post-compact
# subagent to act on.
# user instruction verbatim: "finish what we can, make review and make PR"
set -u

LIB="$(dirname "$0")/lib.sh"
if ! source "$LIB" 2>/dev/null; then
  printf '{"timestamp":"%s","script":"pre-compact.sh","message":"lib.sh source failed: %s","exit_code":0}\n' \
    "$(date -u +%FT%TZ)" "$LIB" >> "$HOME/.second-brain/error-log.jsonl" 2>/dev/null
  exit 0
fi

SB_GATE=""
trap '[ -n "$SB_GATE" ] && sb_log_error "pre-compact.sh" "gate=$SB_GATE" 0' EXIT

slug=$(basename "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")")
baseline="$BRAIN_DIR/.session-baseline-$slug.md"
current="$BRAIN_DIR/projects/$slug/PROJECT.md"

if [ ! -f "$baseline" ]; then SB_GATE="baseline-missing slug=$slug path=$baseline"; exit 0; fi
if [ ! -f "$current" ];  then SB_GATE="project-md-missing slug=$slug path=$current"; exit 0; fi

if bash "$(dirname "$0")/stop-hook-predicate.sh" "$baseline" "$current"; then
  echo "predicate-fired-precompact" > "$BRAIN_DIR/.project-update-pending-$slug"
else
  SB_GATE="predicate-noop slug=$slug"
fi
rm -f "$baseline"
exit 0
