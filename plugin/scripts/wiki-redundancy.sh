#!/bin/bash
# Shim so the dream-runner + FORGET scripts — which may run Bash(bash $CLAUDE_PLUGIN_ROOT/scripts/*)
# but NOT `node` directly — can invoke the bundled redundancy CLI (same pattern as
# graph-cluster.sh -> graph-cluster-cli, wiki-forget-candidates.sh -> wiki-recall-check -> node).
# Emits near-duplicate page pairs as JSON: [{a,b,sim,a_cat,b_cat}, ...].
# Fail-safe: prints `[]` and exits 0 when node or the bundle is unavailable (or the kill switch
# is set), so callers simply see "no near-duplicates" instead of an error.
# Usage: wiki-redundancy.sh --knowledge-dir <dir>   (scans <dir>/wiki)
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
# Machine-enforce the kill switch HERE (not just in agent prose): SB_REDUNDANCY=off emits the same
# `[]` sentinel as the fail-safe path, so the redundancy signal is byte-identically absent
# regardless of what any caller does with the result. (Default on; only the literal `off` gates.)
if [ "${SB_REDUNDANCY:-on}" = "off" ]; then echo '[]'; exit 0; fi
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BUNDLE="$ROOT/mcp/dist/tools/wiki-redundancy-cli.bundle.js"
if ! command -v node >/dev/null 2>&1 || [ ! -f "$BUNDLE" ]; then echo '[]'; exit 0; fi
# Capture stdout and emit it ONLY on success, so a partial write before a non-zero exit can't
# produce mixed "<partial>\n[]" invalid JSON — preserves the fail-safe contract.
out=$(node "$BUNDLE" --knowledge-dir "$KDIR" 2>/dev/null) && printf '%s\n' "$out" || echo '[]'
