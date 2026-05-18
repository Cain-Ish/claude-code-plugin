#!/bin/bash
# v2.8.0 migration: convert binary .maintainer-needed flags to integer
# .wiki-writes counters. Idempotent — safe to re-run.
set -u
BRAIN_DIR="${BRAIN_DIR:-$HOME/.second-brain}"
N="${SB_MAINTAINER_THRESHOLD:-3}"

# Refuse to migrate with an invalid threshold — leaving the old flag in place
# is safer than writing a useless counter value.
if ! [[ "$N" =~ ^[1-9][0-9]*$ ]]; then
  echo "migrate-to-2.8.0: SB_MAINTAINER_THRESHOLD=$N is not a positive integer" >&2
  exit 1
fi

if [ ! -d "$BRAIN_DIR/projects" ]; then
  exit 0
fi

migrated=0
for d in "$BRAIN_DIR"/projects/*/; do
  [ -d "$d" ] || continue
  if [ -f "$d/.maintainer-needed" ]; then
    # Only remove the legacy flag if the atomic counter write succeeded.
    if printf '%d' "$N" > "$d/.wiki-writes.tmp" && mv "$d/.wiki-writes.tmp" "$d/.wiki-writes"; then
      rm -f "$d/.maintainer-needed"
      migrated=$((migrated+1))
    fi
  fi
done

echo "migrate-to-2.8.0: $migrated project(s) migrated" >&2
