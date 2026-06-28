# P6b — Transcript-ingest Sanitization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or executing-plans. Steps use `- [ ]` checkboxes.

**Goal:** Close the dominant memory-poisoning vector P6a left open — untrusted **session transcripts** carrying invisible/Tags-block smuggling chars into `transcript → dream → wiki → auto-injection` and `transcript → episodic`.

**Architecture (decided):** Sanitize at the two **consume-side** intake points, reusing the single canonical TS `stripInvisible` (no codepoint drift, no per-hook latency, no fragile cross-platform sed):
1. **Dream path** — `dream-snapshot.sh` stages transcripts for the dream-runner agent. Replace the copy/symlink with a **sanitize-on-copy** through a small bundled node CLI, so the agent only ever reads cleaned staged copies (the original transcript is never mutated — critical, because POSIX staging currently *symlinks* the original).
2. **Episodic path** — `buildEpisodicIndex` + `episodicRead` (TS) sanitize content on read.

**Tech Stack:** TypeScript (MCP, esbuild bundle, vitest) + bash (lib.sh/dream-snapshot.sh, shell tests).

## Global Constraints

- Single source of truth: `stripInvisible` lives in ONE module (`mcp/src/tools/sanitize.ts`); raw-inbox/episodic/CLI all import it. No second codepoint list.
- Cross-platform: macOS/Windows-MSYS/Linux/BSD. The bash side must not depend on GNU-only sed/awk; it shells out to the node CLI (node is already required for the dream pipeline).
- **Never mutate the source transcript** — sanitize into the staging copy only.
- Version lockstep on release (plugin.json + marketplace.json + CHANGELOG). Current 0.33.20 → 0.33.21.
- Fail-loud-but-degrade: if the sanitize CLI/node is unavailable at snapshot time, log via `sb_log_error` and fall back to a plain copy (the episodic TS layer is an independent second line of defense).

---

### Task 1: Extract `sanitize.ts` + add the `sanitize-cli` bundle

**Files:**
- Create: `mcp/src/tools/sanitize.ts`, `mcp/src/tools/sanitize-cli.ts`, `mcp/src/tools/sanitize.test.ts`
- Modify: `mcp/src/tools/raw-inbox.ts` (import + re-export `stripInvisible`), `mcp/package.json` (bundle list)

**Interfaces:**
- Produces: `export function stripInvisible(s: string): string` (moved verbatim from raw-inbox.ts, same regex `/[\u{200B}\u{2060}\u{FEFF}\u{E0000}-\u{E007F}]/gu`).
- `sanitize-cli`: no args → stdin→stdout; with file args → rewrite each file in place.

- [ ] **Step 1:** Create `mcp/src/tools/sanitize.ts` with the `INVISIBLE_RE` + `stripInvisible` (move the definition + docstring out of raw-inbox.ts).
- [ ] **Step 2:** In `raw-inbox.ts` replace the local `const INVISIBLE_RE`/`stripInvisible` with `import { stripInvisible } from './sanitize.js';` and `export { stripInvisible } from './sanitize.js';` (keeps `raw-inbox.test.ts`'s existing import working). `fmValue` keeps calling `stripInvisible`.
- [ ] **Step 3:** Write `mcp/src/tools/sanitize.test.ts` — the 4 unit cases (Tags block stripped; ZWSP/WJ/BOM stripped; emoji ZWJ U+200D preserved; idempotent/empty). Run: `npx vitest run src/tools/sanitize.test.ts` → expect PASS (function already exists).
- [ ] **Step 4:** Create `sanitize-cli.ts`:
```typescript
#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'fs';
import { stripInvisible } from './sanitize.js';

const files = process.argv.slice(2);
if (files.length === 0) {
  let input = '';
  process.stdin.setEncoding('utf-8');
  process.stdin.on('data', c => { input += c; });
  process.stdin.on('end', () => process.stdout.write(stripInvisible(input)));
} else {
  for (const f of files) writeFileSync(f, stripInvisible(readFileSync(f, 'utf-8')));
}
```
- [ ] **Step 5:** Add `sanitize-cli` to the `bundle` script in `mcp/package.json` (one more `&& esbuild src/tools/sanitize-cli.ts … --outfile=dist/tools/sanitize-cli.bundle.js`). Run `npm run build`. Verify `dist/tools/sanitize-cli.bundle.js` exists.
- [ ] **Step 6:** `npx vitest run src/tools/raw-inbox.test.ts` (re-export intact) + commit.

### Task 2: Sanitize the episodic TS read path

**Files:** Modify `mcp/src/tools/episodic-search.ts`; Test `mcp/src/tools/episodic-search.test.ts` (or new).

- [ ] **Step 1 (red):** Add a test: write a transcript `.txt` containing a Tags-block char in an exchange; assert `episodicRead(path)` returns content with no `[\u{E0000}-\u{E007F}]`; and `buildEpisodicIndex` indexes a clean snippet.
- [ ] **Step 2 (green):** `import { stripInvisible } from './sanitize.js';` Wrap both reads:
  - line ~210: `const content = stripInvisible(await fs.readFile(filePath, 'utf-8'));`
  - line ~519: `const content = stripInvisible(await fs.readFile(filePath, 'utf-8'));`
- [ ] **Step 3:** Run the episodic test + full `npm test`. Commit.

### Task 3: Sanitize the dream-snapshot path (sanitize-on-copy)

**Files:** Modify `scripts/lib.sh` (+ `sb_plugin_root`, `sb_strip_invisible_copy`), `scripts/dream-snapshot.sh`; Test `tests/test-dream-snapshot-sanitize.sh`.

- [ ] **Step 1:** In `lib.sh`, add `sb_plugin_root()` (extract the `${CLAUDE_PLUGIN_ROOT:-}` → `$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)` fallback already inlined in `sb_reindex_wiki`) and refactor `sb_reindex_wiki` to use it (kills the duplicate resolver — matches the project's single-source-resolver rule).
- [ ] **Step 2:** Add `sb_strip_invisible_copy SRC DST`:
```sh
# Copy SRC -> DST with invisible/Tags-block chars stripped (reuses the canonical TS
# sanitizer via the bundled CLI). Never mutates SRC. Degrades to a plain copy + log
# if node/CLI is unavailable (the episodic TS layer is an independent second line).
sb_strip_invisible_copy() {
  local src="$1" dst="$2"
  local cli; cli="$(sb_plugin_root)/mcp/dist/tools/sanitize-cli.bundle.js"
  if command -v node >/dev/null 2>&1 && [ -f "$cli" ] \
     && node "$cli" < "$src" > "$dst" 2>/dev/null; then
    touch -r "$src" "$dst" 2>/dev/null || true   # preserve mtime (autostage watermark)
  else
    sb_log_error "dream-snapshot" "sanitize-cli unavailable; staged UNSANITIZED copy of $(basename "$src")" 0
    cp -p "$src" "$dst"
  fi
}
```
- [ ] **Step 3:** In `dream-snapshot.sh` replace the `case "$(uname -s)" … cp -p / ln -sf … esac` block (≈ lines 139–142) with `sb_strip_invisible_copy "$tf" "$_dst"`.
- [ ] **Step 4 (test):** `tests/test-dream-snapshot-sanitize.sh` — seed `$BRAIN_DIR/transcripts/<sess>_<slug>_<date>.txt` containing a Tags-block + ZWSP char; run `dream-snapshot.sh --slug <slug>`; assert (a) the staged `dreams/<id>/transcripts/<name>` has NO invisible chars, and (b) the ORIGINAL transcript still contains them (proves no source mutation). Mirror `tests/test-dream-snapshot-mtime.sh` setup.
- [ ] **Step 5:** `bash tests/test-dream-snapshot-sanitize.sh` + `bash tests/test-dream-snapshot-mtime.sh` (regression) + `bash tests/test-script-portability.sh`. Commit.

### Task 4: Rebundle, version bump 0.33.21, gates

- [ ] Build (`npm run build`), bump 0.33.20→0.33.21 (plugin.json + marketplace.json `second-brain` + CHANGELOG entry scoping the claim to "transcript ingest: dream-snapshot + episodic read paths").
- [ ] Gates: `cd mcp && npm test`; `bash scripts/validate-plugin.sh`; targeted shell gates (test-dream-snapshot-*, test-script-portability, test-bundle-current, test-validate-plugin); then the full `bash tests/run-all.sh` (backgrounded — ~13 min on MSYS). Commit release.

## Verification (end-to-end)
- A transcript with a smuggled Tags-block char, once staged for a dream, is clean in staging and unchanged at source; `episodicRead` of it returns clean text. Full suite green; version 0.33.21 consistent.

## Out of scope (still P6b-later / P6c)
- **Scope the dream-runner's read grant** to the sanitized staging dir. Today the transcript chokepoint
  is *prompt-enforced* — the agent is directed to read the staging copies, but its broad `Read`/`Glob`/
  `Bash(cat/head/tail/grep *)` grants could still reach the un-sanitized originals at
  `~/.second-brain/transcripts/`. Grant-enforcing the chokepoint turns defense-in-depth into closure.
- bidi-control (Trojan-Source U+202A–202E/2066–2069) + variation-selector (U+E0100–E01EF) channels (need deliberate RTL/emoji-VS handling).
- Quarantine/dual-LLM drainer split; write-scoping (rm/mv/cp + Write/Edit); network sandbox; wiki-write-guard path canonicalization; the live-drain node-grant smoke check.
