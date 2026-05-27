#!/usr/bin/env bash
# install-vector-deps.sh: shared dir + per-version symlink, with SAFE rebuilds
# (a failed npm must not destroy a working install). npm is stubbed (no 70MB pull);
# SB_VECTOR_DEPS_DIR sandboxes the shared dir. Invariant under test: the live shared
# tree and the symlink are only touched AFTER a staged rebuild validates.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/plugin/mcp/dist" "$TMP/plugin/bin" "$TMP/shared"
cp "$SCRIPT_DIR/bin/install-vector-deps.sh" "$TMP/plugin/bin/"

pkg() { cat > "$TMP/plugin/mcp/package.json"; }
pkg <<'EOF'
{ "name":"fake-mcp","version":"1.0.0","type":"module","dependencies":{"@huggingface/transformers":"*"} }
EOF

# npm stub: records calls; honors NPM_FAIL=1 to simulate a failed install; otherwise
# installs EVERY dependency named in ./package.json (cwd = staging dir).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/npm" <<'EOF'
#!/usr/bin/env bash
echo x >> "$NPM_CALLS"
[ "${NPM_FAIL:-0}" = "1" ] && { echo "npm: simulated failure" >&2; exit 1; }
# NPM_BREAK=1 installs all dep DIRS (so deps_ok passes) but a transformers entry
# that THROWS on import — simulates an ABI-broken tree that must not be trusted.
BREAK="${NPM_BREAK:-0}" node -e '
  const fs=require("fs");
  const broken=process.env.BREAK==="1";
  const p=JSON.parse(fs.readFileSync("package.json","utf8"));
  for (const d of Object.keys(p.dependencies||{})) {
    fs.mkdirSync("node_modules/"+d,{recursive:true});
    fs.writeFileSync("node_modules/"+d+"/package.json",
      JSON.stringify({name:d,version:"0.0.0",main:"index.js",type:"module"}));
    const body = (broken && d==="@huggingface/transformers")
      ? "throw new Error(\"broken abi\");" : "export default {};";
    fs.writeFileSync("node_modules/"+d+"/index.js", body);
  }
'
EOF
chmod +x "$TMP/bin/npm"

export PATH="$TMP/bin:$PATH"
export CLAUDE_PLUGIN_ROOT="$TMP/plugin"
export SB_VECTOR_DEPS_DIR="$TMP/shared"
export NPM_CALLS="$TMP/npm-calls"; : > "$NPM_CALLS"

MCP_NM="$TMP/plugin/mcp/node_modules"
SHARED_NM="$TMP/shared/node_modules"
SHARED_MARKER="$SHARED_NM/@huggingface/transformers/package.json"
calls() { wc -l < "$NPM_CALLS" | tr -d ' '; }
run() { bash "$TMP/plugin/bin/install-vector-deps.sh" >/dev/null 2>&1; }

# T1: fresh install → npm runs once, shared marker present, mcp/node_modules symlink.
run || { echo "FAIL T1: installer non-zero"; exit 1; }
[ -f "$SHARED_MARKER" ] || { echo "FAIL T1: no shared marker"; exit 1; }
[ -L "$MCP_NM" ] && [ "$(readlink "$MCP_NM")" = "$SHARED_NM" ] || { echo "FAIL T1: symlink wrong"; exit 1; }
[ "$(calls)" = "1" ] || { echo "FAIL T1: want 1 npm call, got $(calls)"; exit 1; }
echo "PASS T1: fresh install → shared + symlink"

# T2: idempotent reuse → no new npm call.
run || { echo "FAIL T2: non-zero"; exit 1; }
[ "$(calls)" = "1" ] || { echo "FAIL T2: reused but npm ran ($(calls))"; exit 1; }
echo "PASS T2: idempotent reuse (no download)"

# T3: version bump (symlink gone) → re-link, no npm.
rm -f "$MCP_NM"; run || { echo "FAIL T3: non-zero"; exit 1; }
[ "$(calls)" = "1" ] || { echo "FAIL T3: bump re-downloaded ($(calls))"; exit 1; }
[ -L "$MCP_NM" ] || { echo "FAIL T3: no symlink after bump"; exit 1; }
echo "PASS T3: version bump re-links, no download"

# T4: deps-key change (add glob) → reinstall; glob present.
pkg <<'EOF'
{ "name":"fake-mcp","version":"1.0.0","type":"module","dependencies":{"@huggingface/transformers":"*","glob":"*"} }
EOF
run || { echo "FAIL T4: non-zero"; exit 1; }
[ "$(calls)" = "2" ] || { echo "FAIL T4: dep change did not reinstall ($(calls))"; exit 1; }
[ -d "$SHARED_NM/glob" ] || { echo "FAIL T4: glob missing after reinstall"; exit 1; }
echo "PASS T4: dependency change reinstalls (glob present)"

# T5: NPM FAILURE on a forced rebuild must NOT destroy the working tree or dangle the symlink.
#     Force a rebuild via another dep-key change, with npm failing.
pkg <<'EOF'
{ "name":"fake-mcp","version":"1.0.0","type":"module","dependencies":{"@huggingface/transformers":"*","glob":"*","zod":"*"} }
EOF
NPM_FAIL=1 run && { echo "FAIL T5: installer should have failed under NPM_FAIL"; exit 1; }
[ -f "$SHARED_MARKER" ] || { echo "FAIL T5: prior shared tree destroyed by failed reinstall"; exit 1; }
[ -L "$MCP_NM" ] && [ "$(readlink "$MCP_NM")" = "$SHARED_NM" ] || { echo "FAIL T5: symlink dangling/changed after failure"; exit 1; }
( cd "$TMP/plugin/mcp" && node --input-type=module -e 'await import("@huggingface/transformers")' ) 2>/dev/null \
  || { echo "FAIL T5: prior install no longer importable after failed reinstall"; exit 1; }
[ ! -e "$SHARED_NM/zod" ] || { echo "FAIL T5: a failed install partially applied (zod present)"; exit 1; }
echo "PASS T5: failed reinstall keeps the prior working tree + symlink intact"

# T6: invalid harvest — a real mcp/node_modules missing a required dep must NOT be
#     trusted; the installer falls back to npm (which installs the full set).
rm -rf "$TMP/shared" "$MCP_NM"; mkdir -p "$TMP/shared"; : > "$NPM_CALLS"
pkg <<'EOF'
{ "name":"fake-mcp","version":"1.0.0","type":"module","dependencies":{"@huggingface/transformers":"*","glob":"*"} }
EOF
mkdir -p "$MCP_NM/@huggingface/transformers"
echo '{"name":"@huggingface/transformers","version":"4.2.0","main":"index.js","type":"module"}' > "$MCP_NM/@huggingface/transformers/package.json"
echo 'export default {};' > "$MCP_NM/@huggingface/transformers/index.js"   # NOTE: no glob
run || { echo "FAIL T6: non-zero"; exit 1; }
[ "$(calls)" -ge 1 ] || { echo "FAIL T6: incomplete tree was harvested without rebuild ($(calls))"; exit 1; }
[ -d "$SHARED_NM/glob" ] || { echo "FAIL T6: rebuild did not supply the missing dep"; exit 1; }
[ -L "$MCP_NM" ] || { echo "FAIL T6: no symlink after rebuild"; exit 1; }
echo "PASS T6: incomplete harvest rejected, rebuilt to a complete tree"

# T7: valid harvest — a complete real mcp/node_modules is moved, not re-downloaded.
rm -rf "$TMP/shared" "$MCP_NM"; mkdir -p "$TMP/shared"; : > "$NPM_CALLS"
for d in @huggingface/transformers glob; do
  mkdir -p "$MCP_NM/$d"
  echo "{\"name\":\"$d\",\"version\":\"0.0.0\",\"main\":\"index.js\",\"type\":\"module\"}" > "$MCP_NM/$d/package.json"
  echo 'export default {};' > "$MCP_NM/$d/index.js"
done
run || { echo "FAIL T7: non-zero"; exit 1; }
[ "$(calls)" = "0" ] || { echo "FAIL T7: complete harvest re-downloaded ($(calls))"; exit 1; }
[ -L "$MCP_NM" ] && [ -f "$SHARED_MARKER" ] && [ -d "$SHARED_NM/glob" ] || { echo "FAIL T7: harvest did not populate shared"; exit 1; }
echo "PASS T7: complete harvest moves the tree (no download)"

# T8: portability + wiring — sha256 fallback present; SKILL still wires the health check.
grep -q 'shasum -a 256' "$SCRIPT_DIR/bin/install-vector-deps.sh" \
  || { echo "FAIL T8: no shasum fallback for non-GNU (macOS) hosts"; exit 1; }
grep -q "vector-deps health" "$SCRIPT_DIR/skills/upgrade/SKILL.md" \
  && grep -q "install-vector-deps.sh" "$SCRIPT_DIR/skills/upgrade/SKILL.md" \
  || { echo "FAIL T8: upgrade SKILL.md lost the vector-deps health wiring"; exit 1; }
echo "PASS T8: sha256 fallback + upgrade wiring present"

# T9: a staged tree with all dep DIRS but a non-importable transformers (ABI break)
#     must NOT be swapped in or key-stamped — the prior working tree + key stay intact
#     (prevents the "key poisoning" re-download loop).
rm -rf "$TMP/shared" "$MCP_NM"; mkdir -p "$TMP/shared"; : > "$NPM_CALLS"
pkg <<'EOF'
{ "name":"fake-mcp","version":"1.0.0","type":"module","dependencies":{"@huggingface/transformers":"*"} }
EOF
run || { echo "FAIL T9 setup: clean baseline install failed"; exit 1; }
KEY_BEFORE="$(cat "$TMP/shared/.deps-key")"
pkg <<'EOF'
{ "name":"fake-mcp","version":"1.0.0","type":"module","dependencies":{"@huggingface/transformers":"*","glob":"*"} }
EOF
NPM_BREAK=1 run && { echo "FAIL T9: installer accepted a non-importable staged tree"; exit 1; }
( cd "$TMP/plugin/mcp" && node --input-type=module -e 'await import("@huggingface/transformers")' ) 2>/dev/null \
  || { echo "FAIL T9: prior working tree no longer imports after a broken rebuild"; exit 1; }
[ "$(cat "$TMP/shared/.deps-key")" = "$KEY_BEFORE" ] \
  || { echo "FAIL T9: deps-key stamped despite a non-importable tree (poisoning)"; exit 1; }
[ ! -e "$SHARED_NM/glob" ] || { echo "FAIL T9: broken staged tree was swapped in (glob present)"; exit 1; }
echo "PASS T9: non-importable staged tree rejected; prior tree + key intact"

# T10: stale staging dirs from a hard-killed run are swept, not accumulated.
mkdir -p "$TMP/shared/.staging.deadbeef/node_modules"
run || { echo "FAIL T10: non-zero"; exit 1; }
ls -d "$TMP/shared"/.staging.* >/dev/null 2>&1 && { echo "FAIL T10: stale staging dir not swept"; exit 1; }
echo "PASS T10: stale staging dirs swept"

echo "ALL PASS"
