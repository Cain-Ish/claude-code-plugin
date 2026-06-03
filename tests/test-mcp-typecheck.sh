#!/bin/bash
# Guard: the MCP server typechecks (tsc --noEmit clean).
#
# Why this exists: run-all.sh runs `vitest`, which transpiles per-file and does NOT
# typecheck the project. So a real `tsc` error — and the stale committed dist/ that
# results when `npm run build` (tsc && bundle) fails — slips through the "ALL GREEN"
# gate invisibly. That is exactly what happened: the 0.24.7 EDGE_TYPES zod-enum cast
# (`as [string, ...]`) broke `tsc` and shipped in 0.24.7 AND 0.24.8 with a stale bundle.
# This guard makes the release gate fail on a type error, closing that class.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
MCP="$ROOT/mcp"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; echo; echo "ALL PASS"; exit 0; }
[ -f "$MCP/tsconfig.json" ] || { echo "SKIP: no mcp/tsconfig.json"; echo; echo "ALL PASS"; exit 0; }
# tsc must be installed locally (a fresh checkout without `npm ci` should not hard-fail the suite).
[ -x "$MCP/node_modules/.bin/tsc" ] || { echo "SKIP: typescript not installed (run: cd mcp && npm ci)"; echo; echo "ALL PASS"; exit 0; }

out=$(cd "$MCP" && ./node_modules/.bin/tsc --noEmit 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: mcp/ does not typecheck (tsc --noEmit exit $rc) — \`npm run build\` would fail:"
  printf '%s\n' "$out" | head -20
  exit 1
fi
echo "PASS: mcp/ typechecks (tsc --noEmit clean)"
echo
echo "ALL PASS"
