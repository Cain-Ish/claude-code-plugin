#!/usr/bin/env bash
# install-vector-deps.sh — installs the runtime npm deps the episodic vector
# indexer needs (@huggingface/transformers + onnxruntime). The plugin ships
# mcp/dist/ as a tracked bundle so most features work without npm, but
# @huggingface/transformers is marked --external in the esbuild config because
# its native binaries (onnxruntime-node, sharp) can't be bundled. This script
# is the one-time installer that fills that gap.
#
# Usage:
#   bash $CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh
#
# Safe to re-run. Exits 0 if dep already present and the smoke check passes.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MCP_DIR="$PLUGIN_ROOT/mcp"
MARKER="$MCP_DIR/node_modules/@huggingface/transformers/package.json"

if [ ! -d "$MCP_DIR" ]; then
  echo "install-vector-deps: cannot find $MCP_DIR — is CLAUDE_PLUGIN_ROOT set correctly?" >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "install-vector-deps: npm not found on PATH. Install Node.js + npm first." >&2
  echo "  Debian/Ubuntu/Pi:  sudo apt install -y nodejs npm" >&2
  exit 2
fi

if [ -f "$MARKER" ]; then
  echo "install-vector-deps: @huggingface/transformers already installed."
  echo "  $(node -e "console.log(require('$MARKER').name + '@' + require('$MARKER').version)")"
  echo "install-vector-deps: smoke-checking import resolution …"
  if (cd "$MCP_DIR" && node --input-type=module -e 'await import("@huggingface/transformers"); console.log("ok")') 2>/dev/null | grep -q '^ok$'; then
    echo "install-vector-deps: OK — vector search should be functional."
    exit 0
  fi
  echo "install-vector-deps: import failed despite package present — reinstalling." >&2
fi

echo "install-vector-deps: installing runtime deps in $MCP_DIR …"
echo "install-vector-deps: this needs network access and downloads ~70MB of native"
echo "                     deps (onnxruntime-node, sharp). One-time on first use."

# --omit=dev drops vitest/esbuild/typescript. --no-audit/--no-fund quiet the install.
( cd "$MCP_DIR" && npm install --omit=dev --no-audit --no-fund )

if [ ! -f "$MARKER" ]; then
  echo "install-vector-deps: npm install completed but @huggingface/transformers still missing." >&2
  echo "                     Inspect: cd $MCP_DIR && npm ls @huggingface/transformers" >&2
  exit 3
fi

echo "install-vector-deps: OK. Run an extractor cycle to populate embeddings:"
echo "  rm $HOME/.second-brain/episodic-index.json   # one-time reset, indexer rebuilds"
echo "  node $MCP_DIR/dist/tools/episodic-index-cli.bundle.js"
