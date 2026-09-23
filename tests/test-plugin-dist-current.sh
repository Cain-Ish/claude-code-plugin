#!/bin/bash
# R8 plugin-dist gate: plugin/ (what a marketplace install actually receives — marketplace.json
# `source: "./plugin"`) must be byte-identical to a fresh build from .claude-plugin/ship-manifest.txt,
# and must contain NOTHING outside that manifest. Same incident class as the stale-bundle gate:
# source reviewed, shipped tree stale — except here the failure mode is a user running last
# release's hooks against this release's docs. Also pins the manifest's negative space: the dev-only
# trees must never be shippable by accident.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

[ -f "$ROOT/.claude-plugin/ship-manifest.txt" ] || fail "ship-manifest.txt missing"
[ -d "$ROOT/plugin" ] || fail "plugin/ missing — run: bash scripts/build-plugin.sh"
src=$(jq -r '.plugins[0].source' "$ROOT/.claude-plugin/marketplace.json" 2>/dev/null)
[ "$src" = "./plugin" ] || fail "marketplace.json plugins[0].source must be ./plugin (is: $src) — otherwise the whole repo ships"
pass "marketplace source points at plugin/"

# 1. Drift: rebuild to a temp dir and compare.
if ! out=$(bash "$ROOT/scripts/build-plugin.sh" --check 2>&1); then
  printf '%s\n' "$out" | head -20
  fail "plugin/ drifts from the manifest build — run: bash scripts/build-plugin.sh (or make build-plugin)"
fi
pass "plugin/ is byte-identical to a fresh manifest build"

# 2. Negative space: dev-only material must be absent from the shipped tree.
for bad in tests docs mcp/src mcp/node_modules .claude .superpowers .codex .agents .github .githooks home; do
  [ -e "$ROOT/plugin/$bad" ] && fail "plugin/$bad is shipped — dev-only tree leaked into the manifest"
done
for badf in CONSTITUTION.md RELEASING.md Makefile hooks/hooks.notes.md .claude-plugin/marketplace.json .claude-plugin/surface-budget.json .claude-plugin/ship-manifest.txt; do
  [ -e "$ROOT/plugin/$badf" ] && fail "plugin/$badf is shipped — dev-only file leaked into the manifest"
done
find "$ROOT/plugin" -name '*.test.ts' -o -name '*.stackdump' -o -name '.DS_Store' | grep -q . && fail "test/debris files inside plugin/"
pass "no dev-only trees or files in plugin/"

# 3. Positive space: every runtime surface the manifests and hooks reference must be present.
for need in .claude-plugin/plugin.json .claude-plugin/mcp.json hooks/hooks.json mcp/dist/server.bundle.js mcp/dist/cli/sb-entry.bundle.js mcp/package.json kb-schema.json model-ladder.json scripts/lib.sh scripts/session-load.sh bin/sb LICENSE; do
  [ -e "$ROOT/plugin/$need" ] || fail "plugin/$need missing — an install would break"
done
# every script hooks.json runs, every skill/agent/output-style at the root, exists in plugin/
for s in $(jq -r '.. | .command? // empty' "$ROOT/hooks/hooks.json" | grep -o 'scripts/[A-Za-z0-9_.-]*\.sh' | sort -u); do
  [ -f "$ROOT/plugin/$s" ] || fail "hook script $s not shipped"
done
for d in skills agents output-styles; do
  for f in "$ROOT/$d"/*; do [ -e "$f" ] || continue; [ -e "$ROOT/plugin/$d/$(basename "$f")" ] || fail "$d/$(basename "$f") not shipped"; done
done
rootv=$(jq -r .version "$ROOT/.claude-plugin/plugin.json"); shipv=$(jq -r .version "$ROOT/plugin/.claude-plugin/plugin.json")
[ "$rootv" = "$shipv" ] || fail "version mismatch root=$rootv plugin/=$shipv"
pass "every hook script, skill, agent, output style and manifest is shipped; versions match ($rootv)"

# 4. Every manifest entry landed. The drift diff above compares plugin/ against a fresh build from
#    the SAME manifest, so a build that silently drops an entry drifts nowhere and passes it.
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"; line="${line%"${line##*[! ]}"}"; [ -n "$line" ] || continue
  p="${line%% *}"
  case "$p" in
    */) [ -n "$(find "$ROOT/plugin/$p" -type f 2>/dev/null | head -1)" ] || fail "manifest entry $p shipped no files" ;;
    *)  [ -f "$ROOT/plugin/$p" ] || fail "manifest entry $p is not in plugin/" ;;
  esac
done < "$ROOT/.claude-plugin/ship-manifest.txt"
pass "every ship-manifest entry is present in plugin/"

# 5. The installed copy validates. /second-brain:upgrade runs validate-plugin.sh from the cache, where
#    dev-repo-only files (surface-budget.json, tests/) are absent by design — it must still exit 0.
if ! vout=$(CLAUDE_PLUGIN_ROOT="$ROOT/plugin" bash "$ROOT/plugin/scripts/validate-plugin.sh" 2>&1); then
  printf '%s\n' "$vout" | grep -E '^FAIL' | head -5
  fail "validate-plugin.sh fails on the shipped tree — every upgrade would report it"
fi
pass "validate-plugin.sh passes on the shipped tree (what /second-brain:upgrade runs)"

echo; echo "ALL PASS"
