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
# Safety: every rebuild is staged in a PRIVATE temp dir and validated (all deps
# present + import works) BEFORE the live shared tree or the symlink is touched, so a
# failed/offline npm install can never destroy a working install or leave a dangling
# symlink. A unique staging dir also makes concurrent runs collision-free.
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

# sha256: GNU coreutils ships `sha256sum`; macOS/BSD ship `shasum`. Support both.
sha256() { sha256sum 2>/dev/null || shasum -a 256; }

# deps-key: a stable hash of the dependencies block, so the shared tree is rebuilt
# only when the actual dependency set changes — not on every version bump.
WANT_KEY="$(node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(JSON.stringify(p.dependencies||{}))' "$PKG" | sha256 | awk '{print $1}')"
HAVE_KEY="$(cat "$KEY_FILE" 2>/dev/null || echo none)"

# deps_ok <node_modules-dir>: exit 0 iff EVERY dependency in package.json has a dir
# there. Stops a partial / wrong-deps tree (e.g. a harvested tree predating an added
# dependency) from being trusted and stamped with the current key.
deps_ok() {
  node -e '
    const fs=require("fs"), path=require("path");
    const pkg=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const nm=process.argv[2];
    for (const d of Object.keys(pkg.dependencies||{}))
      if (!fs.existsSync(path.join(nm,d))) process.exit(1);
    process.exit(0);
  ' "$PKG" "$1"
}

# import_ok <dir-with-node_modules>: exit 0 iff transformers imports from there.
import_ok() { ( cd "$1" && node --input-type=module -e 'await import("@huggingface/transformers"); console.log("ok")' ) 2>/dev/null | grep -q '^ok$'; }

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

# 1. Shared tree present, key-current, complete, importable → just (re)link and done.
if [ -f "$SHARED_MARKER" ] && [ "$HAVE_KEY" = "$WANT_KEY" ] && deps_ok "$SHARED_NM"; then
  link_version
  if import_ok "$MCP_DIR"; then
    echo "install-vector-deps: OK — shared deps reused, mcp/node_modules linked."
    exit 0
  fi
  echo "install-vector-deps: shared deps present but import failed — rebuilding (existing tree kept until the new one is ready)." >&2
fi

mkdir -p "$SHARED"

# Build the NEW tree in a private staging dir. The live $SHARED_NM and the symlink are
# NOT touched until staging validates, so a failed/offline npm install can never
# destroy a working install or leave a dangling symlink. A unique staging dir makes
# concurrent runs collision-free (last successful swap wins).
STAGE="$(mktemp -d "${SHARED%/}/.staging.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
STAGE_NM="$STAGE/node_modules"

# 2. Harvest an existing real per-version install instead of downloading — ONLY if it
#    actually satisfies the current dependency set.
if [ ! -L "$MCP_DIR/node_modules" ] \
   && [ -d "$MCP_DIR/node_modules/@huggingface/transformers" ] \
   && deps_ok "$MCP_DIR/node_modules"; then
  echo "install-vector-deps: harvesting existing mcp/node_modules -> staging (no download)."
  mv "$MCP_DIR/node_modules" "$STAGE_NM"
fi

# 3. No usable staged tree → npm install into staging.
if [ ! -f "$STAGE_NM/@huggingface/transformers/package.json" ] || ! deps_ok "$STAGE_NM"; then
  command -v npm >/dev/null 2>&1 || {
    echo "install-vector-deps: npm not found on PATH. Install Node.js + npm first." >&2
    echo "  Debian/Ubuntu/Pi:  sudo apt install -y nodejs npm" >&2
    exit 2
  }
  echo "install-vector-deps: installing runtime deps (staged) ..."
  echo "install-vector-deps: this needs network access and downloads ~70MB of native"
  echo "                     deps (onnxruntime-node, sharp). One-time; shared across versions."
  cp "$PKG" "$STAGE/package.json"
  ( cd "$STAGE" && npm install --omit=dev --no-audit --no-fund )
fi

# 4. Validate staging BEFORE swapping. If incomplete, abort WITHOUT touching the live
#    tree or symlink — they remain whatever they were (never half-destroyed).
if [ ! -f "$STAGE_NM/@huggingface/transformers/package.json" ] || ! deps_ok "$STAGE_NM"; then
  echo "install-vector-deps: staged build incomplete — leaving any existing install untouched." >&2
  echo "                     Inspect: cd $STAGE && npm ls @huggingface/transformers" >&2
  exit 3
fi

# 5. Swap staging into place, keeping the old tree as a backup until the new one lands.
cp "$PKG" "$SHARED/package.json"
rm -rf "$SHARED/node_modules.old"
[ -e "$SHARED_NM" ] && mv "$SHARED_NM" "$SHARED/node_modules.old"
mv "$STAGE_NM" "$SHARED_NM"
rm -rf "$SHARED/node_modules.old"
echo "$WANT_KEY" > "$KEY_FILE"

link_version

# 6. Final smoke-check through the symlink.
if import_ok "$MCP_DIR"; then
  echo "install-vector-deps: OK — shared deps installed and linked."
  echo "  Run an extractor cycle to populate embeddings:"
  echo "    rm $HOME/.second-brain/episodic-index.json   # one-time reset, indexer rebuilds"
  echo "    node $MCP_DIR/dist/tools/episodic-index-cli.bundle.js"
  exit 0
fi

echo "install-vector-deps: import still failing after install + link." >&2
echo "                     Inspect: ls -la $MCP_DIR/node_modules ; cd $MCP_DIR && npm ls @huggingface/transformers" >&2
exit 4
