#!/usr/bin/env bash
# install-vector-deps.sh — install the episodic vector indexer's runtime deps
# (@huggingface/transformers + native onnxruntime-node/sharp) ONCE into a shared,
# version-independent dir, and symlink the current plugin version's mcp/node_modules
# at it.
#
# Why shared: @huggingface/transformers is esbuild --external (native binaries can't
# be bundled) and the plugin cache ships dist/ but never node_modules/. Installing
# per-version meant a 519MB tree per version — re-downloaded on every bump and
# accumulating across versions. The shared dir lives in the plugin's data home
# (~/.second-brain), survives cache wipes, and is symlinked into each version so
# there is only ever ONE copy on disk.
#
# Usage:  bash $CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh
# Override shared location with SB_VECTOR_DEPS_DIR (used by tests).
# Safe to re-run: no-op when shared deps + symlink + import all check out.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MCP_DIR="$PLUGIN_ROOT/mcp"
SHARED="${SB_VECTOR_DEPS_DIR:-$HOME/.second-brain/vector-deps}"
PKG="$MCP_DIR/package.json"
SHARED_NM="$SHARED/node_modules"
SHARED_MARKER="$SHARED_NM/@huggingface/transformers/package.json"
KEY_FILE="$SHARED/.deps-key"

if [ ! -d "$MCP_DIR" ]; then
  echo "install-vector-deps: cannot find $MCP_DIR — is CLAUDE_PLUGIN_ROOT set correctly?" >&2
  exit 1
fi
if [ ! -f "$PKG" ]; then
  echo "install-vector-deps: $PKG missing — cannot determine deps." >&2
  exit 1
fi

# deps-key: a stable hash of the dependencies block, so the shared tree is rebuilt
# only when the actual dependency set changes — not on every version bump.
WANT_KEY="$(node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(JSON.stringify(p.dependencies||{}))' "$PKG" | sha256sum | awk '{print $1}')"
HAVE_KEY="$(cat "$KEY_FILE" 2>/dev/null || echo none)"

smoke() { ( cd "$MCP_DIR" && node --input-type=module -e 'await import("@huggingface/transformers"); console.log("ok")' ) 2>/dev/null | grep -q '^ok$'; }

link_version() {
  local nm="$MCP_DIR/node_modules"
  if [ -L "$nm" ]; then
    [ "$(readlink "$nm")" = "$SHARED_NM" ] && return 0
    rm -f "$nm"
  elif [ -e "$nm" ]; then
    rm -rf "$nm"
  fi
  ln -s "$SHARED_NM" "$nm"
}

# 1. Shared tree present and current → just (re)link and verify.
if [ -f "$SHARED_MARKER" ] && [ "$HAVE_KEY" = "$WANT_KEY" ]; then
  link_version
  if smoke; then
    echo "install-vector-deps: OK — shared deps reused, mcp/node_modules linked."
    exit 0
  fi
  echo "install-vector-deps: shared deps present but import failed — rebuilding." >&2
  rm -rf "$SHARED_NM"          # force a fresh rebuild below
fi

mkdir -p "$SHARED"

# Stale shared tree (the dependency set changed since it was built) → clear it so
# the npm-install branch rebuilds fresh instead of reusing outdated deps.
if [ -f "$SHARED_MARKER" ] && [ "$HAVE_KEY" != "$WANT_KEY" ]; then
  echo "install-vector-deps: dependency set changed — rebuilding shared deps."
  rm -rf "$SHARED_NM"
fi

# 2. Harvest an existing real per-version install instead of downloading (one-time
#    transition from the old per-version layout).
if [ ! -f "$SHARED_MARKER" ] \
   && [ ! -L "$MCP_DIR/node_modules" ] \
   && [ -d "$MCP_DIR/node_modules/@huggingface/transformers" ]; then
  echo "install-vector-deps: harvesting existing mcp/node_modules -> $SHARED_NM (no download)."
  rm -rf "$SHARED_NM"
  mv "$MCP_DIR/node_modules" "$SHARED_NM"
fi

# 3. Still no shared tree → npm install into the shared dir.
if [ ! -f "$SHARED_MARKER" ]; then
  command -v npm >/dev/null 2>&1 || {
    echo "install-vector-deps: npm not found on PATH. Install Node.js + npm first." >&2
    echo "  Debian/Ubuntu/Pi:  sudo apt install -y nodejs npm" >&2
    exit 2
  }
  echo "install-vector-deps: installing runtime deps in $SHARED ..."
  echo "install-vector-deps: this needs network access and downloads ~70MB of native"
  echo "                     deps (onnxruntime-node, sharp). One-time; shared across versions."
  cp "$PKG" "$SHARED/package.json"
  ( cd "$SHARED" && npm install --omit=dev --no-audit --no-fund )
fi

if [ ! -f "$SHARED_MARKER" ]; then
  echo "install-vector-deps: shared install completed but @huggingface/transformers still missing." >&2
  echo "                     Inspect: cd $SHARED && npm ls @huggingface/transformers" >&2
  exit 3
fi

echo "$WANT_KEY" > "$KEY_FILE"
link_version

# 4. Smoke-check resolution through the symlink.
if smoke; then
  echo "install-vector-deps: OK — shared deps installed and linked."
  echo "  Run an extractor cycle to populate embeddings:"
  echo "    rm $HOME/.second-brain/episodic-index.json   # one-time reset, indexer rebuilds"
  echo "    node $MCP_DIR/dist/tools/episodic-index-cli.bundle.js"
  exit 0
fi

echo "install-vector-deps: import still failing after install + link." >&2
echo "                     Inspect: ls -la $MCP_DIR/node_modules ; cd $MCP_DIR && npm ls @huggingface/transformers" >&2
exit 4
