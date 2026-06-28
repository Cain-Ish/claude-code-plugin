# P6a — Security Hardening Quick-Wins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close two concrete, low-risk security exposures in the second-brain memory plugin: (1) untrusted ingested content can carry invisible Unicode-Tags/zero-width characters (ASCII-smuggling) into the memory store, and (2) the background consolidation agents hold an over-broad `Bash(node *)` grant that permits arbitrary Node execution (RCE/exfil) on attacker-influenceable transcript content.

**Architecture:** Add a deterministic `stripInvisible()` sanitizer at the MCP raw-inbox ingest chokepoint so all captured bodies are cleaned before they are stored (and later auto-injected). Independently, scope the consolidation agents' `Bash(node *)` grant down to the only Node they actually invoke — the plugin's own bundled CLIs under `mcp/dist/` — and add a source-scan regression test that fails if any consolidation agent ever re-introduces an unscoped `node` grant.

**Tech Stack:** TypeScript (MCP server, bundled with esbuild, tested with vitest); Markdown agent definitions with a `tools:` frontmatter allowlist; bash hook/test harness (`tests/run-all.sh`).

This plan is **P6a** — the quick-wins slice of spec workstream **P6** (`docs/superpowers/specs/2026-06-26-second-brain-constitution-and-diet-design.md` §6). The larger **P6b** (quarantine/dual-LLM drainer split; bash transcript-archive sanitization with a cross-platform astral-codepoint stripper; `wiki-write-guard.sh` path canonicalization; consolidation network-sandbox) is a separate follow-up plan. The tool-return injection scanner needs **no change** — it is already advisory (`exit 0`, never blocks) and is documented as telemetry-only in `CONSTITUTION.md`.

## Global Constraints

- **Version lockstep:** any shipped change bumps the version in `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and adds a `CHANGELOG.md` entry — in the same commit. Current version: `0.33.19` → target `0.33.20`.
- **Cross-platform:** must work on macOS, Windows (git-bash/MSYS), Linux (+ BSD CI). No new runtime dependency. The sanitizer is pure JS (no native/`perl` dep).
- **Surface-budget ratchet:** adding test files is fine; do not add new skills/agents/scripts without a `docs/surface-budget.json` bump. This plan adds one test file — verify it does not trip the gate in Task 3 (tests are not part of the skill/agent/script counts; if the gate counts it, bump the baseline in the same commit).
- **Bundled-CLI grants only:** consolidation agents may run Node *only* via `Bash(node ${CLAUDE_PLUGIN_ROOT}/mcp/dist/*)`; never unscoped `Bash(node *)`.
- **Preserve emoji/script joiners:** the sanitizer strips unambiguous invisibles (Unicode Tags block, ZWSP, BOM, word-joiner) but MUST preserve U+200C/U+200D (ZWNJ/ZWJ used by scripts and emoji sequences). All code blocks use `\u` escapes — never paste literal invisible characters into source.

---

### Task 1: Invisible-character sanitizer at raw-inbox ingest

**Files:**
- Modify: `mcp/src/tools/raw-inbox.ts` (add `stripInvisible()`; apply to `body` and `gist` in `captureItem()`)
- Test: `mcp/src/tools/raw-inbox.test.ts` (existing file — add a `describe('stripInvisible')` block)

**Interfaces:**
- Produces: `export function stripInvisible(s: string): string` — removes the Unicode Tags block (U+E0000–U+E007F), ZERO WIDTH SPACE (U+200B), WORD JOINER (U+2060), and BOM/ZWNBSP (U+FEFF); leaves all other characters (incl. U+200C/U+200D) untouched. Idempotent; returns `''` for `''`.
- Consumes (Task 1 internal): `captureItem()` already computes `body` (the resolved item text) and `gist` (first non-empty line) — see `raw-inbox.ts` `captureItem()`.

- [ ] **Step 1: Write the failing test**

Add to `mcp/src/tools/raw-inbox.test.ts` (match the file's existing vitest imports — `import { describe, it, expect } from 'vitest'`; add `stripInvisible` to the existing import from `./raw-inbox.js`):

```typescript
describe('stripInvisible', () => {
  it('removes the Unicode Tags block (ASCII-smuggling channel)', () => {
    // U+E0041 is TAG LATIN CAPITAL LETTER A — invisible, decodes to "A" for the model.
    const smuggled = 'hello\u{E0041}\u{E0042}world';
    expect(stripInvisible(smuggled)).toBe('helloworld');
  });

  it('removes zero-width space, word joiner, and BOM', () => {
    // Build from codepoints so the source stays pure-ASCII and reviewable.
    const dirty = 'a' + String.fromCodePoint(0x200B) + 'b'
      + String.fromCodePoint(0x2060) + 'c' + String.fromCodePoint(0xFEFF) + 'd';
    expect(stripInvisible(dirty)).toBe('abcd');
  });

  it('preserves ZWNJ/ZWJ used by scripts and emoji sequences', () => {
    // U+200D joins the family emoji; stripping it would corrupt legitimate text.
    const family = String.fromCodePoint(0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467);
    expect(stripInvisible(family)).toBe(family);
  });

  it('is idempotent and handles empty input', () => {
    expect(stripInvisible('')).toBe('');
    const once = stripInvisible('x' + String.fromCodePoint(0x200B) + 'y');
    expect(stripInvisible(once)).toBe(once);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npx vitest run src/tools/raw-inbox.test.ts -t stripInvisible`
Expected: FAIL — `stripInvisible is not a function` / not exported.

- [ ] **Step 3: Add the implementation**

In `mcp/src/tools/raw-inbox.ts`, add near the top-level helpers (beside `serialize`):

```typescript
// Strip invisible characters that can smuggle hidden instructions into stored
// memory (later auto-injected): the Unicode Tags block decodes to ASCII for the
// model while rendering invisibly, and zero-width spaces/BOM/word-joiner hide
// token boundaries. We deliberately KEEP U+200C/U+200D (ZWNJ/ZWJ) — they are
// load-bearing in many scripts and in emoji ZWJ sequences. See spec P6 /
// wiki/learnings/claude-agent-architecture-deep-2026-06.
const INVISIBLE_RE = /[\u{200B}\u{2060}\u{FEFF}\u{E0000}-\u{E007F}]/gu;
export function stripInvisible(s: string): string {
  return s.replace(INVISIBLE_RE, '');
}
```

Then, in `captureItem()`, sanitize the resolved `body` immediately after the `if (input.kind === 'paste') { … } else { … }` block sets it (before `const hash = …`), and sanitize `gist` where it is computed:

```typescript
  // ...end of the kind-resolution if/else that assigns `body`...
  body = stripInvisible(body);
  // ...existing: const hash = hashContent(hashInput);  (unchanged)
```

```typescript
  const gist = stripInvisible(
    gistSeed.replace(/^#\s*/, '').split('\n').map(l => l.trim()).find(Boolean)?.slice(0, 120) ?? ''
  );
```

- [ ] **Step 4: Run the unit test to verify it passes**

Run: `cd mcp && npx vitest run src/tools/raw-inbox.test.ts -t stripInvisible`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full raw-inbox suite to verify no regression**

Run: `cd mcp && npx vitest run src/tools/raw-inbox.test.ts`
Expected: PASS (all pre-existing capture/dedup tests still green — `body`/`gist` are unchanged for clean input because `stripInvisible` is a no-op on text without invisibles).

- [ ] **Step 6: Commit**

```bash
git add mcp/src/tools/raw-inbox.ts mcp/src/tools/raw-inbox.test.ts
git commit -m "feat(security): strip invisible/Tags-block chars at raw-inbox ingest (P6a)"
```

---

### Task 2: Scope the consolidation agents' `node` grant + source-scan guard

**Files:**
- Modify: `agents/raw-drainer.md` (frontmatter `tools:` line — the `Bash(node *)` token)
- Modify: `agents/knowledge-maintainer.md` (frontmatter `tools:` line — the `Bash(node *)` token)
- Test: `mcp/src/agent-grants.test.ts` (Create — source-scan regression guard)

**Interfaces:**
- Consumes: the three consolidation agent definition files at repo-root `agents/`. `dream-runner.md` already has **no** `Bash(node *)` grant — leave it unchanged; the guard still asserts it stays clean.
- Produces: a vitest source-scan that reads each consolidation agent `.md` and asserts the literal substring `Bash(node *)` is absent and (for the two that need Node) the scoped `Bash(node ${CLAUDE_PLUGIN_ROOT}/mcp/dist/*)` form is present.

Background (verified): both `raw-drainer` and `knowledge-maintainer` invoke Node only as `node "$CLAUDE_PLUGIN_ROOT/mcp/dist/tools/{raw-capture-cli,ai-block-render-cli}.bundle.js"`. Scoping the grant to `mcp/dist/*` preserves every real call and removes arbitrary-Node execution.

- [ ] **Step 1: Write the failing test**

Create `mcp/src/agent-grants.test.ts`:

```typescript
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';

// repo-root/agents from mcp/src/
const agentsDir = fileURLToPath(new URL('../../agents/', import.meta.url));
const read = (f: string) => readFileSync(agentsDir + f, 'utf-8');

const NODE_USERS = ['raw-drainer.md', 'knowledge-maintainer.md'];
const ALL = [...NODE_USERS, 'dream-runner.md'];

describe('consolidation agent grants (P6a least-privilege)', () => {
  it('no consolidation agent grants unscoped Bash(node *)', () => {
    const offenders = ALL.filter(f => read(f).includes('Bash(node *)'));
    expect(offenders, `unscoped node grant in: ${offenders.join(', ')}`).toEqual([]);
  });

  it('Node-using agents grant only the scoped bundled-CLI form', () => {
    for (const f of NODE_USERS) {
      expect(read(f), `${f} missing scoped node grant`)
        .toContain('Bash(node ${CLAUDE_PLUGIN_ROOT}/mcp/dist/*)');
    }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp && npx vitest run src/agent-grants.test.ts`
Expected: FAIL — both agents still contain `Bash(node *)` and lack the scoped form.

- [ ] **Step 3: Scope the grant in both agent files**

In `agents/raw-drainer.md` and `agents/knowledge-maintainer.md`, in the single-line `tools:` frontmatter value, replace the token `Bash(node *)` with `Bash(node ${CLAUDE_PLUGIN_ROOT}/mcp/dist/*)`. Change only that one token; leave every other grant (including `Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)`, `Bash(rm *)`, `Bash(mv *)`, `Bash(cp *)`) untouched.

- [ ] **Step 4: Run the guard to verify it passes**

Run: `cd mcp && npx vitest run src/agent-grants.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Sanity-check the agent bodies still match their grant**

Run: `grep -n 'node "\$CLAUDE_PLUGIN_ROOT' agents/raw-drainer.md agents/knowledge-maintainer.md`
Expected: every `node` invocation targets `$CLAUDE_PLUGIN_ROOT/mcp/dist/...` (covered by the scoped grant). If any invocation targets a path outside `mcp/dist/`, STOP — widen the scope minimally to cover it (e.g. `mcp/dist/`), do not revert to `node *`.

- [ ] **Step 6: Commit**

```bash
git add agents/raw-drainer.md agents/knowledge-maintainer.md mcp/src/agent-grants.test.ts
git commit -m "feat(security): scope consolidation agents' node grant to bundled CLIs + source-scan guard (P6a)"
```

---

### Task 3: Rebundle, version bump, and run the CI gates

**Files:**
- Modify: `.claude-plugin/plugin.json` (`version`)
- Modify: `.claude-plugin/marketplace.json` (the `second-brain` plugin `version`)
- Modify: `CHANGELOG.md` (new top entry)
- Modify: `mcp/dist/**` (regenerated bundles — `raw-inbox.ts` is imported by `server.ts` and `raw-capture-cli.ts`, both bundled)

**Interfaces:** none (release task).

- [ ] **Step 1: Rebuild the MCP bundles**

Run: `cd mcp && npm run build`
Expected: `tsc --noEmit` passes with no type errors, then esbuild regenerates `dist/server.bundle.js` and the CLI bundles (which now embed the sanitized `raw-inbox.ts`). No errors.

- [ ] **Step 2: Bump the version in lockstep**

Set `version` to `0.33.20` in `.claude-plugin/plugin.json` and in the `second-brain` entry of `.claude-plugin/marketplace.json`. Add a `CHANGELOG.md` entry at the top:

```markdown
## 0.33.20 — P6a security hardening quick-wins

- Strip invisible Unicode (Tags block, ZWSP, BOM, word-joiner) from captured content at the
  raw-inbox ingest chokepoint — closes the ASCII-smuggling path into auto-injected memory.
  (Preserves U+200C/U+200D for script/emoji correctness.)
- Scope the raw-drainer + knowledge-maintainer `node` grant from `Bash(node *)` to
  `Bash(node ${CLAUDE_PLUGIN_ROOT}/mcp/dist/*)` (bundled CLIs only) — removes arbitrary-Node
  execution on untrusted transcript content. Guarded by a source-scan regression test.
```

- [ ] **Step 3: Run the full local gate suite (the user's required pre-push gates)**

Run: `cd mcp && npm ci && npm test`
Expected: full vitest suite green (including the two new tests).

Run: `bash scripts/validate-plugin.sh`
Expected: PASS — bundle-drift check passes (dist is freshly built), version lockstep consistent across plugin.json/marketplace.json, surface-budget ratchet not exceeded.

Run: `bash tests/run-all.sh`
Expected: all shell tests + vitest green.

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json CHANGELOG.md mcp/dist
git commit -m "release: 0.33.20 — P6a security hardening (invisible-char strip + scoped node grant)"
```

---

## Verification (end-to-end)

1. **Sanitizer:** `cd mcp && npx vitest run src/tools/raw-inbox.test.ts` — green; smuggled Tags-block input is stripped, emoji ZWJ preserved.
2. **Grant scope:** `cd mcp && npx vitest run src/agent-grants.test.ts` — green; no agent grants `Bash(node *)`.
3. **Manual ingest check:** capture a paste containing a Tags-block char (e.g. via the raw-capture CLI), then read the stored `~/.second-brain/projects/<slug>/raw/<id>.md` and confirm the invisible char is gone from the body.
4. **Gates:** `bash scripts/validate-plugin.sh` and `bash tests/run-all.sh` both green; version `0.33.20` consistent across the three files.

## Done in P6a (incl. adversarial-review follow-up, commit 62e1c42)

- Invisible-char strip (Tags-block + ZWSP/WJ/BOM) on the raw-inbox **write AND read** paths
  (`serialize()` + `parse()`), covering legacy/dedup'd items, applied to body, gist, and all
  free-text frontmatter (source/origin/target_node).
- Scoped node grant on the consolidation agents + a directory-walked + body-scan grant guard.
- Honest, scoped claims in CHANGELOG + code comments.

## Out of scope (deferred to P6b) — incl. items the P6a adversarial review surfaced

- **Transcript ingest sanitization** — `scripts/lib.sh` `sb_archive_transcript()` (the MAIN,
  automatic vector — not just `sb_archive_subagent_result()`) writes untrusted session text verbatim
  into `transcripts/*.txt`, which dream mines into auto-injected wiki pages. This is the DOMINANT
  un-sanitized path; needs a cross-platform astral-codepoint stripper (no `perl` dep).
- **Broader invisible channels** — bidi controls (U+202A–202E, U+2066–2069, U+200E/F — Trojan-Source)
  and variation selectors (U+E0100–E01EF), with deliberate handling of legitimate RTL text and emoji
  variation selectors (U+FE0F must be preserved).
- **Quarantine/dual-LLM split** of the drainer (quarantined summarizer → privileged writer).
- **Write-scoping** — `Bash(rm/mv/cp/touch *)` + `Write`/`Edit` are unscoped, so the node-grant
  scoping is defense-in-depth, not containment (an injected agent could write a `.js` into `mcp/dist`
  then run it). Needs sandboxing or path-scoped write grants.
- `wiki-write-guard.sh` path canonicalization (currently string-glob; junction/`\\?\`/symlink hardening).
- Severing network egress during consolidation (sandbox/deny proxy).
- **One-time live-drain smoke check** confirming the scoped node grant executes without a permission
  prompt (the matcher can't be unit-tested from source; structurally proven-analogous to the shipped
  `Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*)` grant, but unverified at runtime).
