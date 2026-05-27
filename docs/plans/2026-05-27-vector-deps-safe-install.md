# vector-deps safe-install (0.20.1 review-fix) Implementation Plan

> **For agentic workers:** Implement task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** Fix the findings the v0.20.0 dogfood surfaced in its own installer + pipeline — chiefly: a failed/offline `npm install` must never destroy a working vector-deps install or leave a dangling symlink.

**Architecture:** Rewrite `bin/install-vector-deps.sh` to a **stage → validate → atomic-swap** model: every rebuild is built in a private `mktemp` staging dir and proven (deps present + import) before the live shared tree or the per-version symlink is touched. Add a `sha256sum||shasum` fallback (macOS), a `deps_ok` completeness guard (so a harvested or partial tree is never trusted), and use per-run staging so concurrent runs can't corrupt each other. Plus three small prose fixes (review-skill dedup preference, wave-cap clarification, session-load banner wording) and a doc-snippet correction.

**Tech Stack:** Bash + Node 20 + npm; structural Bash tests via `make test`; `jq`.

**Source:** the 0.20.0 dogfood review (this session). Findings: F1 (dangling-symlink/destroyed-tree on failed reinstall, score 90), F3 (failure paths untested, 78), W1 (`sha256sum` GNU-only), F4 (harvest stamps key without validating), W2 (dedup may drop a regression's SHA), W3/I1 (invariant + wave-cap prose), I2 (stale banner text), I3 (concurrency — addressed via per-run staging, NOT a lock), doc drift.

**Branch:** `vector-deps-safe-install` (off `main` at 0.20.0).

---

## File Structure

| File | Change | Tasks |
|------|--------|-------|
| `bin/install-vector-deps.sh` | Rewrite: stage/validate/swap, `sha256` fallback, `deps_ok`, validated harvest, per-run staging | 1 |
| `tests/test-upgrade-vector-deps.sh` | Rewrite: deps-aware npm stub, failure-mode, no-destroy-on-failure, invalid-harvest, sha256-fallback assertions | 1 |
| `skills/code-review-deep/SKILL.md` | Pass 3 dedup prefers `regression` on collision (W2); wave-cap asymmetric-case sentence (I1) | 2 |
| `tests/test-code-review-deep.sh` | Assert the two SKILL additions | 2 |
| `scripts/session-load.sh` | Banner wording: symlink reality, not "ships dist/ not node_modules" (I2) | 3 |
| `docs/plans/2026-05-27-shared-vector-deps.md` | Snippet `require`→`readFileSync` (doc drift) | 4 |
| `.claude-plugin/plugin.json`, `skills/upgrade/SKILL.md` | 0.20.1 bump + migration row | 5 |

---

## Task 1: Safe stage/validate/swap installer + tests

**Files:** Modify `bin/install-vector-deps.sh`; Modify `tests/test-upgrade-vector-deps.sh`.

- [ ] **Step 1: Replace the test (red first)**

Replace the entire contents of `tests/test-upgrade-vector-deps.sh` with:

```bash
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
node -e '
  const fs=require("fs");
  const p=JSON.parse(fs.readFileSync("package.json","utf8"));
  for (const d of Object.keys(p.dependencies||{})) {
    fs.mkdirSync("node_modules/"+d,{recursive:true});
    fs.writeFileSync("node_modules/"+d+"/package.json",
      JSON.stringify({name:d,version:"0.0.0",main:"index.js",type:"module"}));
    fs.writeFileSync("node_modules/"+d+"/index.js","export default {};");
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

echo "ALL PASS"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-upgrade-vector-deps.sh`
Expected: FAIL — at minimum **T5** (`failed reinstall keeps the prior working tree + symlink intact`) and **T6** (`incomplete harvest rejected`), because the current installer clears `$SHARED_NM` before a reinstall and harvests without validating. (T4 may also fail: the old npm stub only made transformers, but this new stub makes all deps — so the *old* installer + new stub could pass T1-T4; the decisive reds are T5/T6/T8.)

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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-upgrade-vector-deps.sh`
Expected: `ALL PASS` (T1–T8).

- [ ] **Step 5: Confirm the exec bit, run exec-bits + validate gates**

Run: `git ls-files --stage bin/install-vector-deps.sh` → expect `100755` (else `git update-index --chmod=+x bin/install-vector-deps.sh`). Then `bash tests/test-exec-bits.sh && bash scripts/validate-plugin.sh` → both succeed.

- [ ] **Step 6: Commit**

```bash
git add bin/install-vector-deps.sh tests/test-upgrade-vector-deps.sh
git commit -m "fix(mcp): stage/validate/swap install — failed reinstall never destroys a working tree (F1/F3/F4/W1/I3)"
```

---

## Task 2: Review-skill dedup preference + wave-cap clarification

**Files:** Modify `skills/code-review-deep/SKILL.md`; Modify `tests/test-code-review-deep.sh`.

- [ ] **Step 1: Add assertions (red)**

In `tests/test-code-review-deep.sh`, immediately after the `FP write-back is user-dismissals-only` check block, insert:

```bash
  # v2.2.1: dedup must prefer the regression finding (with its commit SHA) on a
  # cross-pass collision, and the wave-cap prose must cover the asymmetric cases.
  grep -qi "prefer the \`regression\`" "$ORCH" \
    && ok "dedup prefers regression finding on collision" \
    || bad "dedup must prefer the regression-category finding on cross-pass collision"
  grep -qi "in every combination" "$ORCH" \
    && ok "wave-cap prose covers asymmetric pass combinations" \
    || bad "wave-cap note missing the asymmetric-combination clarification"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-code-review-deep.sh`
Expected: FAIL — `dedup must prefer the regression-category finding` and `wave-cap note missing the asymmetric-combination clarification`.

- [ ] **Step 3: Edit the dedup rule (W2)**

In `skills/code-review-deep/SKILL.md`, replace the Pass 3 dedup line:

```
1. **Dedup**: if a shared file produced the same finding in two units, keep the
   better-explained one.
```

with:

```
1. **Dedup**: if a shared file produced the same finding in two units, keep the
   better-explained one. On a cross-pass collision between a `regression` finding
   (Pass 2c, which cites a prior commit short-SHA) and a non-regression finding on
   the same line, prefer the `regression` one — its commit citation is what makes it
   actionable and would otherwise be lost.
```

- [ ] **Step 4: Edit the wave-cap note (I1)**

In `skills/code-review-deep/SKILL.md` Pass 2b, replace:

```
intact. When either advisory/history pass is skipped, its slot returns to
unit-reviewers. It depends only on Pass 1's unit list, not Pass 2's
```

with:

```
intact. When either advisory/history pass is skipped, its slot returns to
unit-reviewers (2b runs → ≤4 unit-reviewers + arch; 2c runs → ≤4 + history; both →
≤3 + both; neither → ≤5 unit-reviewers) — the ≤5 cap holds in every combination. It
depends only on Pass 1's unit list, not Pass 2's
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/test-code-review-deep.sh`
Expected: PASS the two new lines; final `PASS: <n>, FAIL: 0`.

- [ ] **Step 6: Commit**

```bash
git add skills/code-review-deep/SKILL.md tests/test-code-review-deep.sh
git commit -m "fix(code-review-deep): dedup prefers regression finding (W2); clarify wave-cap combinations (I1)"
```

---

## Task 3: session-load banner wording (I2)

**Files:** Modify `scripts/session-load.sh`.

- [ ] **Step 1: Correct the deps-absent reason + fix line**

In `scripts/session-load.sh` block 0b, replace the deps-absent `EPI_REASON` assignment:

```
      EPI_REASON='`@huggingface/transformers` is not installed in this plugin cache (a cache refresh ships dist/ but not node_modules/) — every NEW embedding will silently fail.'
```

with:

```
      EPI_REASON='`@huggingface/transformers` is not linked in this plugin cache — a version bump creates a fresh dir whose `mcp/node_modules` symlink to the shared deps is not yet created — so every NEW embedding will silently fail.'
```

And in the same block, replace the fix-line fragment `(one-time per cache version, ~70MB native deps)` with `(re-links the shared deps; downloads ~70MB only on the first ever install)`.

- [ ] **Step 2: Verify the embed-banner test still passes**

Run: `bash tests/test-session-load-embed-banner.sh`
Expected: PASS — the test asserts the `-d node_modules/@huggingface/transformers` *detection* (which a symlink still satisfies), not the reason wording, so the text change is safe.

- [ ] **Step 3: Commit**

```bash
git add scripts/session-load.sh
git commit -m "fix(session-load): banner wording reflects symlinked shared deps, not per-version install (I2)"
```

---

## Task 4: Doc-snippet drift

**Files:** Modify `docs/plans/2026-05-27-shared-vector-deps.md`.

- [ ] **Step 1: Match the shipped readFileSync form**

In `docs/plans/2026-05-27-shared-vector-deps.md`, find the line containing `const p=require(process.argv[1])` (Task 1 Step 3 snippet) and replace that `node -e` command with the shipped form:

```
WANT_KEY="$(node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(JSON.stringify(p.dependencies||{}))' "$PKG" | sha256sum | awk '{print $1}')"
```

(Historical plan doc; this just removes the require/readFileSync drift the dogfood flagged. No test.)

- [ ] **Step 2: Commit**

```bash
git add docs/plans/2026-05-27-shared-vector-deps.md
git commit -m "docs: correct shared-vector-deps plan snippet to shipped readFileSync form"
```

---

## Task 5: Release plumbing — 0.20.1

**Files:** Modify `.claude-plugin/plugin.json`; Modify `skills/upgrade/SKILL.md`.

- [ ] **Step 1: Bump version**

In `.claude-plugin/plugin.json`, change `"version": "0.20.0"` to `"version": "0.20.1"`.

- [ ] **Step 2: Add migration row**

In `skills/upgrade/SKILL.md`, add immediately after the `| **0.20.0** | …` row:

```
| **0.20.1** | vector-deps safe-install + dogfood review fixes. `bin/install-vector-deps.sh` rewritten to a stage→validate→atomic-swap model: a rebuild is built in a private `mktemp` staging dir and proven (all deps present + import works) BEFORE the live shared tree or the per-version symlink is touched, so a failed/offline `npm install` can no longer destroy a working install or leave a dangling symlink. Adds a `sha256sum`→`shasum -a 256` fallback (macOS), a `deps_ok` completeness guard (a harvested or partial tree is never trusted/stamped), and per-run staging (concurrent runs can't corrupt each other — no lock needed). Also: code-review-deep dedup now prefers a `regression` finding on a cross-pass collision (keeps its commit citation); wave-cap prose clarified; session-load embeddings banner wording reflects the symlink reality. Script/prompt/test-only — no user-state migration. | The vector-deps health check runs the new installer (idempotent). Bumping the marker is sufficient. |
```

- [ ] **Step 3: Migration-row gate**

Run: `bash tests/test-upgrade-migration-row.sh` → `PASS: upgrade migration row present for 0.20.1`.

- [ ] **Step 4: Full suite**

Run: `SB_RUN_ALL_VITEST=0 make test` → `ALL GREEN` (pass > 0, fail: 0).

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/plugin.json skills/upgrade/SKILL.md
git commit -m "chore(release): vector-deps safe-install — bump 0.20.1 + migration row"
```

- [ ] **Step 6: Deep-review release gate**

After the cache refreshes to 0.20.1, run `/second-brain:code-review-deep` (no `--comment`) over the range and read the output — re-dogfood to confirm F1/F4 are resolved and no new high-confidence findings remain. (Verification step; report output.)

---

## Self-Review (completed by plan author)

- **Coverage:** F1 → Task 1 (stage/validate/swap; T5 proves no-destroy-on-failure). F3 → Task 1 (npm-failure stub + T5). W1 → Task 1 (`sha256()` fallback; T8 asserts). F4 → Task 1 (`deps_ok` guards harvest + reuse; T6 proves incomplete harvest rebuilt). I3 → Task 1 (per-run `mktemp` staging; pushback on flock recorded in plan header/spec). W2 → Task 2. I1 → Task 2. W3 (invariant) → the test header comment + the negative-check comments already in `test-code-review-deep.sh`; the new dedup/wave assertions document intent. I2 → Task 3. doc drift → Task 4. Release → Task 5. F2 → made unreachable by `deps_ok` (Task 1), not separately fixed (correctly killed at score 8).
- **Placeholder scan:** none; every code step shows full content.
- **Type/name consistency:** `deps_ok`, `import_ok`, `sha256`, `link_version`, `$STAGE`/`$STAGE_NM`, `$SHARED_NM`, `SB_VECTOR_DEPS_DIR`, `NPM_FAIL`, `NPM_CALLS` are used identically in script and test. Sentinels asserted by tests exist verbatim in the edited files: `shasum -a 256` (T8), `prefer the \`regression\`` and `in every combination` (Task 2). Version `0.20.1` matches across plugin.json, the migration row, and the migration-row test.
```
