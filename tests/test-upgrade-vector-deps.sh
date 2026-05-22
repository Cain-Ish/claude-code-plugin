#!/usr/bin/env bash
# Verify bin/install-vector-deps.sh installs the marker when missing and
# is idempotent on re-run. Uses an npm stub so we don't pull 70MB during CI.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Build a fake plugin root with mcp/ + bin/
mkdir -p "$TMP/plugin/mcp/dist" "$TMP/plugin/bin"
cp "$SCRIPT_DIR/bin/install-vector-deps.sh" "$TMP/plugin/bin/"

cat > "$TMP/plugin/mcp/package.json" <<'EOF'
{
  "name": "fake-mcp",
  "version": "1.0.0",
  "type": "module",
  "dependencies": { "@huggingface/transformers": "*" }
}
EOF

# Stub npm: pretend to install by creating the marker + a fake import target.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/npm" <<'EOF'
#!/usr/bin/env bash
# The script does `cd "$MCP_DIR" && npm install ...`, so cwd is the mcp dir.
MARKER="node_modules/@huggingface/transformers/package.json"
mkdir -p "$(dirname "$MARKER")"
echo '{"name":"@huggingface/transformers","version":"4.2.0","main":"index.js","type":"module"}' > "$MARKER"
echo 'export default {};' > "node_modules/@huggingface/transformers/index.js"
EOF
chmod +x "$TMP/bin/npm"
export PATH="$TMP/bin:$PATH"
export CLAUDE_PLUGIN_ROOT="$TMP/plugin"

MARKER="$TMP/plugin/mcp/node_modules/@huggingface/transformers/package.json"

# Test 1: marker missing → installer runs, marker now present
[ ! -f "$MARKER" ] || { echo "FAIL: marker pre-exists, test setup broken"; exit 1; }
bash "$TMP/plugin/bin/install-vector-deps.sh" >/dev/null 2>&1 \
  || { echo "FAIL: installer exited non-zero"; exit 1; }
[ -f "$MARKER" ] || { echo "FAIL: marker not created after install"; exit 1; }
echo "PASS: install-vector-deps creates marker when missing"

# Test 2: re-run is idempotent (smoke-import passes, exits 0 quickly)
START=$(date +%s)
bash "$TMP/plugin/bin/install-vector-deps.sh" >/dev/null 2>&1 \
  || { echo "FAIL: idempotent re-run exited non-zero"; exit 1; }
ELAPSED=$(( $(date +%s) - START ))
[ "$ELAPSED" -lt 5 ] || { echo "FAIL: re-run too slow (${ELAPSED}s) — should short-circuit"; exit 1; }
echo "PASS: idempotent re-run (${ELAPSED}s)"

# Test 3: SKILL.md migration table covers 2.9.0–2.10.3 and vector-deps health
grep -q "2.9.0.*2.10.3" "$SCRIPT_DIR/skills/upgrade/SKILL.md" \
  || { echo "FAIL: SKILL.md missing 2.9.0–2.10.3 catch-up row"; exit 1; }
grep -q "vector-deps health" "$SCRIPT_DIR/skills/upgrade/SKILL.md" \
  || { echo "FAIL: SKILL.md missing vector-deps health migration"; exit 1; }
grep -q "install-vector-deps.sh" "$SCRIPT_DIR/skills/upgrade/SKILL.md" \
  || { echo "FAIL: SKILL.md does not reference install-vector-deps.sh"; exit 1; }
echo "PASS: upgrade SKILL.md has catch-up + vector-deps rows"

echo "ALL PASS"
