#!/usr/bin/env bash
# Enforce the RELEASING.md checklist item: skills/upgrade/SKILL.md's migration
# table MUST contain a row for the version currently in plugin.json. Without it,
# an upgrader from the prior version walks no migration and silently lands in an
# inconsistent state — the exact "aspirational version" failure RELEASING.md
# exists to prevent. (The missing 0.12/0.13 rows show why this needs a gate.)
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=$(jq -r '.version' "$ROOT/.claude-plugin/plugin.json")
TABLE="$ROOT/skills/upgrade/SKILL.md"

if grep -qF "| **$VERSION** |" "$TABLE"; then
  echo "PASS: upgrade migration row present for $VERSION"
  exit 0
fi

echo "FAIL: skills/upgrade/SKILL.md has no migration row for plugin.json version $VERSION"
echo "      add a row: | **$VERSION** | <what changed> | <idempotent check> |"
exit 1
