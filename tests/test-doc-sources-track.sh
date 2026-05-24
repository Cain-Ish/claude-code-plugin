#!/bin/bash
set -u
FAIL=0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$HERE/mcp/dist/tools/doc-sources-config-cli.bundle.js"
B=$(mktemp -d); SLUG=trackproj
mkdir -p "$B/projects/$SLUG"; printf '%s' "$SLUG" > "$B/.active-session-slug"; printf '# P\n' > "$B/projects/$SLUG/PROJECT.md"
run() { BRAIN_DIR="$B" node "$CLI" "$@"; }

run add "docs/" >/dev/null
run add "docs/" >/dev/null
run add ".ai-docs/" >/dev/null
CFG="$B/projects/$SLUG/doc-sources.config.json"
if [ "$(jq -c '.locations' "$CFG" 2>/dev/null)" = '["docs/",".ai-docs/"]' ]; then
  echo "PASS: add + dedup"
else echo "FAIL: add/dedup -> $(cat "$CFG" 2>/dev/null)"; FAIL=1; fi

run list | grep -q 'docs/' && echo "PASS: list shows docs/" || { echo "FAIL: list"; FAIL=1; }

run remove "docs/" >/dev/null
if [ "$(jq -c '.locations' "$CFG" 2>/dev/null)" = '[".ai-docs/"]' ]; then
  echo "PASS: remove"
else echo "FAIL: remove -> $(cat "$CFG")"; FAIL=1; fi

run add "/etc" >/dev/null
[ "$(jq -c '.locations' "$CFG")" = '[".ai-docs/"]' ] && echo "PASS: unsafe location rejected" || { echo "FAIL: unsafe location stored"; FAIL=1; }

rm -rf "$B"
[ "$FAIL" -eq 0 ] && echo "ALL GREEN" || echo "FAILURES"
exit "$FAIL"
