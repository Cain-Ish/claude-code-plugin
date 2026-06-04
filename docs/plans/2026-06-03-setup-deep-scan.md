# SP-3 Setup Deep-Scan Implementation Plan

> **For agentic workers:** Implement this plan task-by-task following TDD. Steps use checkbox (`- [ ]`) syntax for tracking. See `second-brain:test-driven-development` and `second-brain:verification-before-completion`.

**Goal:** At setup, deep-scan the repo for high-signal knowledge docs and capture them into the project's raw inbox (`captured_by: setup-scan`), with a dry-run preview, a cap, and content-hash dedup — reusing `doc-sources` filtering and SP-2's `captureItem`.

**Architecture:** A pure `raw-scan.ts` module globs `**/*.{md,markdown}`, applies a curation heuristic (high-signal include rules) plus low-signal/secret denylists plus `doc-sources.filterIgnored` (junk + git-ignore), caps at `SB_SCAN_MAX`, and captures survivors via SP-2 `captureItem`. A thin `raw-scan-cli` exposes `--dry-run`/capture; the `setup` skill runs it (preview → confirm → capture).

**Tech Stack:** TypeScript (esbuild ESM, Node 20), vitest, the `glob` dep, POSIX bash (mawk-safe), git.

**Spec:** `docs/specs/2026-06-03-setup-deep-scan-design.md`

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `mcp/src/tools/doc-sources.ts` | export `filterIgnored` (reuse junk + git-ignore drop) | Modify (1 line) |
| `mcp/src/tools/raw-scan.ts` | pure: `scanCandidates`, `scanCap`, `runScan` | Create |
| `mcp/src/tools/raw-scan.test.ts` | vitest | Create |
| `mcp/src/tools/raw-scan-cli.ts` | thin CLI (`--dry-run` / capture) | Create |
| `mcp/package.json` | register the esbuild bundle | Modify |
| `skills/setup/SKILL.md` | new scan step + `Bash(node *)` allowed-tool | Modify |
| `tests/test-setup-scan.sh` | CLI/skill end-to-end (incl. git-ignore) | Create |

Reused as-is: `captureItem` (SP-2), `assertSafeSlug`/`hashContent` (already exported), the `glob` dep, the `CapturedBy` union (`'setup-scan'` already valid — no schema change).

---

## Task 1: `raw-scan.ts` curation + capture module

**Files:**
- Modify: `mcp/src/tools/doc-sources.ts` (export `filterIgnored`)
- Create: `mcp/src/tools/raw-scan.ts`
- Test: `mcp/src/tools/raw-scan.test.ts`

- [ ] **Step 1: Export `filterIgnored`.** In `mcp/src/tools/doc-sources.ts` line 52, change `function filterIgnored(` to `export function filterIgnored(`.

- [ ] **Step 2: Write the failing test.** Create `mcp/src/tools/raw-scan.test.ts`:

```typescript
import { describe, it, expect } from 'vitest';
import { promises as fs } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { scanCandidates, runScan, scanCap } from './raw-scan.js';
import { listItems } from './raw-inbox.js';

/** Build a temp repo with a known file set; returns its root. NOT a git repo (junk-filter only). */
async function repo(): Promise<string> {
  const root = await fs.mkdtemp(join(tmpdir(), 'scan-'));
  // Distinct body per file — captureItem dedups by content hash, so identical bodies
  // would collapse to one captured item and break the capture-count assertion.
  const w = async (rel: string, body = `# ${rel}\nunique content for ${rel}`) => {
    await fs.mkdir(join(root, rel, '..'), { recursive: true });
    await fs.writeFile(join(root, rel), body);
  };
  await w('README.md');                       // rule 1 (root)
  await w('docs/guide.md');                    // rule 2 (docs dir)
  await w('docs/adr/ADR-001.md');              // rule 2 (adr dir)
  await w('src/DESIGN.md');                    // rule 3 (basename)
  await w('src/components/notes.md');          // EXCLUDED: file named notes, not a notes/ dir
  await w('CHANGELOG.md');                      // EXCLUDED: low-signal denylist
  await w('docs/credentials.md');              // EXCLUDED: secret denylist
  await w('node_modules/pkg/README.md');       // EXCLUDED: junk dir
  return root;
}

async function brain(): Promise<{ brainDir: string; slug: string }> {
  const brainDir = await fs.mkdtemp(join(tmpdir(), 'scan-brain-'));
  const slug = 'demo';
  await fs.mkdir(join(brainDir, 'projects', slug), { recursive: true });
  return { brainDir, slug };
}

function rels(root: string, paths: string[]): string[] {
  return paths.map(p => p.slice(root.length + 1).split('\\').join('/'));
}

describe('raw-scan', () => {
  it('curates high-signal docs and excludes notes/changelog/secret/junk', async () => {
    const root = await repo();
    const got = rels(root, await scanCandidates(root)).sort();
    expect(got).toEqual(['README.md', 'docs/adr/ADR-001.md', 'docs/guide.md', 'src/DESIGN.md']);
  });

  it('scanCap reads SB_SCAN_MAX (default 50)', () => {
    delete process.env.SB_SCAN_MAX;
    expect(scanCap()).toBe(50);
    process.env.SB_SCAN_MAX = '2';
    expect(scanCap()).toBe(2);
    delete process.env.SB_SCAN_MAX;
  });

  it('dryRun previews (capped) and writes nothing', async () => {
    const root = await repo();
    const { brainDir, slug } = await brain();
    process.env.SB_SCAN_MAX = '2';
    const r = await runScan(root, brainDir, slug, { dryRun: true });
    delete process.env.SB_SCAN_MAX;
    expect(r.candidates).toHaveLength(2);
    expect(r.truncated).toBe(2);          // 4 high-signal, cap 2
    expect(r.captured).toBe(0);
    expect(await listItems(brainDir, slug)).toHaveLength(0); // nothing written
  });

  it('captures survivors stamped captured_by: setup-scan, and dedups on re-run', async () => {
    const root = await repo();
    const { brainDir, slug } = await brain();
    const r1 = await runScan(root, brainDir, slug, {});
    expect(r1.captured).toBe(4);
    const items = await listItems(brainDir, slug);
    expect(items).toHaveLength(4);
    expect(items.every(i => i.captured_by === 'setup-scan')).toBe(true);
    const r2 = await runScan(root, brainDir, slug, {});   // re-run: unchanged → all skipped
    expect(r2.captured).toBe(0);
    expect(r2.skipped).toBe(4);
    expect(await listItems(brainDir, slug)).toHaveLength(4);
  });
});
```

- [ ] **Step 3: Run it to verify it fails.**

Run: `cd mcp && npx vitest run raw-scan.test.ts`
Expected: FAIL — `Cannot find module './raw-scan.js'`.

- [ ] **Step 4: Implement `mcp/src/tools/raw-scan.ts`.**

```typescript
import { resolve, relative, sep } from 'path';
import { glob } from 'glob';
import { filterIgnored, assertSafeSlug } from './doc-sources.js';
import { captureItem } from './raw-inbox.js';

const DOC_DIRS = new Set(['docs', 'doc', 'adr', 'adrs', 'rfc', 'rfcs', 'spec', 'specs', 'decisions', '.ai-docs', 'notes']);
const NAME_INCLUDE = /^(readme|architecture|design|contributing|roadmap)/i;  // basename (sans ext)
const LOW_SIGNAL = /^(changelog|license|licence|code_of_conduct)/i;          // basename (sans ext)
const TEMPLATE_RE = /template/i;                                              // basename
const SECRET_RE = /(^|\/)\.env|\.pem$|\.key$|id_rsa|secret|credential/i;      // full rel path

/** A repo-relative markdown path is high-signal iff it matches an include rule and no denylist. */
function isHighSignal(rel: string): boolean {
  const segs = rel.split('/');
  const file = segs[segs.length - 1];
  if (!/\.(md|markdown)$/i.test(file)) return false;
  const baseName = file.replace(/\.(md|markdown)$/i, '');
  const dirs = segs.slice(0, -1).map(s => s.toLowerCase());
  const include = segs.length === 1                       // rule 1: root-level *.md
    || dirs.some(d => DOC_DIRS.has(d))                    // rule 2: a directory segment is a doc dir
    || NAME_INCLUDE.test(baseName);                       // rule 3: high-signal basename anywhere
  if (!include) return false;
  if (LOW_SIGNAL.test(baseName) || TEMPLATE_RE.test(file)) return false;  // low-signal
  if (SECRET_RE.test(rel)) return false;                                  // secret defense-in-depth
  return true;
}

/** Max items captured per scan (SB_SCAN_MAX, default 50). */
export function scanCap(): number {
  const n = parseInt(process.env.SB_SCAN_MAX ?? '', 10);
  return Number.isFinite(n) && n >= 0 ? n : 50;
}

/** Walk the repo for high-signal markdown docs (junk + git-ignored dropped). Sorted, uncapped. */
export async function scanCandidates(projectRoot: string): Promise<string[]> {
  const root = resolve(projectRoot);
  const matches = await glob('**/*.{md,markdown}', { cwd: root, absolute: true, nodir: true }).catch(() => [] as string[]);
  const within = matches.filter(p => { const r = resolve(p); return r === root || r.startsWith(root + sep); });
  const highSignal = within.filter(p => isHighSignal(relative(root, p)));
  const kept = filterIgnored(root, highSignal);  // drops JUNK_DIRS + `git check-ignore` paths
  kept.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));  // byte-stable, locale-independent
  return kept;
}

export interface ScanResult { candidates: string[]; captured: number; skipped: number; truncated: number; }

/** Scan + (unless dryRun) capture each candidate into the raw inbox as `setup-scan` material. */
export async function runScan(projectRoot: string, brainDir: string, slug: string,
                              opts: { dryRun?: boolean }): Promise<ScanResult> {
  assertSafeSlug(slug);
  const all = await scanCandidates(projectRoot);
  const cap = scanCap();
  const candidates = all.slice(0, cap);
  const truncated = Math.max(0, all.length - cap);
  if (opts.dryRun) return { candidates, captured: 0, skipped: 0, truncated };
  let captured = 0, skipped = 0;
  for (const src of candidates) {
    try {
      const r = await captureItem({ brainDir, slug, kind: 'file', source: src, capturedBy: 'setup-scan' });
      if (r.duplicate) skipped++; else captured++;
    } catch { skipped++; }  // unreadable → skip, never abort the scan
  }
  return { candidates, captured, skipped, truncated };
}
```

- [ ] **Step 5: Run the tests to verify they pass.**

Run: `cd mcp && npx vitest run raw-scan.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 6: Run the full vitest suite (the `filterIgnored` export is the only shared change).**

Run: `cd mcp && npx vitest run`
Expected: all green.

- [ ] **Step 7: Commit.**

```bash
git add mcp/src/tools/doc-sources.ts mcp/src/tools/raw-scan.ts mcp/src/tools/raw-scan.test.ts
git commit -m "feat(kb): raw-scan curation + capture module (SP-3 Task 1)"
```

---

## Task 2: `raw-scan-cli` thin bundle

**Files:**
- Create: `mcp/src/tools/raw-scan-cli.ts`
- Modify: `mcp/package.json` (esbuild registration)

- [ ] **Step 1: Write the CLI.** Create `mcp/src/tools/raw-scan-cli.ts`:

```typescript
import { homedir } from 'os';
import { join, basename, relative } from 'path';
import { existsSync, readFileSync } from 'fs';
import { runScan } from './raw-scan.js';

function resolveSlug(brainDir: string): string | undefined {
  if (process.env.SB_ACTIVE_SLUG) return process.env.SB_ACTIVE_SLUG;
  try {
    const pin = readFileSync(join(brainDir, '.active-session-slug'), 'utf-8').trim();
    if (pin && existsSync(join(brainDir, 'projects', pin, 'PROJECT.md'))) return pin;
  } catch { /* no pin */ }
  const base = basename(process.cwd());
  return base && base !== '/' && base !== '.' && base !== '..' ? base : undefined;
}

async function main(): Promise<void> {
  const brainDir = process.env.BRAIN_DIR || join(homedir(), '.second-brain');
  const projectRoot = process.env.SCAN_ROOT || process.cwd();
  const slug = resolveSlug(brainDir);
  if (!slug) { console.log('scan: could not resolve the active project. cd into a project.'); return; }
  const dryRun = process.argv.includes('--dry-run');
  try {
    const r = await runScan(projectRoot, brainDir, slug, { dryRun });
    if (dryRun) {
      const more = r.truncated ? ` (+${r.truncated} over the SB_SCAN_MAX cap)` : '';
      console.log(`${r.candidates.length} high-signal doc(s) to capture into ${slug}'s raw inbox${more}:`);
      for (const p of r.candidates) console.log(`  - ${relative(projectRoot, p)}`);
      if (r.candidates.length === 0) console.log('  (no high-signal docs found)');
    } else {
      const more = r.truncated ? `, ${r.truncated} over the cap (raise SB_SCAN_MAX or /second-brain:track them)` : '';
      console.log(`Captured ${r.captured}, skipped ${r.skipped} already-in-inbox${more}. Review: /second-brain:capture --list`);
    }
  } catch (e) {
    console.log(`scan error: ${e instanceof Error ? e.message : String(e)}`);
  }
}

main();
```

- [ ] **Step 2: Register the esbuild bundle.** In `mcp/package.json`, the `"bundle"` script ends with the `raw-capture-cli` entry. Append one more after it (identical flags, new entry name):

```
 && esbuild src/tools/raw-scan-cli.ts --bundle --platform=node --target=node20 --format=esm --external:@huggingface/transformers --outfile=dist/tools/raw-scan-cli.bundle.js
```

- [ ] **Step 3: Build to verify it compiles + bundles.**

Run: `cd mcp && npm run build`
Expected: build succeeds; `ls dist/tools/raw-scan-cli.bundle.js` exists.

- [ ] **Step 4: Smoke-test the CLI by hand.**

Run:
```bash
T=$(mktemp -d); mkdir -p "$T/projects/demo"; : > "$T/projects/demo/PROJECT.md"
R=$(mktemp -d); printf '# Readme\nx\n' > "$R/README.md"; mkdir -p "$R/docs"; printf '# G\nx\n' > "$R/docs/guide.md"
BRAIN_DIR="$T" SB_ACTIVE_SLUG=demo SCAN_ROOT="$R" node mcp/dist/tools/raw-scan-cli.bundle.js --dry-run
BRAIN_DIR="$T" SB_ACTIVE_SLUG=demo SCAN_ROOT="$R" node mcp/dist/tools/raw-scan-cli.bundle.js
rm -rf "$T" "$R"
```
Expected: dry-run lists `README.md` + `docs/guide.md`; capture prints `Captured 2, skipped 0 already-in-inbox.`

- [ ] **Step 5: Commit.**

```bash
git add mcp/src/tools/raw-scan-cli.ts mcp/package.json mcp/dist
git commit -m "feat(kb): raw-scan-cli bundle (SP-3 Task 2)"
```

---

## Task 3: `setup` scan step + end-to-end test

**Files:**
- Modify: `skills/setup/SKILL.md`
- Test: `tests/test-setup-scan.sh`

- [ ] **Step 1: Write the failing bash test.** Create `tests/test-setup-scan.sh`:

```bash
#!/bin/bash
# End-to-end: raw-scan-cli previews + captures high-signal docs into a project's raw inbox,
# honors git-ignore, dedups on re-run; the setup skill wires the CLI.
set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
CLI="$ROOT/mcp/dist/tools/raw-scan-cli.bundle.js"
SKILL="$ROOT/skills/setup/SKILL.md"
fail(){ echo "FAIL: $1"; exit 1; }; pass(){ echo "PASS: $1"; }

grep -q 'raw-scan-cli.bundle.js' "$SKILL" || fail "setup skill does not invoke raw-scan-cli"
grep -qE 'allowed-tools:.*Bash\(node \*\)' "$SKILL" || fail "setup skill missing Bash(node *) allowed-tool"
pass "setup skill wires the scan CLI"

command -v node >/dev/null 2>&1 || { echo "SKIP: node"; echo; echo "ALL PASS"; exit 0; }
[ -f "$CLI" ] || { echo "SKIP: CLI bundle not built"; echo; echo "ALL PASS"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; echo; echo "ALL PASS"; exit 0; }

T=$(mktemp -d); export BRAIN_DIR="$T" SB_ACTIVE_SLUG=demo
mkdir -p "$T/projects/demo"; : > "$T/projects/demo/PROJECT.md"
R=$(mktemp -d)
( cd "$R" && git init -q && git config user.email t@t && git config user.name t )
printf '# Readme\nx\n' > "$R/README.md"
mkdir -p "$R/docs"; printf '# G\nx\n' > "$R/docs/guide.md"; printf '# sec\nx\n' > "$R/docs/secret-ignored.md"
printf 'docs/secret-ignored.md\n' > "$R/.gitignore"   # git-ignored → must be excluded

OUT=$(SCAN_ROOT="$R" node "$CLI" --dry-run)
echo "$OUT" | grep -q 'README.md' || fail "dry-run missing README.md ($OUT)"
echo "$OUT" | grep -q 'docs/guide.md' || fail "dry-run missing docs/guide.md"
echo "$OUT" | grep -q 'secret-ignored' && fail "dry-run included a git-ignored file"
[ -z "$(ls -A "$T/projects/demo/raw" 2>/dev/null)" ] || fail "dry-run wrote items"
pass "dry-run previews high-signal docs, excludes git-ignored, writes nothing"

OUT=$(SCAN_ROOT="$R" node "$CLI")
echo "$OUT" | grep -q 'Captured 2, skipped 0' || fail "capture count wrong ($OUT)"
grep -lq '^captured_by: setup-scan$' "$T/projects/demo/raw"/*.md || fail "items not stamped setup-scan"
pass "capture writes 2 setup-scan items"

OUT=$(SCAN_ROOT="$R" node "$CLI")
echo "$OUT" | grep -q 'Captured 0, skipped 2' || fail "re-run not idempotent ($OUT)"
pass "re-run dedups (idempotent)"

rm -rf "$T" "$R"
echo; echo "ALL PASS"
```

- [ ] **Step 2: Run it to verify it fails.**

Run: `bash tests/test-setup-scan.sh`
Expected: FAIL — `setup skill does not invoke raw-scan-cli`.

- [ ] **Step 3a: Add `Bash(node *)` to the setup skill's allowed-tools.** In `skills/setup/SKILL.md` line 6, append ` Bash(node *)` to the end of the `allowed-tools:` line.

- [ ] **Step 3b: Insert the scan step.** In `skills/setup/SKILL.md`, replace the `### 6. Confirm` heading line with the new scan step followed by a renumbered Confirm:

```markdown
### 6. Deep-scan the repo into the raw inbox (preview, then confirm)

Seed this project's KB by capturing its **high-signal docs** (README, `docs/`, ADRs,
`DESIGN.md`, …) into the raw inbox, where the maintainer later refines them into wiki
notes. Skipped entirely if `SB_SCAN_SKIP=1`. Curation reuses the doc-sources junk +
git-ignore filtering and a low-signal/secret denylist; the inbox dedups by content hash,
so re-running setup only captures new or changed docs.

```bash
if [ "${SB_SCAN_SKIP:-0}" != "1" ]; then
  SCAN_CLI="${CLAUDE_PLUGIN_ROOT}/mcp/dist/tools/raw-scan-cli.bundle.js"
  SCAN_ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  SCAN_ROOT="$SCAN_ROOT_DIR" node "$SCAN_CLI" --dry-run
fi
```

Show the preview list. This writes nothing yet. **Ask the user to confirm** capturing
these into the raw inbox (an impactful action). On a yes:

```bash
SCAN_ROOT="$SCAN_ROOT_DIR" node "$SCAN_CLI"
```

Report the captured/skipped counts and point the user to `/second-brain:capture --list`.
If the preview was empty, say there were no high-signal docs to seed and move on.

### 7. Confirm
```

- [ ] **Step 4: Build the CLI bundle (needed for the e2e), then run the test to verify it passes.**

Run: `cd mcp && npm run build && cd .. && bash tests/test-setup-scan.sh`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit.**

```bash
git add skills/setup/SKILL.md tests/test-setup-scan.sh
git commit -m "feat(kb): setup deep-scan step — seed the raw inbox (SP-3 Task 3)"
```

---

## Task 4: Ship — gate, version bump, PR

- [ ] **Step 1: Branch (if not already).** `git checkout -b feat/sp3-setup-deep-scan` (do all of SP-3 on this branch from the start).

- [ ] **Step 2: Build + full suite.** `cd mcp && npm run build && cd .. && bash tests/run-all.sh` → expect `ALL GREEN` (includes `test-setup-scan`, `test-mcp-typecheck`).

- [ ] **Step 3: Deep-review gate.** Run `second-brain:code-review-deep --base main`. Fix any confirmed (≥70) finding with TDD; re-run until clean.

- [ ] **Step 4: Version bump + migration row.**
  - `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json`: `0.24.11` → `0.24.12`.
  - `skills/upgrade/SKILL.md`: add a `**0.24.12**` row above `**0.24.11**` (setup deep-scan: curated high-signal repo docs → raw inbox via `/second-brain:setup`'s new step, reusing `filterIgnored` + SP-2 `captureItem`; dry-run preview + confirm; `SB_SCAN_MAX=50`, `SB_SCAN_SKIP=1`; no MCP server tool change, server stays 2.6.4; additive — opt-in via the setup confirm).

- [ ] **Step 5: Rebuild + verify lockstep + migration-row test.**

```bash
cd mcp && npm run build && cd ..
bash scripts/validate-plugin.sh
bash tests/test-upgrade-migration-row.sh
```
Expected: `OK: all plugin files valid` + `PASS: upgrade migration row present for 0.24.12`.

- [ ] **Step 6: Commit + PR + merge.**

```bash
git add -A
git commit -m "chore(release): setup deep-scan (SP-3) — bump 0.24.12 + migration row"
git push -u origin feat/sp3-setup-deep-scan
gh pr create --base main --title "feat(kb): setup deep-scan (SP-3)" --body "<summary>"
gh pr merge --merge --delete-branch
git checkout main && git pull --ff-only origin main
```

---

## Self-Review

**1. Spec coverage:**
- Curation heuristic (rules 1–3 + low-signal + secret + junk/git-ignore) → Task 1 `isHighSignal` + `scanCandidates`. ✓
- Reuse `filterIgnored` → Task 1 Step 1 export + use. ✓
- Cap `SB_SCAN_MAX=50` + truncated report → Task 1 `scanCap`/`runScan`. ✓
- Capture via SP-2 `captureItem` (`captured_by: setup-scan`) → Task 1 `runScan`. ✓
- Dedup on re-run → Task 1 test + Task 3 e2e. ✓
- Dry-run preview → Task 1 `runScan({dryRun})` + Task 2 CLI + Task 3 setup step. ✓
- Folded into setup, confirm-first, `SB_SCAN_SKIP` → Task 3. ✓
- No new server tool / no schema change → no server.ts/kb-schema edits in any task. ✓
- Cross-OS (glob + path; bash mawk-safe) → Task 1/2 use `glob`/`path`; Task 3 bash has no awk. ✓
- git-ignore tested in bash e2e; vitest hermetic (junk only) → Task 1 test (no git) + Task 3 test (`git init`). ✓

**2. Placeholder scan:** Task 4 Step 6 `--body "<summary>"` is filled at ship time (write a real summary like SP-2's). No other placeholders; all code complete.

**3. Type consistency:** `scanCandidates(projectRoot): Promise<string[]>`, `scanCap(): number`, `runScan(projectRoot, brainDir, slug, {dryRun}): Promise<ScanResult>` are identical across Task 1 (impl), Task 1 (test), and Task 2 (CLI). `ScanResult` fields (`candidates`, `captured`, `skipped`, `truncated`) match every consumer. `captureItem({kind:'file', source, capturedBy:'setup-scan'})` matches SP-2's `CaptureInput`. The CLI's `resolveSlug` mirrors `raw-capture-cli` (incl. the `..` guard).
