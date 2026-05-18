#!/bin/bash
# v2.8.0 migration: convert binary .maintainer-needed flags to integer
# .wiki-writes counters. Idempotent — safe to re-run.
set -u
BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
N="${SB_MAINTAINER_THRESHOLD:-3}"

if [ ! -d "$BRAIN_DIR/projects" ]; then
  exit 0
fi

migrated=0
for d in "$BRAIN_DIR"/projects/*/; do
  [ -d "$d" ] || continue
  if [ -f "$d/.maintainer-needed" ]; then
    # Set counter to threshold so next SessionStart auto-dispatches once.
    printf '%d' "$N" > "$d/.wiki-writes.tmp" && mv "$d/.wiki-writes.tmp" "$d/.wiki-writes"
    rm -f "$d/.maintainer-needed"
    migrated=$((migrated+1))
  fi
done

echo "migrate-to-2.8.0: $migrated project(s) migrated"
