#!/bin/bash
# Shim so the dream-runner — which may run `Bash(bash $CLAUDE_PLUGIN_ROOT/scripts/*)` but
# NOT `node` directly — can invoke the bundled clustering CLI (same pattern as
# wiki-forget-candidates.sh -> wiki-recall-check.sh -> node search CLI).
# Fail-safe: prints `[]` and exits 0 when node or the bundle is unavailable, so the
# dream SUMMARIZE phase simply produces no theme pages this run.
# Usage: graph-cluster.sh --knowledge-dir <dir>   (clusters <dir>/wiki)
set -u
KDIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --knowledge-dir) KDIR="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    *) shift ;;
  esac
done
[ -z "$KDIR" ] && KDIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-${KNOWLEDGE_DIR:-$HOME/knowledge}}"
KDIR="${KDIR/#\~/$HOME}"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BUNDLE="$ROOT/mcp/dist/tools/graph-cluster-cli.bundle.js"

if ! command -v node >/dev/null 2>&1 || [ ! -f "$BUNDLE" ]; then echo '[]'; exit 0; fi
# Capture stdout and emit it ONLY on success, so a partial write before a non-zero exit
# can't produce mixed "<partial>\n[]" invalid JSON — preserves the fail-safe contract.
out=$(node "$BUNDLE" "$KDIR/wiki" 2>/dev/null) && printf '%s\n' "$out" || echo '[]'
