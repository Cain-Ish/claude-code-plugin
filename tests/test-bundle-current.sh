#!/usr/bin/env bash
# R8 bundle-current gate: every committed mcp/dist bundle must be reproducible
# from the committed src with the committed esbuild — the 0.24.7/0.24.8
# stale-bundle incident class (src reviewed, dist shipped stale; the tsc gate
# only catches the type-error subclass). Rebuilds each entry of package.json's
# bundle script to a temp outfile and byte-compares against dist.
set -u

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
MCP="$REPO_ROOT/mcp"
fail() { echo "FAIL: $1"; exit 1; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 0; }
[ -x "$MCP/node_modules/.bin/esbuild" ] || { echo "SKIP: esbuild not installed (run npm ci in mcp/)"; exit 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Each ' && '-separated entry is one esbuild invocation ending in
# --outfile=dist/<path>. Re-run it with the outfile redirected to $TMP.
BUNDLE_SCRIPT=$(jq -r '.scripts.bundle' "$MCP/package.json")
[ -n "$BUNDLE_SCRIPT" ] || fail "no bundle script in mcp/package.json"

checked=0
printf '%s\n' "$BUNDLE_SCRIPT" | sed 's/ && /\n/g' | while IFS= read -r cmd; do
  out=$(printf '%s' "$cmd" | grep -oE -- '--outfile=[^ ]+' | cut -d= -f2)
  [ -n "$out" ] || fail "could not parse outfile from: $cmd"
  rel="${out#dist/}"
  mkdir -p "$TMP/$(dirname "$rel")"
  newcmd=${cmd//--outfile=$out/--outfile=$TMP/$rel}
  ( cd "$MCP" && PATH="$MCP/node_modules/.bin:$PATH" eval "$newcmd" ) >/dev/null 2>&1 \
    || fail "rebuild failed for $rel"
  cmp -s "$TMP/$rel" "$MCP/dist/$rel" \
    || fail "mcp/dist/$rel is STALE — committed bundle differs from a rebuild of committed src (run: cd mcp && npm run bundle)"
  echo "PASS: $rel current"
done || exit 1

echo "ALL PASS"
