# Design: shared vector-deps (de-duplicate mcp `node_modules` across versions)

**Date:** 2026-05-27
**Status:** Approved (design) — pending implementation plan
**Author:** second-brain session
**Target release:** 0.20.0

## Summary

The episodic vector indexer needs `@huggingface/transformers` (+ its native
`onnxruntime-node` / `sharp` binaries), which esbuild marks `--external` and the
plugin cache never ships (`node_modules/` is gitignored; the cache ships `dist/`
only). `bin/install-vector-deps.sh` fills the gap by running `npm install` **inside
the installed version's `mcp/` dir** — i.e. `~/.claude/plugins/cache/second-brain/
second-brain/<version>/mcp/node_modules` — which is **519 MB per version**.

Two consequences, both measured on the dev box (2026-05-27):

- **Every version bump re-downloads** ~70 MB and rebuilds a fresh 519 MB tree (the
  new `<version>/` dir starts with no `node_modules`).
- **Old versions keep their copies.** 8 stale version dirs each held a full 519 MB —
  the second-brain cache had grown to **4.7 GB**, of which only the live version
  (~524 MB) was in use. ~4.1 GB was dead duplicate deps (pruned manually as the
  immediate fix; this spec is the durable fix so it never recurs).

The fix: install the dep tree **once** into a version-independent shared dir and
**symlink** each version's `mcp/node_modules` at it. Disk holds one 519 MB copy
ever; version bumps re-link instead of re-download.

## Goals

- One on-disk copy of the vector deps, shared across all installed versions.
- Version bumps cost a symlink (milliseconds, no network), not a 70 MB download.
- Better offline behaviour than today: once the shared dir is populated, bumps need
  no network at all.
- No changes to the MCP bundle or to the two existing consumers of the
  `mcp/node_modules` path.

## Non-goals (YAGNI)

- **No pnpm / alternative package manager.** A content-addressed global store would
  dedup via hardlinks but requires installing `pnpm` — an extra system dep against
  the minimal-deps/offline posture. Rejected.
- **No partial hoist** of just the native packages — symlinking the whole
  `node_modules` is simpler for equal benefit.
- **No separate garbage-collector.** Once deps are symlinked, no version holds a real
  `node_modules`, so accumulation cannot recur. The already-orphaned copies were
  pruned manually; no recurring GC step is needed.
- **No change to `ensure-dirs.sh`** beyond (optionally) creating the shared dir.

## Current consumers of `mcp/node_modules` (must keep working)

Both are **symlink-safe** (verified by reading them), so this design touches neither:

1. **`skills/upgrade/SKILL.md` vector-deps health check** — `cd "$CLAUDE_PLUGIN_ROOT/mcp"
   && node ... import("@huggingface/transformers")`. Resolves through a symlinked
   `node_modules` (Node follows symlinks during resolution).
2. **`scripts/session-load.sh` block 0b** — `[ ! -d "$CLAUDE_PLUGIN_ROOT/mcp/node_modules/@huggingface/transformers" ]`.
   `test -d` follows symlinks, so a symlinked tree passes.

## Architecture

### Shared location

`~/.second-brain/vector-deps/` containing:
- `package.json` — copied from the installed version's `mcp/package.json` at install
  time (so `npm install` there resolves the same dependency set).
- `node_modules/` — the single shared dep tree.
- `.deps-key` — a hash of the `dependencies` block of `mcp/package.json`, used to
  detect when a real dependency change requires a rebuild.

*Why `~/.second-brain/` and not the cache:* it is the plugin's own data home, it
survives cache wipes and version bumps, and `ensure-dirs.sh` already owns it. A
cache-sibling dir would live inside the harness-managed cache tree (less stable,
and a candidate for harness GC).

### `bin/install-vector-deps.sh` rewrite

The only behavioural change. New flow:

1. Resolve `MCP_DIR="$PLUGIN_ROOT/mcp"` and `SHARED="$HOME/.second-brain/vector-deps"`.
2. Compute `WANT_KEY` = stable hash (e.g. `sha256`) of the `dependencies` object in
   `$MCP_DIR/package.json`.
3. **Ensure shared deps:** if `$SHARED/node_modules/@huggingface/transformers` exists
   **and** `$SHARED/.deps-key` == `$WANT_KEY` → reuse (no download). Else:
   - **Harvest optimization (avoids the one-time transition download):** if
     `$MCP_DIR/node_modules` is a **real directory** (not a symlink) already
     containing `@huggingface/transformers` — i.e. an existing pre-0.20.0 install —
     `mv` it to `$SHARED/node_modules` instead of downloading, then proceed to link.
   - Otherwise: create `$SHARED`, copy `$MCP_DIR/package.json` → `$SHARED/package.json`,
     run `npm install --omit=dev --no-audit --no-fund` in `$SHARED`. (Report the
     ~70 MB network requirement before this download, as today.)
   - Either way, write `$WANT_KEY` → `$SHARED/.deps-key`.
4. **Link the version at the shared tree:** if `$MCP_DIR/node_modules` exists and is
   a real directory, remove it; create symlink `$MCP_DIR/node_modules` → `$SHARED/node_modules`.
   (If it is already the correct symlink, leave it.)
5. **Smoke-check:** `cd "$MCP_DIR" && node --input-type=module -e 'await import("@huggingface/transformers")'`
   — resolves through the symlink. Fail loudly (non-zero exit) if it does not.

Idempotent: re-running with deps present + key matching + symlink correct is a
no-op. A bump (fresh `<version>/mcp` with no `node_modules`) hits step 4 only →
re-link, no download.

### Failure / fallback

If the verify-first step finds the harness clobbers or rejects a symlinked
`node_modules` inside a cache version dir, fall back to leaving `node_modules` a real
dir but pointing Node at the shared tree via a `mcp/.npmrc` or `NODE_PATH` shim. The
spec's primary path is the symlink; the shim is the contingency.

## Verify-first (implementation plan Task 0)

1. **Symlink resolution:** in a scratch dir, symlink `mcp/node_modules` → a populated
   shared tree and confirm `import("@huggingface/transformers")` resolves. Expected
   yes (Node follows symlinks).
2. **Harness tolerance:** confirm a symlinked `node_modules` inside
   `cache/second-brain/second-brain/<version>/mcp/` is not clobbered or rejected by
   the harness on load/reload. If it is → use the shim fallback.

Record both verdicts in the plan before implementing step 4.

## Testing

`tests/test-install-vector-deps-shared.sh` (npm stubbed so no real download):

- Install target is `$HOME/.second-brain/vector-deps`, not the version's `mcp/`.
- After a run, `<plugin>/mcp/node_modules` is a **symlink** resolving to the shared
  `node_modules`.
- A matching `.deps-key` → reinstall is **skipped** (npm stub not called).
- A mismatched `.deps-key` → reinstall **runs** (npm stub called) and the key is
  rewritten.
- Smoke-check passes when the shared tree contains the package; fails (non-zero) when
  it does not.

The existing exec-bits / validate-plugin gates continue to apply.

## Release plumbing

- Bump `.claude-plugin/plugin.json` → `0.20.0`.
- `skills/upgrade/SKILL.md`: the vector-deps health row already re-runs every upgrade
  and calls `install-vector-deps.sh`; add a `0.20.0` migration row describing the
  shared-deps move (prompt/script/test-only — no user-state migration; the first
  post-0.20.0 run of the health check creates the shared dir and re-links).
- README: no catalog change (internal infra), unless a one-line note is wanted.
- Run the standing deep-review release gate after the cache refreshes to 0.20.0.

## Open risks

- **Harness symlink tolerance** (primary) — mitigated by the verify-first gate + shim
  fallback.
- **Concurrent installs** — two sessions running the health check at once could race
  on the shared dir. Low likelihood; mitigate with a simple lock/temp-dir-rename
  (install into `$SHARED.tmp` then atomic `mv`), or accept npm's own idempotence.
  Decide in the plan.
- **`npm install` in a bare shared dir** — needs the copied `package.json`; without a
  lockfile npm resolves latest-in-range. Acceptable (same as today's in-`mcp` install,
  which also has no committed lock for the external dep). If reproducibility matters
  later, copy a lockfile too.

## Decision log

1. **Shared dir + symlink**, not pnpm (extra dep) or partial hoist (complexity).
2. **Location `~/.second-brain/vector-deps/`** — plugin data home, survives cache
   wipes, already managed by `ensure-dirs.sh`.
3. **`.deps-key` = hash of `mcp/package.json` dependencies** — rebuild the shared tree
   only on a real dependency change, not on every version bump.
4. **No GC step** — symlinking makes per-version accumulation structurally impossible.
5. **Consumers unchanged** — both are symlink-safe; verified by reading them.
6. **Symlink primary, NODE_PATH/.npmrc shim fallback** — gated on the verify-first
   harness-tolerance check.
7. **Own release (0.20.0)** — one concern per release.
