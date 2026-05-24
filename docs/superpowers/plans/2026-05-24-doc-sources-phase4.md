# Local Doc-Sources — Phase 4: `/second-brain:track` skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Let the user declare/list/remove tracked doc locations without hand-editing JSON, via `/second-brain:track`. Completes the doc-sources feature ergonomically.

**Architecture:** The skill is a **thin wrapper** over a deterministic config-mutation CLI — a skill that has Claude hand-edit the JSON would risk malformed configs. `doc-sources.ts` gains `addLocation`/`removeLocation`/`listLocations` (atomic write, dedup, slug + location validation, reusing `assertSafeSlug`). `doc-sources-config-cli.ts` resolves the active project (pin-first, else `basename(cwd)`) and prints results to stdout. `skills/track/SKILL.md` maps the user's arg to a CLI action and shows the output.

**Tech Stack:** TypeScript (ESM, bundled), Vitest, a Markdown skill, a shell test. Reuses Phase-1 `readConfig`/`assertSafeSlug`.

**Build/test (from `mcp/`):** `npx vitest run test/doc-sources.test.ts`; full `npm test`; build `npm run build`. Shell: `bash tests/test-doc-sources-track.sh`; aggregate `bash tests/run-all.sh`.
**Commit:** Conventional Commits + trailer `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`. Commit to `main`.

**Scope:** Phase 4 of 4 (final). Phase 3b (`knowledge_fetch` doc resolution) remains optional/additive.

---

### Task 1: config-mutation functions + CLI + bundle

**Files:** Modify `mcp/src/tools/doc-sources.ts`; Create `mcp/src/tools/doc-sources-config-cli.ts`; Modify `mcp/package.json` (bundle list); Test `mcp/test/doc-sources.test.ts` (append).

- [ ] **Step 1: failing tests** — append to `mcp/test/doc-sources.test.ts` (it already has `mkdtempSync, rmSync, writeFileSync, mkdirSync` from 'fs', `join`, `tmpdir`):
```ts
import { addLocation, removeLocation, listLocations } from '../src/tools/doc-sources.js';

describe('track config mutations', () => {
  let brain: string;
  beforeEach(() => {
    brain = mkdtempSync(join(tmpdir(), 'ds-cfg-'));
    mkdirSync(join(brain, 'projects', 'proj'), { recursive: true });
  });
  afterEach(() => rmSync(brain, { recursive: true, force: true }));

  it('adds a location (dedup) and lists it', async () => {
    const r1 = await addLocation(brain, 'proj', 'docs/');
    expect(r1.added).toBe(true);
    expect(await listLocations(brain, 'proj')).toEqual(['docs/']);
    const r2 = await addLocation(brain, 'proj', 'docs/'); // dedup
    expect(r2.added).toBe(false);
    expect(await listLocations(brain, 'proj')).toEqual(['docs/']);
  });

  it('removes a location', async () => {
    await addLocation(brain, 'proj', 'docs/');
    await addLocation(brain, 'proj', '.ai-docs/');
    const r = await removeLocation(brain, 'proj', 'docs/');
    expect(r.removed).toBe(true);
    expect(await listLocations(brain, 'proj')).toEqual(['.ai-docs/']);
    const r2 = await removeLocation(brain, 'proj', 'nope/');
    expect(r2.removed).toBe(false);
  });

  it('rejects an unsafe location (absolute or ..)', async () => {
    await expect(addLocation(brain, 'proj', '/etc')).rejects.toThrow(/invalid location/);
    await expect(addLocation(brain, 'proj', '../outside')).rejects.toThrow(/invalid location/);
  });

  it('rejects an unsafe slug', async () => {
    await expect(addLocation(brain, '../escape', 'docs/')).rejects.toThrow(/unsafe slug/);
    expect(await listLocations(brain, '../escape').catch(() => 'threw')).toBe('threw');
  });

  it('normalizes ./ prefix and trims', async () => {
    await addLocation(brain, 'proj', '  ./docs/  ');
    expect(await listLocations(brain, 'proj')).toEqual(['docs/']);
  });
});
```

- [ ] **Step 2: run, expect FAIL** — `cd mcp && npx vitest run test/doc-sources.test.ts`.

- [ ] **Step 3: implement** — append to `mcp/src/tools/doc-sources.ts` (it already has `assertSafeSlug`, `readConfig`, `fs`, `join`):
```ts
function normalizeLocation(location: string): string {
  return location.trim().replace(/^\.\//, '');
}

async function writeConfig(brainDir: string, slug: string, locations: string[]): Promise<void> {
  assertSafeSlug(slug);
  const dir = join(brainDir, 'projects', slug);
  const out = join(dir, 'doc-sources.config.json');
  await fs.mkdir(dir, { recursive: true });
  const tmp = `${out}.tmp`;
  await fs.writeFile(tmp, JSON.stringify({ locations }, null, 2));
  await fs.rename(tmp, out); // atomic
}

export async function listLocations(brainDir: string, slug: string): Promise<string[]> {
  assertSafeSlug(slug);
  return (await readConfig(brainDir, slug)).locations;
}

export async function addLocation(brainDir: string, slug: string, location: string): Promise<{ locations: string[]; added: boolean }> {
  assertSafeSlug(slug);
  const loc = normalizeLocation(location);
  if (!loc || loc.startsWith('/') || loc.split('/').includes('..')) {
    throw new Error(`invalid location: ${JSON.stringify(location)} (must be a relative path or glob within the project)`);
  }
  const cfg = await readConfig(brainDir, slug);
  if (cfg.locations.includes(loc)) return { locations: cfg.locations, added: false };
  const locations = [...cfg.locations, loc];
  await writeConfig(brainDir, slug, locations);
  return { locations, added: true };
}

export async function removeLocation(brainDir: string, slug: string, location: string): Promise<{ locations: string[]; removed: boolean }> {
  assertSafeSlug(slug);
  const loc = normalizeLocation(location);
  const cfg = await readConfig(brainDir, slug);
  const locations = cfg.locations.filter((l) => l !== loc);
  const removed = locations.length !== cfg.locations.length;
  if (removed) await writeConfig(brainDir, slug, locations);
  return { locations, removed };
}
```

- [ ] **Step 4: run targeted → PASS; full `cd mcp && npm test` → green.**

- [ ] **Step 5: create the CLI** `mcp/src/tools/doc-sources-config-cli.ts`:
```ts
import { homedir } from 'os';
import { join, basename } from 'path';
import { existsSync, readFileSync } from 'fs';
import { addLocation, removeLocation, listLocations } from './doc-sources.js';

function resolveSlug(brainDir: string): string | undefined {
  try {
    const pin = readFileSync(join(brainDir, '.active-session-slug'), 'utf-8').trim();
    if (pin && existsSync(join(brainDir, 'projects', pin, 'PROJECT.md'))) return pin;
  } catch { /* no pin */ }
  const base = basename(process.cwd());
  return base && base !== '/' && base !== '.' ? base : undefined;
}

async function main(): Promise<void> {
  const brainDir = process.env.BRAIN_DIR || join(homedir(), '.second-brain');
  const action = process.argv[2];
  const location = process.argv[3];
  const slug = resolveSlug(brainDir);
  if (!slug) { console.log('track: could not resolve the active project (no slug)'); return; }
  try {
    if (action === 'list') {
      const locs = await listLocations(brainDir, slug);
      console.log(`Tracked doc locations for ${slug} (${locs.length}):`);
      for (const l of locs) console.log(`  - ${l}`);
      if (locs.length === 0) console.log('  (none — add one, e.g. /second-brain:track docs/)');
    } else if (action === 'add') {
      if (!location) { console.log('usage: track add <path-or-glob>'); return; }
      const r = await addLocation(brainDir, slug, location);
      console.log(r.added ? `Tracking "${location}" for ${slug}. Locations: ${r.locations.join(', ')}` : `"${location}" is already tracked.`);
      console.log('(scanned into the searchable registry at next session start)');
    } else if (action === 'remove') {
      if (!location) { console.log('usage: track remove <path-or-glob>'); return; }
      const r = await removeLocation(brainDir, slug, location);
      console.log(r.removed ? `Untracked "${location}". Remaining: ${r.locations.join(', ') || '(none)'}` : `"${location}" was not tracked.`);
    } else {
      console.log('usage: track add|remove|list [location]');
    }
  } catch (e) {
    console.log(`track error: ${e instanceof Error ? e.message : String(e)}`);
  }
}

main();
```

- [ ] **Step 6: add to the esbuild bundle list** in `mcp/package.json` — append into the `&&` chain (mirror the `doc-sources-cli` entry's flags):
```
&& esbuild src/tools/doc-sources-config-cli.ts --bundle --platform=node --target=node20 --format=esm --external:@huggingface/transformers --outfile=dist/tools/doc-sources-config-cli.bundle.js
```

- [ ] **Step 7: build + smoke** —
```bash
cd mcp && npm run build && test -f dist/tools/doc-sources-config-cli.bundle.js && echo "bundle present"
B=$(mktemp -d); mkdir -p "$B/projects/smoke"; printf '%s' smoke > "$B/.active-session-slug"; printf '# P\n' > "$B/projects/smoke/PROJECT.md"
D=$(mktemp -d); ( cd "$D" && ln -sfn "$D" "$D/smoke" 2>/dev/null; )   # ensure cwd basename can be 'smoke' if needed
BRAIN_DIR="$B" node dist/tools/doc-sources-config-cli.bundle.js add "docs/"   # slug from pin=smoke
BRAIN_DIR="$B" node dist/tools/doc-sources-config-cli.bundle.js list
cat "$B/projects/smoke/doc-sources.config.json"
rm -rf "$B" "$D"
```
Expected: `bundle present`, an "add" confirmation, a list showing `docs/`, and the config JSON `{"locations":["docs/"]}`. (The pin `smoke` + its PROJECT.md make `resolveSlug` return `smoke` regardless of cwd.)

- [ ] **Step 8: full suite + commit**
```bash
cd mcp && npm test   # green
git add mcp/src/tools/doc-sources.ts mcp/src/tools/doc-sources-config-cli.ts mcp/package.json mcp/test/doc-sources.test.ts mcp/dist
git commit -m "$(printf 'feat(doc-sources): track config-mutation CLI (add/remove/list) (phase 4)\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: `/second-brain:track` skill + shell test

**Files:** Create `skills/track/SKILL.md`; Create `tests/test-doc-sources-track.sh`.

- [ ] **Step 1: read an existing skill's frontmatter** (e.g. `skills/status/SKILL.md` or `skills/setup/SKILL.md`) to match the exact frontmatter keys the plugin validator requires (`name`, `description`, `user-invocable`, `disable-model-invocation`, `allowed-tools`). Then create `skills/track/SKILL.md`:
```markdown
---
name: track
description: Declare which local folders or globs the second brain tracks as doc sources for the current project (e.g. docs/, .ai-docs/, "notes/**/*.mdx"). Tracked docs are auto-indexed each session and surface in knowledge_search. Usage: /second-brain:track <path|glob> | --list | --remove <path|glob>.
user-invocable: true
disable-model-invocation: false
allowed-tools: Bash(node *)
---

# /second-brain:track — declare local doc sources

Map the user's argument to a config-CLI action and run it. The CLI resolves the active project and atomically updates `~/.second-brain/projects/<slug>/doc-sources.config.json` (with dedup + validation).

Argument → action:
- `--list` (or no argument) → `list`
- `--remove <loc>` → `remove <loc>`
- `<loc>` — a folder like `docs/` or a glob like `notes/**/*.mdx` → `add <loc>`

Run exactly this (quote the location), then show the command's output to the user verbatim:
```
node "${CLAUDE_PLUGIN_ROOT}/mcp/dist/tools/doc-sources-config-cli.bundle.js" <action> "<location>"
```

Then tell the user that newly-tracked locations are scanned into the searchable registry at the **next session start** (the `discover-doc-sources` SessionStart hook), after which `knowledge_search` will surface matching docs.
```
(Match the frontmatter shape of the existing skill you read; if the validator wants different keys, adjust to match.)

- [ ] **Step 2: create the shell test** `tests/test-doc-sources-track.sh` (style of existing `tests/*.sh`; exercises the CLI end-to-end since the skill is a thin wrapper over it):
```bash
#!/bin/bash
set -u
FAIL=0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$HERE/mcp/dist/tools/doc-sources-config-cli.bundle.js"
B=$(mktemp -d); SLUG=trackproj
mkdir -p "$B/projects/$SLUG"; printf '%s' "$SLUG" > "$B/.active-session-slug"; printf '# P\n' > "$B/projects/$SLUG/PROJECT.md"

run() { BRAIN_DIR="$B" node "$CLI" "$@"; }

run add "docs/" >/dev/null
run add "docs/" >/dev/null   # dedup
run add ".ai-docs/" >/dev/null
CFG="$B/projects/$SLUG/doc-sources.config.json"
if [ "$(jq -c '.locations' "$CFG" 2>/dev/null)" = '["docs/",".ai-docs/"]' ]; then
  echo "PASS: add + dedup"
else echo "FAIL: add/dedup -> $(cat "$CFG" 2>/dev/null)"; FAIL=1; fi

LIST=$(run list)
echo "$LIST" | grep -q 'docs/' && echo "PASS: list shows docs/" || { echo "FAIL: list"; FAIL=1; }

run remove "docs/" >/dev/null
if [ "$(jq -c '.locations' "$CFG" 2>/dev/null)" = '[".ai-docs/"]' ]; then
  echo "PASS: remove"
else echo "FAIL: remove -> $(cat "$CFG")"; FAIL=1; fi

# unsafe location rejected (config unchanged)
run add "/etc" >/dev/null
[ "$(jq -c '.locations' "$CFG")" = '[".ai-docs/"]' ] && echo "PASS: unsafe location rejected" || { echo "FAIL: unsafe location stored"; FAIL=1; }

rm -rf "$B"
[ "$FAIL" -eq 0 ] && echo "ALL GREEN" || echo "FAILURES"
exit "$FAIL"
```
`chmod +x tests/test-doc-sources-track.sh`.

- [ ] **Step 3: run the shell test** — `bash tests/test-doc-sources-track.sh`. Expected: 4× PASS + `ALL GREEN`. (Requires Task-1 bundle built.)

- [ ] **Step 4: validate plugin + aggregate suite** — `bash scripts/validate-plugin.sh` (skill frontmatter OK) and `bash tests/run-all.sh` (all green; the new shell test is auto-discovered if run-all globs `tests/*.sh` — confirm it ran).

- [ ] **Step 5: commit**
```bash
git add skills/track/SKILL.md tests/test-doc-sources-track.sh
git commit -m "$(printf 'feat(doc-sources): /second-brain:track skill to declare doc locations (phase 4)\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>')"
```

---

## Definition of done (Phase 4)
- `addLocation`/`removeLocation`/`listLocations` (atomic, dedup, slug+location validated) + `doc-sources-config-cli` bundled.
- `/second-brain:track <loc> | --list | --remove <loc>` works end-to-end (shell test green); `validate-plugin` passes.
- `cd mcp && npm test` + `bash tests/run-all.sh` green. **Doc-sources feature is complete**: declare via `/second-brain:track` → SessionStart scan → searchable in `knowledge_search`.

## Remaining after Phase 4
- Phase 3b (optional): `knowledge_fetch` doc-source resolution (tiered/capped fetch; Claude can `Read` the path today).
- Memory egress Phases 3–5.
