#!/bin/bash
# Stop-hook entry. Invokes predicate, flags pending update on fire.
source "$(dirname "$0")/lib.sh"

slug=$(basename "$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")")
baseline="$BRAIN_DIR/.session-baseline-$slug.md"
current="$BRAIN_DIR/projects/$slug/PROJECT.md"

if [ ! -f "$baseline" ] || [ ! -f "$current" ]; then exit 0; fi

if bash "$(dirname "$0")/stop-hook-predicate.sh" "$baseline" "$current"; then
  echo "predicate-fired" > "$BRAIN_DIR/.project-update-pending-$slug"
fi
rm -f "$baseline"
exit 0
