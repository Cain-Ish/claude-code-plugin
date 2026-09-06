#!/bin/bash
# Shim so the dream-runner — which may run `Bash(bash $CLAUDE_PLUGIN_ROOT/scripts/*)` but
# NOT `node` directly — can invoke the bundled clustering CLI (same pattern as
# wiki-forget-candidates.sh -> wiki-recall-check.sh -> node search CLI).
# Fail-safe: prints `[]` and exits 0 when node or the bundle is unavailable, so the
# dream SUMMARIZE phase simply produces no theme pages this run.
# Usage: graph-cluster.sh --knowledge-dir <dir>   (clusters <dir>/wiki)
set -u
KDIR=""; GATE="summarize"   # which consumer's kill switch to honor: summarize | reflect
while [ $# -gt 0 ]; do
  case "$1" in
    --knowledge-dir) KDIR="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    --gate) GATE="${2:-summarize}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    *) shift ;;
  esac
done
if [ -z "$KDIR" ]; then
  # Re-implementing the knowledge-dir precedence inline (bare KNOWLEDGE_DIR before the
  # plugin option) drifted from sb_knowledge_dir()'s precedence and every other resolver
  # in the repo — the "two wikis" bug class. Source lib.sh for the single shared resolver
  # instead; only reached when the caller omitted --knowledge-dir (the dream-runner always
  # passes it explicitly).
  # shellcheck source=lib.sh
  . "$(cd "$(dirname "$0")" && pwd)/lib.sh"
  KDIR="$(sb_knowledge_dir)"
fi
KDIR="${KDIR/#\~/$HOME}"
# Machine-enforce the consumer's kill switch HERE (not just in agent prose): emit the same `[]`
# sentinel the fail-safe path uses so the dream's SUMMARIZE/REFLECT loop writes zero pages —
# byte-identical to the documented skip, independent of what the LLM does. The two consumers gate
# INDEPENDENTLY (a user may want themes without reflections or vice-versa). Default on; only `off` gates.
case "$GATE" in
  reflect) [ "${SB_DREAM_REFLECT:-on}" = "off" ] && { echo '[]'; exit 0; } ;;
  *)       [ "${SB_DREAM_SUMMARIZE:-on}" = "off" ] && { echo '[]'; exit 0; } ;;
esac
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BUNDLE="$ROOT/mcp/dist/tools/graph-cluster-cli.bundle.js"

if ! command -v node >/dev/null 2>&1 || [ ! -f "$BUNDLE" ]; then echo '[]'; exit 0; fi
# Capture stdout and emit it ONLY on success, so a partial write before a non-zero exit
# can't produce mixed "<partial>\n[]" invalid JSON — preserves the fail-safe contract.
out=$(node "$BUNDLE" "$KDIR/wiki" 2>/dev/null) && printf '%s\n' "$out" || echo '[]'
