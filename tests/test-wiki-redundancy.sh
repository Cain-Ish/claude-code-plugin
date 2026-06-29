#!/usr/bin/env bash
# The redundancy shim (scripts/wiki-redundancy.sh) must: (a) honor the SB_REDUNDANCY=off kill
# switch and fail-safe to `[]`, and (b) when the bundle + node are present, flag a near-duplicate
# page pair and NOT flag a distinct page. This is the deterministic, embedding-free redundancy
# signal that the dream DEDUPLICATE phase + the FORGET gate consume (P4 redundancy engine).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$ROOT/scripts/wiki-redundancy.sh"
BUNDLE="$ROOT/mcp/dist/tools/wiki-redundancy-cli.bundle.js"
[ -x "$SHIM" ] || chmod +x "$SHIM" 2>/dev/null
P=0; F=0; ok(){ P=$((P+1)); echo "  PASS $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/wiki/learnings" "$T/wiki/entities"
# two near-identical learnings (differ only in the trailing word) + one distinct entity
base="Always funnel path resolution through brain paths so Windows backslash paths are not mangled in project decisions and the stray folder bug class stays closed for good across every sibling repo"
printf -- '---\ntitle: A\n---\n%s morning\n' "$base" > "$T/wiki/learnings/path-a.md"
printf -- '---\ntitle: B\n---\n%s evening\n' "$base" > "$T/wiki/learnings/path-b.md"
printf -- '---\ntitle: C\n---\nPostgres vacuum analyze tuning for autovacuum thresholds and table bloat on large append only ledgers\n' > "$T/wiki/entities/pg.md"

# (1) kill switch -> [] (machine-enforced, independent of bundle presence)
out=$(SB_REDUNDANCY=off bash "$SHIM" --knowledge-dir "$T")
[ "$out" = "[]" ] && ok "kill switch SB_REDUNDANCY=off emits []" || bad "kill switch got: $out"

# (2+3) real path — only when the bundle + node are present (else the fail-safe [] is correct).
if [ -f "$BUNDLE" ] && command -v node >/dev/null 2>&1; then
  out=$(bash "$SHIM" --knowledge-dir "$T")
  if printf '%s' "$out" | grep -q '"path-a"' && printf '%s' "$out" | grep -q '"path-b"'; then
    ok "near-duplicate pair (path-a, path-b) flagged"
  else
    bad "near-dup not flagged: $out"
  fi
  printf '%s' "$out" | grep -q '"pg"' && bad "distinct page pg wrongly flagged: $out" || ok "distinct page (pg) not flagged"
else
  echo "  SKIP real-path assertions (node/bundle absent — exercising fail-safe instead)"
  out=$(bash "$SHIM" --knowledge-dir "$T")
  [ "$out" = "[]" ] && ok "fail-safe emits [] when node/bundle absent" || bad "fail-safe got: $out"
fi
echo "PASS:$P FAIL:$F"; [ "$F" -eq 0 ]
