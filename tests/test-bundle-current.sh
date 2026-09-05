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

# Record each expected outfile (relative to dist/) so the orphan guard below can
# prove every COMMITTED bundle is actually produced by the script. Written to a file
# because the `while` runs in a pipe-subshell — a shell var would not survive it.
EXPECTED="$TMP/expected.txt"; : > "$EXPECTED"

# D210: split on ' && ' with awk, not `sed 's/ && /\n/g'` — GNU sed interprets
# \n in the REPLACEMENT text as a literal newline (a GNU extension); BSD/macOS
# sed does not, so the whole bundle script stayed on one line there and the
# per-entry loop below silently processed zero commands. awk string literals
# uniformly support the \n escape (POSIX), so gsub-into-newline is portable.
printf '%s\n' "$BUNDLE_SCRIPT" | awk '{gsub(/ && /, "\n")}1' | while IFS= read -r cmd; do
  out=$(printf '%s' "$cmd" | grep -oE -- '--outfile=[^ ]+' | cut -d= -f2)
  [ -n "$out" ] || fail "could not parse outfile from: $cmd"
  rel="${out#dist/}"
  printf '%s\n' "$rel" >> "$EXPECTED"
  mkdir -p "$TMP/$(dirname "$rel")"
  newcmd=${cmd//--outfile=$out/--outfile=$TMP/$rel}
  ( cd "$MCP" && PATH="$MCP/node_modules/.bin:$PATH" eval "$newcmd" ) >/dev/null 2>&1 \
    || fail "rebuild failed for $rel"
  cmp -s "$TMP/$rel" "$MCP/dist/$rel" \
    || fail "mcp/dist/$rel is STALE — committed bundle differs from a rebuild of committed src (run: cd mcp && npm run bundle)"
  echo "PASS: $rel current"
done || exit 1

# Orphan guard: the STALE check above only covers bundles the script KNOWS about.
# A *.bundle.js committed under dist/ with NO scripts.bundle entry is never rebuilt
# nor byte-compared — it can ship stale forever (e.g. a tool renamed in src, its old
# bundle left behind). Fail on any committed bundle the script does not produce.
orphans=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  rel="${f#$MCP/dist/}"
  if ! grep -qxF "$rel" "$EXPECTED"; then
    echo "FAIL: orphan bundle mcp/dist/$rel — committed but no scripts.bundle entry builds it"
    echo "      (stale-artifact risk: add an esbuild entry for it, or delete the file)"
    orphans=$((orphans + 1))
  fi
done <<EOF
$(find "$MCP/dist" -name '*.bundle.js' 2>/dev/null)
EOF
[ "$orphans" -eq 0 ] || exit 1

echo "ALL PASS"
