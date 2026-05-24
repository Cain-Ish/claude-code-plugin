#!/bin/bash
set -u
FAIL=0
HERE="$(cd "$(dirname "$0")/.." && pwd)"

BRAIN=$(mktemp -d); PROJ=$(mktemp -d)
SLUG="$(basename "$PROJ")"
mkdir -p "$BRAIN/projects/$SLUG" "$PROJ/docs"
printf '%s' "$SLUG" > "$BRAIN/.active-session-slug"
printf '# PROJECT: %s\n' "$SLUG" > "$BRAIN/projects/$SLUG/PROJECT.md"
printf '{"locations":["docs/"]}' > "$BRAIN/projects/$SLUG/doc-sources.config.json"
printf '# Deploy\n\n## Steps\n\ndo it\n' > "$PROJ/docs/deploy.md"

printf '{"cwd":"%s"}' "$PROJ" | BRAIN_DIR="$BRAIN" bash "$HERE/scripts/discover-doc-sources.sh"

REG="$BRAIN/projects/$SLUG/doc-sources.json"
if [ -f "$REG" ] && jq -e '.entries[] | select(.rel=="docs/deploy.md")' "$REG" >/dev/null 2>&1; then
  echo "PASS: hook built registry with docs/deploy.md"
else
  echo "FAIL: registry missing or entry absent"; FAIL=1
fi

BRAIN2=$(mktemp -d); PROJ2=$(mktemp -d); SLUG2="$(basename "$PROJ2")"
mkdir -p "$BRAIN2/projects/$SLUG2"; printf '%s' "$SLUG2" > "$BRAIN2/.active-session-slug"
printf '# PROJECT: %s\n' "$SLUG2" > "$BRAIN2/projects/$SLUG2/PROJECT.md"
printf '{"cwd":"%s"}' "$PROJ2" | BRAIN_DIR="$BRAIN2" bash "$HERE/scripts/discover-doc-sources.sh"
if [ -f "$BRAIN2/projects/$SLUG2/doc-sources.json" ]; then
  echo "FAIL: registry written despite no config"; FAIL=1
else
  echo "PASS: no config -> no registry (zero cost)"
fi

rm -rf "$BRAIN" "$PROJ" "$BRAIN2" "$PROJ2"
[ "$FAIL" -eq 0 ] && echo "ALL GREEN" || echo "FAILURES"
exit "$FAIL"
