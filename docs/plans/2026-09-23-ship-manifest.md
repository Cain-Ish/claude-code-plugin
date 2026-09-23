# Ship manifest — what a marketplace install receives

**Status: IMPLEMENTED 2026-09-23.** Decision: option A below, chosen by the maintainer.

## Problem

`marketplace.json` pointed installs at `source: "./"`, so every `/plugin install` copied the whole
repository into the user's plugin cache: 530 tracked files, ~8 MB, of which ~4.5 MB is dev material
(`tests/`, `docs/`, `mcp/src/`, `.claude/` dev skills, `.superpowers/`, `.codex/`, the constitution
and release notes). Claude Code copies the `source` directory in full; there is no `.pluginignore`,
no `files` allowlist in `plugin.json`, and a copied plugin cannot reference files outside its own
directory (docs: plugins-reference, plugin-marketplaces). The only lever is which directory
`source` names.

## Options considered

- **A. Committed `plugin/` built from a manifest (chosen).** `.claude-plugin/ship-manifest.txt`
  is the allowlist; `scripts/build-plugin.sh` assembles `plugin/` (atomic swap, `--check` mode);
  `tests/test-plugin-dist-current.sh` fails when `plugin/` drifts from a fresh build, when any
  dev-only tree leaks in, or when a hook script / skill / agent / manifest is missing from it.
  Cost: the runtime tree exists twice in the repo (~4.5 MB), rebuilt on each release commit.
  No CI token or workflow change; the dev loop (`second-brain@local`, `path: "."`) is untouched.
- **B. Generated release branch.** `make release` builds the tree and pushes it to `release`;
  marketplace.json uses a `github` source with `ref: release`. No duplication, but a write-capable
  release step outside the current read-only CI posture, and two install routes to keep in sync.
- **C. Move the runtime into `plugin/` as the source of truth.** Cleanest long-term; ~170 test
  files and every `$ROOT/scripts` reference change at once, on a repo whose vitest/esbuild could
  not be run in the authoring sandbox. Deferred until it can be done with the full suite green.

## What ships (manifest)

`.claude-plugin/{plugin.json,mcp.json}`, `hooks/hooks.json`, `skills/`, `agents/`, `output-styles/`,
`scripts/`, `bin/`, `mcp/dist/**/*.bundle.js`, `mcp/package.json`, `mcp/package-lock.json`
(install-vector-deps needs them), `kb-schema.json`, `model-ladder.json`, `systemd/`, `LICENSE`,
`NOTICE.md`, plus a generated `README.md` and `.ship-manifest.lock` (the file list). 137 files.

Not shipped: `tests/`, `docs/`, `mcp/src/`, `mcp/node_modules/`, `.claude/`, `.superpowers/`,
`.codex/`, `.agents/`, `.github/`, `.githooks/`, `CONSTITUTION.md`, `RELEASING.md`, `Makefile`,
`hooks/hooks.notes.md`, `marketplace.json`, `surface-budget.json`, the manifest itself.

## Invariants the gate holds

1. `marketplace.json plugins[0].source == "./plugin"`.
2. `plugin/` is byte-identical to `build-plugin.sh --check`'s fresh build.
3. No dev-only tree or file is present in `plugin/`; no `*.test.ts`, stackdumps, `.DS_Store`.
4. Every script `hooks.json` runs, every skill, agent, output style and manifest is present;
   `plugin.json` versions match between root and `plugin/`.

## Follow-ups

- `scripts/validate-plugin.sh` and `scripts/build-plugin.sh` ship with the rest of `scripts/`
  (dev-only, harmless). A `scripts/dev/` split would let the manifest drop them; not worth a
  164-test path churn today.
- The plugin cache layout (`cache/<marketplace>/second-brain/<version>/`) is unchanged, so the
  extract-drain and buddy shims that resolve the newest version keep working.
