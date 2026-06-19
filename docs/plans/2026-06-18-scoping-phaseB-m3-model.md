# Phase B — M3 Scoping Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make project scoping monorepo-aware: a session in sub-project B sees **B + parent A + siblings C,D,E + global**, while standalone repos behave exactly as today (the no-parent degenerate case).

**Architecture:** `projects.jsonl` gains two optional fields — `parent` (the monorepo root slug) and `root_path` (the project's absolute dir). A new pure TS module `project-registry.ts` reads the registry to answer two questions: *what is X's family?* (`projectFamily`) and *which registered project owns this cwd?* (`resolveSlugByPath`, longest-prefix). `resolveActiveSlug` consults `resolveSlugByPath` so a single-git-monorepo subdir resolves to its registered path-qualified slug. `knowledge-search` inserts a **family tier** between own-project and graph-neighbour. A bash `sb_detect_project` helper auto-detects the three monorepo topologies and yields `slug / parent / root_path`; `session-load.sh` writes them silently, `setup` proposes-then-confirms. `dream --family` mines the whole family. The graph "reconciliation" projection (Task 7) is **optional** — scoping reads `projects.jsonl` truth, not the graph.

**Tech Stack:** TypeScript (ESM, `node>=22`), vitest (`npm test` = `vitest run`), esbuild bundles (`npm run build`), bash, `jq`, git.

## Global Constraints

- **Additive + back-compatible.** `parent`/`root_path` are OPTIONAL. A record without them = a standalone project = today's behavior, unchanged. Every existing reader uses `.slug`; never reorder or require the new fields. Legacy `projects.jsonl` (4-field records) must keep working.
- **Bash ↔ TS slug parity is sacred.** `sb_slug_from_dir` (bash) and `slugFromProjectDir` (TS) MUST agree on the slug for any given dir, including the new path-qualified `<root>__<leaf>` form. Any change to one is mirrored in the other, and a parity test asserts it.
- **Scoping reads `projects.jsonl` truth, not the graph projection.** The family tier and resolver read the registry directly. Task 7's graph edge is for graph-native navigation only and must NOT rewrite any page's `project:` facet (the `set_project` never-overwrite guard at `kb-project-backfill.sh:32` is the safety net; a test asserts it).
- **Fail loud, never silent** — no `2>/dev/null` swallow of real errors; surface detection ambiguity to the operator in `setup` rather than guessing.
- **Flat single-level hierarchy.** A sub-project's `parent` is the *nearest* workspace/monorepo root. No grandparent chains; deeper nesting collapses to the nearest root.
- **Path-qualified slug = `<root>__<leaf>`** (double underscore). Only sub-projects are qualified; roots and standalones keep bare slugs.
- **Working dir for `npm`/`vitest`/`build`:** `mcp/`. **Rebuild bundles** (`npm run build`) after editing any file that ships in a bundle (`project-dir.ts`, `project-registry.ts`, `knowledge-search.ts`, `dream.ts` → `server.bundle.js`; `knowledge-search-cli.ts` if touched) and stage `mcp/dist` in that task's commit (`mcp/dist` is git-tracked).
- **`git_remote` collision identity and old-data migration are Phase C** — out of scope here.

---

### Task 1: `project-registry.ts` — registry model, family, and path resolver

**Files:**
- Create: `mcp/src/tools/project-registry.ts`
- Test: `mcp/src/tools/project-registry.test.ts`

**Interfaces:**
- Consumes: nothing (leaf).
- Produces: `interface ProjectRecord { slug: string; name?: string; last_session_iso?: string; hot_byte_count?: number; parent?: string; root_path?: string; }`; `loadRegistry(brainDir: string): ProjectRecord[]`; `projectFamily(brainDir: string, slug: string): Set<string>`; `resolveSlugByPath(brainDir: string, dir: string): string | undefined`. Tasks 2, 5, 6 depend on these.

- [ ] **Step 1: Write the failing tests**

Create `mcp/src/tools/project-registry.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { loadRegistry, projectFamily, resolveSlugByPath } from './project-registry.js';

function brain(records: string): string {
  const dir = mkdtempSync(join(tmpdir(), 'sb-reg-'));
  writeFileSync(join(dir, 'projects.jsonl'), records);
  return dir;
}

const FAMILY =
  '{"slug":"acme","root_path":"/repos/acme"}\n' +
  '{"slug":"acme__api","parent":"acme","root_path":"/repos/acme/packages/api"}\n' +
  '{"slug":"acme__web","parent":"acme","root_path":"/repos/acme/packages/web"}\n' +
  '{"slug":"companion","root_path":"/repos/companion"}\n';

describe('loadRegistry', () => {
  it('parses JSONL tolerantly, skipping blank and malformed lines', () => {
    const dir = brain(FAMILY + '\n{ not json }\n');
    const recs = loadRegistry(dir);
    expect(recs.map(r => r.slug).sort()).toEqual(['acme', 'acme__api', 'acme__web', 'companion']);
    rmSync(dir, { recursive: true, force: true });
  });
  it('returns [] when the registry is absent', () => {
    const dir = mkdtempSync(join(tmpdir(), 'sb-reg-empty-'));
    expect(loadRegistry(dir)).toEqual([]);
    rmSync(dir, { recursive: true, force: true });
  });
});

describe('projectFamily', () => {
  it('a sub-project sees root + all siblings + itself (symmetric)', () => {
    const dir = brain(FAMILY);
    expect([...projectFamily(dir, 'acme__api')].sort()).toEqual(['acme', 'acme__api', 'acme__web']);
    expect([...projectFamily(dir, 'acme__web')].sort()).toEqual(['acme', 'acme__api', 'acme__web']);
    rmSync(dir, { recursive: true, force: true });
  });
  it('the root sees all its children + itself', () => {
    const dir = brain(FAMILY);
    expect([...projectFamily(dir, 'acme')].sort()).toEqual(['acme', 'acme__api', 'acme__web']);
    rmSync(dir, { recursive: true, force: true });
  });
  it('a standalone project is its own singleton family', () => {
    const dir = brain(FAMILY);
    expect([...projectFamily(dir, 'companion')]).toEqual(['companion']);
    rmSync(dir, { recursive: true, force: true });
  });
  it('an unregistered slug is its own singleton family', () => {
    const dir = brain(FAMILY);
    expect([...projectFamily(dir, 'ghost')]).toEqual(['ghost']);
    rmSync(dir, { recursive: true, force: true });
  });
});

describe('resolveSlugByPath', () => {
  it('longest-prefix matches a cwd inside a registered child', () => {
    const dir = brain(FAMILY);
    expect(resolveSlugByPath(dir, '/repos/acme/packages/api/src/x')).toBe('acme__api');
    rmSync(dir, { recursive: true, force: true });
  });
  it('matches the monorepo root when cwd is the root (not a child)', () => {
    const dir = brain(FAMILY);
    expect(resolveSlugByPath(dir, '/repos/acme')).toBe('acme');
    rmSync(dir, { recursive: true, force: true });
  });
  it('returns undefined when no root_path is a prefix', () => {
    const dir = brain(FAMILY);
    expect(resolveSlugByPath(dir, '/somewhere/else')).toBeUndefined();
    rmSync(dir, { recursive: true, force: true });
  });
  it('does not match a sibling-prefix false positive (/repos/acme-other)', () => {
    const dir = brain(FAMILY);
    expect(resolveSlugByPath(dir, '/repos/acme-other/src')).toBeUndefined();
    rmSync(dir, { recursive: true, force: true });
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mcp && npx vitest run src/tools/project-registry.test.ts`
Expected: FAIL — module `./project-registry.js` does not exist (import error).

- [ ] **Step 3: Implement `project-registry.ts`**

Create `mcp/src/tools/project-registry.ts`:

```ts
import { readFileSync } from 'fs';
import { join } from 'path';
import { cleanEnvPath } from '../path-guard.js';

export interface ProjectRecord {
  slug: string;
  name?: string;
  last_session_iso?: string;
  hot_byte_count?: number;
  parent?: string;     // monorepo root slug; absent = standalone/root (Phase B, M3)
  root_path?: string;  // absolute project dir; absent = legacy record (Phase B, M3)
}

/** Read projects.jsonl tolerantly: one JSON object per line, blank/malformed lines skipped.
 *  Returns [] when the file is absent or unreadable. A hand-pretty-printed file is repaired by
 *  the Phase C migration, not silently mis-parsed here. */
export function loadRegistry(brainDir: string): ProjectRecord[] {
  let text: string;
  try { text = readFileSync(join(brainDir, 'projects.jsonl'), 'utf-8'); } catch { return []; }
  const out: ProjectRecord[] = [];
  for (const line of text.split('\n')) {
    const s = line.trim();
    if (!s) continue;
    try {
      const r = JSON.parse(s);
      if (r && typeof r.slug === 'string' && r.slug) out.push(r as ProjectRecord);
    } catch { /* skip malformed line */ }
  }
  return out;
}

/** The family of a project = its monorepo root + every project sharing that root + itself.
 *  root(X) = X.parent ?? X.slug. A standalone (no parent, no children) is its own singleton.
 *  An unregistered slug is its own singleton (degenerate — today's behavior). */
export function projectFamily(brainDir: string, slug: string): Set<string> {
  const recs = loadRegistry(brainDir);
  const self = recs.find(r => r.slug === slug);
  const root = self?.parent ?? slug;
  const fam = new Set<string>([slug, root]);
  for (const r of recs) if ((r.parent ?? r.slug) === root) fam.add(r.slug);
  return fam;
}

/** Resolve which registered project owns `dir` by LONGEST-PREFIX match of `dir` against each
 *  record's root_path. Path-segment aware: /repos/acme matches /repos/acme/x but NOT
 *  /repos/acme-other. Returns the slug of the deepest matching root_path, or undefined. */
export function resolveSlugByPath(brainDir: string, dir: string): string | undefined {
  const norm = (p: string) => cleanEnvPath(p).replace(/\\/g, '/').replace(/\/+$/, '');
  const target = norm(dir);
  let best: { slug: string; len: number } | undefined;
  for (const r of loadRegistry(brainDir)) {
    if (!r.root_path) continue;
    const rp = norm(r.root_path);
    if (target === rp || target.startsWith(rp + '/')) {
      if (!best || rp.length > best.len) best = { slug: r.slug, len: rp.length };
    }
  }
  return best?.slug;
}
```

- [ ] **Step 4: Run tests + typecheck to verify green**

Run: `cd mcp && npx vitest run src/tools/project-registry.test.ts && npm run typecheck`
Expected: PASS (all cases) + typecheck clean.

- [ ] **Step 5: Commit**

```bash
git add mcp/src/tools/project-registry.ts mcp/src/tools/project-registry.test.ts
git commit -m "feat(registry): project-registry helpers — family + longest-prefix path resolver (Phase B)"
```

---

### Task 2: `resolveActiveSlug` registry-path lookup

**Files:**
- Modify: `mcp/src/tools/project-dir.ts` (`resolveActiveSlug` ~40-56; add import)
- Test: `mcp/test/project-dir.test.ts` (add cases)

**Interfaces:**
- Consumes: `resolveSlugByPath` (Task 1).
- Produces: updated `resolveActiveSlug` precedence: `CLAUDE_PROJECT_DIR (registry-path → else basename) > cwd registry-path > cwd-if-known-project > pin > bare cwd`.

- [ ] **Step 1: Write the failing tests**

Add to `mcp/test/project-dir.test.ts` (ensure imports: `mkdtempSync, mkdirSync, writeFileSync, rmSync` from `'fs'`, `tmpdir` from `'os'`, `join` from `'path'`, `resolveActiveSlug` from the module — add any missing):

```ts
describe('resolveActiveSlug — registry-path (monorepo)', () => {
  function brainWithChild(): string {
    const dir = mkdtempSync(join(tmpdir(), 'sb-resolve-'));
    writeFileSync(join(dir, 'projects.jsonl'),
      '{"slug":"acme__api","parent":"acme","root_path":"/repos/acme/packages/api"}\n');
    mkdirSync(join(dir, 'projects', 'acme__api'), { recursive: true });
    writeFileSync(join(dir, 'projects', 'acme__api', 'PROJECT.md'), '# PROJECT: acme__api\n');
    return dir;
  }
  it('resolves a cwd inside a registered child to its path-qualified slug', () => {
    const dir = brainWithChild();
    const slug = resolveActiveSlug(dir, {} as NodeJS.ProcessEnv, () => '/repos/acme/packages/api/src');
    expect(slug).toBe('acme__api');
    rmSync(dir, { recursive: true, force: true });
  });
  it('CLAUDE_PROJECT_DIR inside a registered child also maps via root_path', () => {
    const dir = brainWithChild();
    const slug = resolveActiveSlug(dir, { CLAUDE_PROJECT_DIR: '/repos/acme/packages/api' } as any, () => '/elsewhere');
    expect(slug).toBe('acme__api');
    rmSync(dir, { recursive: true, force: true });
  });
  it('falls back to bare basename when no root_path matches (standalone, unchanged)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'sb-resolve2-'));
    const slug = resolveActiveSlug(dir, {} as NodeJS.ProcessEnv, () => '/repos/standalone');
    expect(slug).toBe('standalone');
    rmSync(dir, { recursive: true, force: true });
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mcp && npx vitest run test/project-dir.test.ts -t registry-path`
Expected: FAIL — first case resolves to `api` (bare basename) instead of `acme__api`, because the registry-path tier isn't wired yet.

- [ ] **Step 3: Wire the registry-path lookup into `resolveActiveSlug`**

In `mcp/src/tools/project-dir.ts`, add the import at the top:

```ts
import { resolveSlugByPath } from './project-registry.js';
```

Replace the body of `resolveActiveSlug` with (registry-path tier added for BOTH CLAUDE_PROJECT_DIR and cwd, before the bare-basename fallbacks):

```ts
export function resolveActiveSlug(
  brainDir: string,
  env: NodeJS.ProcessEnv = process.env,
  cwd: () => string = process.cwd,
): string | undefined {
  if (env.CLAUDE_PROJECT_DIR) {
    // A registered monorepo child whose root_path contains this dir wins (path-qualified slug),
    // else fall back to the basename slug.
    const byPath = resolveSlugByPath(brainDir, env.CLAUDE_PROJECT_DIR);
    if (byPath) return byPath;
    const fromEnv = slugFromProjectDir(env.CLAUDE_PROJECT_DIR);
    if (fromEnv) return fromEnv;
  }
  const here = cwd();
  const byCwdPath = resolveSlugByPath(brainDir, here);
  if (byCwdPath) return byCwdPath;
  const cwdSlug = slugFromProjectDir(here);
  if (cwdSlug && existsSync(join(brainDir, 'projects', cwdSlug, 'PROJECT.md'))) return cwdSlug;
  try {
    const pin = readFileSync(join(brainDir, '.active-session-slug'), 'utf-8').trim();
    if (pin && existsSync(join(brainDir, 'projects', pin, 'PROJECT.md'))) return pin;
  } catch { /* no pin */ }
  return cwdSlug;
}
```

Update the precedence comment above the function to: `CLAUDE_PROJECT_DIR (registry-path > basename) > cwd registry-path > cwd-if-known-project > pin > cwd`.

- [ ] **Step 4: Run tests + typecheck to verify green**

Run: `cd mcp && npx vitest run test/project-dir.test.ts && npm run typecheck`
Expected: PASS (new registry-path cases + all 12 pre-existing project-dir tests).

- [ ] **Step 5: Build + commit**

Run: `cd mcp && npm run build`

```bash
git add mcp/src/tools/project-dir.ts mcp/test/project-dir.test.ts mcp/dist
git commit -m "feat(resolver): resolveActiveSlug maps cwd to registered monorepo child via root_path (Phase B)"
```

---

### Task 3: `sb_detect_project` — bash monorepo detection + path-qualified slug

**Files:**
- Modify: `scripts/lib.sh` (add `sb_detect_project`, `sb_is_workspace_root`, `sb_find_up`; keep `sb_slug_from_dir` for the degenerate path)
- Test: `tests/test-detect-project.sh` (new)

**Interfaces:**
- Produces: `sb_detect_project <dir>` echoes one TAB-separated line `slug<TAB>parent<TAB>root_path`. Standalone → `parent` empty, `slug` = basename, `root_path` = abs git-toplevel (or abs dir). Sub-project → `slug` = `<root>__<leaf>`, `parent` = `<root>`, `root_path` = abs cwd. Consumed by Task 4.

- [ ] **Step 1: Write the failing test**

Create `tests/test-detect-project.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/scripts/lib.sh"
fail=0
check() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — expected [$2] got [$3]"; fail=1; fi
}

TMP=$(mktemp -d)

# --- standalone git repo ---
mkdir -p "$TMP/standalone"; ( cd "$TMP/standalone" && git init -q )
OUT=$(cd "$TMP/standalone" && sb_detect_project "$PWD")
check "standalone slug"   "standalone" "$(printf '%s' "$OUT" | cut -f1)"
check "standalone parent" ""           "$(printf '%s' "$OUT" | cut -f2)"

# --- single-git monorepo (pnpm-workspace.yaml at root), working in packages/api ---
mkdir -p "$TMP/acme/packages/api"; ( cd "$TMP/acme" && git init -q )
printf 'packages:\n  - "packages/*"\n' > "$TMP/acme/pnpm-workspace.yaml"
OUT=$(cd "$TMP/acme/packages/api" && sb_detect_project "$PWD")
check "monorepo child slug"   "acme__api" "$(printf '%s' "$OUT" | cut -f1)"
check "monorepo child parent" "acme"      "$(printf '%s' "$OUT" | cut -f2)"

# --- working AT the monorepo root → treated as the root (bare slug, no parent) ---
OUT=$(cd "$TMP/acme" && sb_detect_project "$PWD")
check "monorepo root slug"   "acme" "$(printf '%s' "$OUT" | cut -f1)"
check "monorepo root parent" ""     "$(printf '%s' "$OUT" | cut -f2)"

rm -rf "$TMP"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-detect-project.sh`
Expected: FAIL — `sb_detect_project: command not found` (or empty output), since the function doesn't exist.

- [ ] **Step 3: Implement `sb_detect_project` in `lib.sh`**

Add to `scripts/lib.sh` (place after `sb_slug_from_dir`):

```bash
# Detect a project's slug / parent / root_path for a directory, monorepo-aware.
# Echoes a single TAB-separated line: <slug>\t<parent>\t<root_path>
#   - git submodule (superproject exists)                                       → <super>__<leaf>, parent=<super>
#   - single-git monorepo (workspace manifest at the git root, cwd in a subdir) → <root>__<leaf>, parent=<root>
#   - .sb-monorepo.json marker at an ancestor with a "parent" key               → <parent>__<leaf>, parent=<parent>
#   - otherwise (standalone, or working at the monorepo root)                    → <leaf>, parent=""
sb_detect_project() {
  local dir; dir=$(printf '%s' "${1:-$PWD}" | tr -d '\r')
  local abs; abs=$(cd "$dir" 2>/dev/null && pwd) || abs="$dir"
  local top; top=$(git -C "$abs" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')
  local sup; sup=$(git -C "$abs" rev-parse --show-superproject-working-tree 2>/dev/null | tr -d '\r')
  local leaf; leaf=$(sb_slug_from_dir "$abs")

  # 1. git submodule: the superproject is the monorepo root.
  if [ -n "$sup" ]; then
    printf '%s__%s\t%s\t%s\n' "$(sb_slug_from_dir "$sup")" "$leaf" "$(sb_slug_from_dir "$sup")" "$abs"
    return 0
  fi

  # 2. single-git monorepo: a workspace manifest at the git root + cwd is a subdir of it.
  if [ -n "$top" ] && [ "$abs" != "$top" ] && sb_is_workspace_root "$top"; then
    printf '%s__%s\t%s\t%s\n' "$(sb_slug_from_dir "$top")" "$leaf" "$(sb_slug_from_dir "$top")" "$abs"
    return 0
  fi

  # 3. .sb-monorepo.json marker walking up from cwd (sibling-repo topology).
  local marker; marker=$(sb_find_up "$abs" ".sb-monorepo.json")
  if [ -n "$marker" ]; then
    local pkey; pkey=$(jq -r '.parent // empty' "$marker" 2>/dev/null | tr -d '\r')
    if [ -n "$pkey" ] && [ "$abs" != "$(dirname "$marker")" ]; then
      printf '%s__%s\t%s\t%s\n' "$pkey" "$leaf" "$pkey" "$abs"
      return 0
    fi
  fi

  # 4. standalone (or working at the monorepo root): bare slug, no parent.
  printf '%s\t\t%s\n' "$leaf" "${top:-$abs}"
}

# True if DIR contains a recognized monorepo workspace manifest.
sb_is_workspace_root() {
  local d="$1"
  [ -f "$d/pnpm-workspace.yaml" ] || [ -f "$d/nx.json" ] || [ -f "$d/turbo.json" ] \
    || [ -f "$d/lerna.json" ] || [ -f "$d/go.work" ] \
    || { [ -f "$d/Cargo.toml" ] && grep -q '^\[workspace\]' "$d/Cargo.toml" 2>/dev/null; } \
    || { [ -f "$d/package.json" ] && jq -e 'has("workspaces")' "$d/package.json" >/dev/null 2>&1; }
}

# Walk up from DIR looking for FILE; echo its full path, or nothing.
sb_find_up() {
  local d="$1" file="$2"
  d=$(cd "$d" 2>/dev/null && pwd) || return 0
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -f "$d/$file" ] && { printf '%s\n' "$d/$file"; return 0; }
    d=$(dirname "$d")
  done
  [ -f "/$file" ] && printf '%s\n' "/$file"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-detect-project.sh`
Expected: `ALL PASS` (standalone, monorepo child, monorepo root cases).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh tests/test-detect-project.sh
git commit -m "feat(detect): sb_detect_project — monorepo-aware slug/parent/root_path (Phase B)"
```

---

### Task 4: registration writes `parent`/`root_path` (session-load + setup)

**Files:**
- Modify: `scripts/session-load.sh` (slug derivation ~21; append block ~49-60; update block ~644-650)
- Modify: `skills/setup/SKILL.md` (Step 1 + Step 4)
- Test: `tests/test-session-load-jsonl-membership.sh` (extend)

**Interfaces:**
- Consumes: `sb_detect_project` (Task 3).
- Produces: `projects.jsonl` records now carry `parent` (when a sub-project) and `root_path`; on re-registration both are refreshed. `setup` proposes the detected slug/parent and confirms.

- [ ] **Step 1: Write the failing test**

Add to `tests/test-session-load-jsonl-membership.sh` a case asserting a freshly-registered record carries `root_path` (and `parent` when detected). Append before the final pass/fail tally (adapt to the file's existing harness — it sets up a temp `BRAIN_DIR`; reuse its helpers and failure-flag variable name):

```bash
# --- Phase B: registration records root_path (+ parent for a sub-project) ---
MONO=$(mktemp -d); mkdir -p "$MONO/mono/packages/api"; ( cd "$MONO/mono" && git init -q )
printf 'packages:\n  - "packages/*"\n' > "$MONO/mono/pnpm-workspace.yaml"
read -r SLUG PARENT ROOTP < <(cd "$MONO/mono/packages/api" && sb_detect_project "$PWD" | awk -F'\t' '{print $1, $2, $3}')
test "$SLUG" = "mono__api"  && echo "PASS: detect child slug"  || { echo "FAIL: detect child slug ($SLUG)"; FAILED=1; }
test "$PARENT" = "mono"     && echo "PASS: detect child parent" || { echo "FAIL: detect child parent ($PARENT)"; FAILED=1; }
REC=$(jq -c --arg s "$SLUG" 'select(.slug==$s)' "$BRAIN_DIR/projects.jsonl" 2>/dev/null | head -1)
echo "$REC" | jq -e '.parent=="mono" and (.root_path|test("packages/api$"))' >/dev/null \
  && echo "PASS: record has parent+root_path" || { echo "FAIL: record missing parent/root_path: $REC"; FAILED=1; }
rm -rf "$MONO"
```

(If the harness's failure variable is not `FAILED`, match the file's existing convention. The "record has parent+root_path" assertion presumes this test drives the session-load registration path the file already exercises; wire it to that same path.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-session-load-jsonl-membership.sh`
Expected: the detect-slug/parent asserts PASS (Task 3 is in), but "record has parent+root_path" FAILS — session-load still writes only the 4 legacy fields.

- [ ] **Step 3: Make `session-load.sh` detect + write the new fields**

In `scripts/session-load.sh`, replace the slug derivation (line 21):

```bash
# Monorepo-aware: slug / parent / root_path for the active dir.
IFS=$'\t' read -r slug parent root_path < <(sb_detect_project "${CLAUDE_PROJECT_DIR:-$PWD}")
```

Replace the append block (~49-60) so a NEW record carries `parent`/`root_path` (empty `parent` omitted):

```bash
  if [ -f "$INDEX_FILE" ]; then
    if ! jq -se --arg s "$slug" 'map(select(.slug == $s)) | length > 0' \
        "$INDEX_FILE" >/dev/null 2>&1; then
      jq -nc --arg s "$slug" --arg n "$slug" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
             --arg p "$parent" --arg rp "$root_path" \
        '{slug:$s, name:$n, last_session_iso:$t, hot_byte_count:0}
         + (if $p  != "" then {parent:$p}     else {} end)
         + (if $rp != "" then {root_path:$rp} else {} end)' >> "$INDEX_FILE"
    fi
  fi
```

Replace the update block (~644-650) so re-registration refreshes `root_path` (and `parent` if newly detected), still updating `last_session_iso`:

```bash
if [ -f "$INDEX_FILE" ] && command -v jq >/dev/null 2>&1; then
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  TMP_IDX=$(mktemp)
  jq --arg s "$slug" --arg t "$TS" --arg p "$parent" --arg rp "$root_path" '
    if .slug == $s then
      .last_session_iso = $t
      | (if $rp != "" then .root_path = $rp else . end)
      | (if $p  != "" then .parent    = $p  else . end)
    else . end
  ' "$INDEX_FILE" > "$TMP_IDX" 2>/dev/null && mv "$TMP_IDX" "$INDEX_FILE" || rm -f "$TMP_IDX"
fi
```

- [ ] **Step 4: Update `setup/SKILL.md` Step 1 (detect + confirm) and Step 4 (jq write)**

Replace Step 1's slug block with a detect-and-confirm flow:

```bash
# Monorepo-aware detection: slug / parent / root_path. Source lib.sh for sb_detect_project.
. "${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh"
IFS=$'\t' read -r SLUG PARENT ROOT_PATH < <(sb_detect_project "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
NAME="$SLUG"
if [ -n "$PARENT" ]; then
  echo "Detected sub-project: slug=$SLUG  parent=$PARENT  root_path=$ROOT_PATH"
else
  echo "Detected standalone project: slug=$SLUG  root_path=$ROOT_PATH"
fi
```

Then, in the skill PROSE (not a bash literal), instruct: **show the detected `slug`/`parent` and ask the operator to accept, edit the parent, or clear it (treat as standalone) before writing** — never write a guessed `parent` without confirmation. (This is the "auto-detect, then confirm" gate.)

Replace Step 4's append (switch the legacy grep to the jq membership-check + write the new fields):

```bash
mkdir -p ~/.second-brain/projects/"$SLUG"
if [ ! -f ~/.second-brain/projects.jsonl ] || \
   ! jq -se --arg s "$SLUG" 'map(select(.slug == $s)) | length > 0' ~/.second-brain/projects.jsonl >/dev/null 2>&1; then
  jq -nc --arg s "$SLUG" --arg n "$NAME" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         --arg p "$PARENT" --arg rp "$ROOT_PATH" \
    '{slug:$s, name:$n, last_session_iso:$t, hot_byte_count:0}
     + (if $p  != "" then {parent:$p}     else {} end)
     + (if $rp != "" then {root_path:$rp} else {} end)' \
    >> ~/.second-brain/projects.jsonl
fi
```

Note in the skill that `mkdir -p ~/.second-brain/projects/"$SLUG"` now uses the path-qualified slug for sub-projects.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-session-load-jsonl-membership.sh`
Expected: `PASS: record has parent+root_path` (and all pre-existing membership assertions still pass).

- [ ] **Step 6: Commit**

```bash
git add scripts/session-load.sh skills/setup/SKILL.md tests/test-session-load-jsonl-membership.sh
git commit -m "feat(registration): write parent/root_path via sb_detect_project; setup confirms (Phase B)"
```

---

### Task 5: family tier in `knowledge-search.ts`

**Files:**
- Modify: `mcp/src/tools/knowledge-search.ts` (scoping block ~320-339; in-scope cutoff ~352-357; add import)
- Test: `mcp/src/tools/knowledge-search.test.ts` (add a family-scoping case)

**Interfaces:**
- Consumes: `projectFamily` (Task 1).
- Produces: tier cascade `own(1) > family(2) > graph-neighbour(3) > global(4) > other(5)`; in-scope cutoff `tier <= 4`.

- [ ] **Step 1: Write the failing test**

Add to `mcp/src/tools/knowledge-search.test.ts` a case under the existing SP-1 suite, REUSING its fixture-wiki + temp-brain helpers (the SP-1 tests at lines 177-263 show the exact `makeFixture`/temp-brain/result-field idiom — follow it; the snippet below is the behavioral shape):

```ts
it('SP-1 family: a sibling project page is in-scope, an unrelated project is dropped', async () => {
  const { knowledgeDir, brainDir, cleanup } = await makeFixture([
    { path: 'wiki/learnings/own.md',     fm: { project: 'acme__api' },  body: 'shared shibboleth token' },
    { path: 'wiki/learnings/sibling.md', fm: { project: 'acme__web' },  body: 'shared shibboleth token' },
    { path: 'wiki/learnings/global.md',  fm: { project: '' },           body: 'shared shibboleth token' },
    { path: 'wiki/learnings/foreign.md', fm: { project: 'unrelated' },  body: 'shared shibboleth token' },
  ]);
  writeFileSync(join(brainDir, 'projects.jsonl'),
    '{"slug":"acme"}\n{"slug":"acme__api","parent":"acme"}\n{"slug":"acme__web","parent":"acme"}\n{"slug":"unrelated"}\n');
  const r = await knowledgeSearch({ query: 'shibboleth token', projectSlug: 'acme__api', knowledgeDir, brainDir });
  const slugs = r.results.map(x => x.slug ?? x.path);
  expect(slugs.some(s => /sibling/.test(s))).toBe(true);   // family member in-scope
  expect(slugs.some(s => /foreign/.test(s))).toBe(false);  // unrelated project dropped
  await cleanup();
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd mcp && npx vitest run src/tools/knowledge-search.test.ts -t "SP-1 family"`
Expected: FAIL — the sibling page (`project: acme__web`) is currently tier 4 (other-project) and dropped, so the `sibling` assertion fails.

- [ ] **Step 3: Insert the family tier**

In `mcp/src/tools/knowledge-search.ts`, add the import near the other tool imports:

```ts
import { projectFamily } from './project-registry.js';
```

Replace the inner `if (scopeOn) { ... }` scoping block (~321-339) with the family-aware version:

```ts
  if (scopeOn) {
    const slug = args.projectSlug!;
    // Family = the monorepo root + siblings + self (reads projects.jsonl truth, not the graph).
    // Standalone projects → {slug}, so the family tier collapses to "own project" (today's behavior).
    const family = args.brainDir ? projectFamily(args.brainDir, slug) : new Set<string>([slug]);
    const projBySlug = new Map(
      allDocs.filter(d => d.source === 'wiki').map(d => [slugFromPath(d.doc.path), d.doc.project ?? '']));
    const anchors = allDocs.filter(d => d.source === 'wiki' && (d.doc.project ?? '') === slug)
      .map(d => slugFromPath(d.doc.path));
    const neigh = graphNeighbourhood(anchors, graphEdges, clampEnvInt('SB_SCOPE_HOPS', 2, 0, 4));
    for (const s of scored) {
      if (s.source === 'local-doc') { s.tier = 1; continue; }  // active project's own registry pages
      const sl = slugFromPath(s.path);
      const proj = projBySlug.get(sl) ?? '';
      s.tier = proj === slug ? 1
             : (proj !== '' && family.has(proj)) ? 2   // NEW: a family-member project's page
             : neigh.has(sl) ? 3                        // graph-neighbour (was 2)
             : proj === '' ? 4                          // global (was 3)
             : 5;                                       // other project (was 4)
    }
  }
```

In the in-scope block (~352-357), move the cutoff from `tier <= 3` to `tier <= 4`:

```ts
  let pool = scored;
  if (scopeOn) {
    const inScope = scored.filter(s => s.tier <= 4);
    // Enough in-scope hits → drop other-project (tier 5). Thin → broaden (keep all; in-scope sorted first).
    pool = inScope.filter(passesFloor).length >= clampEnvInt('SB_SCOPE_MIN_HITS', 3, 0, 100) ? inScope : scored;
  }
```

(The `scored.sort` at line 341 is already tier-major — `(a.tier - b.tier) || (b.score - a.score)` — so the new tiers order correctly with no change.)

- [ ] **Step 4: Run tests + typecheck to verify green**

Run: `cd mcp && npx vitest run src/tools/knowledge-search.test.ts && npm run typecheck`
Expected: PASS — the new family case + all pre-existing SP-1 scoping tests (own-project still tier 1, global still in-scope, broaden still fires).

- [ ] **Step 5: Build + commit**

Run: `cd mcp && npm run build`

```bash
git add mcp/src/tools/knowledge-search.ts mcp/src/tools/knowledge-search.test.ts mcp/dist
git commit -m "feat(search): family tier — sibling/parent projects in-scope for monorepo families (Phase B)"
```

---

### Task 6: `dream --family` — mine the whole family

**Files:**
- Modify: `mcp/src/tools/dream.ts` (`DreamCreateArgs`, `buildSnapshotArgs`, `dreamCreate`)
- Modify: `scripts/dream-snapshot.sh` (accept repeated `--slug`, OR them in transcript selection)
- Modify: `skills/dream/SKILL.md` (document `--family`)
- Test: `mcp/src/tools/dream.test.ts` (add `buildSnapshotArgs` family cases)

**Interfaces:**
- Consumes: `projectFamily` (Task 1), `buildSnapshotArgs` (Phase A).
- Produces: `DreamCreateArgs.transcript_filter.family?: boolean`; when set, dream mines every family member (multiple `--slug`).

- [ ] **Step 1: Write the failing tests**

Add to `mcp/src/tools/dream.test.ts`:

```ts
describe('buildSnapshotArgs — family', () => {
  it('emits one --slug per family member (sorted)', () => {
    const args = { transcript_filter: { family: true } };
    const fam = new Set(['acme', 'acme__api', 'acme__web']);
    expect(buildSnapshotArgs(args, 'acme__api', fam)).toEqual(
      ['--slug', 'acme', '--slug', 'acme__api', '--slug', 'acme__web', '--max-count', '50']);
  });
  it('ignores the family set when family flag is not set (leaf default)', () => {
    const fam = new Set(['acme', 'acme__api', 'acme__web']);
    expect(buildSnapshotArgs({}, 'acme__api', fam)).toEqual(['--slug', 'acme__api', '--max-count', '50']);
  });
  it('"all" opt-out still wins over family', () => {
    const fam = new Set(['acme', 'acme__api']);
    expect(buildSnapshotArgs({ transcript_filter: { project_slug: 'all', family: true } }, 'acme__api', fam))
      .toEqual(['--max-count', '50']);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mcp && npx vitest run src/tools/dream.test.ts -t "buildSnapshotArgs — family"`
Expected: FAIL — `buildSnapshotArgs` takes 2 args today; the 3rd `family` param and the multi-`--slug` behavior don't exist.

- [ ] **Step 3: Extend `DreamCreateArgs` and `buildSnapshotArgs`**

In `mcp/src/tools/dream.ts`, add `family` to the filter:

```ts
export interface DreamCreateArgs {
  instructions?: string;
  transcript_filter?: {
    project_slug?: string;
    since?: string;
    max_count?: number;
    family?: boolean;        // mine the whole monorepo family (Phase B)
  };
  model?: string;
}
```

Replace `buildSnapshotArgs` with the family-aware version (3rd param is the resolved family set; ignored unless `family` is requested and no `"all"` opt-out):

```ts
/** Build the dream-snapshot.sh argv. Scope: project_slug:"all" → no --slug (every transcript);
 *  transcript_filter.family → one --slug per family member (sorted); else the single active project
 *  (leaf) or an explicit project_slug. (Assumes instructions length already validated.) */
export function buildSnapshotArgs(
  args: DreamCreateArgs, activeSlug: string | undefined, family?: Set<string>,
): string[] {
  const out: string[] = [];
  if (args.instructions) out.push('--instructions', args.instructions);
  const requested = args.transcript_filter?.project_slug;
  if (requested === 'all') {
    // explicit cross-project opt-out → no --slug
  } else if (args.transcript_filter?.family && family && family.size) {
    for (const s of [...family].sort()) out.push('--slug', s);
  } else {
    const scope = requested ?? activeSlug;
    if (scope) out.push('--slug', scope);
  }
  if (args.transcript_filter?.since) out.push('--since', args.transcript_filter.since);
  const maxCount = Math.min(args.transcript_filter?.max_count ?? 50, 100);
  out.push('--max-count', String(maxCount));
  if (args.model) out.push('--model', args.model);
  return out;
}
```

In `dreamCreate`, compute the family and pass it (add the import: `import { projectFamily } from './project-registry.js';`):

```ts
  const activeSlug = resolveActiveSlug(brainDir());
  const family = activeSlug ? projectFamily(brainDir(), activeSlug) : undefined;
  const scriptArgs = buildSnapshotArgs(args, activeSlug, family);
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd mcp && npx vitest run src/tools/dream.test.ts && npm run typecheck`
Expected: PASS (family cases + the Phase A buildSnapshotArgs cases still green — they call the 2-arg form; the 3rd param is optional so they remain valid).

- [ ] **Step 5: Make `dream-snapshot.sh` OR multiple `--slug` values**

In `scripts/dream-snapshot.sh`, where `--slug` is parsed, accumulate into a list instead of a single var:

```bash
    --slug) FILTER_SLUGS="${FILTER_SLUGS:+$FILTER_SLUGS }$2"; shift 2 ;;
```

Then replace the single-slug filter (the `_${FILTER_SLUG}_` block at ~118-121) with an alternation over all requested slugs:

```bash
    if [ -n "$FILTER_SLUGS" ]; then
      # OR every requested slug: a transcript matches if its name contains _<slug>_ for ANY family member.
      ALT=$(printf '%s' "$FILTER_SLUGS" | tr ' ' '|')
      fname=$(basename "$tf")
      echo "$fname" | grep -qE "_(${ALT})_" || continue
    fi
```

If the script still references `$FILTER_SLUG` elsewhere (the Phase A `PROJECT_SLUG_RECORD` for `status.json`), set `PROJECT_SLUG_RECORD="${FILTER_SLUGS:-all}"` so the recorded scope reflects the family list, keeping the empty→`"all"` rule.

- [ ] **Step 6: Document `--family` in the dream SKILL.md**

In `skills/dream/SKILL.md`, Phase: Creation, extend the `transcript_filter` bullet:

```
   - `transcript_filter`: omit `project_slug` → the **active project** (leaf); `project_slug: "all"`
     → every project; `family: true` → the whole **monorepo family** (the active project's root +
     siblings, from `projects.jsonl`). `"all"` wins if both are set.
```

- [ ] **Step 7: Build + run dream e2e + commit**

Run: `cd mcp && npm run build && npm run typecheck`
Run: `bash tests/test-dream-lifecycle.sh` — confirm only the PRE-EXISTING "out-of-tree symlink" failure remains (no new failure from the multi-slug change).

```bash
git add mcp/src/tools/dream.ts mcp/src/tools/dream.test.ts scripts/dream-snapshot.sh skills/dream/SKILL.md mcp/dist
git commit -m "feat(dream): --family mines the whole monorepo family (Phase B)"
```

---

### Task 7 (OPTIONAL — graph navigation only): reconciliation projection

> **Scope note:** family scoping (Tasks 1–6) is fully functional WITHOUT this task — it reads `projects.jsonl` truth. Task 7 only mirrors the parent link into the relational graph so `knowledge_neighbors` and MOC cross-links surface family MOCs. It is the lowest-priority Phase B task and may be deferred. The load-bearing constraint is the **facet-merge guard**: this must NOT cause any child page's `project:` facet to be rewritten to the parent key.

**Files:**
- Modify: `skills/setup/SKILL.md` (after writing `parent`, project the edge + anchors)
- Test: `tests/test-reconciliation-facet-guard.sh` (new)

**Interfaces:**
- Consumes: `parent`/`root_path` in `projects.jsonl` (Task 4); `appendEdge` JSONL format; `kb-project-backfill.sh`.

- [ ] **Step 1: Write the failing facet-guard test**

Create `tests/test-reconciliation-facet-guard.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); KD="$TMP/knowledge"; mkdir -p "$KD/wiki/learnings" "$KD/graph"
# a child member page that ALREADY carries its own (leaf) facet
printf -- '---\ntitle: X\ntype: learnings\nproject: acme__web\n---\nbody\n' > "$KD/wiki/learnings/x.md"
# registry registers EACH project as its OWN anchor (never the parent → no propagation)
printf '{"anchor":"acme","project":"acme"}\n{"anchor":"acme__web","project":"acme__web"}\n' > "$KD/graph/project-registry.jsonl"
# a project-level part_of edge child→parent (graph navigation only)
printf '{"op":"assert","from":"acme__web","to":"acme","type":"part_of","recorded_at":"2026-06-18T00:00:00Z"}\n' > "$KD/graph/edges.jsonl"
KNOWLEDGE_DIR="$KD" bash "$HERE/scripts/kb-project-backfill.sh" >/dev/null 2>&1
FACET=$(grep -E '^project:' "$KD/wiki/learnings/x.md" | head -1)
if [ "$FACET" = "project: acme__web" ]; then echo "PASS: child facet preserved (not rewritten to parent)"; else echo "FAIL: child facet became [$FACET]"; rm -rf "$TMP"; exit 1; fi
rm -rf "$TMP"; echo "ALL PASS"
```

- [ ] **Step 2: Run the test to verify the guard holds**

Run: `bash tests/test-reconciliation-facet-guard.sh`
Expected: `ALL PASS` — `kb-project-backfill.sh`'s `set_project` never overwrites an existing facet (`:32`), so the guard already holds. (If it FAILS, the projection design is unsafe and must not ship — stop and escalate.) Note: confirm `kb-project-backfill.sh` reads the knowledge dir from `KNOWLEDGE_DIR` (the var it uses for `KDIR`); if it uses a different env var, set that instead.

- [ ] **Step 3: Project the edge + anchors from `setup` (prose + bash)**

In `skills/setup/SKILL.md`, after the operator confirms a `parent`, add a step that (a) appends each project as its OWN anchor to `project-registry.jsonl` (idempotent), and (b) asserts the project-level `part_of` edge child→parent. There is no bash graph-relate CLI, so append the edge JSONL directly mirroring `appendEdge`'s format:

```bash
KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"; KD="${KD/#\~/$HOME}"
REG="$KD/graph/project-registry.jsonl"; mkdir -p "$KD/graph"
# each project anchors ITSELF (never the parent) — keeps facet assignment leaf-correct
for pair in "$SLUG:$SLUG" "$PARENT:$PARENT"; do
  a="${pair%%:*}"; p="${pair##*:}"; [ -n "$a" ] || continue
  grep -qF "\"anchor\":\"$a\"" "$REG" 2>/dev/null || \
    jq -nc --arg a "$a" --arg p "$p" '{anchor:$a, project:$p}' >> "$REG"
done
# project-level part_of edge (graph navigation): child __ parent
EDGES="$KD/graph/edges.jsonl"
if [ -n "$PARENT" ] && ! jq -se --arg f "$SLUG" --arg t "$PARENT" \
     'map(select(.from==$f and .to==$t and .type=="part_of" and .valid_to==null)) | length>0' "$EDGES" >/dev/null 2>&1; then
  jq -nc --arg f "$SLUG" --arg t "$PARENT" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{op:"assert", from:$f, to:$t, type:"part_of", recorded_at:$ts, source:"setup", confidence:"high"}' >> "$EDGES"
fi
```

State in the skill that the maintainer's Phase 3 re-validates `projects.jsonl ↔ graph` on its normal cadence (re-parent = `knowledge_relate --invalidate` then assert).

- [ ] **Step 4: Re-run the guard test + commit**

Run: `bash tests/test-reconciliation-facet-guard.sh`
Expected: `ALL PASS`.

```bash
git add skills/setup/SKILL.md tests/test-reconciliation-facet-guard.sh
git commit -m "feat(reconciliation): project parent link to graph (anchors+part_of), facet-guarded (Phase B, optional)"
```

---

### Task 8: Phase B integration verification

**Files:** none (verification only).

- [ ] **Step 1: Full unit suite + typecheck + build**

Run: `cd mcp && npm test && npm run build`
Expected: Phase B's new tests pass (`project-registry`, `project-dir` registry-path, `knowledge-search` family, `dream` family); **zero NEW failures** vs the 14 pre-existing. Verify the new `knowledge-search` family test passes and the pre-existing `knowledge-search.test.ts` failures are the SAME ones as before Phase B (not the new family case).

- [ ] **Step 2: Bash tests**

Run: `bash tests/test-detect-project.sh && bash tests/test-session-load-jsonl-membership.sh && bash tests/test-reconciliation-facet-guard.sh`
Expected: `ALL PASS` for each (run the last only if Task 7 was done).

- [ ] **Step 3: Bash↔TS slug parity spot-check**

From a fixture monorepo child dir, confirm `sb_detect_project`'s slug equals what `resolveActiveSlug` returns when `projects.jsonl` carries that child's `root_path` — both yield `<root>__<leaf>`. Document the commands + result.

- [ ] **Step 4: End-to-end family-scope demonstration**

With a registered family in a temp brain dir, query as `acme__api` and confirm a sibling (`acme__web`) page is in-scope while an `unrelated`-project page is dropped. (The Task 5 unit test proves this; this is the integrated confirmation.)

- [ ] **Step 5: Report Phase B complete**

Summarize: family scoping live (resolver + search + dream), detection covers the three topologies, registration writes `parent`/`root_path`, reconciliation (if Task 7) is facet-guarded. Note Phase C (migration + setup-collision, incl. `git_remote` identity) is the final plan.

---

## Self-Review (against the spec)

**Spec coverage — "Approved design (M3 scoping)" §:**
- Data model `parent`/`root_path` (additive) → Task 1 (`ProjectRecord`) + Task 4 (written). ✓ (`git_remote` deferred to Phase C.)
- Detection = auto-detect + confirm + marker fallback, three topologies → Task 3 (`sb_detect_project`: superproject / workspace-manifest / `.sb-monorepo.json`) + Task 4 (setup confirm). ✓
- Path-qualified `<root>__<leaf>` → Task 3 (slug form) + parity constraint. ✓
- Family computation (root + siblings + self, symmetric) → Task 1 (`projectFamily`) + tests. ✓
- Search tier `own>family>neigh>global>other`, cutoff ≤3→≤4 → Task 5. ✓
- Drain stays leaf-default → unchanged; Phase B adds no new drain path (family changes READ scope only). ✓
- `resolveActiveSlug` registry-path longest-prefix → Task 2. ✓
- Reconciliation (projects.jsonl→graph), facet-merge guard → Task 7 (optional) + guard test. ✓
- Dream `--family` → Task 6. ✓

**Placeholder scan:** Every code step carries complete code. Three "adapt to the existing harness" notes (Task 4 failure-flag var; Task 5 `makeFixture`/result fields; Task 7 backfill env var) point at the concrete existing idiom in the named files rather than inventing a divergent one. No TBD/TODO.

**Type consistency:** `ProjectRecord`/`loadRegistry`/`projectFamily`/`resolveSlugByPath` (Task 1) are consumed with matching signatures by `resolveActiveSlug` (Task 2), `knowledgeSearch` (Task 5), `dreamCreate` (Task 6). `buildSnapshotArgs` gains an optional 3rd `family?: Set<string>` — Phase A 2-arg calls stay valid. `sb_detect_project` emits `slug\tparent\troot_path`, consumed verbatim by `session-load.sh` + `setup` (Task 4).

**Scope:** Phase B only. No `git_remote`, no old-data migration, no setup-collision (all Phase C). Drain/capture unchanged. Task 7 explicitly optional + facet-guarded.
