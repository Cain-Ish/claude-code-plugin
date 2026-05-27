# Shared vector-deps Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Install the mcp vector deps (`@huggingface/transformers` + native binaries, 519 MB) ONCE into a version-independent shared dir and symlink each plugin version's `mcp/node_modules` at it, so version bumps re-link instead of re-downloading and old versions stop accumulating duplicate copies.

**Architecture:** A single rewritten Bash installer (`bin/install-vector-deps.sh`) that targets `~/.second-brain/vector-deps/` (override via `SB_VECTOR_DEPS_DIR`), keyed by a hash of `mcp/package.json` dependencies so it rebuilds only on a real dep change. It harvests an existing per-version `node_modules` (the old layout) instead of re-downloading on first run. The two existing consumers of `mcp/node_modules` are symlink-safe and untouched.

**Tech Stack:** Bash, npm, Node 20; structural Bash tests under `tests/` run by `make test`; `jq` for plugin.json.

**Spec:** `docs/specs/2026-05-27-shared-vector-deps-design.md`

**Branch:** `shared-vector-deps` (spec already committed there; off `main` at 0.19.0).

---

## Verification Outcomes (filled in by Task 0 — gates Task 1's symlink path)

- `SYMLINK_RESOLVES` = **yes** — Node resolved `import("@huggingface/transformers")`
  through a symlinked `mcp/node_modules` pointing at an out-of-tree shared dir (Task 0
  Step 1 printed `resolves`).
- `HARNESS_TOLERATES_SYMLINK` = **yes** — the harness ships `dist/` only and never
  creates/manages `node_modules` (gitignored); the live real `node_modules` persisted
  across the earlier `/reload-plugins`, so a symlink in the same spot is left alone.
- Both `yes` → the symlink path ships; the Task 1 Step 7 shim fallback is NOT needed.

---

## File Structure

| File | Responsibility | Tasks |
|------|----------------|-------|
| `bin/install-vector-deps.sh` | **Rewrite** — shared-dir install + deps-key + harvest + symlink | 1 |
| `tests/test-upgrade-vector-deps.sh` | **Extend** — `$HOME`/shared isolation + symlink/key/harvest assertions | 1 |
| `.claude-plugin/plugin.json` | Version → 0.20.0 | 2 |
| `skills/upgrade/SKILL.md` | Migration row for 0.20.0 | 2 |

---

## Task 0: Verify-first — symlink resolution + harness tolerance

**Files:** none (decision spike). Record results in "Verification Outcomes" above.

- [ ] **Step 1: Prove Node resolves through a symlinked `node_modules`**

```bash
T=$(mktemp -d)
mkdir -p "$T/shared/node_modules/@huggingface/transformers" "$T/mcp"
printf '{"name":"@huggingface/transformers","version":"0.0.0","main":"i.js","type":"module"}\n' \
  > "$T/shared/node_modules/@huggingface/transformers/package.json"
echo 'export default {};' > "$T/shared/node_modules/@huggingface/transformers/i.js"
ln -s "$T/shared/node_modules" "$T/mcp/node_modules"
( cd "$T/mcp" && node --input-type=module -e 'await import("@huggingface/transformers"); console.log("resolves")' )
rm -rf "$T"
```
Expected: prints `resolves`. → set `SYMLINK_RESOLVES = yes`. (If it errors, set `no`.)

- [ ] **Step 2: Confirm the harness doesn't manage `node_modules`**

The harness ships `dist/` and never `node_modules/` (gitignored), and the real
`node_modules` we created earlier survived a `/reload-plugins`. Confirm it's still a
real, intact dir under the live version (evidence the harness leaves it alone — a
symlink would be treated the same):

```bash
ls -ld ~/.claude/plugins/cache/second-brain/second-brain/0.19.0/mcp/node_modules
```
Expected: the dir exists. → set `HARNESS_TOLERATES_SYMLINK = yes` (harness does not
touch `node_modules`). If you can trigger a reload after placing a symlink and it
survives, even stronger; if the harness is found to wipe/replace it, set `no`.

- [ ] **Step 3: Record verdicts + commit**

Edit this file's "Verification Outcomes" with both values + a one-line note each.

```bash
git add docs/plans/2026-05-27-shared-vector-deps.md
git commit -m "chore(mcp): record shared-vector-deps verify-first (symlink/harness)"
```

---

## Task 1: Rewrite the installer for shared deps + symlink

**Files:**
- Modify (rewrite): `bin/install-vector-deps.sh`
- Modify (extend): `tests/test-upgrade-vector-deps.sh`

> If Task 0 set `SYMLINK_RESOLVES = no` or `HARNESS_TOLERATES_SYMLINK = no`, apply the
> Step 7 shim fallback instead of the symlink in the script and adjust the test's
> symlink assertion to the shim form. Otherwise implement as written.

- [ ] **Step 1: Replace the test with the shared-deps version**

Replace the entire contents of `tests/test-upgrade-vector-deps.sh` with:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-upgrade-vector-deps.sh`
Expected: FAIL on Test 1 (`mcp/node_modules is not a symlink`) — the current installer
installs a real dir in `mcp/`, ignores `SB_VECTOR_DEPS_DIR`, and makes no symlink.

- [ ] **Step 3: Rewrite the installer**

Replace the entire contents of `bin/install-vector-deps.sh` with:

```bash
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
fi

mkdir -p "$SHARED"

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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-upgrade-vector-deps.sh`
Expected: `ALL PASS` (Tests 1–6 each print PASS).

- [ ] **Step 5: Confirm the exec bit is retained**

Run: `git ls-files --stage bin/install-vector-deps.sh`
Expected: mode `100755`. If it shows `100644`, run `git update-index --chmod=+x bin/install-vector-deps.sh`. (The exec-bits gate lists `bin/install-vector-deps.sh`.)

- [ ] **Step 6: Run the exec-bits + full structural gates**

Run: `bash tests/test-exec-bits.sh && bash scripts/validate-plugin.sh`
Expected: both report success (`PASS: bin/install-vector-deps.sh → 100755`, `OK: all plugin files valid`).

- [ ] **Step 7 (FALLBACK — only if Task 0 said symlink is unsupported):** instead of
`link_version` symlinking, write `$MCP_DIR/.npmrc` (or export `NODE_PATH`) pointing
Node at `$SHARED_NM`, and change the test's `[ -L "$MCP_NM" ]` assertions to check the
shim file/var instead. Skip this step entirely if symlink works.

- [ ] **Step 8: Commit**

```bash
git add bin/install-vector-deps.sh tests/test-upgrade-vector-deps.sh
git commit -m "feat(mcp): shared vector-deps dir + per-version symlink (de-dupe node_modules)"
```

---

## Task 2: Release plumbing — version, migration row, full gate

**Files:**
- Modify: `.claude-plugin/plugin.json` (version)
- Modify: `skills/upgrade/SKILL.md` (migration table)

- [ ] **Step 1: Bump the version**

In `.claude-plugin/plugin.json`, change `"version": "0.19.0"` to `"version": "0.20.0"`.

- [ ] **Step 2: Add the migration row**

In `skills/upgrade/SKILL.md`, add a row immediately after the `| **0.19.0** | …` row:

```
| **0.20.0** | Shared vector-deps. `bin/install-vector-deps.sh` now installs `@huggingface/transformers` (+ native `onnxruntime-node`/`sharp`, ~519MB) ONCE into a version-independent shared dir (`~/.second-brain/vector-deps`, override `SB_VECTOR_DEPS_DIR`) keyed by a hash of `mcp/package.json` deps, and symlinks each version's `mcp/node_modules` at it. Version bumps re-link (milliseconds, no network) instead of re-downloading 519MB, and old versions no longer accumulate duplicate copies (was 4.7GB cache, ~4.1GB dead dupes). First post-0.20.0 run harvests any existing per-version `node_modules` (mv, no download). The vector-deps health check (re-runs every upgrade) drives this automatically; the two consumers (`session-load.sh` 0b `-d` test, upgrade `import()` check) are symlink-safe. Script/test-only — no user-state migration. | The vector-deps health check runs `install-vector-deps.sh`, which creates the shared dir + symlink on first run. Bumping the marker is sufficient. |
```

- [ ] **Step 3: Verify the migration-row gate**

Run: `bash tests/test-upgrade-migration-row.sh`
Expected: `PASS: upgrade migration row present for 0.20.0`.

- [ ] **Step 4: Run the full suite**

Run: `SB_RUN_ALL_VITEST=0 make test`
Expected: `ALL GREEN` (pass > 0, fail: 0). Run vitest separately if scoped out.

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/plugin.json skills/upgrade/SKILL.md
git commit -m "chore(release): shared vector-deps — bump 0.20.0 + migration row"
```

- [ ] **Step 6: Deep-review release gate (standing release rule)**

After the plugin cache refreshes to 0.20.0, run `/second-brain:code-review-deep` on this
branch (no `--comment`) and read the output. (Verification step — report the output;
not a commit gate. Until the cache refreshes, the installed pipeline is the older
version — note the plugin-cache-vs-repo gap.)

---

## Self-Review (completed by plan author)

- **Spec coverage:** shared dir + symlink → Task 1 (installer rewrite); deps-key
  rebuild-on-change → Task 1 (Test 4 + `WANT_KEY`); harvest optimization → Task 1
  (Test 5 + step 2 of the script); consumers unchanged → no task touches them (Test 6
  only re-asserts the upgrade wiring); verify-first (symlink + harness) → Task 0 with
  the shim fallback in Task 1 Step 7; offline benefit → inherent in the reuse/re-link
  path (Test 3); testing matrix → Task 1 Step 1; release plumbing → Task 2. No
  uncovered spec section.
- **Placeholder scan:** the only `TBD`s are the Task-0-filled Verification Outcomes
  (by design). Every code step shows the full file content.
- **Type/name consistency:** the env override `SB_VECTOR_DEPS_DIR`, the shared paths
  (`$SHARED`, `$SHARED_NM`, `$SHARED_MARKER`, `$KEY_FILE`), the `WANT_KEY`/`HAVE_KEY`
  names, and the `link_version`/`smoke` helpers are used identically in the script and
  asserted by matching paths in the test (`$TMP/shared/node_modules/...`, `readlink`
  target `$TMP/shared/node_modules`, `NPM_CALLS` count). The migration row version
  `0.20.0` matches the plugin.json bump and the migration-row test.
