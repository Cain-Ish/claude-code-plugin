# Local Doc-Sources — Phase 2: SessionStart discovery wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.

**Goal:** Make the Phase-1 registry core actually run — a bundled `doc-sources-cli` invokes `buildRegistry`, and a `discover-doc-sources.sh` SessionStart hook runs it for the active project (only when the project has declared doc locations).

**Architecture:** `doc-sources-cli.ts` is a thin entry (env `BRAIN_DIR` + argv `projectRoot`/`slug` → `buildRegistry`). The hook resolves slug via `sb_resolve_slug`, runs the CLI **in the foreground** (the scan is fast — hash+gist only, no embeddings — so it's testable and doesn't need backgrounding), and **exits immediately when the project has no `doc-sources.config.json`** (zero cost for projects not using the feature). Registered in `hooks.json` SessionStart after `discover-installed.sh`.

**Tech Stack:** TypeScript (ESM, bundled by esbuild), bash hook, shell test. Reuses Phase-1 `buildRegistry`.

**Build/test (from repo root unless noted):** bundle `cd mcp && npm run build`; vitest `cd mcp && npm test`; shell test `bash tests/test-doc-sources-hook.sh`; aggregate `bash tests/run-all.sh`.
**Commit:** Conventional Commits + trailer `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`. Commit directly to `main`.

**Scope:** Phase 2 of 4. Phase 3 = `knowledge_search`/`knowledge_fetch` merge; Phase 4 = `/second-brain:track` skill. No retrieval changes here — this phase only *populates* the registry.

---

### Task 1: `doc-sources-cli.ts` + bundle wiring

**Files:**
- Create: `mcp/src/tools/doc-sources-cli.ts`
- Modify: `mcp/package.json` (esbuild bundle list)

- [ ] **Step 1: create the CLI entry** `mcp/src/tools/doc-sources-cli.ts`:
```ts
import { homedir } from 'os';
import { join } from 'path';
import { buildRegistry } from './doc-sources.js';

// Thin entry: BRAIN_DIR from env, projectRoot + slug from argv. Invoked by
// scripts/discover-doc-sources.sh at SessionStart. Fail-soft (always exit 0).
async function main(): Promise<void> {
  const brainDir = process.env.BRAIN_DIR || join(homedir(), '.second-brain');
  const projectRoot = process.argv[2] || process.cwd();
  const slug = process.argv[3];
  if (!slug) { process.stderr.write('doc-sources-cli: missing slug arg\n'); return; }
  try {
    const reg = await buildRegistry(projectRoot, brainDir, slug);
    process.stderr.write(`doc-sources: ${reg.entries.length} entries for ${reg.project}\n`);
  } catch (e) {
    process.stderr.write(`doc-sources-cli error: ${e instanceof Error ? e.message : String(e)}\n`);
  }
}

main();
```
(Note: this module is only ever executed as a bundle, never imported by tests, so a top-level `main()` is safe. It writes only to **stderr** — stdout stays clean.)

- [ ] **Step 2: add to the esbuild bundle list** in `mcp/package.json`. The `"bundle"` script is a chain of `esbuild … && esbuild …`. Append one more, mirroring the existing `episodic-index-cli` entry exactly (same flags, including `--external:@huggingface/transformers` and the format/target/banner the chain uses):
```
&& esbuild src/tools/doc-sources-cli.ts --bundle --platform=node --target=node20 --format=esm --external:@huggingface/transformers --outfile=dist/tools/doc-sources-cli.bundle.js
```
Insert it into the existing `&&` chain (e.g., right after the `episodic-search-cli` esbuild call). Keep it one continuous script string.

- [ ] **Step 3: build** — `cd mcp && npm run build`. Expect `tsc` exit 0 and the new bundle emitted.

- [ ] **Step 4: verify the bundle exists + is runnable** —
```bash
cd mcp && test -f dist/tools/doc-sources-cli.bundle.js && echo "bundle present"
# smoke: run against a throwaway project with a config
T=$(mktemp -d); B=$(mktemp -d); mkdir -p "$B/projects/smoke" "$T/docs"
printf '{"locations":["docs/"]}' > "$B/projects/smoke/doc-sources.config.json"
printf '# Smoke\n\nbody\n' > "$T/docs/s.md"
BRAIN_DIR="$B" node dist/tools/doc-sources-cli.bundle.js "$T" "smoke" 2>&1
test -f "$B/projects/smoke/doc-sources.json" && echo "registry written" && cat "$B/projects/smoke/doc-sources.json" | head -c 300
rm -rf "$T" "$B"
```
Expected: `bundle present`, `doc-sources: 1 entries for smoke`, `registry written`, and the JSON shows the `docs/s.md` entry.

- [ ] **Step 5: full vitest suite (no regressions)** — `cd mcp && npm test` → all green.

- [ ] **Step 6: commit (source + regenerated dist)**
```bash
git add mcp/src/tools/doc-sources-cli.ts mcp/package.json mcp/dist
git commit -m "$(printf 'feat(doc-sources): bundled CLI invoking buildRegistry (phase 2)\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: SessionStart hook + `hooks.json` wiring + shell test

**Files:**
- Create: `scripts/discover-doc-sources.sh`
- Modify: `hooks/hooks.json` (SessionStart array)
- Create: `tests/test-doc-sources-hook.sh`

- [ ] **Step 1: create the hook** `scripts/discover-doc-sources.sh`:
```bash
#!/bin/bash
# discover-doc-sources.sh — SessionStart hook. Rebuilds the active project's
# local doc-source registry (docs the user declared via doc-sources.config.json).
# Zero cost when the project has no config. Always exits 0 (fail-soft).
set -u

LIB="$(dirname "$0")/lib.sh"
source "$LIB" 2>/dev/null || exit 0

RAW=$(cat 2>/dev/null || true)
CWD=$(printf '%s' "$RAW" | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r')
{ [ -z "$CWD" ] || [ ! -d "$CWD" ]; } && CWD="$PWD"

SLUG=$(sb_resolve_slug "$CWD")
[ -z "$SLUG" ] && exit 0

CONFIG="$BRAIN_DIR/projects/$SLUG/doc-sources.config.json"
[ -f "$CONFIG" ] || exit 0   # feature not enabled for this project

CLI="$(dirname "$0")/../mcp/dist/tools/doc-sources-cli.bundle.js"
if command -v node >/dev/null 2>&1 && [ -f "$CLI" ]; then
  BRAIN_DIR="$BRAIN_DIR" node "$CLI" "$CWD" "$SLUG" 2>/dev/null || true
fi
exit 0
```
Make it executable: `chmod +x scripts/discover-doc-sources.sh`.

- [ ] **Step 2: register in `hooks/hooks.json`** — add `discover-doc-sources.sh` to the `SessionStart` hooks array, **after** the `discover-installed.sh` entry, following the exact JSON shape of the sibling entries (same `command` form using `${CLAUDE_PLUGIN_ROOT}` / the path style already used there — match the existing entries verbatim). Validate JSON after: `jq . hooks/hooks.json >/dev/null && echo "hooks.json valid"`.

- [ ] **Step 3: write the failing shell test** `tests/test-doc-sources-hook.sh` (follow the style of existing `tests/*.sh` — set up temp dirs, run, assert, print PASS/FAIL, exit non-zero on failure):
```bash
#!/bin/bash
set -u
FAIL=0
HERE="$(cd "$(dirname "$0")/.." && pwd)"

BRAIN=$(mktemp -d); PROJ=$(mktemp -d)
SLUG="$(basename "$PROJ")"
mkdir -p "$BRAIN/projects/$SLUG" "$PROJ/docs"
# pin the slug so sb_resolve_slug is deterministic in the test
printf '%s' "$SLUG" > "$BRAIN/.active-session-slug"
# the pin requires a PROJECT.md to be honored
printf '# PROJECT: %s\n' "$SLUG" > "$BRAIN/projects/$SLUG/PROJECT.md"
printf '{"locations":["docs/"]}' > "$BRAIN/projects/$SLUG/doc-sources.config.json"
printf '# Deploy\n\n## Steps\n\ndo it\n' > "$PROJ/docs/deploy.md"

# run the hook with a SessionStart-style payload
printf '{"cwd":"%s"}' "$PROJ" | BRAIN_DIR="$BRAIN" bash "$HERE/scripts/discover-doc-sources.sh"

REG="$BRAIN/projects/$SLUG/doc-sources.json"
if [ -f "$REG" ] && jq -e '.entries[] | select(.rel=="docs/deploy.md")' "$REG" >/dev/null 2>&1; then
  echo "PASS: hook built registry with docs/deploy.md"
else
  echo "FAIL: registry missing or entry absent"; FAIL=1
fi

# config-absent → zero cost (no registry written)
BRAIN2=$(mktemp -d); PROJ2=$(mktemp -d); SLUG2="$(basename "$PROJ2")"
mkdir -p "$BRAIN2/projects/$SLUG2"; printf '%s' "$SLUG2" > "$BRAIN2/.active-session-slug"
printf '# PROJECT: %s\n' "$SLUG2" > "$BRAIN2/projects/$SLUG2/PROJECT.md"
printf '{"cwd":"%s"}' "$PROJ2" | BRAIN_DIR="$BRAIN2" bash "$HERE/scripts/discover-doc-sources.sh"
if [ -f "$BRAIN2/projects/$SLUG2/doc-sources.json" ]; then
  echo "FAIL: registry written despite no config"; FAIL=1
else
  echo "PASS: no config → no registry (zero cost)"
fi

rm -rf "$BRAIN" "$PROJ" "$BRAIN2" "$PROJ2"
[ "$FAIL" -eq 0 ] && echo "ALL GREEN" || echo "FAILURES"
exit "$FAIL"
```

- [ ] **Step 4: run the test — expect FAIL first** if the bundle isn't built or hook missing, then PASS once Task 1's bundle + this hook are in place. Run: `bash tests/test-doc-sources-hook.sh`. Expected after wiring: `PASS … PASS … ALL GREEN`. (Requires `scripts/discover-doc-sources.sh` executable and the Task-1 bundle present.)

- [ ] **Step 5: run the aggregate suite** — `bash tests/run-all.sh` → all green (shell tests + vitest). Confirms `hooks.json` validity + no regressions.

- [ ] **Step 6: commit**
```bash
git add scripts/discover-doc-sources.sh hooks/hooks.json tests/test-doc-sources-hook.sh
git commit -m "$(printf 'feat(doc-sources): SessionStart discovery hook + wiring (phase 2)\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>')"
```

---

## Definition of done (Phase 2)
- `doc-sources-cli.bundle.js` built; runs `buildRegistry` from env+argv.
- `discover-doc-sources.sh` registered in SessionStart; config-guarded (zero cost when unused); fail-soft; writes the registry for projects that declared locations.
- Shell test proves hook→registry end-to-end + the config-absent no-op; `tests/run-all.sh` green.

## Hand-off to Phase 3
`knowledge_search` loads `loadRegistry(active slug)` and merges entries (BM25 over gist+headings, `source:"local-doc"`, real `path`, `tokens`); `knowledge_fetch` resolves registry entries (full = read file, GUARD-capped). The active slug is resolved server-side from `process.cwd()` + `BRAIN_DIR`.
