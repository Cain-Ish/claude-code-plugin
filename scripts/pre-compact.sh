#!/bin/bash
# v1.0 PreCompact entry. Same logic as run-stop-predicate.sh but with a
# different trigger label. Captures PROJECT.md state for a future post-compact
# subagent to act on.
# user instruction verbatim: "finish what we can, make review and make PR"
source "$(dirname "$0")/lib.sh"

slug=$(basename "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")")
baseline="$BRAIN_DIR/.session-baseline-$slug.md"
current="$BRAIN_DIR/projects/$slug/PROJECT.md"

if [ ! -f "$baseline" ] || [ ! -f "$current" ]; then exit 0; fi

if bash "$(dirname "$0")/stop-hook-predicate.sh" "$baseline" "$current"; then
  echo "predicate-fired-precompact" > "$BRAIN_DIR/.project-update-pending-$slug"
fi
rm -f "$baseline"
exit 0
