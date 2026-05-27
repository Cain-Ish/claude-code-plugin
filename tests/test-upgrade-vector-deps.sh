#!/usr/bin/env bash
# Verify bin/install-vector-deps.sh installs the vector deps ONCE into a shared
# dir and symlinks the version's mcp/node_modules at it. Uses an npm stub (no
# 70MB download) and SB_VECTOR_DEPS_DIR to keep the shared dir inside the tmp
# sandbox (never touches the real ~/.second-brain).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/plugin/mcp/dist" "$TMP/plugin/bin" "$TMP/shared"
cp "$SCRIPT_DIR/bin/install-vector-deps.sh" "$TMP/plugin/bin/"

cat > "$TMP/plugin/mcp/package.json" <<'EOF'
{
  "name": "fake-mcp",
  "version": "1.0.0",
  "type": "module",
  "dependencies": { "@huggingface/transformers": "*" }
}
EOF

# npm stub: records each call (count file) and "installs" by creating the marker +
# a fake import target in cwd/node_modules (the script runs npm in the shared dir).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/npm" <<'EOF'
#!/usr/bin/env bash
echo x >> "$NPM_CALLS"
MARKER="node_modules/@huggingface/transformers"
mkdir -p "$MARKER"
echo '{"name":"@huggingface/transformers","version":"4.2.0","main":"index.js","type":"module"}' > "$MARKER/package.json"
echo 'export default {};' > "$MARKER/index.js"
EOF
chmod +x "$TMP/bin/npm"

export PATH="$TMP/bin:$PATH"
export CLAUDE_PLUGIN_ROOT="$TMP/plugin"
export SB_VECTOR_DEPS_DIR="$TMP/shared"
export NPM_CALLS="$TMP/npm-calls"; : > "$NPM_CALLS"

MCP_NM="$TMP/plugin/mcp/node_modules"
SHARED_MARKER="$TMP/shared/node_modules/@huggingface/transformers/package.json"
calls() { wc -l < "$NPM_CALLS" | tr -d ' '; }

run() { bash "$TMP/plugin/bin/install-vector-deps.sh" >/dev/null 2>&1; }

# Test 1: fresh install → npm runs, shared marker created, mcp/node_modules is a symlink.
run || { echo "FAIL: installer exited non-zero on fresh install"; exit 1; }
[ -f "$SHARED_MARKER" ] || { echo "FAIL: shared marker not created"; exit 1; }
[ -L "$MCP_NM" ]        || { echo "FAIL: mcp/node_modules is not a symlink"; exit 1; }
[ "$(readlink "$MCP_NM")" = "$TMP/shared/node_modules" ] || { echo "FAIL: symlink does not point at shared node_modules"; exit 1; }
[ "$(calls)" = "1" ]    || { echo "FAIL: expected 1 npm call on fresh install, got $(calls)"; exit 1; }
echo "PASS: fresh install → shared dir + symlink (1 npm call)"

# Test 2: idempotent re-run → key matches, NO new npm call, still a symlink.
run || { echo "FAIL: idempotent re-run exited non-zero"; exit 1; }
[ "$(calls)" = "1" ] || { echo "FAIL: re-run re-downloaded (npm calls=$(calls), want 1)"; exit 1; }
[ -L "$MCP_NM" ]     || { echo "FAIL: re-run lost the symlink"; exit 1; }
echo "PASS: idempotent re-run reuses shared deps (no extra npm call)"

# Test 3: simulate a version bump → fresh version dir, no mcp/node_modules.
#         Must RE-LINK only, no download.
rm -f "$MCP_NM"
run || { echo "FAIL: re-link exited non-zero"; exit 1; }
[ "$(calls)" = "1" ] || { echo "FAIL: bump re-downloaded (npm calls=$(calls), want 1)"; exit 1; }
[ -L "$MCP_NM" ]     || { echo "FAIL: bump did not recreate the symlink"; exit 1; }
echo "PASS: version bump re-links without downloading"

# Test 4: deps-key mismatch (real dep change) → reinstall (npm runs again).
cat > "$TMP/plugin/mcp/package.json" <<'EOF'
{ "name": "fake-mcp", "version": "1.0.0", "type": "module",
  "dependencies": { "@huggingface/transformers": "*", "glob": "*" } }
EOF
run || { echo "FAIL: key-mismatch reinstall exited non-zero"; exit 1; }
[ "$(calls)" = "2" ] || { echo "FAIL: dep change did not trigger reinstall (npm calls=$(calls), want 2)"; exit 1; }
echo "PASS: dependency change triggers a shared reinstall"

# Test 5: harvest — pre-0.20.0 layout (real mcp/node_modules, empty shared) is moved,
#         not re-downloaded.
rm -rf "$TMP/shared" "$MCP_NM"; mkdir -p "$TMP/shared"
: > "$NPM_CALLS"
mkdir -p "$MCP_NM/@huggingface/transformers"
echo '{"name":"@huggingface/transformers","version":"4.2.0","main":"index.js","type":"module"}' > "$MCP_NM/@huggingface/transformers/package.json"
echo 'export default {};' > "$MCP_NM/@huggingface/transformers/index.js"
run || { echo "FAIL: harvest run exited non-zero"; exit 1; }
[ "$(calls)" = "0" ] || { echo "FAIL: harvest re-downloaded instead of moving (npm calls=$(calls), want 0)"; exit 1; }
[ -L "$MCP_NM" ]     || { echo "FAIL: harvest left mcp/node_modules a real dir, not a symlink"; exit 1; }
[ -f "$SHARED_MARKER" ] || { echo "FAIL: harvest did not populate the shared dir"; exit 1; }
echo "PASS: harvest moves an existing per-version install (no download)"

# Test 6: migration table still carries the (non-version-gated) vector-deps health row.
grep -q "vector-deps health" "$SCRIPT_DIR/skills/upgrade/SKILL.md" \
  || { echo "FAIL: SKILL.md missing vector-deps health migration"; exit 1; }
grep -q "install-vector-deps.sh" "$SCRIPT_DIR/skills/upgrade/SKILL.md" \
  || { echo "FAIL: SKILL.md does not reference install-vector-deps.sh"; exit 1; }
echo "PASS: upgrade SKILL.md still wires the vector-deps health check"

echo "ALL PASS"
